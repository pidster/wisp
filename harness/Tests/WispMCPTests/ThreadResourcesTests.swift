import Foundation
import MCP
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// A server whose threads run `steps` on a scripted model through the framework's tool loop, with the
/// audit written to a file as well, so the resources that read the log have something to serve. Each
/// thread gets its own copy of the script.
///
/// - Parameter steps: What the model does on each thread.
/// - Returns: The server.
/// - Throws: What setting up the scratch session throws.
func threadServer(steps: [ScriptedModel.Step]) throws -> WispServer {
    let sink = MemoryAuditSink()
    let dependencies = Session.Dependencies(
        makeClassifier: { _, _ in RuleRiskClassifier.standard },
        makeSink: { home, config in
            TeeAuditSink([sink, try FileAuditSink(url: home.auditFile, limits: config.auditLimits)])
        })
    let session = try scratchSession(dependencies: dependencies)
    return WispServer(session: session) { session, host, id, instructions, tools, model, _ in
        let thread = try session.thread(
            id: id, host: host, instructions: instructions, tools: tools, model: model,
            auditSession: ThreadDirectory.auditSession(for: id))
        let agent = Agent(
            instructions: thread.prompting.rendered, tools: thread.tools,
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)), audit: thread.audit)
        return OpenThread(
            thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
            receipts: thread.receipts, relay: thread.relay, model: thread.model.description,
            tools: thread.tools.map(\.name))
    }
}

/// The text of a resource.
func text(_ server: WispServer, _ uri: String) async throws -> String {
    try await server.read(.init(uri: uri)).contents.first?.text ?? ""
}

/// A JSON resource, decoded.
func json(_ server: WispServer, _ uri: String) async throws -> [String: JSONValue] {
    let data = Data(try await text(server, uri).utf8)
    return try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
}

