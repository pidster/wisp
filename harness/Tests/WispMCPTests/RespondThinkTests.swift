import Foundation
import MCP
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// `respond`'s `think` (ADR 0053, amended 2026-10-11): chosen when a thread starts, refused on one that exists, as
/// `model`, `tools`, and `instructions` are; asked of every turn of the thread; shown in `wisp://threads/{id}`.
@Suite struct RespondThinkTests {
    /// A server whose threads open their agent as the real factory does, through the thread's own `openAgent`, on one
    /// scripted model, so what each turn asked is in its script.
    private func server(_ model: ScriptedModel) throws -> WispServer {
        WispServer(session: try scratchSession()) { session, host, id, instructions, tools, selection, think, _ in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: selection, think: think)
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay, model: thread.model.description,
                tools: thread.tools.map(\.name), think: think?.text)
        }
    }

    @Test func aThreadsThinkIsAskedOfEveryTurnAndShownInItsResource() async throws {
        let model = ScriptedModel(steps: [.say("one"), .say("two"), .say("three")])
        let server = try server(model)
        let first = try await server.call(
            .init(
                name: "respond",
                arguments: ["prompt": "hi", "thread_id": "git", "tools": .array([]), "think": .bool(false)]))
        #expect(first.isError == false)
        let second = try await server.call(.init(name: "respond", arguments: ["prompt": "again", "thread_id": "git"]))
        #expect(second.isError == false)
        #expect(model.script.thinking.withLock { $0 } == [.off, .off])
        let summary = try await json(server, "wisp://threads/git")
        #expect(summary["think"] == "false")
        let list = try await json(server, "wisp://threads")
        #expect(list["threads"]?.arrayValue?.first?.objectValue?["think"] == "false")
        // A thread started without it leaves the model its default, and says so.
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "thread_id": "other"]))
        #expect(model.script.thinking.withLock { $0.last } == .some(nil))
        #expect(try await json(server, "wisp://threads/other")["think"] == .null)
    }

    @Test func thinkIsRefusedOnAThreadThatExistsAndForAValueTheRuntimeDoesNotTake() async throws {
        let model = ScriptedModel(steps: [.say("one")])
        let server = try server(model)
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "thread_id": "t"]))
        let again = try await server.call(
            .init(name: "respond", arguments: ["prompt": "again", "thread_id": "t", "think": .bool(true)]))
        #expect(again.isError == true)
        #expect(again.content.description.contains("apply only when a thread is created"))
        // A level only Ollama takes, on a model whose runtime has no levels: refused as the thread opens.
        let level = try await server.call(
            .init(name: "respond", arguments: ["prompt": "hi", "thread_id": "u", "think": .string("high")]))
        #expect(
            level.isError == true && level.content.description.contains("does not support think"), "\(level.content)")
        // Not a value at all.
        await #expect(throws: MCPError.self) {
            try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "think": .string("extreme")]))
        }
        await #expect(throws: MCPError.self) {
            try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "think": .int(1)]))
        }
    }

    @Test func respondsArgumentsTakeThinkAsABooleanOrALevel() throws {
        #expect(try RespondRequest(arguments: ["prompt": "x", "think": .bool(true)]).think == .on)
        #expect(try RespondRequest(arguments: ["prompt": "x", "think": .string("false")]).think == .off)
        #expect(try RespondRequest(arguments: ["prompt": "x", "think": .string("max")]).think == .level("max"))
        #expect(try RespondRequest(arguments: ["prompt": "x"]).think == nil)
        let properties = ToolCatalog.respond.inputSchema.objectValue?["properties"]?.objectValue
        #expect(properties?["think"] != nil)
    }
}
