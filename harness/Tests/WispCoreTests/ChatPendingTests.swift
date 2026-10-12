import Darwin
import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Plain chat shows the requests waiting in `wisp mcp` servers between prompts and answers them with slash commands
/// (ADR 0046, note of 2026-10-12): a request filed by a stand-in server is noted once, answered through
/// `/approvals approve|deny` or `/facts keep|drop` with the channel's own checks, and reported once when it goes.
@Suite(.timeLimit(.minutes(1))) struct ChatPendingTests {
    /// A watcher over `channel` that may answer, following `auditFile` when given.
    private func watcher(
        _ channel: PendingApprovals, auditFile: URL? = nil, facts: SharedFacts? = nil, canAnswer: Bool = true
    ) -> ChatPending {
        ChatPending(
            channel: channel, facts: facts, auditFile: auditFile, canAnswer: canAnswer, patience: .seconds(2))
    }

    /// A scratch directory, removed by the caller.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stand-in for the waiting server: takes the answer to `request` as soon as one is written.
    private func serve(
        _ channel: PendingApprovals, _ request: PendingApprovals.Request
    ) -> Task<
        PendingApprovals.Answer?, Never
    > {
        Task {
            for _ in 0..<200 {
                if case .answer(let answer)? = channel.take(request) { return answer }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
    }

    @Test func nothingWaitingNotesNothing() {
        let channel = scratchChannel()
        let pending = watcher(channel)
        #expect(pending.notes().isEmpty)
        #expect(pending.waiting().isEmpty)
    }

    @Test func aWaitingCommandIsNotedOnceWithItsIdAndHowToAnswer() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let pending = watcher(channel)
        let request = PendingApprovals.request(for: approvalRequest(), client: "claude-code", timeout: nil)
        try channel.file(request)
        let notes = pending.notes()
        #expect(
            notes == [
                "⚠ \(request.id) waiting in wisp mcp (claude-code, thread git): run git push origin main in "
                    + "/tmp/repo, moderate",
                "  answer with /approvals approve ID [once|session|project|always] or /approvals deny ID",
            ])
        #expect(pending.notes().isEmpty, "never repeated")
        // A second request is noted, the hint not named again.
        let second = PendingApprovals.request(for: approvalRequest("git push --tags"), client: nil, timeout: nil)
        try channel.file(second)
        #expect(
            pending.notes() == [
                "⚠ \(second.id) waiting in wisp mcp (thread git): run git push --tags in "
                    + "/tmp/repo, moderate"
            ])
        // A chat that cannot answer says where to.
        let piped = watcher(channel, canAnswer: false)
        #expect(piped.notes().contains { $0.contains("from a terminal") })
    }

    @Test func aRequestAnsweredElsewhereOrWithdrawnIsReportedOnce() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let auditFile = dir.appending(path: "audit.jsonl")
        let server = AuditLog(session: "mcp", sink: try FileAuditSink(url: auditFile))
        let pending = watcher(channel, auditFile: auditFile)
        let tui = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        let gone = PendingApprovals.request(for: approvalRequest("git fetch"), client: nil, timeout: nil)
        try channel.file(tui)
        try channel.file(gone)
        #expect(pending.notes().count == 3)
        // The server takes wisp-tui's answer, then records how the request ended; the other is removed unexplained.
        try channel.answer(tui.id, decision: "once", via: "tui")
        guard case .answer? = channel.take(tui) else {
            Issue.record("no answer")
            return
        }
        server.record(
            .approvalSettled,
            details: AuditEvent.Details.approvalSettled(tui, outcome: "answered", via: "tui", decision: "once"))
        channel.withdraw(gone)
        let notes = pending.notes()
        #expect(notes.contains("· \(tui.id) no longer waiting: answered in wisp-tui (git push origin main)"))
        #expect(notes.contains("· \(gone.id) no longer waiting: answered elsewhere or withdrawn (git fetch)"))
        #expect(notes.count == 2)
        #expect(pending.notes().isEmpty, "reported once")
        #expect(
            ChatPending.ending(["outcome": "answered", "via": "elicitation"]) == "answered in the client's dialog")
        #expect(ChatPending.ending(["outcome": "timed-out"]) == "its wait ran out unanswered")
        #expect(ChatPending.ending(["outcome": "stale"]) == "withdrawn: its server stopped")
    }

    @Test func approvingThroughTheSlashCommandSettlesItForTheServer() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let request = PendingApprovals.request(for: approvalRequest(), client: "claude-code", timeout: nil)
        try channel.file(request)
        let server = serve(channel, request)
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()),
            audit: AuditLog(session: "chat", sink: sink))
        var context = ChatLoopTests.context
        context.pending = watcher(channel)
        let capture = ChatLoopTests.Capture(lines: ["/approvals approve \(request.id) session", "", "quit"])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let answer = await server.value
        #expect(answer?.decision == "session" && answer?.via == "chat")
        let notes = capture.noted
        #expect(notes.filter { $0.hasPrefix("⚠ \(request.id) waiting") }.count == 1, "\(notes)")
        #expect(notes.contains("approved (session): git push origin main for thread git"), "\(notes)")
        #expect(!notes.contains { $0.contains("no longer waiting") }, "answered here, so not reported again")
        let event = try #require(sink.events.last { $0.kind == .approvalAnswered })
        #expect(event.details["via"] == "chat" && event.details["delivery"] == "taken")
        #expect(event.details["decision"] == "session")
    }

    @Test func denyingChoosesFromWhatWaitsWhenNoIdIsGiven() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        let server = serve(channel, request)
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        var context = ChatLoopTests.context
        context.pending = watcher(channel)
        let capture = ChatLoopTests.Capture(lines: [
            "/approvals pending", "/approvals deny", "1", "/approvals pending", "/facts keep", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        #expect(await server.value?.decision == "no")
        let out = capture.output
        #expect(out.contains("Which command is refused?") && out.contains(request.id) && out.contains("COMMAND"))
        #expect(capture.noted.contains("denied: git push origin main for thread git"), "\(capture.noted)")
        #expect(capture.noted.contains("nothing waits in wisp mcp servers"))
        #expect(capture.noted.contains("no facts waiting to be kept"))
    }

    @Test func aFactToKeepIsNotedAndKeptThroughTheSlashCommand() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let store = SharedFacts.permanent(home: Home(root: dir.appending(path: "home")))
        let live = PendingApprovals.request(keeping: proposedFact(), thread: "git", client: nil, timeout: nil)
        // A fact request outlives its server: this one's has stopped, so the chat applies the answer itself.
        let orphan = PendingApprovals.request(
            keeping: proposedFact("c4", name: "mascot", value: "OTTER"), thread: "docs", client: nil, pid: 999_999,
            timeout: nil)
        try channel.file(live)
        try channel.file(orphan)
        let server = serve(channel, live)
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        var context = ChatLoopTests.context
        context.pending = watcher(channel, facts: store)
        let capture = ChatLoopTests.Capture(lines: [
            "/facts", "/facts drop \(live.id)", "/facts keep \(orphan.id)", "/approvals approve \(orphan.id)", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        #expect(await server.value?.decision == "drop")
        let notes = capture.noted
        #expect(
            notes.contains(
                "⚠ \(live.id) waiting in wisp mcp (thread git): keep as a permanent fact entity release codename = "
                    + "BLUE HERON, from model"), "\(notes)")
        #expect(notes.contains("  answer with /facts keep ID or /facts drop ID"))
        #expect(notes.contains("dropped, left in its thread: release codename = BLUE HERON (thread git)"), "\(notes)")
        #expect(
            notes.contains("kept as a permanent fact, p1: mascot = OTTER (thread docs); its server had stopped"),
            "\(notes)")
        #expect(store.current.map(\.value) == ["OTTER"])
        #expect(capture.output.contains("KEEP AS PERMANENT"))
        // A fact's id given to /approvals is refused with a pointer to /facts' words; it was answered already.
        #expect(notes.contains { $0.contains(orphan.id) && $0.contains("no pending request") }, "\(notes)")
    }

    @Test func aTamperedStaleOrUnknownRequestIsRefused() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "chat", sink: sink)
        let pending = watcher(channel)
        let request = PendingApprovals.request(for: approvalRequest("git status"), client: nil, timeout: nil)
        try channel.file(request)
        let file = channel.directory.appending(path: "\(request.id).request.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "git status", with: "git push --force")
        try Data(text.utf8).write(to: file)
        #expect(
            await pending.answer(request.id, decision: "once", audit: audit)
                == .failed("\(PendingApprovals.Failure.altered(request.id))"))
        #expect(channel.delivery(of: request.id) == .waiting, "no answer was written")
        #expect(sink.events.last?.details["delivery"] == "refused" && sink.events.last?.details["via"] == "chat")
        // Gone, stale, or of the other kind.
        #expect(
            await pending.answer("abcdef12", decision: "no", audit: nil)
                == .failed("\(PendingApprovals.Failure.unknown("abcdef12"))"))
        let dead = PendingApprovals.request(for: approvalRequest(), client: nil, pid: 999_999, timeout: nil)
        try channel.file(dead)
        #expect(
            await pending.answer(dead.id, decision: "no", audit: nil)
                == .failed("\(PendingApprovals.Failure.stale(dead.id))"))
        let fact = PendingApprovals.request(keeping: proposedFact(), thread: "git", client: nil, timeout: nil)
        try channel.file(fact)
        #expect(
            await pending.answer(fact.id, decision: "once", audit: nil)
                == .usage("\(PendingApprovals.Failure.otherKind(fact.id, .fact))"))
    }

    @Test func aChatWhoseInputIsNotATerminalDoesNotAnswer() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        let ending = await watcher(channel, canAnswer: false).answer(request.id, decision: "once", audit: nil)
        guard case .failed(let message) = ending else {
            Issue.record("answered: \(ending)")
            return
        }
        #expect(message.contains("not a terminal"))
        #expect(channel.delivery(of: request.id) == .waiting && channel.isFiled(request))
    }

    @Test func aFaceWithoutAWatcherSaysWhereToAnswer() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        let capture = ChatLoopTests.Capture(lines: ["/approvals pending", "/facts drop", "/facts frob", "quit"])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context,
            io: capture.io)
        try await loop.run()
        #expect(capture.noted.filter { $0 == ChatLoop.notWatched }.count == 3)
    }

    @Test func aQuestionIsNotedAndAnsweredWithTheAnswerTypedAtAPrompt() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let choice = PendingApprovals.request(
            asking: Question(text: "Which config?", options: ["~/.wisp", "./wisp.json"], thread: "git"),
            client: "claude-code")
        try channel.file(choice)
        let server = serve(channel, choice)
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()),
            audit: AuditLog(session: "chat", sink: sink))
        var context = ChatLoopTests.context
        context.pending = watcher(channel)
        // A word that is no option is asked again; then the second option by number.
        let capture = ChatLoopTests.Capture(lines: [
            "/approvals pending", "/questions answer \(choice.id)", "neither", "2", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let answer = await server.value
        #expect(answer?.decision == "chose" && answer?.text == "./wisp.json" && answer?.via == "chat")
        let notes = capture.noted
        #expect(
            notes.contains(
                "? \(choice.id) waiting in wisp mcp (claude-code, thread git): the model asks: Which config? "
                    + "(~/.wisp | ./wisp.json)"), "\(notes)")
        #expect(
            notes.contains(
                "  answer with /questions answer ID, which prompts for the answer, or /questions decline ID"))
        #expect(notes.contains("answered: Which config?; thread git reads it on its next turn"), "\(notes)")
        let out = capture.output
        #expect(out.contains("? the model asks") && out.contains("type a number from 1 to 3"), "\(out)")
        #expect(out.contains(choice.id), "/approvals pending lists the question: \(out)")
        let event = try #require(sink.events.last { $0.kind == .inquiryAnswered })
        #expect(event.details["inquiry"] == .string(choice.id))
        #expect(event.details["via"] == "chat" && event.details["delivery"] == "taken")
        #expect(!sink.events.contains { $0.kind == .approvalAnswered }, "a question is not an approval")
    }

    @Test func aFreeTextQuestionIsAnsweredAndAnotherDeclined() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let codename = PendingApprovals.request(asking: Question(text: "Codename?", thread: "docs"), client: nil)
        let mascot = PendingApprovals.request(asking: Question(text: "Mascot?", thread: "docs"), client: nil)
        try channel.file(codename)
        try channel.file(mascot)
        let first = serve(channel, codename)
        let second = serve(channel, mascot)
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        var context = ChatLoopTests.context
        context.pending = watcher(channel)
        // An empty line writes nothing; the free-text answer is the line typed; decline with no id chooses.
        let capture = ChatLoopTests.Capture(lines: [
            "/questions answer \(codename.id)", "", "/questions answer \(codename.id)", "BLUE HERON",
            "/questions decline", "1", "/questions", "/questions frob", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let answered = await first.value
        #expect(answered?.decision == "answer" && answered?.text == "BLUE HERON")
        #expect(await second.value?.decision == "decline")
        let notes = capture.noted
        #expect(notes.contains("no answer written; /questions decline \(codename.id) declines it"), "\(notes)")
        #expect(notes.contains("declined: Mascot?; thread docs reads it on its next turn"), "\(notes)")
        #expect(notes.contains("no questions waiting"), "\(notes)")
        #expect(notes.contains("unknown /questions frob; \(QuestionsRequest.usage)"), "\(notes)")
        #expect(capture.output.contains("Which question is declined?"))
    }

    @Test func aQuestionSettledElsewhereIsReportedOnceAndOnlyAPersonsChatAnswers() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let auditFile = dir.appending(path: "audit.jsonl")
        let server = AuditLog(session: "mcp", sink: try FileAuditSink(url: auditFile))
        let pending = watcher(channel, auditFile: auditFile)
        let question = Question(text: "Codename?", thread: "git")
        let request = PendingApprovals.request(asking: question, client: nil)
        try channel.file(request)
        #expect(pending.notes().count == 2)
        // A chat whose input is not a terminal neither prompts nor answers, and says where to answer.
        let piped = watcher(channel, canAnswer: false)
        #expect(piped.notes().contains("  answer in wisp-tui, or with wisp questions answer ID from a terminal"))
        let refused = await piped.answer(request.id, decision: "decline", audit: nil)
        guard case .failed(let message) = refused, message.contains("not a terminal") else {
            Issue.record("answered: \(refused)")
            return
        }
        #expect(channel.delivery(of: request.id) == .waiting && channel.isFiled(request))
        // Answered with wisp questions, the server records how it ended.
        try channel.answer(request.id, decision: "answer", text: "BLUE HERON", via: "cli")
        guard case .answer? = channel.take(request) else {
            Issue.record("no answer")
            return
        }
        server.record(
            .inquirySettled,
            details: AuditEvent.Details.inquirySettled(
                question, outcome: .answered("BLUE HERON"), via: "cli", delivered: "notice", redacted: []))
        #expect(pending.notes() == ["· \(request.id) no longer waiting: answered in wisp questions (Codename?)"])
        #expect(pending.notes().isEmpty, "reported once")
        #expect(ChatPending.questionEnding(["outcome": "declined", "via": "tui"]) == "declined in wisp-tui")
        #expect(ChatPending.questionEnding(["outcome": "withdrawn"]) == "withdrawn")
    }

    @Test func wispTuisInputPointsToItsPickerToAnswerAQuestion() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let channel = PendingApprovals(directory: dir.appending(path: "pending"))
        let request = PendingApprovals.request(asking: Question(text: "Codename?", thread: "git"), client: nil)
        try channel.file(request)
        let server = serve(channel, request)
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        var context = ChatLoopTests.context
        context.pending = ChatPending(
            channel: channel, facts: nil, auditFile: nil, canAnswer: true, shows: false, via: "tui",
            patience: .seconds(2))
        let capture = ChatLoopTests.Capture(lines: [
            "/questions answer \(request.id)", "/questions decline \(request.id)", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        try await loop.run()
        let answer = await server.value
        #expect(answer?.decision == "decline" && answer?.via == "tui")
        #expect(capture.noted.contains { $0.contains("open in wisp-tui's picker") }, "\(capture.noted)")
        #expect(!capture.output.contains("? the model asks"), "the picker asks, not the input")
    }

    @Test func theCommandsParseAndComplete() {
        #expect(ChatInput(line: "/approvals pending") == .approvals(.pending))
        #expect(ChatInput(line: "/approvals approve ab12") == .approvals(.approve("ab12", scope: .once)))
        #expect(ChatInput(line: "/approvals approve ab12 project") == .approvals(.approve("ab12", scope: .project)))
        #expect(ChatInput(line: "/approvals approve session") == .approvals(.approve(nil, scope: .session)))
        #expect(ChatInput(line: "/approvals approve a b") == .approvals(.unknown("approve a b")))
        #expect(ChatInput(line: "/approvals deny") == .approvals(.deny(nil)))
        #expect(ChatInput(line: "/approvals deny ab12") == .approvals(.deny("ab12")))
        #expect(ChatInput(line: "/facts") == .pendingFacts(.pending))
        #expect(ChatInput(line: "/facts pending") == .pendingFacts(.pending))
        #expect(ChatInput(line: "/facts keep ab12") == .pendingFacts(.keep("ab12")))
        #expect(ChatInput(line: "/facts drop") == .pendingFacts(.drop(nil)))
        #expect(ChatInput(line: "/facts keep a b") == .pendingFacts(.unknown("keep a b")))
        let complete = { (text: String) in
            ChatCompletion.complete(text, pendingCommands: ["ab12", "cd34"], pendingFacts: ["ef56"]).candidates
        }
        #expect(complete("/approvals ") == ["approve", "deny", "list", "pending", "revoke"])
        #expect(complete("/approvals approve a") == ["ab12"])
        #expect(complete("/approvals approve ab12 s") == ["session"])
        #expect(complete("/approvals deny ") == ["ab12", "cd34"])
        #expect(complete("/facts ") == ["drop", "keep", "pending"])
        #expect(complete("/facts keep ") == ["ef56"])
        #expect(complete("/fa") == ["/fact", "/facts"])
        #expect(ChatInput(line: "/questions") == .questions(.pending))
        #expect(ChatInput(line: "/questions answer ab12") == .questions(.answer("ab12")))
        #expect(ChatInput(line: "/questions decline") == .questions(.decline(nil)))
        #expect(ChatInput(line: "/questions answer a b") == .questions(.unknown("answer a b")))
        let questions = { (text: String) in ChatCompletion.complete(text, pendingQuestions: ["gh78"]).candidates }
        #expect(questions("/questions ") == ["answer", "decline", "pending"])
        #expect(questions("/questions answer ") == ["gh78"])
        #expect(questions("/questions decline g") == ["gh78"])
        #expect(complete("/qu") == ["/questions", "/quit"])
        #expect(ChatInput.helpText.contains("/approvals approve [ID] [once|session|project|always]"))
    }
}
