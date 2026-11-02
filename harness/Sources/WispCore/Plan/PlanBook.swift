import Foundation
import Synchronization

/// One conversation's live plan, shared by its `plan` tool, which the framework calls from its own task, and its
/// agent, which saves it with the record when each turn ends and roots the trees the turn began
/// ([ADR 0081](../../../../docs/decisions/0081-the-plan-tool.md)). Changes go through `change`, one at a time.
///
/// A `final class` with a `Mutex`, since every operation is a short synchronous critical section (`docs/design.md`,
/// "Concurrency"); a change is a pure function of the plan run inside the lock, so a failed one leaves nothing half
/// applied.
public final class PlanBook: Sendable {
    /// The plan, and what the turn under way did to it.
    struct State: Sendable {
        /// The plan.
        var plan = Plan()
        /// The tree the turn under way rooted, which a task added without a parent joins.
        var current: Int?
        /// Whether the turn under way changed the plan.
        var changed = false
        /// Whether the turn under way marked a task (`update`).
        var marked = false
        /// The turn's calls made while no single task was running, oldest first, at most `Plan.callsPerTask`, for the
        /// next task settled (ADR 0079, decision 21).
        var held: [Plan.Call] = []
        /// Calls held this turn and let go past the bound, counted on the task that takes the rest.
        var heldDropped = 0
        /// The changes from outside the model's turns that the turn under way tells it of, taken as it began.
        var told: [String] = []
    }

    /// The state, behind a lock.
    private let state = Mutex(State())

    /// Whether later turns' lines name each tree's next task (`PlanText.reference`'s `next`), a variant under
    /// measurement by the plan probe; off everywhere wisp opens a book.
    let namesNext: Bool

    /// Whether other tools' results carry `PlanText.nudge` while a task is open and none was marked this turn
    /// (ADR 0081, decision 12); on wherever wisp opens a book, off for the plan probe's variants without it.
    let reminds: Bool

    /// An empty book.
    ///
    /// - Parameters:
    ///   - namesNext: Whether later turns' lines name each tree's next task.
    ///   - reminds: Whether other tools' results carry the reminder to mark a task.
    public init(namesNext: Bool = false, reminds: Bool = true) {
        self.namesNext = namesNext
        self.reminds = reminds
    }

    /// The line to append to another tool's result: the reminder to mark the running or next task, when the book
    /// reminds, a task is running or ready, and the turn has marked none.
    ///
    /// - Returns: The line, or nil.
    public func reminder() -> String? {
        guard reminds else { return nil }
        return state.withLock { $0.marked ? nil : PlanText.nudge($0.plan) }
    }

    /// The plan as it stands.
    public var plan: Plan { state.withLock { $0.plan } }

    /// Whether the turn under way changed the plan.
    public var changedThisTurn: Bool { state.withLock { $0.changed } }

    /// Takes `plan` as the book's when the book holds none: a resumed conversation's, or the record an agent took
    /// over. A book with a plan keeps it, since it is the newer.
    ///
    /// - Parameter plan: The plan saved with the record.
    func seed(_ plan: Plan) {
        state.withLock { state in
            if state.plan.isEmpty { state.plan = plan }
        }
    }

    /// Empties the book, for a conversation started afresh (`/new`).
    func reset() { state.withLock { $0 = State() } }

    /// Marks the start of a turn: no tree rooted yet, nothing changed, no call held, and the changes made since the last
    /// turn from outside it taken from the plan for this one's requests to tell (ADR 0079, decision 22).
    func beginTurn() {
        state.withLock { state in
            (state.plan, state.told) = state.plan.takingUntold()
            state.current = nil
            state.changed = false
            state.marked = false
            state.held = []
            state.heldDropped = 0
        }
    }

    /// Keeps `line` for the next turn to tell the model: a change that could not be made, which is still news to it.
    ///
    /// - Parameter line: The line, naming who made the change.
    func tell(_ line: String) { state.withLock { $0.plan.tellModel(line) } }

    /// Sets the task the question is taken to be about `waiting` on question `id`, when the model asks the person
    /// something (ADR 0079, decision 24): the one running, else the first ready.
    ///
    /// - Parameters:
    ///   - id: The question's id.
    ///   - now: The time.
    /// - Returns: The task that waits, or nil when several were running or none was running or ready.
    func wait(on id: String, now: Date = Date()) -> String? {
        state.withLock { state in
            let (plan, task) = state.plan.waiting(on: id, now: now)
            state.plan = plan
            return task
        }
    }