/// The resources about `respond` threads: `wisp://threads`, a thread's summary, its tool calls and their
/// output, and its audit, which moved there from `wisp://output/…` and `wisp://audit/{thread_id}`.
@Suite struct ThreadResourcesTests {
    /// A scratch file of `lines` lines.
    private func file(lines: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-threads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "f.txt")
        try Data((1...lines).map { "line \($0) of a file" }.joined(separator: "\n").utf8).write(to: file)
        return file
    }

    @Test func threadsAreListedSummarisedAndKeptAfterTheyClose() async throws {
        let file = try file(lines: 3)
        let server = try threadServer(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("read"), .say("again"),
        ])
        _ = try await server.call(
            .init(
                name: "respond",
                arguments: [
                    "prompt": "read it", "thread_id": "one", "tools": .array(["read_file"]),
                    "instructions": "Be brief.",
                ]))
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "again", "thread_id": "one"]))
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "thread_id": "two"]))
        let list = try await json(server, "wisp://threads")
        let rows = try #require(list["threads"]?.arrayValue).compactMap(\.objectValue)
        #expect(rows.map { $0["thread_id"] } == [.string("two"), .string("one")])
        #expect(rows[1]["turns"] == .int(2) && rows[1]["state"] == .string("open") && rows[1]["model"] == "system")
        #expect(rows[1]["uri"] == .string("wisp://threads/one") && list["pages"] == .int(1) && list["next"] == .null)
        let one = try await json(server, "wisp://threads/one")
        #expect(
            one["tools"] == .array(["read_file"]) && one["instructions"] == .bool(true)
                && one["task"] == .null)
        #expect(one["resources"]?.objectValue?["output"] == .string("wisp://threads/one/output"))
        #expect(one["resources"]?.objectValue?["contextNext"] == .string("wisp://threads/one/context/next"))
        #expect(try await json(server, "wisp://threads/two")["instructions"] == .bool(false))
        // Closed, the thread is still listed, and its output and audit still read.
        _ = try await server.call(.init(name: "close_thread", arguments: ["thread_id": "one"]))
        #expect(try await json(server, "wisp://threads/one")["state"] == .string("closed"))
        let calls = try await json(server, "wisp://threads/one/output")
        let call = try #require(calls["calls"]?.arrayValue?.first?.objectValue)
        #expect(call["turn"] == .int(1) && call["tool"] == .string("read_file") && (call["bytes"]?.intValue ?? 0) > 50)
        let uri = try #require(call["uri"]?.stringValue)
        #expect(uri.hasPrefix("wisp://threads/one/output/"))
        #expect(try await text(server, uri).hasPrefix("1\tline 1 of a file"))
        // The thread's events are under an audit session of its own, named by the thread with a suffix, and paged.
        let auditSession = try #require(one["auditSession"]?.stringValue)
        #expect(auditSession.hasPrefix("one-") && auditSession.count == 12, "\(auditSession)")
        let audit = try await json(server, "wisp://threads/one/audit")
        let events = try #require(audit["events"]?.arrayValue).compactMap(\.objectValue)
        #expect(events.contains { $0["kind"] == .string("tool.result") })
        #expect(events.allSatisfy { $0["session"] == .string(auditSession) })
        #expect(audit["page"] == .int(1) && audit["limit"] == .int(100) && audit["next"] == .null)
        #expect(audit["last"] == .string("wisp://threads/one/audit?page=1"))
        let paged = try await json(server, "wisp://threads/one/audit?page=2&limit=3")
        #expect(paged["events"]?.arrayValue?.count == 3 && paged["page"] == .int(2))
        #expect(paged["next"] == .string("wisp://threads/one/audit?page=3&limit=3"))
        await #expect(throws: MCPError.self) {
            _ = try await server.read(.init(uri: "wisp://threads/one/audit?page=99"))
        }
        // A thread's audit is not served under wisp://audit/{session}, by its id or its audit session; other
        // sessions still are, paged the same way; and wisp://audit pages every session's events.
        await #expect(throws: MCPError.self) { _ = try await server.read(.init(uri: "wisp://audit/one")) }
        await #expect(throws: MCPError.self) { _ = try await server.read(.init(uri: "wisp://audit/\(auditSession)")) }
        #expect(try await json(server, "wisp://audit/triage-0000")["events"] == .array([]))
        let all = try await json(server, "wisp://audit?limit=2")
        #expect(all["events"]?.arrayValue?.count == 2 && (all["pages"]?.intValue ?? 0) > 2)
        #expect(all["next"] == .string("wisp://audit?page=2&limit=2"))
        // A second thread under the same id, after the first closed, has a session and resources of its own.
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "again", "thread_id": "one"]))
        let reopened = try await json(server, "wisp://threads/one")
        #expect(reopened["auditSession"]?.stringValue != auditSession && reopened["turns"] == .int(1))
        #expect(try await json(server, "wisp://threads/one/output")["total"] == .int(1))
        // Unknown threads, pages, and paths are protocol errors.
        for uri in [
            "wisp://threads/three", "wisp://threads?page=2", "wisp://threads?page=0", "wisp://threads/bad id",
            "wisp://threads/one/nope", "wisp://threads/one/output/NOPE",
        ] {
            await #expect(throws: MCPError.self, "\(uri)") { _ = try await server.read(.init(uri: uri)) }
        }
    }

    @Test func theModelsThinkingIsListedAndReadUnderItsThread() async throws {
        let server = try threadServer(steps: [.think("Is 91 prime? 7 times 13."), .say("No.")])
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "Is 91 prime?", "thread_id": "t"]))
        #expect(
            try await json(server, "wisp://threads/t")["resources"]?.objectValue?["reasoning"]
                == .string("wisp://threads/t/reasoning"))
        let list = try await json(server, "wisp://threads/t/reasoning")
        let row = try #require(list["reasoning"]?.arrayValue?.first?.objectValue)
        #expect(row["turn"] == .int(1) && row["tokens"] == .int(6) && list["total"] == .int(1))
        let uri = try #require(row["uri"]?.stringValue)
        #expect(uri.hasPrefix("wisp://threads/t/reasoning/"))
        #expect(try await text(server, uri) == "Is 91 prime? 7 times 13.")
        for bad in ["wisp://threads/t/reasoning/NOPE", "wisp://threads/t/reasoning/0123456789abcdef"] {
            await #expect(throws: MCPError.self, "\(bad)") { _ = try await server.read(.init(uri: bad)) }
        }
    }

    @Test func collectionsArePaged() throws {
        let rows = (1...120).map { JSONValue.int($0) }
        let first = try WispServer.paged(rows, page: 1, base: "wisp://x", key: "rows").objectValue ?? [:]
        #expect(first["rows"]?.arrayValue?.count == 50 && first["pages"] == .int(3) && first["total"] == .int(120))
        #expect(first["next"] == .string("wisp://x?page=2"))
        let last = try WispServer.paged(rows, page: 3, base: "wisp://x", key: "rows").objectValue ?? [:]
        #expect(last["rows"]?.arrayValue == Array(rows[100...]) && last["next"] == .null)
        #expect(throws: MCPError.self) { _ = try WispServer.paged(rows, page: 4, base: "wisp://x", key: "rows") }
        let empty = try WispServer.paged([], page: 1, base: "wisp://x", key: "rows").objectValue ?? [:]
        #expect(empty["pages"] == .int(1) && empty["rows"] == .array([]))
        let parsed = WispServer.ThreadURI("wisp://threads/a/output?page=3")
        #expect(parsed?.path == ["a", "output"] && parsed?.page == 3)
        #expect(WispServer.ThreadURI("wisp://threads")?.path == [] && WispServer.ThreadURI("wisp://threads")?.page == 1)
        #expect(WispServer.ThreadURI("wisp://threadsx") == nil && WispServer.ThreadURI("wisp://audit") == nil)
    }

    @Test func theDirectoryKeepsTheLatestClosedRecordsWithinItsCapacity() {
        let directory = ThreadDirectory(capacity: 2)
        let start = Date(timeIntervalSince1970: 0)
        directory.opened(id: "a", model: nil, tools: [], instructions: false, now: start)
        directory.ended(id: "a", as: .closed)
        directory.opened(id: "b", model: nil, tools: [], instructions: false, now: start.addingTimeInterval(1))
        directory.used(id: "b", turns: 3, now: start.addingTimeInterval(5))
        directory.opened(
            id: "c", model: "system", tools: ["notify"], instructions: true, now: start.addingTimeInterval(2))
        // Over capacity, the closed record goes; open ones stay.
        #expect(directory.all.map(\.id) == ["b", "c"] && directory.record("b")?.turns == 3)
        directory.ended(id: "c", as: .evicted)
        #expect(directory.record("c")?.state == .evicted && directory.record("a") == nil)
    }
}
