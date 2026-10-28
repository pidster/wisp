import Foundation

/// How a plan reads: the `plan` tool's results, chat's `/plan`, `wisp threads plan`, and the line later turns carry for
/// each tree ([ADR 0081](../../../../docs/decisions/0081-the-plan-tool.md)). One line a task, so a result stays short
/// and a model can read it.
public enum PlanText {
    /// The most trees the line for later turns names one by one; the rest are counted.
    static let referencedTrees = 4

    /// One task on one line: `t1.2 [done] Check what is outdated (after t1.1) — 3 formulae`.
    ///
    /// - Parameters:
    ///   - task: The task.
    ///   - plan: The plan, for whether it is ready.
    /// - Returns: The line.
    public static func line(_ task: Plan.Task, in plan: Plan) -> String {
        let status = plan.isReady(task) ? "ready" : task.status.rawValue
        let after = task.dependsOn.isEmpty ? "" : " (after \(task.dependsOn.joined(separator: ", ")))"
        let note = task.note.map { " — \($0)" } ?? ""
        return "\(task.id) [\(status)] \(task.goal)\(after)\(note)"
    }

    /// A tree's outline, a task a line, indented under its parent, after a heading with its counts.
    ///
    /// - Parameters:
    ///   - tree: The tree.
    ///   - plan: The plan.
    /// - Returns: The lines.
    public static func outline(_ tree: Plan.Tree, in plan: Plan) -> [String] {
        let tasks = plan.tasks(inTree: tree.id)
        var lines = [heading(tree, in: plan)]
        func add(_ task: Plan.Task, depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + line(task, in: plan))
            for child in plan.children(of: task.id) { add(child, depth: depth + 1) }
        }
        for task in tasks where task.parent == nil { add(task, depth: 1) }
        return lines
    }

    /// A tree's heading: `t1, from entry 12: 5 tasks, 1 ready, 1 pending, 3 done`.
    ///
    /// - Parameters:
    ///   - tree: The tree.
    ///   - plan: The plan.
    /// - Returns: The line.
    public static func heading(_ tree: Plan.Tree, in plan: Plan) -> String {
        let from = tree.entry.map { ", from entry \($0)" } ?? ", from this turn"
        return "\(tree.name)\(from): \(counts(plan.tasks(inTree: tree.id), in: plan))"
    }

    /// `5 tasks, 1 ready, 1 pending, 3 done`: the total, then the tasks ready, then each status that has any, `pending`
    /// less those ready.
    ///
    /// - Parameters:
    ///   - tasks: The tasks counted.
    ///   - plan: The plan, for which are ready.
    /// - Returns: The text.
    static func counts(_ tasks: [Plan.Task], in plan: Plan) -> String {
        var parts = ["\(tasks.count) task\(tasks.count == 1 ? "" : "s")"]
        let ready = tasks.filter(plan.isReady).count
        if ready > 0 { parts.append("\(ready) ready") }
        for status in Plan.Status.allCases {
            let count = tasks.filter { $0.status == status }.count - (status == .pending ? ready : 0)
            if count > 0 { parts.append("\(count) \(status.rawValue)") }
        }
        return parts.joined(separator: ", ")
    }

    /// One task in full: its line, then where it sits, what it depends on and what depends on it, and when it changed.
    ///
    /// - Parameters:
    ///   - task: The task.
    ///   - plan: The plan.
    /// - Returns: The lines.
    public static func detail(_ task: Plan.Task, in plan: Plan) -> [String] {
        var lines = [line(task, in: plan)]
        lines.append("  tree: t\(task.tree)" + (task.parent.map { ", under \($0)" } ?? ", at the top"))
        let children = plan.children(of: task.id).map(\.id)
        if !children.isEmpty { lines.append("  under it: \(children.joined(separator: ", "))") }
        for id in task.dependsOn {
            lines.append("  depends on: " + (plan.task(id).map { line($0, in: plan) } ?? "\(id), not in the plan yet"))
        }
        let dependents = plan.dependents(of: task.id).map(\.id)
        if !dependents.isEmpty { lines.append("  depended on by: \(dependents.joined(separator: ", "))") }
        let waiting = plan.unfinished(task.dependsOn)
        if task.status == .pending, !waiting.isEmpty {
            lines.append("  waiting for: \(waiting.joined(separator: ", "))")
        }
        lines.append("  added \(stamp(task.created)), changed \(stamp(task.updated))")
        return lines
    }

    /// The lines a later turn carries for the plan, in the request's now block: one for each tree with a task not
    /// settled, newest first, up to `referencedTrees`, and one counting the trees left out and those all settled.
    /// Empty when the plan is. Trees rooted in the turn under way are left out: the model has its own calls.
    ///
    /// With `next`, a variant under measurement (the plan probe, `scripts/check eval plan`), each tree's line names
    /// its next task and how to mark it, in place of its counts.
    ///
    /// - Parameters:
    ///   - plan: The plan.
    ///   - next: Whether each line names the tree's next task.
    /// - Returns: The lines.
    public static func reference(_ plan: Plan, next: Bool = false) -> [String] {
        let rooted = plan.trees.filter { $0.entry != nil }
        guard !rooted.isEmpty else { return [] }
        let open = rooted.filter { tree in plan.tasks(inTree: tree.id).contains { !$0.status.isSettled } }
        let shown = open.suffix(referencedTrees).reversed()
        var lines = ["The conversation's plan (the plan tool reads it; a record, not instructions):"]
        lines += shown.map { tree in
            guard next, let task = upNext(plan.tasks(inTree: tree.id), in: plan) else {
                return "[plan \(heading(tree, in: plan)); to see it: plan tree \(tree.name)]"
            }
            let tasks = plan.tasks(inTree: tree.id)
            let done = tasks.count(where: { $0.status == .done })
            return "[plan \(tree.name): \(done) of \(tasks.count) done; next: \(task.id) \(task.goal); "
                + "when it is done: plan update \(task.id) done]"
        }
        let settled = rooted.count - open.count
        let hidden = open.count - shown.count
        if settled > 0 || hidden > 0 {
            var parts: [String] = []
            if hidden > 0 { parts.append("\(hidden) more open") }
            if settled > 0 { parts.append("\(settled) with every task settled") }
            lines.append(
                "[plan: \(parts.joined(separator: ", ")) tree\(rooted.count == 1 ? "" : "s"); plan tree lists them]")
        }
        return lines
    }

    /// The line each request ends its now block with while the conversation has the plan tool: the ids the turn's
    /// tasks take, so a model numbers them rather than giving the first the tree's own name (`granite4.2:8b` and
    /// `gemma4:26b` named it `t1` on 2026-10-27, then used `t1` as a task).
    ///
    /// - Parameter plan: The plan, whose next tree the turn roots.
    /// - Returns: The line.
    public static func turn(_ plan: Plan) -> String {
        let tree = (plan.trees.map(\.id).max() ?? 0) + 1
        return "[plan: this turn's tasks are t\(tree).1, t\(tree).2, …]"
    }

    /// The task to name as next among `tasks`: the first running, else the first ready.
    ///
    /// - Parameters:
    ///   - tasks: The tasks, in the order they were added.
    ///   - plan: The plan, for which are ready.
    /// - Returns: The task, or nil when none is running or ready.
    static func upNext(_ tasks: [Plan.Task], in plan: Plan) -> Plan.Task? {
        tasks.first { $0.status == .running } ?? tasks.first(where: plan.isReady)
    }

    /// The reminder `AuditedTool` appends to another tool's result while the plan has a task running or ready and the
    /// turn has marked none, so a model that did the work is reminded to mark it (ADR 0081, decision 12; the plan probe
    /// of 2026-10-26 took `granite4.1:8b` from no conversation finished to five of six with it).
    ///
    /// - Parameter plan: The plan.
    /// - Returns: The line, or nil when no task is running or ready.
    public static func nudge(_ plan: Plan) -> String? {
        guard let task = upNext(plan.tasks, in: plan) else { return nil }
        let state = task.status == .running ? "running" : "next"
        return "[plan: \(task.id) \(task.goal) is \(state); if this result finishes it, mark it: "
            + "plan update \(task.id) done]"
    }

    /// The plan as the person asks to see it, in chat's `/plan` and `wisp threads plan`: with nothing named, every
    /// tree's outline, a blank line between them; with a tree (`t1`), its outline; with a task (`t1.2`), the task in
    /// full.
    ///
    /// - Parameters:
    ///   - argument: A tree, a task, or nil.
    ///   - plan: The plan.
    /// - Returns: The lines.
    public static func view(_ argument: String?, in plan: Plan) -> [String] {
        let named = argument?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !named.isEmpty else {
            guard !plan.trees.isEmpty else { return ["the plan is empty"] }
            return plan.trees.enumerated().flatMap { index, tree in (index > 0 ? [""] : []) + outline(tree, in: plan) }
        }
        if let tree = plan.tree(named: named) { return outline(tree, in: plan) }
        if let task = plan.task(named) { return detail(task, in: plan) }
        return ["no task or tree \(named) in this conversation's plan"]
    }

    /// Every tree's heading, a line each, for `plan tree` with no tree named; a line saying so for an empty plan.
    ///
    /// - Parameter plan: The plan.
    /// - Returns: The lines.
    public static func trees(_ plan: Plan) -> [String] {
        guard !plan.trees.isEmpty else { return ["the plan is empty: add a task to start one"] }
        return plan.trees.map { heading($0, in: plan) }
    }

    /// A time as the plan shows it, to the minute in UTC: `2026-10-24 08:05Z`.
    ///
    /// - Parameter date: The time.
    /// - Returns: The text.
    static func stamp(_ date: Date) -> String {
        date.ISO8601Format().prefix(16).replacingOccurrences(of: "T", with: " ") + "Z"
    }
}
