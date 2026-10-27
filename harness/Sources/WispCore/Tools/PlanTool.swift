import Foundation
import FoundationModels

/// The conversation's plan, for the model to build, track, and search
/// ([ADR 0081](../../../../docs/decisions/0081-the-plan-tool.md)): trees of tasks with dependencies, each tree rooted at
/// the turn that began it, kept with the thread across turns and resumes. It records and reads; it runs nothing. Off by
/// default: a conversation given every tool gets it with `tools.plan` on, or by naming it.
public struct PlanTool: WispTool {
    /// The tool's name, as registries and the prompt name it.
    public static let toolName = "plan"

    /// The identifier the model uses to request this tool.
    public let name = PlanTool.toolName
    /// What the model is told this tool does.
    public let description =
        "The conversation's plan: tasks with dependencies, kept across turns. For work of several steps, add the "
        + "tasks first, then mark each running, done, failed, or skipped as you go, with a note of what you found. "
        + "It records; it runs nothing."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The action.
        @Guide(description: "One of: tree, show, ready, find, add, depend, update.")
        public var action: String
        /// The task or tree acted on.
        @Guide(
            description:
                "A task such as t1.2 (show, depend, update; for add, a name for the new task), or a tree such as t1 "
                + "(tree, find).")
        public var id: String?
        /// For add: what the task is for.
        @Guide(description: "For add: what the task is for, in a short sentence.")
        public var goal: String?
        /// For add: where it goes.
        @Guide(description: "For add: the task it goes under, or a tree such as t1; leave out for this turn's tree.")
        public var parent: String?
        /// For add and depend: tasks it waits for; for find, tasks that wait for this one.
        @Guide(
            description:
                "For add and depend: tasks it waits for, such as t1.1. For find: one task; finds its dependents.")
        public var dependsOn: [String]?
        /// For update and find: a status.
        @Guide(description: "For update: running, done, failed, skipped, or pending. For find: those, or ready.")
        public var status: String?
        /// For update: what the model found, or why.
        @Guide(description: "For update: what you found, or why it failed or was skipped; short.")
        public var note: String?
        /// For find: text in a goal or note.
        @Guide(description: "For find: text to look for in goals and notes.")
        public var text: String?
        /// The page of a long result, from 1.
        @Guide(description: "The page of a long result, from 1.")
        public var page: Int?
    }

    /// The lines a page of a result holds.
    static let pageLines = 40

    /// The conversation's plan.
    let book: PlanBook
    /// The conversation's log, for `plan.add`, `plan.depend`, and `plan.update`.
    private let audit: AuditLog?
    /// The tool-output budget every result is fitted to.
    private let budget: ToolBudget
    /// Where a result larger than the budget is kept whole.
    private let store: OutputStore?

    /// What bounds it.
    public var limits: String {
        "At most \(Plan.tasksPerTree) tasks a tree, \(Plan.tasksPerPlan) in the plan, \(Plan.depthLimit) deep, "
            + "\(Plan.dependencyLimit) dependencies a task; a goal up to \(Plan.goalLimit) characters, a note up to "
            + "\(Plan.noteLimit). A result pages \(Self.pageLines) lines. Records only: nothing in the plan runs. Off by "
            + "default: a conversation gets it with tools.plan on, or by naming it."
    }
    /// How to ask for it.
    public let examplePrompt =
        "Use plan to add three tasks, check the disk, list the largest folders, and report, the second depending on "
        + "the first, then show the tree."

    /// Creates the tool.
    ///
    /// - Parameters:
    ///   - book: The conversation's plan; a fresh one by default (a catalogue).
    ///   - audit: The conversation's log.
    ///   - budget: The tool-output budget.
    ///   - store: The output store.
    public init(
        book: PlanBook = PlanBook(), audit: AuditLog? = nil, budget: ToolBudget = ToolBudget(),
        store: OutputStore? = nil
    ) {
        self.book = book
        self.audit = audit
        self.budget = budget
        self.store = store
    }

    /// Runs one action.
    ///
    /// - Parameter arguments: The action and its arguments.
    /// - Returns: The result, or `error: …` saying what to correct; never throws.
    public func call(arguments: Arguments) async -> String {
        let text: String
        do {
            text = try run(arguments, now: Date())
        } catch {
            return "error: \(error)"
        }
        return ToolOutput.fitted(text, tool: name, budget: budget, store: store)
    }

    /// Runs one action against the book.
    ///
    /// - Parameters:
    ///   - arguments: The action and its arguments.
    ///   - now: The time.
    /// - Returns: The result.
    /// - Throws: `Plan.Failure`, or `Refusal` for a call missing what its action needs.
    func run(_ arguments: Arguments, now: Date) throws -> String {
        let action = arguments.action.trimmingCharacters(in: .whitespaces).lowercased()
        let id = arguments.id?.trimmingCharacters(in: .whitespaces).nonEmpty
        switch action {
        case "tree":
            let plan = book.plan
            guard let id else { return paged(PlanText.trees(plan), page: arguments.page, action: "tree") }
            guard let tree = plan.tree(named: id) ?? plan.task(id).flatMap({ plan.tree($0.tree) }) else {
                throw Plan.Failure.unknown(id)
            }
            return paged(PlanText.outline(tree, in: plan), page: arguments.page, action: "tree \(tree.name)")
        case "show":
            let plan = book.plan
            guard let id else { throw Refusal.missing("id", action: action) }
            guard let task = plan.task(id) else {
                // A tree's id, as a small model sends (2026-10-25), shows the tree rather than refusing it.
                guard let tree = plan.tree(named: id) else { throw Plan.Failure.unknown(id) }
                return paged(PlanText.outline(tree, in: plan), page: arguments.page, action: "tree \(tree.name)")
            }
            return PlanText.detail(task, in: plan).joined(separator: "\n")
        case "ready":
            let plan = book.plan
            let ready = plan.ready.map { PlanText.line($0, in: plan) }
            return ready.isEmpty
                ? "nothing is ready: \(plan.isEmpty ? "the plan is empty" : "every pending task waits on another")"
                : paged(ready, page: arguments.page, action: "ready")
        case "find":
            return try find(arguments, id: id)
        case "add":
            return try add(arguments, now: now)
        case "depend":
            guard let id else { throw Refusal.missing("id", action: action) }
            let on = Plan.distinct(arguments.dependsOn ?? [])
            guard !on.isEmpty else { throw Refusal.missing("dependsOn", action: action) }
            try book.change { plan, current in
                var changed = plan
                for other in on { changed = try changed.depending(id, on: other, now: now) }
                return (changed, current, ())
            }
            audit?.record(
                .planDepend, details: ["task": .string(id), "dependsOn": .array(on.map { .string($0) })])
            return "\(id) now waits for \(on.joined(separator: ", "))"
        case "update":
            guard let id else { throw Refusal.missing("id", action: action) }
            guard let raw = arguments.status?.trimmingCharacters(in: .whitespaces).lowercased(),
                let status = Plan.Status(rawValue: raw)
            else { throw Refusal.badStatus(arguments.status, allowingReady: false) }
            let plan = try book.change { plan, current in
                let changed = try plan.updating(id, status: status, note: arguments.note, now: now)
                return (changed, current, changed)
            }
            book.noteMarked()
            audit?.record(
                .planUpdate,
                details: [
                    "task": .string(id), "status": .string(status.rawValue),
                    "note": plan.task(id)?.note.map { .string($0) } ?? .null,
                ])
            var lines = [plan.task(id).map { PlanText.line($0, in: plan) } ?? id]
            let freed = plan.dependents(of: id).filter(plan.isReady)
            if status == .done, !freed.isEmpty {
                lines.append("now ready: \(freed.map(\.id).joined(separator: ", "))")
            }
            let stopped = plan.dependents(of: id).filter { $0.status == .pending }
            if status == .failed || status == .skipped, !stopped.isEmpty {
                lines.append(
                    "cannot go on while this is \(status.rawValue): \(stopped.map(\.id).joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        default:
            throw Refusal.unknownAction(arguments.action)
        }
    }

    /// `add`: one task, at the top of this turn's tree, under a task, or at the top of a named tree.
    ///
    /// - Parameters:
    ///   - arguments: The call's arguments.
    ///   - now: The time.
    /// - Returns: The task's line.
    /// - Throws: `Plan.Failure`, or `Refusal` without a goal.
    func add(_ arguments: Arguments, now: Date) throws -> String {
        let id = arguments.id?.trimmingCharacters(in: .whitespaces).nonEmpty
        guard let goal = arguments.goal?.nonEmpty else { throw Refusal.missing("goal", action: "add") }
        let dependsOn = arguments.dependsOn ?? []
        let parent = arguments.parent?.trimmingCharacters(in: .whitespaces).nonEmpty
        let (task, plan) = try book.change { plan, current in
            let added = try plan.adding(
                goal: goal, parent: parent, dependsOn: dependsOn, currentTree: current, requestedID: id, now: now)
            return (added.plan, added.currentTree, (added.task, added.plan))
        }
        audit?.record(
            .planAdd,
            details: [
                "task": .string(task.id), "tree": .string("t\(task.tree)"),
                "parent": task.parent.map { .string($0) } ?? .null,
                "goal": .string(task.goal), "dependsOn": .array(task.dependsOn.map { .string($0) }),
            ])
        let missing = task.dependsOn.filter { plan.task($0) == nil }
        let waiting = missing.isEmpty ? "" : "\n\(missing.joined(separator: ", ")) not in the plan yet; add it to go on"
        return "added " + PlanText.line(task, in: plan) + waiting
    }

    /// `find`: tasks matching every criterion given.
    ///
    /// - Parameters:
    ///   - arguments: The call's arguments.
    ///   - id: A tree, or a task whose tree is meant.
    /// - Returns: The matching tasks, a line each, or a line saying there are none.
    /// - Throws: `Plan.Failure` for an unknown tree; `Refusal` for an unknown status.
    func find(_ arguments: Arguments, id: String?) throws -> String {
        let plan = book.plan
        var tree: Int?
        if let id {
            guard let found = plan.tree(named: id) ?? plan.task(id).flatMap({ plan.tree($0.tree) }) else {
                throw Plan.Failure.unknown(id)
            }
            tree = found.id
        }
        let raw = arguments.status?.trimmingCharacters(in: .whitespaces).lowercased().nonEmpty
        var status: Plan.Status?
        if let raw, raw != "ready" {
            guard let known = Plan.Status(rawValue: raw) else { throw Refusal.badStatus(raw, allowingReady: true) }
            status = known
        }
        let dependsOn = Plan.distinct(arguments.dependsOn ?? []).first
        if let dependsOn, plan.task(dependsOn) == nil { throw Plan.Failure.unknown(dependsOn) }
        let found = plan.find(
            status: status, ready: raw == "ready", tree: tree, text: arguments.text, dependsOn: dependsOn)
        guard !found.isEmpty else { return "no task matches" }
        return paged(found.map { PlanText.line($0, in: plan) }, page: arguments.page, action: "find")
    }

    /// One page of `lines`, with a last line saying how to see the next when there is more.
    ///
    /// - Parameters:
    ///   - lines: The whole result.
    ///   - page: The page asked for, from 1; nil for the first.
    ///   - action: The action, for the line naming the next page.
    /// - Returns: The page.
    func paged(_ lines: [String], page: Int?, action: String) -> String {
        let pages = max(1, (lines.count + Self.pageLines - 1) / Self.pageLines)
        let page = min(max(page ?? 1, 1), pages)
        var shown = Array(lines.dropFirst((page - 1) * Self.pageLines).prefix(Self.pageLines))
        if page < pages { shown.append("(page \(page) of \(pages); next: plan \(action) page \(page + 1))") }
        return shown.joined(separator: "\n")
    }

    /// A call the tool cannot act on, said so the model can correct it.
    enum Refusal: Error, CustomStringConvertible, Equatable {
        /// The action is not one the tool has.
        case unknownAction(String)
        /// The action needs an argument the call left out.
        case missing(String, action: String)
        /// The status is not one the tool knows.
        case badStatus(String?, allowingReady: Bool)

        /// The refusal as the model reads it.
        var description: String {
            switch self {
            case .unknownAction(let action):
                "unknown action \"\(action)\"; use tree, show, ready, find, add, depend, or update"
            case .missing(let argument, let action): "\(action) needs \(argument)"
            case .badStatus(let status, let ready):
                "unknown status \"\(status ?? "")\"; use "
                    + (Plan.Status.allCases.map(\.rawValue) + (ready ? ["ready"] : [])).joined(separator: ", ")
            }
        }
    }
}

extension String {
    /// The text, or nil when it is empty or only spaces.
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
