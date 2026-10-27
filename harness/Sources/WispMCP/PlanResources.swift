import Foundation
import MCP
import WispCore

/// `wisp://threads/{thread_id}/plan` and `…/plan/{item}`: a thread's plan ([ADR 0081](../../../docs/decisions/0081-the-plan-tool.md)),
/// read from the live thread while it is open on this server and from its saved record otherwise.
extension WispServer {
    /// The plan of thread `id`: every tree and task with `item` nil, one tree's tasks for `t<n>`, or one task for
    /// `t<n>.<m>` with what depends on it.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - item: A tree or task, or nil.
    /// - Returns: The JSON.
    /// - Throws: `MCPError.invalidParams` for an unknown thread, tree, or task.
    func readPlan(thread id: String, item: String?) async throws -> JSONValue {
        guard let thread = try await viewedThread(id) else {
            if let record = directory.record(id) {
                throw MCPError.invalidParams(
                    "thread \(id) is \(record.state.rawValue); its plan went with it, and its audit remains under "
                        + "\(ToolCatalog.threadURI(id))/audit")
            }
            throw MCPError.invalidParams("no thread \(id) on this server; wisp://threads lists them")
        }
        let plan = await thread.plan() ?? Plan()
        let base = ToolCatalog.threadURI(id) + "/plan"
        guard let item else {
            return .object([
                "thread_id": .string(id),
                "trees": .array(plan.trees.map { Self.json(tree: $0, in: plan, base: base) }),
                "tasks": .array(plan.tasks.map { Self.json(task: $0, in: plan, base: base) }),
                "ready": .array(plan.ready.map { .string($0.id) }),
            ])
        }
        if let tree = plan.tree(named: item) {
            return .object([
                "thread_id": .string(id), "tree": Self.json(tree: tree, in: plan, base: base),
                "tasks": .array(plan.tasks(inTree: tree.id).map { Self.json(task: $0, in: plan, base: base) }),
                "text": .string(PlanText.outline(tree, in: plan).joined(separator: "\n")),
            ])
        }
        if let task = plan.task(item) {
            return .object([
                "thread_id": .string(id), "task": Self.json(task: task, in: plan, base: base),
                "text": .string(PlanText.detail(task, in: plan).joined(separator: "\n")),
            ])
        }
        throw MCPError.invalidParams("no tree or task \(item) in thread \(id)'s plan; \(base) lists them")
    }

    /// One tree: its name, the prompt it was rooted at, when, its counts, and its URI.
    ///
    /// - Parameters:
    ///   - tree: The tree.
    ///   - plan: The plan.
    ///   - base: The plan's URI.
    /// - Returns: The JSON.
    static func json(tree: Plan.Tree, in plan: Plan, base: String) -> JSONValue {
        .object([
            "id": .string(tree.name), "entry": tree.entry.map { .int($0) } ?? .null,
            "created": .string(tree.created.ISO8601Format()),
            "tasks": .int(plan.tasks(inTree: tree.id).count), "heading": .string(PlanText.heading(tree, in: plan)),
            "uri": .string("\(base)/\(tree.name)"),
        ])
    }

    /// One task: its fields as the plan holds them, whether it is ready, its dependents, and its URI.
    ///
    /// - Parameters:
    ///   - task: The task.
    ///   - plan: The plan.
    ///   - base: The plan's URI.
    /// - Returns: The JSON.
    static func json(task: Plan.Task, in plan: Plan, base: String) -> JSONValue {
        .object([
            "id": .string(task.id), "tree": .string("t\(task.tree)"),
            "parent": task.parent.map { .string($0) } ?? .null,
            "goal": .string(task.goal), "status": .string(task.status.rawValue), "ready": .bool(plan.isReady(task)),
            "dependsOn": .array(task.dependsOn.map { .string($0) }),
            "dependents": .array(plan.dependents(of: task.id).map { .string($0.id) }),
            "note": task.note.map { .string($0) } ?? .null, "created": .string(task.created.ISO8601Format()),
            "updated": .string(task.updated.ISO8601Format()), "uri": .string("\(base)/\(task.id)"),
        ])
    }
}

extension WispServer {
    /// What `respond` returns as `plan` when the turn changed the thread's plan: each tree's heading, the tasks ready,
    /// and the URI that reads it in full; null when the turn left the plan as it was.
    ///
    /// - Parameters:
    ///   - plan: The plan after the turn.
    ///   - id: The thread.
    /// - Returns: The value.
    static func planChange(_ plan: Plan, thread id: String) -> Value {
        .object([
            "trees": .array(plan.trees.map { .string(PlanText.heading($0, in: plan)) }),
            "ready": .array(plan.ready.map { .string($0.id) }),
            "uri": .string(ToolCatalog.threadURI(id) + "/plan"),
        ])
    }
}
