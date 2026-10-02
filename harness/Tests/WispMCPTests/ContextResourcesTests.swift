import Foundation
import MCP
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// The model's context of a thread, viewable at no model cost (decision D12): the turn list at
/// `wisp://threads/{thread_id}/context`, the context composed at a turn's start at `…/context/{turn}`, and
/// the next request's at `…/context/next`.
@Suite struct ContextResourcesTests {
    /// A scratch file of forty lines, long enough that its output becomes a reference.
    private func file() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "f.txt")
        try Data((1...40).map { "line \($0) of a file with a few words" }.joined(separator: "\n").utf8).write(to: file)
        return file
    }

    @Test func theTurnsTheirContextsAndTheNextRequestAreServed() async throws {
        let file = try file()
        let server = try threadServer(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("Forty lines."), .say("Yes."),
        ])
        _ = try await server.call(
            .init(
                name: "respond",
                arguments: ["prompt": "read it", "thread_id": "ctx", "tools": .array(["read_file"])]))
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "is that all?", "thread_id": "ctx"]))
        let list = try await json(server, "wisp://threads/ctx/context")
        let turns = try #require(list["turns"]?.arrayValue).compactMap(\.objectValue)
        #expect(turns.map { $0["turn"] } == [.int(1), .int(2)])
        #expect(turns[0]["prompt"] == .string("read it") && turns[0]["uri"] == .string("wisp://threads/ctx/context/1"))
        #expect(turns[1]["changed"]?.objectValue?["referenced"] == .int(1))
        #expect(turns[0]["changed"]?.objectValue?["referenced"] == .int(0))
        #expect((turns[1]["tokens"]?.intValue ?? 0) > 0 && turns[1]["time"] != .null)
        #expect(list["next_request"] == .string("wisp://threads/ctx/context/next"))
        // Turn 1: its own output whole. Turn 2: the output as a reference. Next: the same.
        let first = try await text(server, "wisp://threads/ctx/context/1")
        #expect(first.hasPrefix("# The context composed at the start of turn 1"))
        #expect(first.contains("line 40 of a file") && first.contains("tool output: read_file · this turn's"))
        let second = try await text(server, "wisp://threads/ctx/context/2")
        #expect(second.contains("(sent as a reference)") && !second.contains("line 20 of a file"))
        let next = try await text(server, "wisp://threads/ctx/context/next")
        #expect(next.hasPrefix("# The context the next request carries") && next.contains("[output of entry "))
        // Turns that do not exist, pages past the last, and closed threads are protocol errors.
        for uri in [
            "wisp://threads/ctx/context/3", "wisp://threads/ctx/context/0", "wisp://threads/ctx/context/x",
            "wisp://threads/ctx/context/1?page=2", "wisp://threads/ctx/context?page=2", "wisp://threads/nope/context",
        ] {
            await #expect(throws: MCPError.self, "\(uri)") { _ = try await server.read(.init(uri: uri)) }
        }
        _ = try await server.call(.init(name: "close_thread", arguments: ["thread_id": "ctx"]))
        do {
            _ = try await server.read(.init(uri: "wisp://threads/ctx/context/next"))
            Issue.record("a closed thread's context was served")
        } catch {
            #expect("\(error)".contains("is closed"))
        }
    }

    @Test func aLongContextIsPaged() async throws {
        let long = String(repeating: "word ", count: 5000)
        let server = try threadServer(steps: [.say(long), .say("ok")])
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "talk", "thread_id": "long"]))
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "more", "thread_id": "long"]))
        let first = try await text(server, "wisp://threads/long/context/next")
        // The heading and the prompt, then the long reply's one line across two pages, each within the bound.
        #expect(first.hasPrefix("(page 1 of 3; the next is wisp://threads/long/context/next?page=2)"))
        let last = try await text(server, "wisp://threads/long/context/next?page=3")
        #expect(last.hasPrefix("(page 3 of 3)\n\n"))
        #expect(try await text(server, "wisp://threads/long/context/next?page=2").utf8.count <= Paging.pageBytes + 100)
    }

    @Test func aThreadWithoutAStoreSaysSo() async throws {
        let session = try scratchSession()
        let server = WispServer(session: session) { session, host, id, _, _, _ in
            let thread = try session.thread(id: id, host: host, tools: .none)
            return OpenThread(thread: Replying(), gate: thread.gate, audit: thread.audit)
        }
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "thread_id": "fake"]))
        await #expect(throws: MCPError.self) { _ = try await server.read(.init(uri: "wisp://threads/fake/context")) }
        await #expect(throws: MCPError.self) {
            _ = try await server.read(.init(uri: "wisp://threads/fake/context/next"))
        }
    }
}

/// A thread that answers without a model or a store.
private struct Replying: RespondingThread {
    /// Always "ok".
    func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply {
        Agent.Reply(text: "ok", condensed: false)
    }
}