    /// Sets the task waiting on question `id` running again, with `note` saying how it ended (decision 24).
    ///
    /// - Parameters:
    ///   - id: The question's id.
    ///   - note: How it ended.
    ///   - now: The time.
    /// - Returns: The task running again, or nil when none was waiting on it.
    func resume(after id: String, note: String, now: Date = Date()) -> String? {
        state.withLock { state in
            let (plan, task) = state.plan.resuming(after: id, note: note, now: now)
            state.plan = plan
            return task
        }
    }

    /// The changes from outside the model's turns that the turn under way tells it of.
    var told: [String] { state.withLock { $0.told } }

    /// Applies a change the person or the caller made (ADR 0079, decision 22), kept in the plan for the next turn to
    /// tell the model.
    ///
    /// - Parameters:
    ///   - edit: The change.
    ///   - by: Who made it.
    ///   - lastPrompt: The store id of the conversation's last prompt, for a tree a task added to an empty plan roots.
    ///   - now: The time.
    /// - Returns: What it gave.
    /// - Throws: `Plan.Failure`, with the plan unchanged.
    func apply(_ edit: PlanEdit, by: PlanEdit.Changer, lastPrompt: Int?, now: Date) throws -> PlanEdit.Applied {
        try state.withLock { state in
            let applied = try edit.apply(to: state.plan, by: by, lastPrompt: lastPrompt, now: now)
            state.plan = applied.plan
            return applied
        }
    }

    /// The one task running, whose work a call made now is; nil when none or several are, and the call is held.
    ///
    /// - Returns: The task's id, or nil.
    public func runningTask() -> String? { state.withLock { $0.plan.soleRunning?.id } }

    /// Links a finished call to the task that was running when it was made, or holds it for the next task settled
    /// this turn when none was, or that task has gone (ADR 0079, decision 21). Linking is not a change the turn made
    /// to the plan: it is saved with the plan, but `respond` does not report the plan for it.
    ///
    /// - Parameters:
    ///   - call: The call.
    ///   - task: What ``runningTask()`` said when the call was made.
    public func link(_ call: Plan.Call, to task: String?) {
        state.withLock { state in
            if let task, state.plan.task(task) != nil {
                state.plan = state.plan.linking([call], to: task)
                return
            }
            state.held.append(call)
            if state.held.count > Plan.callsPerTask {
                state.held.removeFirst()
                state.heldDropped += 1
            }
        }
    }

    /// Updates a task's status or note, and, when the update settles it (`done`, `failed`, `skipped`), links to it
    /// the calls held this turn, in one critical section, so no call is held or linked between the two.
    ///
    /// - Parameters:
    ///   - id: The task.
    ///   - status: Its new status; nil keeps it.
    ///   - note: Its new note; nil or empty keeps it.
    ///   - now: The time.
    /// - Returns: The plan, and the calls linked.
    /// - Throws: `Plan.Failure`, with the plan and the held calls unchanged.
    func update(
        _ id: String, status: Plan.Status?, note: String?, now: Date
    ) throws -> (plan: Plan, linked: [Plan.Call]) {
        try state.withLock { state in
            var plan = try state.plan.updating(id, status: status, note: note, now: now)
            var linked: [Plan.Call] = []
            if let status, status.isSettled {
                linked = state.held
                plan = plan.linking(linked, to: id, dropped: state.heldDropped)
                state.held = []
                state.heldDropped = 0
            }
            state.plan = plan
            state.changed = true
            if status != nil { state.marked = true }
            return (plan, linked)
        }
    }

    /// Ends the turn: the tree it rooted, if any, is rooted at `entry`, its prompt's store id.
    ///
    /// - Parameter entry: The turn's prompt in the store; nil leaves the tree unrooted.
    /// - Returns: The plan, to save with the record.
    func endTurn(promptEntry entry: Int?) -> Plan {
        state.withLock { state in
            if let current = state.current, let entry { state.plan = state.plan.rooting(current, at: entry) }
            state.current = nil
            return state.plan
        }
    }

    /// Applies one change: `body` gets the plan and the turn's tree, and returns the new plan, the turn's tree, and
    /// what the caller wants back; the plan changes only when `body` returns.
    ///
    /// - Parameter body: The change.
    /// - Returns: What `body` returned.
    /// - Throws: What `body` threw, with the plan unchanged.
    func change<Result: Sendable>(
        _ body: (Plan, Int?) throws -> (plan: Plan, current: Int?, result: Result)
    ) throws -> Result {
        try state.withLock { state in
            let outcome = try body(state.plan, state.current)
            state.plan = outcome.plan
            state.current = outcome.current
            state.changed = true
            return outcome.result
        }
    }
}
