import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Chat on the thread store (ADR 0066, D2, D11): ids and `/save` renaming, `--resume` from the store and from the
/// transcripts of earlier wisps, an agent's thread opened with its settings, and `/threads`. Every thread runs a
/// `ScriptedModel` in a temporary home.
@Suite struct ChatThreadTests {
    /// A fresh home, its thread store, and its transcripts.
    struct Fixture {
        let home: Home
        var store: ThreadStore { ThreadStore(home: home) }
        var transcripts: TranscriptStore { TranscriptStore(directory: home.transcripts) }
    }

    /// A fresh wisp home under the temporary directory.
    private func fixture() throws -> Fixture {
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-chat-thread-\(UUID().uuidString)"))
        try home.ensure()
        return Fixture(home: home)
    }

    /// An agent on a scripted model saying `steps`, recording to session `session`.
    private func agent(_ steps: [ScriptedModel.Step] = [.say("ok")], session: String = "chat") -> Agent {
        Agent(
            instructions: "x", tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)),
            audit: AuditLog(session: session, sink: MemoryAuditSink()))
    }

    /// A record with one turn of `prompt`, as a conversation that had it holds.
    private func record(_ prompt: String, session: String = "earlier") async throws -> ThreadRecord {
        let agent = agent([.say("noted")], session: session)
        _ = try await agent.respond(to: prompt)
        return agent.store
    }

    /// Lines in, captured notes and output.
    final class Capture: Sendable {
        let lines: Mutex<[String]>
        let out = Mutex<[String]>([])
        let notes = Mutex<[String]>([])
        init(_ lines: [String]) { self.lines = Mutex(lines) }
        var io: ChatLoop.IO {
            .init(
                readLine: { self.lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                print: { text in self.out.withLock { $0.append(text) } }, write: { _ in },
                note: { text in self.notes.withLock { $0.append(text) } }, prompt: { _ in })
        }
        var noted: [String] { notes.withLock { $0 } }
        var printed: [String] { out.withLock { $0 } }
    }

    /// The chat's thread over `opening`, as the CLI opens it for `agent`.
    private func open(_ opening: ChatThread.Opening, _ fixture: Fixture, agent: Agent) -> ChatThread {
        ChatThread(
            opening, store: fixture.store, transcripts: fixture.transcripts, session: agent.audit?.session ?? "chat",
            model: agent.model.selection.description, tools: agent.tools.map(\.name), instructions: nil, think: nil)
    }

    /// Saves an agent's thread `id`, as a `wisp mcp` server does, with one turn.
    private func saveAgentsThread(_ id: String, _ fixture: Fixture, owner: String = "claude-code") async throws {
        var settings = ThreadStore.Settings(
            id: id, owner: owner, model: "system", tools: ["current_date"], instructions: "Run git.",
            commandTimeoutSeconds: 600, session: "\(id)-0000aaaa")
        settings.turns = 1
        settings.state = .saved
        try fixture.store.save(
            settings, record: try await record("remember the agent's turn", session: settings.sessions[0]))
    }

    @Test func aNewChatThreadIsGeneratedAndANamedOneMustBeFree() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        let opening = try ChatThread.reserve(store: fixture.store)
        #expect(opening.id.wholeMatch(of: /chat-[0-9a-f]{8}/) != nil, "\(opening.id)")
        #expect(opening.settings == nil && opening.saved == nil && opening.announcement() == nil)
        #expect(!opening.isAgents && opening.carriedFrom.isEmpty && opening.tools == nil, "a new thread is nobody's")
        // Locked, but nothing is saved until it has something to save: a chat quit at once leaves nothing behind.
        #expect(fixture.store.holder(of: opening.id) != nil)
        let agent = agent()
        let thread = open(opening, fixture, agent: agent)
        try thread.finish(record: agent.store, model: "system", think: nil)
        #expect(fixture.store.ids.isEmpty && fixture.store.holder(of: opening.id) == nil)
        // A name is taken by a saved thread, and must be an id the store takes.
        try await saveAgentsThread("git4", fixture)
        #expect(throws: ChatThread.Failure.taken("git4")) { try ChatThread.reserve("git4", store: fixture.store) }
        #expect(throws: ThreadStore.Failure.invalidID(".hidden")) {
            try ChatThread.reserve(".hidden", store: fixture.store)
        }
    }

    @Test func saveRenamesTheThreadAndRefusesWhatItCannotBe() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        try await saveAgentsThread("git4", fixture)
        let agent = agent([.say("one")])
        let thread = open(try ChatThread.reserve(store: fixture.store), fixture, agent: agent)
        let generated = thread.id
        let capture = Capture([
            "hello", "/save git4", "/save .x", "/save \(String(repeating: "a", count: 49))", "/save mine",
        ])
        var loop = ChatLoop(
            agent: agent, thread: thread, context: .init(directory: "/r", approval: "a"), io: capture.io)
        try await loop.run()
        let notes = capture.noted
        #expect(notes.contains("error: a thread named 'git4' is already saved; choose another name"), "\(notes)")
        #expect(notes.contains { $0.hasPrefix("error: thread id '.x' cannot be saved") }, "\(notes)")
        #expect(notes.filter { $0.hasPrefix("error: thread id 'aaaa") }.count == 1, "\(notes)")
        #expect(notes.contains("saved thread \(generated) as mine"), "\(notes)")
        // Under its new id alone, with its turn, let go; the agent's thread is untouched.
        #expect(fixture.store.all.map(\.id).sorted() == ["git4", "mine"])
        let mine = try #require(try fixture.store.load("mine"))
        #expect(mine.settings.turns == 1 && mine.settings.owner == "chat" && mine.transcript.turnCount == 1)
        #expect(fixture.store.holder(of: "mine") == nil)
        #expect(try fixture.store.settings("git4")?.owner == "claude-code")
    }

    @Test func anAgentsThreadOpensWithItsSettingsAndKeepsThem() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        try await saveAgentsThread("git4", fixture)
        let opening = try ChatThread.find("git4", store: fixture.store, transcripts: fixture.transcripts)
        #expect(opening.isAgents && opening.carriedFrom == ["git4-0000aaaa"])
        #expect(
            opening.announcement()
                == "git4: system, tools current_date, instructions set, commandTimeoutSeconds 600 (an agent's thread: "
                + "claude-code's, 1 turn); its settings hold here, and /new starts a thread of your own")
        // The session takes the thread's settings; the person's flags may repeat them, not change them.
        let request = try opening.applied(
            to: .init(entryPoint: .chat, autoApprove: true), resume: "git4", save: nil)
        #expect(request.model == .system && request.tools == .named(["current_date"]))
        #expect(request.instructions == "Run git." && request.autoApprove)
        #expect(request.resume == "git4" && request.carriedFrom == ["git4-0000aaaa"])
        // The chat's session.start names what it resumes and the sessions the thread had, as MCP's does (D7).
        let sink = MemoryAuditSink()
        let session = try Session.begin(request, home: fixture.home, dependencies: .testing(sink: sink))
        let start = try #require(sink.events.first { $0.kind == .sessionStart })
        #expect(start.details["resume"] == "git4" && start.details["carriedFrom"] == .array([.string("git4-0000aaaa")]))
        #expect(start.details["tools"] == .array([.string("current_date")]))
        session.end()
        #expect(
            try opening.applied(
                to: .init(entryPoint: .chat, instructions: "Run git.", model: .system), resume: "git4", save: "git4"
            ).model == .system)
        #expect(
            throws: ChatThread.Failure.settings(
                "git4", "model system, tools current_date, instructions set, commandTimeoutSeconds 600",
                differing: ["model", "tools"])
        ) {
            try opening.applied(
                to: .init(entryPoint: .chat, model: .ollama("q"), tools: .none), resume: "git4", save: nil)
        }
        #expect(throws: ChatThread.Failure.agents("git4", owner: "claude-code")) {
            try opening.applied(to: .init(entryPoint: .chat), resume: "git4", save: "mine")
        }
        // Run over its saved record: its earlier turn carries, /model, /think, and /save NAME are refused, and what is
        // saved is its record and turns under its own settings and owner.
        let saved = try #require(opening.saved)
        let agent = Agent(
            transcript: saved.transcript, tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("two")])),
            audit: AuditLog(session: "chatsession", sink: MemoryAuditSink()), links: saved.links)
        let thread = open(opening, fixture, agent: agent)
        try thread.save(record: agent.store, model: "system", think: nil)
        #expect(try fixture.store.settings("git4")?.sessions == ["git4-0000aaaa", "chatsession"])
        let capture = Capture(["/model ollama:q", "/think on", "/save other", "and now?"])
        var loop = ChatLoop(
            agent: agent, thread: thread,
            context: .init(directory: "/r", approval: "a"), io: capture.io)
        try await loop.run()
        let notes = capture.noted
        let refusal =
            "thread git4 is claude-code's: its model holds here, so its agent resumes it as it left it; /new "
            + "starts a thread of your own"
        #expect(notes.contains(refusal), "\(notes)")
        #expect(notes.contains { $0.hasPrefix("error: thread git4 is claude-code's, which names it by that id") })
        let after = try #require(try fixture.store.load("git4"))
        #expect(after.settings.owner == "claude-code" && after.settings.model == "system")
        #expect(after.settings.tools == ["current_date"] && after.settings.instructions == "Run git.")
        #expect(after.settings.commandTimeoutSeconds == 600 && after.settings.turns == 2)
        #expect(after.settings.state == .saved && fixture.store.holder(of: "git4") == nil)
        #expect(after.transcript.turnCount == 2)
    }

    @Test func newOnAnAgentsThreadStartsTheChatsOwnWithTheSameTools() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        try await saveAgentsThread("git4", fixture)
        let opening = try ChatThread.find("git4", store: fixture.store, transcripts: fixture.transcripts)
        let saved = try #require(opening.saved)
        let agent = Agent(
            transcript: saved.transcript, tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("fresh")])),
            audit: AuditLog(session: "chatsession", sink: MemoryAuditSink()), links: saved.links)
        let thread = open(opening, fixture, agent: agent)
        let capture = Capture(["/new", "hello"])
        var loop = ChatLoop(
            agent: agent, thread: thread, context: .init(directory: "/r", approval: "a"), io: capture.io)
        try await loop.run()
        #expect(!thread.isAgents && thread.id.hasPrefix("chat-"))
        let fresh = try #require(try fixture.store.settings(thread.id))
        #expect(fresh.owner == "chat" && fresh.tools == ["current_date"] && fresh.instructions == "Run git.")
        #expect(fresh.commandTimeoutSeconds == 600 && fresh.turns == 1 && fresh.sessions == ["chatsession"])
        // The agent's thread was let go as it was: no turn of the chat's was saved into it.
        #expect(try fixture.store.settings("git4")?.turns == 1 && fixture.store.holder(of: "git4") == nil)
    }

    @Test func anOlderTranscriptIsResumedAndSavedIntoTheStoreUnderItsName() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        // An older wisp made the directory; this one only reads it.
        try FileManager.default.createDirectory(at: fixture.home.transcripts, withIntermediateDirectories: true)
        try fixture.transcripts.save(try await record("the old way"), as: "notes")
        let long = String(repeating: "n", count: 60)
        try fixture.transcripts.save(try await record("too long a name"), as: long)
        #expect(throws: ChatThread.Failure.notFound("nothing")) {
            try ChatThread.find("nothing", store: fixture.store, transcripts: fixture.transcripts)
        }
        #expect(
            ChatThread.listing(store: fixture.store, transcripts: fixture.transcripts, current: nil).last
                == "in \(ChatStatus.abbreviated(fixture.home.transcripts.path)), opened with --resume and saved into "
                + "the store then: \(long), notes")
        let opening = try ChatThread.find("notes", store: fixture.store, transcripts: fixture.transcripts)
        #expect(opening.id == "notes" && opening.legacy == "notes" && opening.settings == nil)
        #expect(opening.carriedFrom == ["earlier"])
        #expect(
            opening.announcement() == "resumed 'notes' from ~/.wisp/transcripts (1 turn), now saved as thread notes")
        let saved = try #require(opening.saved)
        let agent = Agent(
            transcript: saved.transcript, tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("again")])),
            audit: AuditLog(session: "chat", sink: MemoryAuditSink()), links: saved.links)
        let thread = open(opening, fixture, agent: agent)
        try thread.save(record: agent.store, model: "system", think: nil)
        let stored = try #require(try fixture.store.load("notes"))
        #expect(stored.settings.owner == "chat" && stored.settings.turns == 1 && stored.transcript.turnCount == 1)
        // The transcript stays where it was; the store is looked in first from now on.
        #expect(try fixture.transcripts.list().contains("notes"))
        try thread.finish(record: agent.store, model: "system", think: nil)
        #expect(try ChatThread.find("notes", store: fixture.store, transcripts: fixture.transcripts).legacy == nil)
        // A name the store cannot take is saved under a generated id.
        let renamed = try ChatThread.find(long, store: fixture.store, transcripts: fixture.transcripts)
        #expect(renamed.id.hasPrefix("chat-") && renamed.legacy == long)
        renamed.abandon(in: fixture.store)
        #expect(try fixture.store.settings(renamed.id) == nil && !fixture.store.ids.contains(renamed.id))
    }

    @Test func aChatsOwnThreadResumesAnnouncedAndTakesTheModelAndToolsTheChatRunsWith() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        var settings = ThreadStore.Settings(
            id: "mine", owner: "chat", model: "system", tools: ["current_date"], instructions: nil, think: nil,
            session: "mine-0000aaaa")
        settings.turns = 1
        settings.state = .saved
        try fixture.store.save(settings, record: try await record("my own turn", session: "mine-0000aaaa"))
        let opening = try ChatThread.find("mine", store: fixture.store, transcripts: fixture.transcripts)
        #expect(!opening.isAgents)
        let line = try #require(opening.announcement())
        #expect(line.hasPrefix("resumed thread mine (1 turn, saved "), "\(line)")
        // The person's own thread follows the flags of this run: its model, tools, and thinking are the chat's now.
        let thread = ChatThread(
            opening, store: fixture.store, transcripts: fixture.transcripts, session: "mine-0000bbbb",
            model: "ollama:granite4.1:8b", tools: ["current_date", "read_file"], instructions: nil, think: "low")
        #expect(thread.settings.model == "ollama:granite4.1:8b" && thread.settings.think == "low")
        #expect(thread.settings.tools == ["current_date", "read_file"] && !thread.isAgents)
        #expect(thread.settings.sessions == ["mine-0000aaaa", "mine-0000bbbb"])
        #expect(fixture.store.holder(of: "mine") != nil)
        try thread.finish(record: try await record("again"), model: "system", think: nil)
        #expect(fixture.store.holder(of: "mine") == nil)
    }

    @Test func aThreadWhoseRecordIsMissingIsNotOpenedAndItsLockIsReleased() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        try fixture.store.save(
            ThreadStore.Settings(
                id: "bare", owner: "claude-code", model: "system", tools: [], instructions: nil,
                session: "bare-0000aaaa"),
            record: nil)
        #expect(throws: ThreadStore.Failure.self) {
            try ChatThread.find("bare", store: fixture.store, transcripts: fixture.transcripts)
        }
        #expect(fixture.store.holder(of: "bare") == nil, "a refused opening does not keep the thread locked")
    }

    @Test func savingUnderTheCurrentNameSavesInPlaceAndAFailedRenameKeepsTheOldThread() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        let agent = agent([.say("one")])
        let thread = open(try ChatThread.reserve("first", store: fixture.store), fixture, agent: agent)
        _ = try await agent.respond(to: "hello")
        try thread.rename(to: "first", record: agent.store, model: "system", think: nil)
        #expect(fixture.store.all.map(\.id) == ["first"] && thread.id == "first")
        // A directory the new name already has, that cannot be written to, makes the save fail: the thread stays as it was.
        let blocked = fixture.store.directory(of: "second")
        try FileManager.default.createDirectory(
            at: blocked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: fixture.store.lockFile("second"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        #expect(throws: (any Error).self) {
            try thread.rename(to: "second", record: agent.store, model: "system", think: nil)
        }
        #expect(thread.id == "first" && fixture.store.holder(of: "second") == nil)
        let stillThere = try fixture.store.settings("first")
        #expect(fixture.store.holder(of: "first") != nil && stillThere != nil)
        try thread.finish(record: agent.store, model: "system", think: nil)
    }

    @Test func shortTimeIsTheLocalTimeToTheMinute() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let expected = String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!)
        #expect(ChatThread.shortTime(date) == expected)
        #expect(ChatThread.shortTime(date).wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil)
    }

    @Test func threadsListsEveryThreadWithItsState() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        try await saveAgentsThread("git4", fixture)
        try await saveAgentsThread("held", fixture, owner: "codex")
        let elsewhere = try fixture.store.lock("held", owner: "codex")
        defer { elsewhere.release() }
        let agent = agent([.say("one")])
        let thread = open(try ChatThread.reserve("here", store: fixture.store), fixture, agent: agent)
        let capture = Capture(["hi", "/threads"])
        var loop = ChatLoop(
            agent: agent, thread: thread, context: .init(directory: "/r", approval: "a"), io: capture.io)
        try await loop.run()
        let lines = capture.printed.filter {
            $0.hasPrefix("THREAD") || $0.hasPrefix("git4") || $0.hasPrefix("held") || $0.hasPrefix("here")
        }
        #expect(lines.count == 4, "\(capture.printed)")
        #expect(
            lines.first?.split(separator: " ", omittingEmptySubsequences: true).map(String.init) == [
                "THREAD", "OWNER", "MODEL", "TURNS", "LAST", "USED", "STATE",
            ])
        let row = { (id: String) in
            lines.first { $0.hasPrefix(id + " ") }?.split(separator: " ", omittingEmptySubsequences: true).map(
                String.init) ?? []
        }
        #expect(row("here").first == "here" && row("here")[1] == "chat" && row("here")[3] == "1")
        #expect(row("here").last == "open", "\(row("here"))")
        #expect(row("git4")[1] == "claude-code" && row("git4").last == "saved", "\(row("git4"))")
        #expect(row("held")[1] == "codex" && row("held").suffix(2) == ["open", "elsewhere"], "\(row("held"))")
        #expect(ChatInput(line: "/threads") == .threads)
        #expect(ChatCompletion.complete("/thr").candidates == ["/threads"])
        #expect(ChatInput.helpText(matching: "threads").contains("/threads"))
    }
}
