import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A command the person types after `!!` in chat (ADR 0064, amended 2026-10-14): parsed as theirs to run outside the
/// sandbox, run without `sandbox-exec` and without asking (typing it is the approval), under the same lists, refused
/// when the operator turned it off, changing nothing with the sandbox off or inside another sandbox, and audited and
/// told to the model as run outside.
@Suite struct PersonOutsideSandboxTests {
    /// The runner's own once-per-process probe; enforcement cannot be asserted when nested.
    static let nested = CommandRunner.isNestedSandbox

    /// A scratch directory under the temporary directory.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-person-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An agent on a scripted model whose runner, rooted at `dir` under `policy`, has a gate whose classifier counts
    /// and whose approver records and refuses, so a test can prove neither was consulted; the audit goes to `sink` and
    /// the chat's tap.
    private func agent(
        in dir: URL, policy: CommandPolicy = .default, steps: [ScriptedModel.Step] = [.say("ok")]
    ) -> (
        agent: Agent, model: ScriptedModel, sink: MemoryAuditSink, tap: ChatEvents.Tap,
        classifier: CommandRunnerPolicyTests.CountingClassifier, approver: TypedCommandTests.RecordingApprover
    ) {
        let sink = MemoryAuditSink()
        let tap = ChatEvents.Tap()
        let audit = AuditLog(session: "chat", sink: TeeAuditSink([sink, tap]))
        let classifier = CommandRunnerPolicyTests.CountingClassifier()
        let approver = TypedCommandTests.RecordingApprover()
        let gate = ApprovalGate(classifier: classifier, approver: approver, threshold: .level(.safe), audit: audit)
        let model = ScriptedModel(steps: steps)
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model), audit: audit)
        agent.commandRunner = CommandRunner(
            options: .init(writableRoot: dir.path, policy: policy), audit: audit, approval: gate)
        return (agent, model, sink, tap, classifier, approver)
    }

    /// The details of the last event of `kind`.
    private func last(_ kind: AuditEvent.Kind, _ sink: MemoryAuditSink) -> [String: JSONValue] {
        sink.events.last { $0.kind == kind }?.details ?? [:]
    }

    @Test func twoMarksTogetherAreACommandOutsideTheSandbox() {
        #expect(ChatInput(line: "!!brew upgrade") == .command("brew upgrade", outsideSandbox: true))
        #expect(ChatInput(line: "!! cargo install x ") == .command("cargo install x", outsideSandbox: true))
        #expect(ChatInput(line: "  !!ls") == .command("ls", outsideSandbox: true))
        // `!!` alone runs nothing, as `!` alone does.
        #expect(ChatInput(line: "!!") == .command("", outsideSandbox: true))
        #expect(ChatInput(line: "!!   ") == .command("", outsideSandbox: true))
        // Only the two marks together: with a space between them it is an ordinary command whose text is `!x`.
        #expect(ChatInput(line: "! !x") == .command("!x"))
        #expect(ChatInput(line: "! !x") != .command("!x", outsideSandbox: true))
        #expect(ChatInput(line: "!x") == .command("x"))
        #expect(ChatInput(line: "!!!x") == .command("!x", outsideSandbox: true))
        #expect(ChatInput(line: "why !!") == .message("why !!"))
        // `/help` lists it, and wisp-tui's keys say how to reach it.
        #expect(ChatInput.helpText.contains("!!COMMAND") && ChatInput.helpText.contains("OUTSIDE the sandbox"))
        #expect(ChatInput.helpText(frontEnd: true).contains("outside the sandbox (red)"))
    }

    @Test func itAsksNobodyAndRunsOutsideTheSandboxUnlessNested() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir)
        let runner = try #require(made.agent.commandRunner)
        let outcome = try await runner.run("echo hi", in: dir.path, origin: .person, outsideSandbox: true)
        #expect(outcome.stdout == "hi\n" && outcome.exitStatus == 0)
        // Typing it is the approval: no classifier, no question, at any threshold.
        #expect(made.classifier.count.withLock { $0 } == 0 && made.approver.asked.withLock { $0 }.isEmpty)
        #expect(!made.sink.events.contains { [.classifierVerdict, .approvalRequested].contains($0.kind) })
        let decision = last(.policyDecision, made.sink)
        let result = last(.commandOutcome, made.sink)
        #expect(decision["origin"] == "person" && result["origin"] == "person" && decision["verdict"] == "allowed")
        if Self.nested {
            #expect(!outcome.outsideSandbox && decision["outsideSandboxIgnored"] == "nested")
            #expect(outcome.outsideNote?.contains("wisp runs inside another sandbox") == true)
        } else {
            #expect(outcome.outsideSandbox && decision["outsideSandbox"] == true && decision["sandbox"] == false)
            #expect(result["outsideSandbox"] == true)
            #expect(outcome.outsideNote == "sandbox: ran outside the sandbox, as the person typed it after !!")
        }
        #expect(Set(decision.keys).isSubset(of: AuditEvent.fields(for: .policyDecision)))
        #expect(Set(result.keys).isSubset(of: AuditEvent.fields(for: .commandOutcome)))
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func aWriteOutsideTheRootsIsRefusedAfterOneMarkAndMadeAfterTwo() async throws {
        let dir = try scratch()
        // The home directory is outside the writable set; a scratch directory there is the target.
        let target = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "wisp-person-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: target)
        }
        let file = target.appending(path: "written.txt").path
        let made = agent(in: dir, steps: [.say("ok")])
        let command = "touch '\(file)'"
        let confined = await made.agent.runTyped(command, in: dir.path)
        guard case .ran(_, _, let refused) = confined.result else {
            Issue.record("\(confined.result)")
            return
        }
        #expect(refused && !FileManager.default.fileExists(atPath: file))
        let outside = await made.agent.runTyped(command, in: dir.path, outsideSandbox: true)
        guard case .ran(let outcome, let entry, let refusedOutside) = outside.result else {
            Issue.record("\(outside.result)")
            return
        }
        #expect(outcome.exitStatus == 0 && !refusedOutside && FileManager.default.fileExists(atPath: file))
        #expect(made.approver.asked.withLock { $0 }.isEmpty && made.classifier.count.withLock { $0 } == 0)
        // The audit marks the line, and chat says before it runs that it runs outside.
        let typed = try #require(made.sink.events.last { $0.kind == .commandTyped })
        #expect(typed.details["outsideSandbox"] == true && typed.details["sandboxRefused"] == false)
        #expect(typed.summary.hasSuffix("exit=0 !! \(command)"))
        #expect(Set(typed.details.keys).isSubset(of: AuditEvent.fields(for: .commandTyped)))
        let decision = try #require(made.sink.events.last { $0.kind == .policyDecision })
        #expect(
            ChatEvents.render(decision, style: .plain)
                == "  ! running OUTSIDE the sandbox, as you typed it: it may write anywhere you can")
        #expect(ChatEvents.render(typed, style: .plain) == nil)
        // The entry and the model's notice say it ran outside the sandbox.
        let stored = try #require(made.agent.store.entries.first { $0.id == entry })
        #expect(stored.command?.outsideSandbox == true)
        _ = try await made.agent.respond(to: "what did I do?")
        let request = try #require(made.model.script.requests.withLock { $0 }.last)
        let notices = request.transcript.map { ThreadRecord.text(of: $0) }.filter { $0.hasPrefix("[the person ran") }
        #expect(notices.count == 2)
        #expect(notices.last?.contains("` themselves, outside the sandbox, in /") == true, "\(notices)")
        #expect(notices.first?.contains("` themselves in /") == true, "\(notices)")
        // A command run in the sandbox carries no mark.
        #expect(made.sink.events.first { $0.kind == .commandTyped }?.details["outsideSandbox"] == nil)
    }

    @Test func theOperatorsSwitchOffRefusesItWithTextAndOneMarkStillRuns() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir, policy: CommandPolicy(sandbox: .init(allowOutsideSandbox: false)))
        let typed = await made.agent.runTyped("echo hi", in: dir.path, outsideSandbox: true)
        let reason = CommandRunner.OutsideSandbox.turnedOffForThePerson
        #expect(typed.result == .refused(.denied(reason)))
        #expect(reason.contains("allowOutsideSandbox is false") && reason.contains("a single !"))
        #expect(!made.sink.events.contains { $0.kind == .commandOutcome })
        let decision = try #require(made.sink.events.last { $0.kind == .policyDecision })
        #expect(decision.details["verdict"] == "denied" && decision.details["outsideSandbox"] == true)
        #expect(ChatEvents.render(decision, style: .plain) == "  · blocked by policy: " + reason)
        let event = try #require(made.sink.events.last { $0.kind == .commandTyped })
        #expect(event.details["outsideSandbox"] == true && event.details["verdict"] == "denied")
        #expect(event.summary.hasSuffix(": denied !! echo hi"))
        #expect(!made.agent.store.entries.contains { $0.kind == .command })
        // After one mark the same command runs in the sandbox, as ever.
        let plain = await made.agent.runTyped("echo hi", in: dir.path)
        guard case .ran(let outcome, _, _) = plain.result else {
            Issue.record("\(plain.result)")
            return
        }
        #expect(outcome.stdout == "hi\n")
    }

    @Test func theDenyListStillApplies() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir, policy: CommandPolicy(deny: ["forbidden-word"]))
        let typed = await made.agent.runTyped("echo forbidden-word", in: dir.path, outsideSandbox: true)
        #expect(typed.result == .refused(.denied("command matches deny pattern forbidden-word")))
        #expect(!made.sink.events.contains { $0.kind == .commandOutcome })
        #expect(last(.policyDecision, made.sink)["origin"] == "person")
    }

    @Test func withTheSandboxOffItChangesNothingAndSaysSo() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir, policy: CommandPolicy(sandbox: .init(enabled: false)))
        let typed = await made.agent.runTyped("echo hi", in: dir.path, outsideSandbox: true)
        guard case .ran(let outcome, let entry, _) = typed.result else {
            Issue.record("\(typed.result)")
            return
        }
        #expect(outcome.stdout == "hi\n" && !outcome.outsideSandbox)
        let decision = try #require(made.sink.events.last { $0.kind == .policyDecision })
        #expect(decision.details["outsideSandboxIgnored"] == "sandbox-off")
        #expect(
            ChatEvents.render(decision, style: .plain)?.contains("!! changes nothing here: the sandbox is off") == true)
        #expect(last(.commandOutcome, made.sink)["outsideSandbox"] == nil)
        // Its entry is not marked: it ran as any command does here.
        #expect(made.agent.store.entries.first { $0.id == entry }?.command?.outsideSandbox == false)
        // The nested note reads as its own.
        let nested = AuditEvent.Details.policyDecision(
            command: "ls", workingDirectory: "/w", verdict: .allowed, reason: nil, sandbox: false, network: false,
            nested: true, origin: .person, outside: .unchanged(.nested))
        #expect(
            ChatEvents.outside(nested, style: .plain)
                == "  · !! changes nothing here: wisp runs inside another sandbox, which confines this command")
        // A command typed after one mark, and the model's, get no line from their allowed decision.
        let one = AuditEvent.Details.policyDecision(
            command: "ls", workingDirectory: "/w", verdict: .allowed, reason: nil, sandbox: true, network: false,
            nested: false, origin: .person)
        #expect(ChatEvents.render(AuditEvent(session: "s", kind: .policyDecision, details: one), style: .plain) == nil)
    }

    @Test func aRecordSavedBeforeTheMarkReadsAndTheMarkRoundTrips() throws {
        let old = Data(#"{"line":"ls","directory":"/w","exitStatus":0,"timedOut":false,"truncated":false}"#.utf8)
        #expect(try JSONDecoder().decode(ThreadRecord.PersonCommand.self, from: old).outsideSandbox == false)
        let marked = ThreadRecord.PersonCommand(line: "ls", directory: "/w", exitStatus: 0, outsideSandbox: true)
        let data = try JSONEncoder().encode(marked)
        #expect(try JSONDecoder().decode(ThreadRecord.PersonCommand.self, from: data) == marked)
        // Unmarked, the key is not written.
        let plain = try JSONEncoder().encode(ThreadRecord.PersonCommand(line: "ls", directory: "/w", exitStatus: 0))
        #expect(!String(decoding: plain, as: UTF8.self).contains("outsideSandbox"))
        #expect(FactDistiller.line(for: marked).contains("themselves, outside the sandbox, in /w"))
    }

    @Test func chatRunsItShowsItAndTheBareMarksRunNothing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = agent(in: dir)
        let commands = Mutex<[String]>([])
        let capture = ChatLoopTests.Capture(lines: ["!!", "!! echo outside", "/quit"])
        var io = capture.io
        io.command = { line in commands.withLock { $0.append(line) } }
        var context = ChatLoopTests.context
        context.directory = dir.path
        let activity = ChatActivity()
        let doing = Mutex<[String?]>([])
        activity.onChange { state in doing.withLock { $0.append(state?.doing) } }
        context.activity = activity
        var loop = ChatLoop(
            agent: made.agent, tap: made.tap,
            context: context, io: io)
        try await loop.run()
        let noted = capture.noted
        #expect(noted.contains("nothing to run: type a command after !!, as in !! brew upgrade"))
        #expect(commands.withLock { $0 } == ["!! echo outside"])
        #expect(doing.withLock { $0 }.first == "running echo outside outside the sandbox")
        if Self.nested {
            #expect(noted.contains { $0.contains("!! changes nothing here: wisp runs inside another sandbox") })
        } else {
            #expect(noted.contains("  ! running OUTSIDE the sandbox, as you typed it: it may write anywhere you can"))
        }
        #expect(noted.contains("  ↳ exit 0"))
        #expect(made.model.script.requests.withLock { $0 }.isEmpty && made.approver.asked.withLock { $0 }.isEmpty)
        // The plain chat's marker takes the outside colour for a `!!` line, the command colour for a `!` line.
        let colour = Style(enabled: true)
        #expect(
            ChatLoop.commandMarker(for: "!!ls", width: 80, style: colour)
                == "\u{1B}[1A\r" + colour.outside("›") + "\u{1B}[1B\r")
        #expect(
            ChatLoop.commandMarker(for: "! !ls", width: 80, style: colour)
                == "\u{1B}[1A\r" + colour.command("›") + "\u{1B}[1B\r")
        #expect(colour.outside("›").contains("38;2;210;112;104"))
        // The palette's two outside colours, which the gate's palette check holds equal to wisp-tui's, apart from
        // the danger colours.
        #expect(Style.Palette.outside == (0xD2, 0x70, 0x68) && Style.Palette.outsideSent == (0x69, 0x38, 0x34))
        #expect(Style.Palette.outside != Style.Palette.ember && Style.Palette.outside != Style.Palette.removed)
    }
}
