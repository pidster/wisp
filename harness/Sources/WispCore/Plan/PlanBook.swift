import Foundation
import Synchronization

/// One conversation's live plan, shared by its `plan` tool, which the framework calls from its own task, and its
/// agent, which saves it with the record when each turn ends and roots the trees the turn began
/// ([ADR 0081](../../../../docs/decisions/0081-the-plan-tool.md)). Changes go through `change`, one at a time.
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

    /// Records that the turn under way marked a task, which quiets the reminder until the next turn.
    func noteMarked() { state.withLock { $0.marked = true } }

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

    /// Marks the start of a turn: no tree rooted yet, nothing changed.
    func beginTurn() {
        state.withLock { state in
            state.current = nil
            state.changed = false
            state.marked = false
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
