import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// A thread's plan under `wisp mcp` (ADR 0081), over the real protocol: `respond` returns `plan` when a turn changed
/// it and null when not, and `wisp://threads/{thread_id}/plan` serves the plan, one tree, or one task.
@Suite(.timeLimit(.minutes(1))) struct PlanWireTests {
    /// A server whose threads run `steps`, and a client connected to it.
    private func connected(steps: [ScriptedModel.Step]) async throws -> Client {
        let session = try scratchSession(dependencies: .testing())
        let model = ScriptedModel(steps: steps)
        let server = WispServer(session: session) { session, host, start in
            let thread = try session.thread(
                id: start.id, host: host, instructions: start.instructions, tools: start.tools,
                auditSession: ThreadDirectory.auditSession(for: start.id))
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
            return OpenThread(
                thread: ThreadActor(id: start.id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay, inquiries: thread.inquiries)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: "wire-test", version: "0")
        _ = try await client.connect(transport: transports.client)
        return client
    }

    /// A resource's JSON.
    private func read(_ client: Client, _ uri: String) async throws -> [String: Value] {
        let text = try await client.readResource(uri: uri).first?.text ?? ""
        return try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
    }

    @Test func respondReturnsTheChangedPlanAndTheResourcesServeIt() async throws {
        let client = try await connected(steps: [
            .call(name: "plan", arguments: #"{"action":"add","goal":"Check the disk"}"#),
            .call(name: "plan", arguments: #"{"action":"add","goal":"Report","dependsOn":["t1.1"]}"#),
            .say("Planned."),
            .say("Nothing to change."),
        ])
        let first = try await call(
            client, "respond", ["prompt": "plan it", "thread_id": "p", "tools": .array([.string("plan")])])
        let change = try #require(first.structuredContent?.objectValue?["plan"]?.objectValue)
        #expect(change["ready"] == .array([.string("t1.1")]))
        #expect(change["uri"] == .string("wisp://threads/p/plan"))
        let heading = try #require(change["trees"]?.arrayValue?.first?.stringValue)
        #expect(heading.hasPrefix("t1, from entry ") && heading.hasSuffix(": 2 tasks, 1 ready, 1 pending"))
        // A turn that leaves the plan as it was returns null.
        let second = try await call(client, "respond", ["prompt": "and now?", "thread_id": "p"])
        #expect(second.structuredContent?.objectValue?["plan"] == .null)
        let plan = try await read(client, "wisp://threads/p/plan")
        #expect(plan["ready"] == .array([.string("t1.1")]))
        let tasks = try #require(plan["tasks"]?.arrayValue)
        #expect(tasks.count == 2)
        let report = try #require(tasks.last?.objectValue)
        #expect(report["id"] == "t1.2" && report["dependsOn"] == .array([.string("t1.1")]) && report["ready"] == false)
        #expect(report["uri"] == "wisp://threads/p/plan/t1.2")
        let tree = try await read(client, "wisp://threads/p/plan/t1")
        #expect(tree["tasks"]?.arrayValue?.count == 2)
        #expect(tree["text"]?.stringValue?.contains("  t1.2 [pending] Report (after t1.1)") == true)
        let task = try await read(client, "wisp://threads/p/plan/t1.1")
        #expect(task["task"]?.objectValue?["dependents"] == .array([.string("t1.2")]))
        await #expect(throws: (any Error).self) { try await client.readResource(uri: "wisp://threads/p/plan/t9") }
        let summary = try await read(client, "wisp://threads/p")
        #expect(summary["resources"]?.objectValue?["plan"] == "wisp://threads/p/plan")
    }

    /// A task's JSON lists the calls linked to it, the count of earlier ones let go, and the question it waits on
    /// (ADR 0079, decisions 21 and 24); a task with none has an empty list, 0, and null.
    @Test func aTasksJSONListsItsCallsAndTheQuestionItWaitsOn() throws {
        let added = try Plan().adding(goal: "Check", parent: nil, dependsOn: [], currentTree: nil, now: .now)
        let call = Plan.Call(id: "c1", tool: "run_command", arguments: #"{"command":"df -h"}"#, failed: true)
        let plan = added.plan.linking([call], to: "t1.1", dropped: 2).waiting(on: "q7", now: .now).plan
        let waiting = try #require(plan.task("t1.1"))
        let task = try #require(WispServer.json(task: waiting, in: plan, base: "b").objectValue)
        #expect(task["status"] == .string("waiting") && task["question"] == .string("q7"))
        #expect(task["droppedCalls"] == .int(2))
        #expect(
            task["calls"]
                == .array([
                    .object([
                        "id": .string("c1"), "tool": .string("run_command"), "summary": .string("df -h"),
                        "failed": .bool(true),
                    ])
                ]))
        let unlinked = try #require(added.plan.task("t1.1"))
        let bare = try #require(WispServer.json(task: unlinked, in: added.plan, base: "b").objectValue)
        #expect(bare["calls"] == .array([]) && bare["droppedCalls"] == .int(0) && bare["question"] == .null)
    }
}
