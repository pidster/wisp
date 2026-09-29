import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct ChatLoopTests {
    /// Captured output of one run, by channel.
    final class Capture: Sendable {
        let stdout = Mutex<[String]>([])
        let notes = Mutex<[String]>([])
        let prompts = Mutex<[ChatStatus]>([])
        let turns = Mutex<[ChatTurn]>([])
        let lines: Mutex<[String]>

        init(lines: [String]) { self.lines = Mutex(lines) }

        var io: ChatLoop.IO {
            .init(
                readLine: { self.lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                print: { text in self.stdout.withLock { $0.append(text + "\n") } },
                write: { text in self.stdout.withLock { $0.append(text) } },
                note: { text in self.notes.withLock { $0.append(text) } },
                prompt: { status in self.prompts.withLock { $0.append(status) } },
                turn: { mark in self.turns.withLock { $0.append(mark) } })
        }

        /// The turn marks with their times dropped: `(start, number)` or `(end, number, failed)`.
        var marks: [String] {
            turns.withLock { $0 }.map { mark in
                switch mark {
                case .start(let turn): "start \(turn)"
                case .end(let turn, _, let failed, _): "end \(turn)\(failed ? " failed" : "")"
                }
            }
        }

        var output: String { stdout.withLock { $0.joined() } }
        var noted: [String] { notes.withLock { $0 } }
        var shownStatus: [ChatStatus] { prompts.withLock { $0 } }
    }

    /// A context with a fixed git answer and an inspect view that echoes its argument.
    static let context = ChatLoop.Context(
        directory: "/repo", approval: "approve at moderate",
        git: { _ in GitState.Summary(branch: "main", dirty: true, added: 12, removed: 3) },
        inspect: { what in "inspected \(what)" }, banner: "wisp test")

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func contextSavesWhatTheNextRequestCarriesOrSaysWhyNot() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("noted")])))
        let unsaved = Capture(lines: ["/inspect context", "quit"])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: unsaved.io)
        try await loop.run()
        #expect(unsaved.noted.contains("the context is not saved here: audit.enabled is false"))
        agent.archive = ContextArchive(directory: dir.appending(path: "context"), session: "c")
        let saved = Capture(lines: ["remember BLUE HERON", "/inspect context", "quit"])
        loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: saved.io)
        try await loop.run()
        let note = saved.noted.first { $0.hasPrefix("saved the context") } ?? ""
        #expect(note.contains("c-turn1.md") && note.contains("1 turn),") && !note.contains("1 turns"), "\(saved.noted)")
        let file = dir.appending(path: "context/c-turn1.md")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("remember BLUE HERON"))
        #expect(ChatInput(line: "/inspect context") == .context && ChatInput(line: "/inspect Context") == .context)
        #expect(ChatInput(line: "/context") == .unknown("context"))
    }

    @Test func commandsMessagesAndTheExitSaveOverAScriptedModel() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("hi there"), .say("second")])),
            audit: AuditLog(session: "chat", sink: sink))
        let capture = Capture(lines: [
            "/help", "/tools", "/tokens", "", "hello", "/save", "/save first", "/bogus", "/new", "again", "/save",
            "/inspect approvals", "/status", "/last", "help", "quit", "never read",
        ])
        var loop = ChatLoop(agent: agent, store: store, saveName: nil, context: Self.context, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains(ChatInput.helpText))
        #expect(out.contains("current_date  Returns the current local date and time.\n"))
        #expect(out.contains("inspected approvals\n") && out.contains("inspected status\n"))
        #expect(out.contains("no tool has run yet\n"))
        #expect(out.components(separatedBy: ChatInput.helpText).count == 3)  // /help and bare help
        #expect(out.contains("unknown tokens in 0 turns; condensed 0 times\n"))
        #expect(out.contains("hi there\n"))
        #expect(out.contains("second\n"))
        let notes = capture.noted
        #expect(notes.first == "wisp test")
        #expect(notes[1] == "/help for commands, /quit or Ctrl-D to exit.")
        // The status line is drawn before every prompt, from the context and the agent.
        let status = capture.shownStatus
        #expect(status.count == 16)
        #expect(status.first?.rendered(style: .plain) == "system · /repo:main+12-3 · approve at moderate")
        #expect(notes.contains("usage: /save <name>"))
        #expect(notes.contains("saved 'first'"))
        #expect(notes.contains("unknown command /bogus; /help lists commands"))
        #expect(notes.contains("new conversation"))
        #expect(notes.filter { $0 == "saved 'first'" }.count == 3)  // /save first, bare /save, exit
        #expect(loop.saveName == "first")
        #expect(try store.list() == ["first"])
        #expect(try store.load("first").turnCount == 1)  // after /new only "again" remains
        // `/save` also writes the store's links, whose sources name this chat's session.
        let links = try #require(try store.loadConversation("first").links)
        #expect(links.sessions == ["chat"])
        #expect(sink.events.contains { $0.kind == .sessionStart && $0.details["reason"] == "new" })
        #expect(sink.events.filter { $0.kind == .prompt }.count == 2)
    }

    @Test func modelsListsAndModelSwitchesKeepingTheTranscript() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("from system")])))
        let context = ChatLoop.Context(
            directory: "/r", approval: "--yes",
            models: { current, _ in ["current \(current)", "  ollama:q\t3B"] },
            openModel: { selection, store in
                Agent(
                    store: store, tools: [],
                    model: ResolvedModel(selection: selection, custom: ScriptedModel(steps: [.say("from ollama")])))
            })
        let capture = Capture(lines: [
            "/models", "/model", "one", "/model ollama:q", "/model", "two", "/model gpt-5", "/quit",
        ])
        var loop = ChatLoop(
            agent: first, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains("current system\n  ollama:q\t3B\n"))
        #expect(out.contains("model: system (toolCalling, guidedGeneration)\n"))
        #expect(out.contains("from system\n") && out.contains("from ollama\n"))
        #expect(out.contains("model: ollama:q (toolCalling, guidedGeneration)\n"))
        #expect(capture.noted.contains("model: ollama:q; the transcript continues"))
        #expect(capture.noted.contains { $0.hasPrefix("error: unknown model 'gpt-5'") })
        // The transcript carried over: both turns are in the switched agent, and the status shows the model.
        #expect(loop.agent.model.selection == .ollama("q"))
        #expect(loop.agent.transcript.turnCount == 2)
        #expect(capture.shownStatus.last?.model == "ollama:q")
        // Without the closures the commands say so.
        let bare = Capture(lines: ["/models", "/model x", "/quit"])
        var plain = ChatLoop(
            agent: first, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: bare.io)
        try await plain.run()
        #expect(
            bare.noted.contains("models are not listed here")
                && bare.noted.contains("the model cannot be switched here"))
    }

    @Test func statsReportTheTurnsAndHistoryListsWhatWasTyped() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = CallStats()
        // The first turn overflows with no condense policy and fails; the second answers.
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("done")], overflowOnce: true)),
            contextPolicy: .failFast)
        agent.stats = stats
        var context = Self.context
        context.stats = stats
        let capture = Capture(lines: ["boom", "fine", "fine", "  ", "/stats", "/history", "/quit"])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        #expect(stats.calls.count == 3)
        #expect(stats.calls.map { $0.failure != nil } == [true, false, false])
        #expect(stats.calls.allSatisfy { $0.kind == .turn && $0.model == "system" })
        let out = capture.output
        #expect(out.contains("3 calls this session"))
        #expect(out.contains("recent, by start time"))
        // A repeated line and a blank one are not added; /history lists itself last.
        #expect(loop.history == ["boom", "fine", "/stats", "/history", "/quit"])
        #expect(out.hasSuffix("1  boom\n2  fine\n3  /stats\n4  /history\n"))
        // Without a store the command says so.
        let bare = Capture(lines: ["/stats"])
        var plain = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: bare.io)
        try await plain.run()
        #expect(bare.noted.contains("stats are not kept here"))
    }

    @Test func configChangesTheFileAuditsAndSaysWhenItApplies() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(#"{"approval": {"timeoutSeconds": 0}}"#.utf8).write(to: file)
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()),
            audit: AuditLog(session: "chat", sink: sink))
        var context = Self.context
        context.configFile = file
        let capture = Capture(lines: [
            "/config set approval.classifier rules", "/config set approval.threshold sometimes", "/config list",
            "/config unset approval.timeoutSeconds", "/config frob", "/config",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let saved = try Config.load(from: file)
        #expect(saved.approval?.classifier == .rules && saved.approval?.timeoutSeconds == nil)
        let notes = capture.noted.joined(separator: "\n")
        #expect(
            notes.contains(
                "approval.classifier: (default) → rules; saved to \(file.path), and used from the next session on"))
        #expect(notes.contains("note: only the rules judge commands"))
        #expect(notes.contains("error: approval.threshold: 'sometimes' is not one of"))
        #expect(notes.contains("unknown /config frob"))
        #expect(capture.output.contains("approval.classifier") && capture.output.contains("(default)"))
        #expect(capture.output.contains("inspected config"))
        let changes = sink.events.filter { $0.kind == .configChange }
        #expect(changes.map { $0.details["path"] } == ["approval.classifier", "approval.timeoutSeconds"])
        #expect(changes.first?.details["source"] == "chat")
        // Without a config file the changes are refused and nothing is written.
        let bare = Capture(lines: ["/config set model system"])
        var unavailable = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: bare.io)
        try await unavailable.run()
        #expect(bare.noted.contains("the configuration cannot be changed here"))
    }

    @Test func configSetAsksForWhatIsLeftOutWithNumberedLists() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        var context = Self.context
        context.configFile = file
        context.configOptions = { setting in
            setting.kind == .model ? [ChatChoice.Option(value: "ollama:granite4.1:8b", detail: "5.4 GB")] : []
        }
        let classifier = String((ConfigSettings.all.firstIndex { $0.path == "approval.classifier" } ?? 0) + 1)
        let capture = Capture(lines: [
            "/config set", classifier, "1",  // the classifier, then rules
            "/config set model", "1",  // the one model offered, unset again below
            "/config set approval.timeoutSeconds", "30",  // typed
            "/config set approval.threshold", "",  // left as it was
            "/config set nosuch",
            "/config unset", "1",  // the first setting in the file
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let saved = try Config.load(from: file)
        // Unset offered the settings in the file in catalogue order; the first is the model.
        #expect(saved.model == nil && saved.approval?.classifier == .rules && saved.approval?.timeoutSeconds == 30)
        let out = capture.output
        #expect(out.contains("Which setting?") && out.contains("approval.classifier: what judges each command"))
        #expect(out.contains("  1  rules") && out.contains("  1  ollama:granite4.1:8b  5.4 GB"))
        #expect(
            out.contains("approval.timeoutSeconds: seconds to wait for an approval; 0 waits forever (now the default)"))
        #expect(out.contains("Which setting goes back to its default?"))
        #expect(capture.noted.contains("left as it was"))
        #expect(capture.noted.contains { $0.hasPrefix("error: no setting 'nosuch'") })
    }

    @Test func getStatusApprovalsAndAuditAreTheirOwnCommands() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(#"{"approval": {"classifier": "rules"}}"#.utf8).write(to: file)
        let store = ApprovalStore(url: dir.appending(path: "approvals.json"))
        let entry = try await store.grant(
            pattern: "git push *", directory: "/repo", scope: .project, level: .moderate, source: "test")
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        var context = Self.context
        context.configFile = file
        context.approvalStore = store
        context.inspect = { what in what == "audit" ? "one event" : #"{"view": "\#(what)", "ok": true}"# }
        let capture = Capture(lines: [
            "/config get approval.classifier", "/config get approval.threshold", "/config get nosuch", "/status",
            "/audit", "/approvals", "/inspect config", "/approvals revoke", "1", "/approvals revoke gone",
            "/approvals frob",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains("approval.classifier: rules  (set in config.json)"))
        #expect(out.contains("approval.threshold: moderate  (the default)"))
        #expect(
            out.contains("ok: true\nview: status") && out.contains("view: approvals") && out.contains("view: config"))
        #expect(out.contains("one event"))
        #expect(out.contains("Which approval goes?") && out.contains("git push *"))
        #expect(capture.noted.contains("revoked \(entry.id); it no longer applies, in this session or any other"))
        #expect(await store.all.isEmpty)
        #expect(capture.noted.contains("no standing approvals"), "the second revoke finds none")
        #expect(capture.noted.contains { $0.hasPrefix("error: no setting 'nosuch'") })
        #expect(capture.noted.contains { $0.hasPrefix("unknown /approvals frob") })
    }

    @Test func historyKeepsTheLatestLinesAndNumbersThemToAlign() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])))
        let lines = (0..<(ChatLoop.historyLimit + 5)).map { "/last \($0)" } + ["/history"]
        let capture = Capture(lines: lines)
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: Self.context, io: capture.io)
        try await loop.run()
        #expect(loop.history.count == ChatLoop.historyLimit)
        #expect(loop.history.first == "/last 6" && loop.history.last == "/history")
        #expect(capture.output.contains("\n  1  /last 6\n") && capture.output.hasSuffix("100  /history\n"))
    }

    @Test func endOfInputSavesUnderTheDefaultNameAndErrorsAreNotes() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        // Overflow with no condense policy is an error the loop reports and survives.
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("done")], overflowOnce: true)),
            contextPolicy: .failFast)
        let capture = Capture(lines: ["boom", "fine"])
        var loop = ChatLoop(agent: agent, store: store, saveName: "session", context: Self.context, io: capture.io)
        try await loop.run()
        #expect(capture.noted.contains { $0.hasPrefix("error: ") }, "\(capture.noted)")
        // Each message is one turn, marked at both ends; the failed one says so.
        #expect(capture.marks == ["start 1", "end 1 failed", "start 2", "end 2"], "\(capture.marks)")
        #expect(capture.output.hasSuffix("done\n"), "\(capture.output)")
        #expect(capture.noted.last == "saved 'session'")
        #expect(try store.list() == ["session"])
        // A condensed turn is announced, through the tap the agent's audit log feeds.
        let tap = ChatEvents.Tap()
        let condensing = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("after")], overflowOnce: true)),
            audit: AuditLog(session: "c", sink: tap))
        let second = Capture(lines: ["go", "/quit"])
        var again = ChatLoop(
            agent: condensing, store: store, saveName: nil, tap: tap, context: Self.context, io: second.io)
        try await again.run()
        #expect(second.noted.contains { $0.hasPrefix("(context condensed, overflow: ") })
        // A save that cannot happen is a note inside the loop and an error on exit.
        let unwritable = TranscriptStore(directory: dir.appending(path: "missing"))
        let third = Capture(lines: ["/save x", "/quit"])
        var broken = ChatLoop(agent: condensing, store: unwritable, saveName: nil, context: Self.context, io: third.io)
        try await broken.run()
        #expect(third.noted.contains { $0.hasPrefix("error: ") })
        var exiting = ChatLoop(
            agent: condensing, store: unwritable, saveName: "x", context: Self.context, io: Capture(lines: []).io)
        await #expect(throws: (any Error).self) { try await exiting.run() }
    }
}
