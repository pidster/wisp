import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Commands the person types in chat after `!` (ADR 0049): the parsing, which checks apply, what chat shows,
/// what the next request carries, the facts, and the audit.
@Suite struct TypedCommandTests {
    /// An approver that records every request and refuses it, so a test can prove it was never asked.
    final class RecordingApprover: Approver {
        let asked = Mutex<[String]>([])
        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            asked.withLock { $0.append(request.command) }
            return .denied("asked")
        }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-typed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An agent on a scripted model whose runner is `run_command`'s, with a gate that counts and refuses, and
    /// the audit in memory.
    private func agent(
        in dir: URL, steps: [ScriptedModel.Step] = [.say("ok")], policy: CommandPolicy = .default
    ) -> (
        agent: Agent, model: ScriptedModel, sink: MemoryAuditSink,
        classifier: CommandRunnerPolicyTests.CountingClassifier, approver: RecordingApprover
    ) {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "chat", sink: sink)
        let classifier = CommandRunnerPolicyTests.CountingClassifier()
        let approver = RecordingApprover()
        let gate = ApprovalGate(classifier: classifier, approver: approver, threshold: .level(.moderate), audit: audit)
        let model = ScriptedModel(steps: steps)
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model), audit: audit)
        agent.commandRunner = CommandRunner(
            options: .init(writableRoot: dir.path, policy: policy), audit: audit, approval: gate)
        return (agent, model, sink, classifier, approver)
    }

    @Test func aLineThatStartsWithABangIsACommand() {
        #expect(ChatInput(line: "!git status") == .command("git status"))
        #expect(ChatInput(line: "! git status --short") == .command("git status --short"))
        #expect(ChatInput(line: "   !ls -la  ") == .command("ls -la"))
        #expect(ChatInput(line: "!") == .command(""))
        #expect(ChatInput(line: "!   ") == .command(""))
        #expect(ChatInput(line: "! ") == .command(""))
        // A `!` inside a message, or after other text, is text.
        #expect(ChatInput(line: "run the tests!") == .message("run the tests!"))
        #expect(ChatInput(line: "why does ! git fail") == .message("why does ! git fail"))
        #expect(ChatInput(line: "/show !x") == .show("!x"))
        // `/help` lists it, though it is not a slash word.
        #expect(ChatInput.helpText.contains("!COMMAND") && ChatInput.helpText.contains("without asking"))
        #expect(ChatInput.helpText(frontEnd: true).contains("command mode"))
    }

    @Test func thePersonsCommandPassesThePolicyAndSandboxButNotTheClassifierOrApproval() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let classifier = CommandRunnerPolicyTests.CountingClassifier()
        let approver = RecordingApprover()
        let gate = ApprovalGate(classifier: classifier, approver: approver, threshold: .level(.moderate), audit: audit)
        let runner = CommandRunner(options: .init(writableRoot: dir.path), audit: audit, approval: gate)
        // Typed: the classifier rates everything moderate and the approver refuses, yet neither is consulted.
        let outcome = try await runner.run("echo typed > typed.txt && cat typed.txt", in: dir.path, origin: .person)
        #expect(outcome.exitStatus == 0 && outcome.stdout == "typed\n", "\(outcome.stderr)")
        #expect(classifier.count.withLock { $0 } == 0 && approver.asked.withLock { $0 }.isEmpty)
        #expect(!sink.events.contains { [.classifierVerdict, .approvalRequested, .approvalDecided].contains($0.kind) })
        let decision = try #require(sink.events.first { $0.kind == .policyDecision })
        #expect(decision.details["verdict"] == "allowed" && decision.details["origin"] == "person")
        #expect(decision.details["sandbox"] == .bool(runner.confines))
        #expect(sink.events.first { $0.kind == .commandOutcome }?.details["origin"] == "person")
        // The same command from the model is classified and asked, and refused here.
        await #expect(throws: CommandRunner.Failure.disapproved("asked")) {
            try await runner.run("echo model", in: dir.path)
        }
        #expect(classifier.count.withLock { $0 } == 1 && approver.asked.withLock { $0 } == ["echo model"])
        // The model's events carry no origin, as before.
        #expect(sink.events.last { $0.kind == .policyDecision }?.details["origin"] == nil)
        // The policy's lists apply to the person as to the model.
        let strict = CommandRunner(
            options: .init(writableRoot: dir.path, policy: CommandPolicy(deny: ["secret"])), audit: audit,
            approval: gate)
        await #expect(throws: CommandRunner.Failure.denied("command matches deny pattern secret")) {
            try await strict.run("echo secret", in: dir.path, origin: .person)
        }
        #expect(sink.events.last { $0.kind == .policyDecision }?.details["verdict"] == "denied")
        #expect(classifier.count.withLock { $0 } == 1)
    }

    @Test func aDeniedCommandIsRefusedWithTheReasonAndNotToldToTheModel() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir, policy: CommandPolicy(deny: ["secret"]))
        let typed = await made.agent.runTyped("cat secret.txt", in: dir.path)
        #expect(typed.result == .refused(.denied("command matches deny pattern secret")))
        let event = try #require(made.sink.events.first { $0.kind == .commandTyped })
        #expect(
            event.details["verdict"] == "denied" && event.details["reason"] == "command matches deny pattern secret")
        #expect(event.details["exitStatus"] == nil && event.details["output"] == "")
        #expect(!made.agent.store.entries.contains { $0.kind == .command })
        // Chat shows the policy's line for it; the typed event adds nothing.
        let decision = try #require(made.sink.events.first { $0.kind == .policyDecision })
        #expect(
            ChatEvents.render(decision, style: .plain) == "  · blocked by policy: command matches deny pattern secret")
        #expect(ChatEvents.render(event, style: .plain) == nil)
        // A missing directory is not a denial: the command could not start, and chat says why.
        let missing = await made.agent.runTyped("ls", in: dir.appending(path: "gone").path)
        #expect(missing.result == .refused(.invalidWorkingDirectory(dir.appending(path: "gone").path)))
        let failed = try #require(made.sink.events.last { $0.kind == .commandTyped })
        #expect(failed.details["verdict"] == "allowed" && failed.details["failure"] != nil)
        #expect(ChatEvents.render(failed, style: .plain)?.contains("could not run it: working directory") == true)
        // Without a runner nothing runs.
        let bare = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])))
        #expect(await bare.runTyped("ls", in: dir.path).result == .unavailable)
    }

    @Test(.enabled(if: !CommandRunnerPolicyTests.nested, "enforcement cannot be asserted inside an outer sandbox"))
    func aSandboxRefusalFailsAsForTheModelAndSaysSo() async throws {
        let dir = try scratch()
        let blocked = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "wisp-typed-blocked-\(UUID().uuidString).txt").path
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(atPath: blocked)
        }
        let made = agent(in: dir)
        let typed = await made.agent.runTyped("echo x > '\(blocked)'", in: dir.path)
        guard case .ran(let outcome, _, let refused) = typed.result else {
            Issue.record("\(typed.result)")
            return
        }
        #expect(outcome.exitStatus != 0 && refused && !FileManager.default.fileExists(atPath: blocked))
        let event = try #require(made.sink.events.first { $0.kind == .commandTyped })
        #expect(event.details["sandboxRefused"] == .bool(true))
        #expect(ChatEvents.render(event, style: .plain)?.contains("the sandbox refused it") == true)
        #expect(made.classifier.count.withLock { $0 } == 0)
    }

    @Test func theNextRequestCarriesTheCommandAsThePersonsWithItsReference() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir, steps: [.say("ok"), .say("again")])
        // A short output goes whole with the notice.
        let short = await made.agent.runTyped("printf 'alpha\\nbeta\\n'", in: dir.path)
        guard case .ran(let outcome, let entry, false) = short.result else {
            Issue.record("\(short.result)")
            return
        }
        #expect(outcome.stdout == "alpha\nbeta\n")
        let stored = try #require(made.agent.store.entries.first { $0.id == entry })
        #expect(stored.kind == .command && stored.turn == 1 && stored.state == .active)
        #expect(stored.command?.line == "printf 'alpha\\nbeta\\n'" && stored.command?.directory == dir.path)
        #expect(ThreadRecord.text(of: stored.value) == "alpha\nbeta\n")
        let typedEvent = try #require(made.sink.events.first { $0.kind == .commandTyped })
        #expect(stored.sources.first?.event == typedEvent.id)
        #expect(typedEvent.details["output"] == "alpha\nbeta\n" && typedEvent.details["bytes"] == .int(11))
        #expect(typedEvent.details["exitStatus"] == .int(0) && typedEvent.details["verdict"] == "allowed")
        // No model turn started.
        #expect(made.model.script.requests.withLock { $0 }.isEmpty && made.agent.turns.current == 0)
        #expect(!made.sink.events.contains { $0.kind == .prompt })
        _ = try await made.agent.respond(to: "what did I see?")
        let first = try #require(made.model.script.requests.withLock { $0 }.last)
        let notices = first.transcript.compactMap { entry -> String? in
            guard case .prompt = entry else { return nil }
            return ThreadRecord.text(of: entry)
        }
        let notice = try #require(notices.first { $0.hasPrefix("[the person ran") })
        #expect(notice.contains("`printf 'alpha\\nbeta\\n'` themselves in \(dir.path)"))
        #expect(notice.contains("(exit status 0, 2 lines); this was not your action; its output:]\nalpha\nbeta"))
        // It comes before the request, and is never a reply or a tool call of the model's.
        #expect(notices.last == "what did I see?")
        #expect(
            !first.transcript.contains { entry in
                if case .response = entry { return ThreadRecord.text(of: entry).contains("alpha") }
                if case .toolCalls = entry { return true }
                return false
            })
        // A long output goes as a reference: its first and last lines, not repeated whole.
        _ = await made.agent.runTyped("seq 1 400", in: dir.path)
        _ = try await made.agent.respond(to: "and now?")
        let second = try #require(made.model.script.requests.withLock { $0 }.last)
        let long = try #require(
            second.transcript.compactMap { entry -> String? in
                guard case .prompt = entry else { return nil }
                let text = ThreadRecord.text(of: entry)
                return text.contains("`seq 1 400`") ? text : nil
            }.first)
        #expect(long.contains("(exit status 0, 400 lines)") && long.contains("its output is not repeated"))
        #expect(long.contains("first line: 1") && long.contains("last line: 400") && !long.contains("\n200\n"))
        #expect(long.utf8.count < OutputReference.maxBytes)
        // The earlier command is still carried as its notice, under the same id, after its turn.
        #expect(second.transcript.contains { ThreadRecord.text(of: $0).hasPrefix("[the person ran `printf") })
    }

    @Test func theContextViewTheSidecarAndTheTurnsCarryTheEntry() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir, steps: [.say("one"), .say("two")])
        _ = try await made.agent.respond(to: "first")
        let typed = await made.agent.runTyped("echo between", in: dir.path)
        guard case .ran(_, let entry, _) = typed.result else {
            Issue.record("\(typed.result)")
            return
        }
        // The next request's context shows it as the person's, sent as its notice.
        let next = try #require(made.agent.composition(atTurn: nil))
        let item = try #require(next.first { $0.entry.id == entry })
        #expect(!item.own && ThreadRecord.text(of: item.sent).hasPrefix("[the person ran `echo between`"))
        let markdown = ContextView.markdown(next, title: "The next request")
        #expect(markdown.contains("## \(entry) · turn 2 · the person's command\n\n[the person ran `echo between`"))
        _ = try await made.agent.respond(to: "second")
        // Turn 1's context, rebuilt, does not have it; turn 2's does, as before the turn's own entries.
        let earlier = try #require(made.agent.composition(atTurn: 1))
        #expect(!earlier.contains { $0.entry.id == entry })
        let atTwo = try #require(made.agent.composition(atTurn: 2))
        let carried = try #require(atTwo.first { $0.entry.id == entry })
        #expect(!carried.own && ThreadRecord.text(of: carried.sent).hasPrefix("[the person ran"))
        #expect(ContextView.turns(of: made.agent).map(\.prompt) == ["first", "second"])
        // The headroom's turn groups leave it out: it is not the model's work.
        #expect(!made.agent.store.turnGroups.flatMap { $0 }.contains { $0.id == entry })
        // Saved and restored, it keeps its kind and what was run.
        let snapshot = made.agent.store.snapshot
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ThreadRecord.Snapshot.self, from: data)
        let restored = try #require(decoded.restored(over: made.agent.store.active))
        let back = try #require(restored.entries.first { $0.id == entry })
        #expect(back.kind == .command && back.command?.line == "echo between" && back.origin == .resumed)
        // A record that claims a command without saying what ran does not restore.
        var broken = decoded
        broken.entries[entry - 1].command = nil
        #expect(broken.restored(over: made.agent.store.active) == nil)
        // `/show` finds its output by entry number and by event id.
        #expect(ChatEvents.output("\(entry)", in: made.agent.store, last: nil) == "between\n")
        let id = try #require(back.sources.first?.event)
        #expect(ChatEvents.output(String(id.prefix(8)), in: made.agent.store, last: nil) == "between\n")
    }

    @Test func factsComeFromTheOutputWithThePersonAsTheirSourceAndMemoryRecallsIt() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
        let thread = try WispThread.setUp(
            session: session, audit: session.audit,
            host: session.host(approver: DenyingApprover(reason: "not in tests")),
            prompting: session.prompting, toolNames: ["run_command", "memory"], model: .system)
        let model = ScriptedModel(steps: [.say("noted")])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        #expect(agent.commandRunner != nil)
        let typed = await agent.runTyped("seq 1 300", in: dir.path)
        guard case .ran(_, let entry, _) = typed.result else {
            Issue.record("\(typed.result)")
            return
        }
        let workdir = try #require(typed.facts.first { $0.identity.subject == "workdir" })
        #expect(workdir.source == .person && workdir.value == dir.standardizedFileURL.path)
        #expect(agent.allFacts.contains { $0.id == workdir.id && $0.source == .person })
        #expect(sink.events.contains { $0.kind == .factRecorded })
        // With memory, the notice says how to recall the output; recall reads it back whole.
        _ = try await agent.respond(to: "what did I run?")
        let request = try #require(model.script.requests.withLock { $0 }.last)
        let notice = try #require(
            request.transcript.map { ThreadRecord.text(of: $0) }.first { $0.hasPrefix("[the person ran `seq") })
        #expect(notice.contains("to see the output: memory \"recall entry \(entry)\""))
        let material = MemorySource.Material(store: agent.store, facts: agent.allFacts)
        let typedEvent = try #require(sink.events.first { $0.kind == .commandTyped })
        let recalled = Recall.material(
            .entry(entry), in: material, read: { $0.event == typedEvent.id ? typedEvent : nil })
        #expect(recalled.header.hasPrefix("entry \(entry): the person's command `seq 1 300` in \(dir.path)"))
        #expect(recalled.from == "audit" && recalled.lines.count == 301 && recalled.lines[299] == "300")
        let copied = Recall.material(.entry(entry), in: material, read: { _ in nil })
        #expect(copied.from == "store" && copied.lines.first == "1")
        // A turn's new facts do not repeat the command's.
        #expect(!(agent.factsChangedThisTurn.contains { $0.id == workdir.id }))
    }

    @Test func chatRunsTheCommandWithoutATurnShowsItsOutputFoldedAndShowsItAgain() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let tap = ChatEvents.Tap()
        let observed = AuditLog(session: "chat", sink: TeeAuditSink([sink, tap]))
        let model = ScriptedModel(steps: [])
        let made = (
            agent: Agent(
                instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model), audit: observed),
            model: model, sink: sink
        )
        made.agent.commandRunner = CommandRunner(options: .init(writableRoot: dir.path), audit: observed)
        let commands = Mutex<[String]>([])
        let capture = ChatLoopTests.Capture(lines: [
            "! printf 'one\\ntwo\\nthree\\nfour\\n'", "!", "!   ", "/show", "/last", "/quit",
        ])
        var io = capture.io
        io.command = { line in commands.withLock { $0.append(line) } }
        var context = ChatLoopTests.context
        context.directory = dir.path
        context.shownOutputLines = 2
        let activity = ChatActivity()
        let doing = Mutex<[String?]>([])
        activity.onChange { state in doing.withLock { $0.append(state?.doing) } }
        context.activity = activity
        var loop = ChatLoop(
            agent: made.agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: io)
        try await loop.run()
        let noted = capture.noted
        // The outcome line, then the first two lines and the fold with the handle /show takes.
        #expect(noted.contains("  ↳ exit 0"))
        let shown = try #require(noted.first { $0.hasPrefix("    one") })
        let id = try #require(made.sink.events.first { $0.kind == .commandTyped }?.id)
        #expect(shown == "    one\n    two\n    … 2 more lines, 19 bytes in all: /show \(id.prefix(8))")
        // A bare `!` runs nothing and says so; no model turn ever starts.
        #expect(noted.filter { $0.hasPrefix("nothing to run") }.count == 2)
        #expect(capture.marks.isEmpty && made.model.script.requests.withLock { $0 }.isEmpty)
        #expect(made.sink.events.filter { $0.kind == .commandTyped }.count == 1)
        // /show and /last print it whole.
        #expect(capture.output.components(separatedBy: "one\ntwo\nthree\nfour\n").count == 3)
        // The face was told the line, to colour its marker, and the activity said what ran, then ended.
        #expect(commands.withLock { $0 } == ["! printf 'one\\ntwo\\nthree\\nfour\\n'"])
        #expect(doing.withLock { $0 }.first == "running printf 'one\\ntwo\\nthree\\nfour\\n'")
        #expect(doing.withLock { $0 }.last == .some(nil))
        #expect(loop.history.first == "! printf 'one\\ntwo\\nthree\\nfour\\n'")
    }

    @Test func theHeadlessProtocolCarriesTheCommandsOutputForTheFrontEnd() throws {
        let event = AuditEvent(
            session: "s", kind: .commandTyped,
            details: AuditEvent.Details.commandTyped(
                command: "ls", workingDirectory: "/w", verdict: .allowed,
                outcome: CommandRunner.Outcome(
                    exitStatus: 0, stdout: "a\nb\n", stderr: "", timedOut: false, truncated: false),
                output: "a\nb\n", seconds: 0.1))
        let fields = ChatProtocol.event(event, shownLines: 5)
        #expect(fields["kind"] == "command.typed" && fields["text"] == .null)
        let output = try #require(fields["output"]?.objectValue)
        #expect(output["text"] == "a\nb\n" && output["lines"] == .int(2) && output["shownLines"] == .int(5))
        #expect(output["id"] == event.id.map { .string($0) })
        // A command that printed nothing, or was denied, carries no output to show.
        let silent = AuditEvent(
            session: "s", kind: .commandTyped,
            details: AuditEvent.Details.commandTyped(
                command: "true", workingDirectory: "/w", verdict: .denied, reason: "no", seconds: 0))
        #expect(ChatProtocol.event(silent)["output"] == nil)
        #expect(event.summary.hasSuffix("command.typed session=s: exit=0 ! ls"))
        #expect(silent.summary.hasSuffix(": denied ! true"))
        // The documented fields are the ones written.
        let written = Set(event.details.keys).union(silent.details.keys)
        #expect(written.isSubset(of: AuditEvent.fields(for: .commandTyped)))
    }

    @Test func plainChatColoursTheMarkerOfACommandsLine() {
        let colour = Style(enabled: true)
        #expect(
            ChatLoop.commandMarker(for: "!ls", width: 80, style: colour)
                == "\u{1B}[1A\r" + colour.command("›") + "\u{1B}[1B\r")
        #expect(colour.command("›").contains("38;2;232;181;119"))
        // A line that wrapped moves up over every row it took.
        let long = String(repeating: "x", count: 100)
        #expect(ChatLoop.commandMarker(for: "!" + long, width: 40, style: colour)?.hasPrefix("\u{1B}[3A") == true)
        #expect(ChatLoop.commandMarker(for: "!ls", width: nil, style: colour) == nil)
        #expect(ChatLoop.commandMarker(for: "!ls", width: 80, style: .plain) == nil)
        // The palette's two command colours, which the gate's palette check holds equal to wisp-tui's.
        #expect(Style.Palette.command == (0xE8, 0xB5, 0x77) && Style.Palette.commandSent == (0x74, 0x5A, 0x3C))
    }

    @Test func aRecordedCommandIsNeverATurnOfItsOwnInCondensing() {
        var store = ThreadRecord()
        store.record(
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "hello"))])), origin: .turn, turn: 1,
            sources: [])
        store.record(
            command: ThreadRecord.PersonCommand(line: "ls", directory: "/w", exitStatus: 0), output: "a\n", turn: 2,
            sources: [], time: Date())
        #expect(store.carriesCommands && store.entries.last?.kind == .command)
        #expect(ThreadRecord.Kind.command.holds(store.entries[1].value))
        #expect(!ThreadRecord.Kind.response.holds(store.entries[1].value))
        // Every switch off, the command is still sent as its notice, never as the bare output.
        var composer = ContextComposer()
        composer.cutsPresentation = false
        composer.referencesOutput = false
        let sent = composer.compose(store).map { ThreadRecord.text(of: $0) }
        #expect(sent.last?.hasPrefix("[the person ran `ls` themselves in /w") == true)
        #expect(!sent.contains("a\n"))
        // A command that printed nothing says so.
        let silent = OutputReference.personCommand(
            .init(line: "true", directory: "/w", exitStatus: 0), entry: 3, time: nil, output: "")
        #expect(silent.hasSuffix("(exit status 0, 0 lines); this was not your action; it printed nothing]"))
        let timedOut = OutputReference.personCommand(
            .init(line: "sleep 99", directory: "/w", exitStatus: -15, timedOut: true, truncated: true), entry: 4,
            time: nil, output: String(repeating: "line\n", count: 200), recallable: true)
        #expect(timedOut.contains("(exit status -15, timed out, 200 lines)") && timedOut.contains("first line: …line"))
    }
}
