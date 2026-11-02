import Foundation

/// A change made to a conversation's plan from outside the model's turns
/// ([ADR 0079](../../../../docs/decisions/0079-the-conversation-as-a-spine-with-task-trees.md), decision 22): by the
/// person, from chat's `/plan` or `wisp threads plan` in a terminal, or by an MCP caller, with `change_plan`. It marks a
/// task done, skips it, reopens it, or adds one. Changes keep the model's limits and checks, except that the person may
/// mark a task done while one it depends on is not, knowing it done some other way; the caller may not. Each is told to
/// the model at the thread's next turn as a line in the now block naming who made it (`Plan.untold`), not as a turn of
/// its own.
public enum PlanEdit: Codable, Equatable, Sendable {
    /// Mark a task done, with a note or none.
    case done(String, note: String?)
    /// Mark a task skipped.
    case skip(String, note: String?)
    /// Set a settled or running task back to pending.
    case reopen(String, note: String?)
    /// Add a task: under a task or at the top of a tree (`under`), or at the top of the newest tree; after tasks.
    case add(goal: String, under: String?, after: [String])

    /// The verbs, as the person types them.
    public static let verbs = ["done", "skip", "reopen", "add"]

    /// Who made a change: the person, or an MCP caller, an agent.
    public enum Changer: String, Codable, Sendable {
        /// The person, from chat or a terminal.
        case person
        /// The MCP client that opened the thread, through `change_plan`.
        case caller
    }

    /// The change as the words that spell it, which `parse` reads back: for a queued change's audit and messages.
    public var words: String {
        switch self {
        case .done(let id, let note): (["done", id] + (note.map { [$0] } ?? [])).joined(separator: " ")
        case .skip(let id, let note): (["skip", id] + (note.map { [$0] } ?? [])).joined(separator: " ")
        case .reopen(let id, let note): (["reopen", id] + (note.map { [$0] } ?? [])).joined(separator: " ")
        case .add(let goal, let under, let after):
            (["add", goal] + (under.map { ["under", $0] } ?? [])
                + (after.isEmpty ? [] : ["after", after.joined(separator: ",")])).joined(separator: " ")
        }
    }

    /// Why a change could not be read.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The verb needs a task, or a goal, that was left out.
        case missing(String, verb: String)

        /// The failure as the person reads it.
        public var description: String {
            switch self {
            case .missing(let what, let verb): "plan \(verb) needs \(what)"
            }
        }
    }

    /// The change `words` spell, or nil when the first is not one of `verbs`, which leaves them a view (`t1`, `t1.2`).
    ///
    /// `done`, `skip`, and `reopen` take a task and an optional note, the rest of the words. `add` takes a goal and,
    /// at its end, `under ID` and `after ID[,ID…]` in either order.
    ///
    /// - Parameter words: The words after `plan`.
    /// - Returns: The change, or nil.
    /// - Throws: `Failure` when the verb lacks what it needs.
    public static func parse(_ words: [String]) throws(Failure) -> PlanEdit? {
        guard let verb = words.first?.lowercased(), verbs.contains(verb) else { return nil }
        var rest = Array(words.dropFirst())
        if verb == "add" {
            var under: String?
            var after: [String] = []
            while rest.count >= 2, ["under", "after"].contains(rest[rest.count - 2].lowercased()) {
                let value = rest.removeLast()
                if rest.removeLast().lowercased() == "under" {
                    under = value
                } else {
                    after =
                        value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty } + after
                }
            }
            let goal = rest.joined(separator: " ")
            guard !goal.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missing("a goal", verb: verb) }
            return .add(goal: goal, under: under, after: after)
        }
        guard let id = rest.first else { throw .missing("a task, such as t1.2", verb: verb) }
        let note = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let given = note.isEmpty ? nil : note
        switch verb {
        case "done": return .done(id, note: given)
        case "skip": return .skip(id, note: given)
        default: return .reopen(id, note: given)
        }
    }

    /// What applying a change gave: the plan, the line told to the person and later to the model, and the audit
    /// event to record.
    public struct Applied: Equatable, Sendable {
        /// The plan after the change, the line added to its `untold`.
        public var plan: Plan
        /// The change in one line, as the person and the model read it: `t1.2 skipped: not needed`.
        public var line: String
        /// `plan.update` or `plan.add`.
        public var kind: AuditEvent.Kind
        /// Its details, with `by`.
        public var details: [String: JSONValue]
    }

    /// Applies the change to `plan`.
    ///
    /// - Parameters:
    ///   - plan: The plan.
    ///   - by: Who made it: the person may mark a task done while one it depends on is not; the caller may not.
    ///   - lastPrompt: The store id of the conversation's last prompt, at which a task added to an empty plan roots
    ///     its tree; nil leaves the tree unrooted until a turn ends.
    ///   - now: The time.
    /// - Returns: What it gave.
    /// - Throws: `Plan.Failure`, with the plan unchanged.
    public func apply(to plan: Plan, by: Changer, lastPrompt: Int?, now: Date) throws(Plan.Failure) -> Applied {
        switch self {
        case .done(let id, let note), .skip(let id, let note), .reopen(let id, let note):
            let status: Plan.Status =
                switch self {
                case .done: .done
                case .skip: .skipped
                default: .pending
                }
            var changed = try plan.updating(id, status: status, note: note, now: now, byPerson: by == .person)
            let said =
                ["done": "done", "skipped": "skipped", "pending": "reopened"][status.rawValue] ?? status.rawValue
            let line = "\(id) \(said)" + (note.map { ": \($0)" } ?? "")
            changed.tellModel("the \(by.rawValue): \(line)")
            return Applied(
                plan: changed, line: line, kind: .planUpdate,
                details: [
                    "task": .string(id), "status": .string(status.rawValue),
                    "note": changed.task(id)?.note.map { .string($0) } ?? .null, "by": .string(by.rawValue),
                ])
        case .add(let goal, let under, let after):
            // Without `under`, the task goes at the top of the newest tree, the work the conversation is on; into an
            // empty plan, at the top of a new tree rooted at the last prompt.
            let newest = plan.trees.last?.id
            let added = try plan.adding(
                goal: goal, parent: under ?? newest.map { "t\($0)" }, dependsOn: after, currentTree: nil, now: now)
            var changed = added.plan
            if newest == nil, let tree = added.currentTree, let lastPrompt {
                changed = changed.rooting(tree, at: lastPrompt)
            }
            let task = added.task
            let line =
                "added \(task.id) \(task.goal)"
                + (task.dependsOn.isEmpty ? "" : " (after \(task.dependsOn.joined(separator: ", ")))")
            changed.tellModel("the \(by.rawValue): \(line)")
            return Applied(
                plan: changed, line: line, kind: .planAdd,
                details: [
                    "task": .string(task.id), "tree": .string("t\(task.tree)"),
                    "parent": task.parent.map { .string($0) } ?? .null, "goal": .string(task.goal),
                    "dependsOn": .array(task.dependsOn.map { .string($0) }), "by": .string(by.rawValue),
                ])
        }
    }
}
