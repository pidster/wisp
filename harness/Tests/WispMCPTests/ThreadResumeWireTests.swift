import Foundation
import MCP
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// Threads saved as they go and resumed by a later server (ADR 0066): a turn on a thread, the server torn down, and a
/// new server on the same wisp home resuming it, over the real protocol. The threads run a `ScriptedModel`, so no
/// model is needed.
@Suite(.timeLimit(.minutes(1))) struct ThreadResumeWireTests {
    /// A connected client and server on one home.
    struct Pair {
        /// The client.
        let client: Client
        /// The server.
        let server: WispServer
        /// Every event the server's session recorded.
        let sink: MemoryAuditSink
    }

    /// A fresh wisp home.
    private func home(config: String? = nil) throws -> Home {
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-resume-tests-\(UUID().uuidString)"))
        try home.ensure()
        if let config { try Data(config.utf8).write(to: home.configFile) }
        return home
    }

    /// The thread factory of these tests: the server's own path (`ThreadStart.thread(on:host:)`, and the saved record
    /// when resuming) over a scripted model that says `steps`.
    private static func factory(_ steps: [ScriptedModel.Step]) -> WispServer.ThreadFactory {
        { session, host, start in
            let thread = try start.thread(on: session, host: host)
            let agent = try thread.openAgent(
                on: ResolvedModel(selection: start.model ?? .system, custom: ScriptedModel(steps: steps)),
                transcript: start.resumed?.transcript, links: start.resumed?.links)
            return OpenThread(
                thread: ThreadActor(id: start.id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay, model: thread.model.description,
                tools: thread.tools.map(\.name), think: start.think?.text, inquiries: thread.inquiries)
        }
    }

    /// A server on `home`, its events also in the audit file the resources read, with a client named `name`; with
    /// `scripted` false, the server's own factory, which opens real models.
    private func connect(
        _ home: Home, steps: [ScriptedModel.Step] = [.say("ok")], client name: String = "wire-test",
        scripted: Bool = true
    ) async throws -> Pair {
        let sink = MemoryAuditSink()
        let dependencies = Session.Dependencies(
            makeClassifier: { _, _ in RuleRiskClassifier.standard },
            makeSink: { home, config in
                TeeAuditSink([sink, try FileAuditSink(url: home.auditFile, limits: config.auditLimits)])
            })
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: dependencies)
        let server =
            scripted ? WispServer(session: session, makeThread: Self.factory(steps)) : WispServer(session: session)
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: name, version: "0")
        _ = try await client.connect(transport: transports.client)
        return Pair(client: client, server: server, sink: sink)
    }

    /// Tears the server down as its client's end does: every thread saved and let go.
    private func end(_ pair: Pair) async {
        await pair.client.disconnect()
        await pair.server.stop()
        await pair.server.endThreads()
    }

    /// The result's text.
    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    /// The result's structured content.
    private func fields(_ result: CallTool.Result) -> [String: Value] { result.structuredContent?.objectValue ?? [:] }

    @Test func aThreadResumesOnANewServerWithItsSettingsAndEarlierTurns() async throws {
        let home = try home()
        let first = try await connect(home, steps: [.say("one")])
        let started = try await call(
            first.client, "respond",
            [
                "prompt": "remember the first prompt", "thread_id": "git", "tools": ["current_date"],
                "instructions": "Run git.", "commandTimeoutSeconds": 600,
            ])
        #expect(started.isError == false && fields(started)["created"] == true && fields(started)["resumed"] == false)
        // Saved after the turn, inside the thread's queue, while the server still holds it.
        let open = try #require(try ThreadStore(home: home).settings("git"))
        #expect(open.turns == 1 && open.state == .open && open.owner == "wire-test" && open.tools == ["current_date"])
        let firstSession = try #require(open.sessions.first)
        await end(first)
        let ended = first.sink.events.last { $0.kind == .sessionEnd && $0.session == firstSession }
        #expect(ended?.details["reason"] == "disconnected")
        #expect(try ThreadStore(home: home).settings("git")?.state == .saved)

        let second = try await connect(home, steps: [.say("two")])
        let resumed = try await call(second.client, "respond", ["prompt": "and now?", "thread_id": "git"])
        #expect(resumed.isError == false, "\(text(resumed))")
        #expect(fields(resumed)["resumed"] == true && fields(resumed)["resumedTurns"] == 1)
        #expect(fields(resumed)["created"] == false)
        #expect(text(resumed).hasPrefix("resumed thread git (1 turn, saved "), "\(text(resumed))")
        #expect(text(resumed).hasSuffix("two"))
        // Its settings came with it, and its earlier turn is in what the model carries.
        let summary = try await json(second.server, "wisp://threads/git")
        #expect(summary["tools"] == ["current_date"] && summary["instructions"] == true)
        #expect(summary["turns"] == 2 && summary["state"] == "open")
        #expect(
            try await WispMCPTests.text(second.server, "wisp://threads/git/context/next").contains("remember the first")
        )
        // The new opening's session.start names what it resumed and the sessions it had.
        let start = try #require(second.sink.events.first { $0.kind == .sessionStart && $0.details["resume"] == "git" })
        #expect(start.details["carriedFrom"] == .array([.string(firstSession)]))
        #expect(start.details["commandTimeoutSeconds"] == 600 && start.details["instructions"] == "Run git.")
        // The thread's resources span both openings.
        let sessions = summary["sessions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(sessions.count == 2 && sessions.first == firstSession && sessions.last == start.session)
        let audit = try await json(second.server, "wisp://threads/git/audit?limit=500")
        let seen = Set(audit["events"]?.arrayValue?.compactMap { $0.objectValue?["session"]?.stringValue } ?? [])
        #expect(seen == Set(sessions), "\(seen)")
        // The next call on the live thread is an ordinary turn, and its own settings sent again are accepted.
        let again = try await call(
            second.client, "respond", ["prompt": "more", "thread_id": "git", "tools": ["current_date"]])
        #expect(again.isError == false && fields(again)["resumed"] == false, "\(text(again))")
        #expect(try ThreadStore(home: home).settings("git")?.turns == 3)
        await end(second)
    }

    @Test func equalSettingsResumeAndDifferentOnesAreRefusedNamingTheField() async throws {
        let home = try home()
        let first = try await connect(home)
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "s", "tools": ["current_date"]])
        await end(first)
        let second = try await connect(home)
        let different = try await call(
            second.client, "respond", ["prompt": "hi", "thread_id": "s", "model": "ollama:granite4.1:8b"])
        #expect(different.isError == true)
        #expect(
            text(different).hasPrefix(
                "s was saved with model system, tools current_date; these settings differ: model"), "\(text(different))"
        )
        #expect(ThreadStore(home: home).holder(of: "s") == nil, "a refused call does not hold the thread")
        let same = try await call(
            second.client, "respond", ["prompt": "hi", "thread_id": "s", "tools": ["current_date"], "model": "system"])
        #expect(same.isError == false && fields(same)["resumed"] == true, "\(text(same))")
        await end(second)
    }

    @Test func aClosedThreadIsNotResumedAndAnEvictedOneIs() async throws {
        let home = try home(config: #"{"maxThreads":1}"#)
        let first = try await connect(home)
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "c"])
        let closed = try await call(first.client, "close_thread", ["thread_id": "c"])
        #expect(closed.isError == false)
        #expect(!FileManager.default.fileExists(atPath: ThreadStore(home: home).directory(of: "c").path))
        let reopened = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "c"])
        #expect(fields(reopened)["created"] == true && fields(reopened)["resumed"] == false)
        // Evicted to make room, it stays saved; naming it again resumes it.
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "other"])
        try await eventually("the evicted thread is saved and let go") {
            ThreadStore(home: home).holder(of: "c") == nil
                && (try? ThreadStore(home: home).settings("c"))?.state == .saved
        }
        let threads = try await json(first.server, "wisp://threads")
        let row = threads["threads"]?.arrayValue?.first { $0.objectValue?["thread_id"] == "c" }?.objectValue
        #expect(row?["state"] == "saved" && row?["owner"] == "wire-test")
        let back = try await call(first.client, "respond", ["prompt": "back", "thread_id": "c"])
        #expect(fields(back)["resumed"] == true && fields(back)["resumedTurns"] == 1, "\(text(back))")
        await end(first)
    }

    @Test func aDisabledModelFailsTheResumeNamingIt() async throws {
        let home = try home()
        let first = try await connect(home)
        _ = try await call(
            first.client, "respond", ["prompt": "hi", "thread_id": "d", "model": "ollama:granite4.1:8b", "tools": []])
        await end(first)
        try Data(#"{"models":{"disabled":["ollama:granite4.1:8b"]}}"#.utf8).write(to: home.configFile)
        let second = try await connect(home, scripted: false)
        let refused = try await call(second.client, "respond", ["prompt": "hi", "thread_id": "d"])
        #expect(refused.isError == true)
        #expect(text(refused).contains("model 'ollama:granite4.1:8b' is disabled"), "\(text(refused))")
        #expect(ThreadStore(home: home).holder(of: "d") == nil, "the lock goes with the failed opening")
        #expect(try ThreadStore(home: home).settings("d")?.model == "ollama:granite4.1:8b", "and the thread stays")
        await end(second)
    }

    @Test func aThreadHeldByAnotherServerIsRefusedUntilItIsLetGo() async throws {
        let home = try home()
        let first = try await connect(home)
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "l"])
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "m"])
        let second = try await connect(home)
        let held = try await call(second.client, "respond", ["prompt": "hi", "thread_id": "l"])
        #expect(held.isError == true)
        #expect(text(held) == "thread l is open in another wisp (pid \(getpid()), wire-test)", "\(text(held))")
        let listed = try await json(second.server, "wisp://threads")
        let row = listed["threads"]?.arrayValue?.first { $0.objectValue?["thread_id"] == "l" }?.objectValue
        #expect(row?["state"] == "open elsewhere")
        #expect(try await call(second.client, "close_thread", ["thread_id": "l"]).isError == true)
        // Closed by its holder, the id is free for a new thread.
        _ = try await call(first.client, "close_thread", ["thread_id": "m"])
        let fresh = try await call(second.client, "respond", ["prompt": "hi", "thread_id": "m"])
        #expect(fresh.isError == false && fields(fresh)["created"] == true)
        // Let go when its server ends, it is resumed.
        await end(first)
        let resumed = try await call(second.client, "respond", ["prompt": "hi", "thread_id": "l"])
        #expect(resumed.isError == false && fields(resumed)["resumed"] == true, "\(text(resumed))")
        await end(second)
    }

    @Test func anotherClientsThreadIsRefusedAndNotListed() async throws {
        let home = try home()
        let codex = try await connect(home, client: "codex")
        _ = try await call(codex.client, "respond", ["prompt": "hi", "thread_id": "o"])
        await end(codex)
        let claude = try await connect(home)
        let refused = try await call(claude.client, "respond", ["prompt": "hi", "thread_id": "o"])
        #expect(refused.isError == true)
        #expect(
            text(refused)
                == "thread o belongs to codex, and this client is wire-test; only codex can resume it, so choose "
                + "another thread_id")
        let listed = try await json(claude.server, "wisp://threads")
        #expect(listed["threads"]?.arrayValue?.isEmpty == true)
        #expect(try await call(claude.client, "close_thread", ["thread_id": "o"]).isError == true)
        #expect(try ThreadStore(home: home).settings("o") != nil)
        await end(claude)
    }

    @Test func aSavedThreadIsReadFromItsFilesAndClosedFromTheStore() async throws {
        let home = try home()
        let first = try await connect(home, steps: [.say("one")])
        _ = try await call(first.client, "respond", ["prompt": "a saved prompt", "thread_id": "r", "task": "Read it."])
        await end(first)
        let second = try await connect(home)
        let summary = try await json(second.server, "wisp://threads/r")
        #expect(summary["state"] == "saved" && summary["turns"] == 1, "\(summary)")
        #expect(summary["task"]?.objectValue?["text"] == "Read it.")
        let facts = try await json(second.server, "wisp://threads/r/facts")
        #expect(facts["facts"]?.arrayValue?.isEmpty == false, "\(facts)")
        let context = try await json(second.server, "wisp://threads/r/context")
        #expect(context["saved"] == true && context["turns"] == [])
        #expect(try await WispMCPTests.text(second.server, "wisp://threads/r/context/next").contains("a saved prompt"))
        await #expect(throws: MCPError.self) {
            _ = try await second.server.read(.init(uri: "wisp://threads/r/context/1"))
        }
        let output = try await json(second.server, "wisp://threads/r/output")
        #expect(output["calls"] == [])
        // close_thread deletes a saved thread the server does not hold.
        let closed = try await call(second.client, "close_thread", ["thread_id": "r"])
        #expect(text(closed) == "closed r: deleted it from the thread store")
        #expect(try ThreadStore(home: home).settings("r") == nil)
        #expect(try await call(second.client, "close_thread", ["thread_id": "r"]).isError == true)
        await end(second)
    }
}
