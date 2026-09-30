import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// A thread's facts over MCP (decisions D2, D3, and D6 of the layered-context proposal): `respond`'s `task`
/// argument, the `wisp://threads/{thread_id}/facts` collection, each fact's history, and the task in the
/// thread's summary.
@Suite struct FactResourcesTests {
    /// A server whose threads run on a scripted model, opened as the faces open them, keeping facts.
    private func server(steps: [ScriptedModel.Step]) throws -> WispServer {
        let session = try scratchSession()
        return WispServer(session: session) { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model)
            // The faces' own path, so the agent keeps facts as the config says and links its tool events.
            let agent = try thread.openAgent(
                on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
    }

    /// A scratch file of three lines.
    private func file() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-facts-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "f.txt")
        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        return file
    }

    @Test func theTaskArgumentSetsTheTaskAsTheCallerAndTheFactsAreServed() async throws {
        let file = try file()
        let server = try server(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("Three lines."), .say("Done."),
        ])
        let first = try await server.call(
            .init(
                name: "respond",
                arguments: [
                    "prompt": "read it", "thread_id": "t", "tools": .array(["read_file"]), "task": "count the lines",
                ]))
        #expect(first.isError != true)
        _ = try await server.call(
            .init(name: "respond", arguments: ["prompt": "and?", "thread_id": "t", "task": "count the words"]))
        let summary = try await json(server, "wisp://threads/t")
        #expect(summary["task"]?.objectValue?["text"] == "count the words")
        #expect(summary["task"]?.objectValue?["source"] == "caller")
        #expect(summary["resources"]?.objectValue?["facts"] == "wisp://threads/t/facts")
        let listing = try await json(server, "wisp://threads/t/facts")
        let facts = try #require(listing["facts"]?.arrayValue).compactMap(\.objectValue)
        try #require(facts.count == 2, "\(facts)")
        #expect(facts.map { $0["subject"] } == ["file", "task"])
        #expect(facts[0]["source"] == "tool" && facts[0]["detail"] == "read_file" && facts[0]["entries"] != [])
        #expect(facts[1]["value"] == "count the words" && facts[1]["uri"] == "wisp://threads/t/facts/c3")
        #expect(listing["total"] == 2 && listing["conflicts"] == 0)
        let all = try await json(server, "wisp://threads/t/facts?all=true")
        #expect(all["total"] == 3)
        let history = try await json(server, "wisp://threads/t/facts/c3")
        #expect(history["fact"]?.objectValue?["id"] == "c3")
        #expect(
            try #require(history["history"]?.arrayValue).compactMap { $0.objectValue?["state"] } == [
                "superseded", "current",
            ])
        for uri in ["wisp://threads/t/facts/c9", "wisp://threads/none/facts", "wisp://threads/t/facts?page=2"] {
            await #expect(throws: MCPError.self, "\(uri)") { _ = try await server.read(.init(uri: uri)) }
        }
        // An empty task is refused before the thread is touched.
        await #expect(throws: MCPError.self) {
            _ = try await server.call(
                .init(name: "respond", arguments: ["prompt": "x", "thread_id": "t", "task": " "]))
        }
        #expect(ToolCatalog.resourceTemplates.contains { $0.uriTemplate == ToolCatalog.factsTemplate })
    }

    @Test func aThreadWithoutFactsRefusesATask() async throws {
        let session = try scratchSession()
        let server = WispServer(session: session) { session, host, id, _, _, _ in
            let thread = try session.thread(id: id, host: host, tools: .none)
            return OpenThread(
                thread: ThreadActor(
                    id: id,
                    agent: Agent(
                        instructions: "x", tools: [],
                        model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))),
                gate: thread.gate, audit: thread.audit)
        }
        let result = try await server.call(
            .init(name: "respond", arguments: ["prompt": "hi", "thread_id": "plain", "task": "a task"]))
        #expect(result.isError == true)
        await #expect(throws: MCPError.self) { _ = try await server.read(.init(uri: "wisp://threads/plain/facts")) }
        #expect(try await json(server, "wisp://threads/plain")["task"] == .null)
    }
}
