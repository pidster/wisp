import Foundation
import FoundationModels
import MCP
import Synchronization
import Testing
import WispCore
import WispTestSupport

@testable import WispCore
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
                == "thread o belongs to codex, and this client is wire-test; choose another thread_id, or the person "
                + "gives it to you with wisp threads hand o wire-test")
        let listed = try await json(claude.server, "wisp://threads")
        #expect(listed["threads"]?.arrayValue?.isEmpty == true)
        #expect(try await call(claude.client, "close_thread", ["thread_id": "o"]).isError == true)
        #expect(try ThreadStore(home: home).settings("o") != nil)
        await end(claude)
    }

    @Test func anotherClientsThreadHandedOverIsResumedByThisOne() async throws {
        let home = try home()
        let codex = try await connect(home, client: "codex")
        _ = try await call(codex.client, "respond", ["prompt": "hi", "thread_id": "h"])
        await end(codex)
        let claude = try await connect(home)
        #expect(try await call(claude.client, "respond", ["prompt": "hi", "thread_id": "h"]).isError == true)
        // The person hands it over, as wisp threads hand h wire-test does, while the server runs.
        #expect(try ThreadAdmin(home: home).hand("h", to: "wire-test")?.from == "codex")
        let resumed = try await call(claude.client, "respond", ["prompt": "again", "thread_id": "h"])
        #expect(resumed.isError == false && fields(resumed)["resumed"] == true, "\(text(resumed))")
        let listed = try await json(claude.server, "wisp://threads")
        #expect(listed["threads"]?.arrayValue?.contains { $0.objectValue?["thread_id"] == "h" } == true)
        await end(claude)
        #expect(try ThreadStore(home: home).settings("h")?.owner == "wire-test")
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

    /// Chat on the store (ADR 0066, D6, D11): a thread an agent holds is refused to chat, saying who holds it; one open
    /// in chat is refused to an agent the same way; and the agent resumes what chat added once chat lets it go.
    @Test func chatAndAnAgentHoldAThreadInTurn() async throws {
        let home = try home()
        let store = ThreadStore(home: home)
        let transcripts = TranscriptStore(directory: home.transcripts)
        let first = try await connect(home, steps: [.say("one")])
        _ = try await call(
            first.client, "respond",
            [
                "prompt": "remember the agent's turn", "thread_id": "git4", "tools": ["current_date"],
                "instructions": "Run git.", "commandTimeoutSeconds": 600,
            ])
        #expect(throws: ThreadStore.Failure.held("git4", .init(pid: getpid(), owner: "wire-test"))) {
            try ChatThread.find("git4", store: store, transcripts: transcripts)
        }
        #expect(
            ThreadStore.Failure.held("git4", .init(pid: getpid(), owner: "wire-test")).description
                == "thread git4 is open in another wisp (pid \(getpid()), wire-test)")
        await end(first)

        // Opened in chat, it shows its settings first and holds them; an agent naming it meanwhile is refused.
        let opening = try ChatThread.find("git4", store: store, transcripts: transcripts)
        let announced = try #require(opening.announcement())
        #expect(
            announced.hasPrefix(
                "git4: system, tools current_date, instructions set, commandTimeoutSeconds 600 (an agent's thread: "
                    + "wire-test's, 1 turn)"), "\(announced)")
        let saved = try #require(opening.saved)
        let agent = Agent(
            transcript: saved.transcript, tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("from chat")])),
            audit: AuditLog(session: "chat-session", sink: MemoryAuditSink()), links: saved.links)
        let thread = ChatThread(
            opening, store: store, transcripts: transcripts, session: "chat-session", model: "system",
            tools: ["current_date"], instructions: nil, think: nil)
        let second = try await connect(home, steps: [.say("two")])
        let refused = try await call(second.client, "respond", ["prompt": "hi", "thread_id": "git4"])
        #expect(refused.isError == true)
        #expect(text(refused) == "thread git4 is open in another wisp (pid \(getpid()), chat)", "\(text(refused))")
        let lines = Mutex(["a turn in chat"])
        var loop = ChatLoop(
            agent: agent, thread: thread, context: .init(directory: "/r", approval: "a"),
            io: .init(
                readLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } }, print: { _ in }, write: { _ in },
                note: { _ in }, prompt: { _ in }))
        try await loop.run()

        // Let go, the agent resumes it with its own settings and chat's turn.
        let resumed = try await call(
            second.client, "respond", ["prompt": "and now?", "thread_id": "git4", "tools": ["current_date"]])
        #expect(resumed.isError == false && fields(resumed)["resumedTurns"] == 2, "\(text(resumed))")
        #expect(
            try await WispMCPTests.text(second.server, "wisp://threads/git4/context/next").contains("a turn in chat"))
        let settings = try #require(try store.settings("git4"))
        #expect(settings.owner == "wire-test" && settings.commandTimeoutSeconds == 600 && settings.turns == 3)
        #expect(settings.sessions.contains("chat-session"))
        await end(second)
    }

    // MARK: Saved threads read from their files, and the refusals around the store

    /// A thread whose `respond` throws `error`, standing for one a model failed on.
    private struct FailingThread: RespondingThread {
        /// What the turn throws.
        let error: any Error

        func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply { throw error }
    }

    /// The factory of a thread built outside the thread store (no `kept`), whose turn throws `error`.
    private static func failingFactory(_ error: any Error) -> WispServer.ThreadFactory {
        { session, host, start in
            let thread = try start.thread(on: session, host: host)
            return OpenThread(
                thread: FailingThread(error: error), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay, model: thread.model.description,
                tools: thread.tools.map(\.name), think: start.think?.text, inquiries: thread.inquiries)
        }
    }

    /// A server on `home` whose threads are built outside the store and throw `error` on a turn.
    private func connectFailing(_ home: Home, error: any Error) async throws -> Pair {
        let sink = MemoryAuditSink()
        let session = try Session.begin(
            .init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let server = WispServer(session: session, makeThread: Self.failingFactory(error))
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: "wire-test", version: "0")
        _ = try await client.connect(transport: transports.client)
        return Pair(client: client, server: server, sink: sink)
    }

    /// The message of the protocol error reading `uri` raised.
    private func refusal(_ server: WispServer, _ uri: String) async -> String? {
        do {
            _ = try await server.read(.init(uri: uri))
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func anotherClientsSavedThreadIsRefusedByItsSummaryAndItsRecordResources() async throws {
        let home = try home()
        let codex = try await connect(home, client: "codex")
        _ = try await call(codex.client, "respond", ["prompt": "hi", "thread_id": "o"])
        await end(codex)
        let claude = try await connect(home)
        let owned = ThreadStore.Failure.owned("o", owner: "codex", client: "wire-test").description
        for uri in ["wisp://threads/o", "wisp://threads/o/facts", "wisp://threads/o/context/next"] {
            let message = try #require(await refusal(claude.server, uri), "\(uri)")
            #expect(message.contains(owned), "\(uri): \(message)")
        }
        // Its audit sessions are not disclosed either: they fall back to the directory's own.
        #expect(await claude.server.auditSessions(of: "o") == [claude.server.directory.auditSession(of: "o")])
        await end(claude)
    }

    @Test func aSavedThreadWithoutItsRecordRefusesItsResourcesSayingHowToClearIt() async throws {
        let home = try home()
        try ThreadStore(home: home).save(
            ThreadStore.Settings(
                id: "bare", owner: "wire-test", model: "system", tools: [], instructions: nil, session: "bare-0000aaaa"),
            record: nil)
        let pair = try await connect(home)
        let message = try #require(await refusal(pair.server, "wisp://threads/bare/facts"))
        #expect(
            message.contains("thread bare cannot be resumed") && message.contains("close_thread bare"), "\(message)")
        // Unsafe ids are no saved thread at all.
        #expect(try pair.server.savedRecord("bad id") == nil)
        await end(pair)
    }

    @Test func aSavedThreadIsNotOpenAndShowsItsSummaryVersionsFromItsRecord() async throws {
        let home = try home()
        let first = try await connect(home, steps: [.say("one")])
        _ = try await call(first.client, "respond", ["prompt": "a saved prompt", "thread_id": "r"])
        await end(first)
        let store = ThreadStore(home: home)
        let record = try #require(try store.record("r"))
        let saved = SavedThread(id: "r", record: record, permanent: [])
        await #expect(throws: SavedThread.Failure.notOpen("r")) { _ = try await saved.respond(to: "hi", schema: nil) }
        #expect(SavedThread.Failure.notOpen("r").description == "thread r is saved, not open; respond resumes it")
        #expect(await saved.summaries() == record.summaries)
        #expect(await saved.facts() == record.facts.facts)
        let withoutFacts = SavedThread(id: "r", record: record, permanent: nil)
        #expect(await withoutFacts.summaries() == nil && withoutFacts.permanent == nil)
        let second = try await connect(home)
        let summary = try await json(second.server, "wisp://threads/r/summary")
        #expect(summary["thread_id"] == "r" && summary["versions"] == .int(record.summaries.count), "\(summary)")
        await end(second)
    }

    @Test func aSavedThreadsStoredOutputsAreListedAndPagedFromTheOutputStore() async throws {
        let home = try home()
        let first = try await connect(
            home, steps: [.call(name: "current_date", arguments: "{}"), .say("done")])
        _ = try await call(
            first.client, "respond", ["prompt": "what day is it", "thread_id": "o", "tools": ["current_date"]])
        let result = try #require(first.sink.events.first { $0.kind == .toolResult && $0.session.hasPrefix("o-") })
        let callID = try #require(result.call)
        let big = (1...2500).map { "line \($0) of a long stored output" }.joined(separator: "\n")
        let outputs = OutputStore(
            directory: home.outputs.appending(path: result.session, directoryHint: .isDirectory))
        #expect(outputs.keep(big, id: callID, tool: "current_date") != nil)
        await end(first)

        let second = try await connect(home)
        let list = try await json(second.server, "wisp://threads/o/output")
        let row = try #require(list["calls"]?.arrayValue?.first?.objectValue)
        #expect(row["stored"] == .string(callID) && row["storedLines"] == .int(2500), "\(row)")
        #expect((row["storedBytes"]?.intValue ?? 0) == big.utf8.count)
        let uri = try #require(row["uri"]?.stringValue)
        let pages = try #require(Paging.page(big, number: 1)).count
        #expect(pages > 2)
        let page1 = try await WispMCPTests.text(second.server, uri)
        #expect(
            page1.hasPrefix("(page 1 of \(pages); the next is \(uri)?page=2)\nline 1 of a long stored output"),
            "\(page1.prefix(120))")
        let last = try await WispMCPTests.text(second.server, uri + "?page=\(pages)")
        #expect(last.hasPrefix("(page \(pages) of \(pages))\n") && last.hasSuffix("line 2500 of a long stored output"))
        let past = try #require(await refusal(second.server, uri + "?page=9"))
        #expect(past.contains("page 9 is past the last"), "\(past)")
        await end(second)
    }

    @Test func aCallWithoutAResultIsListedWithoutAnOutputAndAnEmptyResultReadsEmpty() async throws {
        let home = try home()
        let first = try await connect(home)
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "g"])
        let opening = try #require(try ThreadStore(home: home).settings("g")?.sessions.first)
        // A call the turn never got a result for, and a result that carries no output text.
        let sink = try FileAuditSink(url: home.auditFile, limits: Config().resolved.auditLimits)
        sink.write(
            AuditEvent(
                session: opening, kind: .toolCall, turn: 1, call: "dangling",
                details: ["tool": "read_file", "arguments": "{}"]))
        let empty = AuditEvent(session: opening, kind: .toolResult, turn: 1, call: "empty", details: [:])
        sink.write(empty)
        await end(first)
        let second = try await connect(home)
        let list = try await json(second.server, "wisp://threads/g/output")
        let rows = try #require(list["calls"]?.arrayValue).compactMap(\.objectValue)
        let dangling = try #require(rows.first { $0["tool"] == "read_file" })
        #expect(dangling["id"] == .null && dangling["bytes"] == .null && dangling["uri"] == .null, "\(dangling)")
        #expect(dangling["stored"] == nil)
        let emptyID = try #require(empty.id)
        #expect(try await WispMCPTests.text(second.server, "wisp://threads/g/output/\(emptyID)").isEmpty)
        await end(second)
    }

    @Test func aSavedThreadsNextContextIsPagedAndAPageBeyondTheLastIsRefused() async throws {
        let home = try home()
        let first = try await connect(home, steps: [.say("one")])
        let prompt = (1...1500).map { "line \($0) of a long prompt to carry" }.joined(separator: "\n")
        _ = try await call(first.client, "respond", ["prompt": .string(prompt), "thread_id": "big"])
        await end(first)
        let second = try await connect(home)
        let uri = "wisp://threads/big/context/next"
        let page1 = try await WispMCPTests.text(second.server, uri)
        #expect(page1.hasPrefix("(page 1 of "), "\(page1.prefix(80))")
        #expect(page1.contains("; the next is \(uri)?page=2)"), "\(page1.prefix(120))")
        let past = try #require(await refusal(second.server, uri + "?page=99"))
        #expect(past.contains("page 99 is past the last"), "\(past)")
        await end(second)
    }

    @Test func differentToolsOnAResumeAreRefusedNamingThem() async throws {
        let home = try home()
        let first = try await connect(home)
        _ = try await call(first.client, "respond", ["prompt": "hi", "thread_id": "t", "tools": ["current_date"]])
        await end(first)
        let second = try await connect(home)
        let refused = try await call(
            second.client, "respond", ["prompt": "hi", "thread_id": "t", "tools": ["system_info"]])
        #expect(refused.isError == true)
        #expect(text(refused).contains("these settings differ: tools"), "\(text(refused))")
        #expect(ThreadStore(home: home).holder(of: "t") == nil)
        await end(second)
    }

    @Test func aTurnThatOverflowsTheContextSaysToCloseTheThreadAndOtherFailuresAreReported() async throws {
        let home = try home()
        let overflow = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 10, tokenCount: 11, debugDescription: "x", metadata: [:]))
        let full = try await connectFailing(home, error: overflow)
        let exhausted = try await call(full.client, "respond", ["prompt": "hi", "thread_id": "x"])
        #expect(exhausted.isError == true)
        #expect(
            text(exhausted) == "thread x has exhausted the model's context window; close it and start a new one",
            "\(text(exhausted))")
        await end(full)
        struct Broken: Error, CustomStringConvertible { var description: String { "the model fell over" } }
        let broken = try await connectFailing(home, error: Broken())
        let failed = try await call(broken.client, "respond", ["prompt": "hi", "thread_id": "y"])
        #expect(failed.isError == true && text(failed) == "the model fell over", "\(text(failed))")
        await end(broken)
    }

    @Test func closingAThreadWhoseDirectoryCannotBeDeletedStillClosesIt() async throws {
        let home = try home()
        let pair = try await connect(home)
        _ = try await call(pair.client, "respond", ["prompt": "hi", "thread_id": "stuck"])
        let threads = ThreadStore(home: home).directory(of: "stuck").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: threads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: threads.path) }
        let closed = try await call(pair.client, "close_thread", ["thread_id": "stuck"])
        #expect(closed.isError == false && text(closed) == "closed stuck", "\(text(closed))")
        let end = pair.sink.events.last { $0.kind == .sessionEnd && $0.session.hasPrefix("stuck-") }
        #expect(end?.details["reason"] == "closed")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: threads.path)
        await self.end(pair)
    }
}
