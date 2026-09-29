import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct ChatUITests {
    @Test func styleIsOffWhenPipedOrAskedAndWrapsOtherwise() {
        #expect(Style.plain.bold("x") == "x")
        #expect(Style.detect(isTerminal: false, environment: [:]) == .plain)
        #expect(Style.detect(isTerminal: true, environment: ["NO_COLOR": ""]) == .plain)
        #expect(Style.detect(isTerminal: true, environment: ["TERM": "dumb"]) == .plain)
        let on = Style.detect(isTerminal: true, environment: [:])
        #expect(on.enabled)
        #expect(on.bold("x") == "\u{1B}[1mx\u{1B}[0m" && on.dim("x") == "\u{1B}[2mx\u{1B}[0m")
        #expect(on.level(.dangerous) == "\u{1B}[38;2;255;107;107mdangerous\u{1B}[0m")
        #expect(on.level(.safe).contains("38;2;143;211;244m") && on.level(.moderate).contains("38;2;242;185;80m"))
        #expect(on.prompt("›").hasPrefix("\u{1B}[1m\u{1B}[38;2;207;241;255m›"))
        #expect(on.muted("x") == "\u{1B}[38;2;134;174;200mx\u{1B}[0m")
        #expect(Style.stripped(on.magenta(on.bold("ab"))) == "ab")
    }

    @Test func statusLineRendersWhatIsKnown() {
        let full = ChatStatus(
            model: "ollama:q", directory: "~/src/x", branch: "main", dirty: false, approval: "--yes", contextUsed: 0.137
        )
        #expect(full.rendered(style: .plain) == "ollama:q · ~/src/x · main · clean · --yes · context 14% used")
        let bare = ChatStatus(model: "system", directory: "/tmp", approval: "never asks")
        #expect(bare.rendered(style: .plain) == "system · /tmp · never asks")
        let styled = full.rendered(style: Style(enabled: true))
        #expect(Style.stripped(styled) == full.rendered(style: .plain))
        #expect(styled.contains("\u{1B}[38;2;143;211;244mollama:q") && styled.contains("38;2;134;174;200mcontext"))
        let nearlyFull = ChatStatus(model: "m", directory: "/", approval: "x", contextUsed: 0.85).rendered(
            style: Style(enabled: true))
        #expect(nearlyFull.contains("38;2;242;185;80mcontext 85% used"))
        #expect(ChatStatus.abbreviated("/Users/me/src", home: "/Users/me") == "~/src")
        #expect(ChatStatus.abbreviated("/Users/me", home: "/Users/me") == "~")
        #expect(ChatStatus.abbreviated("/Users/meg/src", home: "/Users/me") == "/Users/meg/src")
        #expect(ChatStatus.approvalMode(threshold: .level(.moderate), autoApprove: false) == "approve at moderate")
        #expect(ChatStatus.approvalMode(threshold: .never, autoApprove: false) == "never asks")
        #expect(ChatStatus.approvalMode(threshold: .never, autoApprove: true) == "--yes")
    }

    @Test func aWorktreesGitFilePointsAtItsOwnHead() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-worktree-\(UUID().uuidString)")
        let gitdir = dir.appending(path: "main/.git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: "wt"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("ref: refs/heads/chat-config\n".utf8).write(to: gitdir.appending(path: "HEAD"))
        try Data("gitdir: \(gitdir.path)\n".utf8).write(to: dir.appending(path: "wt/.git"))
        #expect(GitState.read(in: dir.appending(path: "wt").path).branch == "chat-config")
        // A relative gitdir is taken from the root.
        try Data("gitdir: ../main/.git/worktrees/wt\n".utf8).write(to: dir.appending(path: "wt/.git"))
        #expect(GitState.gitDirectory(of: dir.appending(path: "wt").path).hasSuffix("main/.git/worktrees/wt"))
    }

    @Test func gitStateReadsThisRepositoryAndNothingElsewhere() throws {
        let here = FileManager.default.currentDirectoryPath
        let state = GitState.read(in: here)
        #expect(state.branch != nil && state.dirty != nil, "\(state)")
        #expect(GitState.repositoryRoot(of: here + "/Sources") == GitState.repositoryRoot(of: here))
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitState.read(in: dir.path) == (nil, nil))
        // A detached HEAD shows a short hash; a branch its name.
        let fake = dir.appending(path: ".git")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/x\n".utf8).write(to: fake.appending(path: "HEAD"))
        #expect(GitState.read(in: dir.path).branch == "feature/x")
        try Data("0123456789abcdef\n".utf8).write(to: fake.appending(path: "HEAD"))
        #expect(GitState.read(in: dir.path).branch == "01234567")
    }

    @Test func theGatesDecisionsAndRoutingAreShownToo() {
        func event(_ kind: AuditEvent.Kind, _ details: [String: JSONValue]) -> String? {
            ChatEvents.render(AuditEvent(session: "s", kind: kind, turn: 1, details: details), style: .plain)
        }
        #expect(
            event(
                .classifierVerdict,
                ["level": "safe", "sources": ["rules"], "reasons": ["a known read-only command"], "seconds": 0.0002])
                == "  · safe by rules: a known read-only command (0.2 ms)")
        #expect(
            event(
                .classifierVerdict,
                [
                    "command": "rm -rf build", "line": "make && rm -rf build", "level": "dangerous",
                    "sources": ["rules", "coreml"], "reasons": ["deletes files"], "seconds": 0.02,
                    "metadata": ["classifier.cached": true],
                ]) == "  · rm -rf build: dangerous by rules, coreml: deletes files (remembered)")
        #expect(event(.classifierVerdict, ["level": "moderate", "seconds": 0.25]) == "  · moderate (250 ms)")
        #expect(event(.approvalDecided, ["decision": "approved", "scope": "session"]) == "  · approved (session)")
        #expect(event(.approvalDecided, ["decision": "cached-always"]) == "  · allowed by your standing approval")
        #expect(event(.approvalDecided, ["decision": "cached"]) == "  · allowed by your approval for this session")
        #expect(event(.approvalDecided, ["decision": "timed-out"]) == "  · no answer in time, denied")
        #expect(event(.approvalDecided, ["decision": "denied"]) == "  · denied")
        #expect(event(.policyDecision, ["verdict": "allowed"]) == nil)
        #expect(
            event(.policyDecision, ["verdict": "denied", "reason": "matches deny rule"])
                == "  · blocked by policy: matches deny rule")
        #expect(
            event(.modelRouted, ["task": "secrets", "model": "system", "reason": "the measured default"])
                == "  · secrets runs on system: the measured default")
    }

    @Test func theActivityFollowsTheTurnFromModelToCommandToApprovalAndBack() {
        let activity = ChatActivity()
        let seen = Mutex<[String?]>([])
        activity.onChange { state in seen.withLock { $0.append(state?.doing) } }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ kind: AuditEvent.Kind, _ details: [String: JSONValue] = [:]) -> AuditEvent {
            AuditEvent(session: "s", kind: kind, turn: 1, call: "c", details: details)
        }
        activity.apply(event(.toolCall, ["tool": "current_date", "arguments": "{}"]))
        #expect(activity.current == nil)
        activity.begin(at: start)
        activity.apply(
            event(.toolCall, ["tool": "run_command", "arguments": #"{"command":"git status"}"#]),
            at: start.addingTimeInterval(4))
        let running = activity.current
        #expect(running?.doing == "running git status" && running?.asking == false)
        #expect(
            running.map { ChatActivity.line($0, now: start.addingTimeInterval(12)) }
                == "12 s · running git status (8 s)")
        activity.apply(event(.approvalRequested, ["command": "git push"]), at: start.addingTimeInterval(5))
        #expect(activity.current?.asking == true && activity.current?.doing == "waiting for your approval")
        activity.apply(event(.prompt), at: start.addingTimeInterval(6))
        #expect(activity.current?.doing == "waiting for your approval")
        activity.apply(event(.commandOutcome), at: start.addingTimeInterval(7))
        activity.apply(event(.toolCall, ["tool": "read_file", "arguments": #"{"path":"a.md"}"#]))
        #expect(activity.current?.doing == "read_file a.md")
        activity.end()
        #expect(
            seen.withLock { $0 }
                == [
                    "waiting for the model", "running git status", "waiting for your approval", "waiting for the model",
                    "read_file a.md", nil,
                ])
        let fresh = ChatActivity.State(doing: "waiting for the model", since: start, turnStarted: start, asking: false)
        #expect(ChatActivity.line(fresh, now: start.addingTimeInterval(3)) == "3 s · waiting for the model")
        #expect(ChatProtocol.activity(nil) == ["doing": .null])
        #expect(ChatProtocol.activity(running)["turnSeconds"] == .double(4))
    }

    @Test func aTurnsFooterSaysHowLongItTookAndWhatTokensItUsed() {
        let tokens = TurnTokens(input: 4009, output: 79)
        #expect(
            ChatTurn.end(turn: 1, seconds: 3.16, failed: false, tokens: tokens).footer(style: .plain)
                == "  3.2 s · 4,009 tokens in, 79 out")
        #expect(ChatTurn.end(turn: 1, seconds: 0.5, failed: true).footer(style: .plain) == "  failed after 0.5 s")
        #expect(ChatTurn.start(turn: 1).footer(style: .plain) == nil)
        #expect(TurnTokens.between(.init(input: 100, output: 10), .init(input: 4109, output: 89)) == tokens)
        #expect(TurnTokens.between(.init(input: 5, output: 5), .init(input: 5, output: 5)) == nil)
        #expect(
            ChatProtocol.turn(.end(turn: 2, seconds: 1, failed: false, tokens: tokens))["inputTokens"] == 4009)
    }

    @Test func eventsRenderAsOneDimLineEach() {
        func event(_ kind: AuditEvent.Kind, call: String? = "c", _ details: [String: JSONValue]) -> AuditEvent {
            AuditEvent(session: "s", kind: kind, turn: 1, call: call, details: details)
        }
        let style = Style.plain
        #expect(
            ChatEvents.render(
                event(
                    .toolCall,
                    ["tool": "run_command", "arguments": #"{"command":"git status","workingDirectory":"/r"}"#]),
                style: style)
                == "⚙ run_command git status")
        #expect(
            ChatEvents.render(
                event(.toolCall, ["tool": "read_file", "arguments": #"{"path":"/r/README.md","offset":101}"#]),
                style: style)
                == "⚙ read_file /r/README.md from line 101")
        #expect(
            ChatEvents.render(
                event(
                    .toolCall, ["tool": "edit_file", "arguments": #"{"path":"a.txt","mode":"append","content":"x"}"#]),
                style: style)
                == "⚙ edit_file append a.txt")
        #expect(
            ChatEvents.render(event(.toolCall, ["tool": "other", "arguments": "{\"k\":1}"]), style: style)
                == "⚙ other {\"k\":1}")
        #expect(
            ChatEvents.render(
                event(.toolResult, ["tool": "read_file", "output": "1\tline\n2\tmore", "bytes": 14, "seconds": 0.04]),
                style: style)
                == "  ↳ 14 bytes in 0.0 s: 1\tline")
        #expect(
            ChatEvents.render(event(.commandOutcome, ["command": "x", "exitStatus": 0]), style: style) == "  ↳ exit 0")
        #expect(
            ChatEvents.render(
                event(.commandOutcome, ["command": "x", "exitStatus": 1, "timedOut": true, "truncated": true]),
                style: style)
                == "  ↳ exit 1 (timed out, output truncated)")
        #expect(
            ChatEvents.render(event(.fileWrite, ["path": "a", "mode": "write", "bytesAfter": 9]), style: style)
                == "  ↳ write a, now 9 bytes")
        #expect(ChatEvents.render(event(.error, ["message": "boom"]), style: style) == "  ↳ error: boom")
        #expect(ChatEvents.render(event(.error, call: nil, ["message": "turn failed"]), style: style) == nil)
        #expect(
            ChatEvents.render(
                event(.condensation, ["reason": "budget", "turnsBefore": 4, "turnsAfter": 1]), style: style)
                == "(context condensed, budget: 4 → 1 turns)")
        #expect(ChatEvents.render(event(.prompt, ["text": "hi"]), style: style) == nil)
        #expect(ChatEvents.shortened(String(repeating: "x", count: 120)).count == 101)
        #expect(ChatEvents.firstSentence(of: "Does a thing. Then more.") == "Does a thing.")
        #expect(ChatEvents.firstSentence(of: "No period") == "No period")
        let styled = ChatEvents.render(
            event(.commandOutcome, ["command": "x", "exitStatus": 2]), style: Style(enabled: true))
        #expect(styled?.contains("38;2;255;107;107mexit 2") == true)
    }

    @Test func aCommandsResultLineIsLeftToItsOutcome() {
        let result = AuditEvent(
            session: "s", kind: .toolResult, turn: 1, call: "c",
            details: ["tool": "run_command", "output": "exit status: 0", "bytes": 14])
        #expect(ChatEvents.render(result, style: .plain) == nil)
    }

    @Test func tapForwardsEventsAndKeepsTheLastToolOutput() {
        let tap = ChatEvents.Tap()
        let seen = Mutex<[AuditEvent.Kind]>([])
        tap.write(AuditEvent(session: "s", kind: .prompt))  // before a handler: nothing breaks
        tap.onEvent { event in seen.withLock { $0.append(event.kind) } }
        tap.write(
            AuditEvent(session: "s", kind: .toolResult, call: "c", details: ["tool": "t", "output": "full output"]))
        #expect(seen.withLock { $0 } == [.toolResult])
        #expect(tap.lastToolOutput == "full output")
    }

    @Test func liveToolEventsReachTheChatNotesThroughTheConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-events-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing())
        let tap = ChatEvents.Tap()
        let notes = Mutex<[String]>([])
        // The real conversation set-up with the tap observing; the model is scripted through a custom
        // agent over the same tools and audit, as the wire tests do.
        let conversation = try Conversation.setUp(
            session: session, audit: session.audit, approver: DenyingApprover(reason: "x"),
            prompting: session.prompting,
            toolNames: ["current_date"], model: .system, observer: tap)
        let agent = Agent(
            instructions: "x", tools: conversation.tools,
            model: ResolvedModel(selection: .system, custom: ScriptedModel()), audit: conversation.audit)
        tap.onEvent { event in
            if let line = ChatEvents.render(event, style: .plain) { notes.withLock { $0.append(line) } }
        }
        _ = try await agent.respond(to: "date?")
        let lines = notes.withLock { $0 }
        #expect(lines.first == "⚙ current_date Asia/Tokyo")
        #expect(lines.count == 2 && lines[1].hasPrefix("  ↳ ") && lines[1].contains("bytes"))
        #expect(tap.lastToolOutput?.contains("Asia/Tokyo") == true)
    }

    @Test func approvalDialogIsCompactAndStyled() {
        let request = ApprovalRequest(
            command: "git push origin main",
            line: "git add -A && git push origin main", pattern: "git push *",
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path + "/src/x",
            assessment: RiskAssessment(
                level: .dangerous, reasons: ["changes repository state", String(repeating: "r", count: 130)],
                sources: ["rules"]))
        let text = TerminalApprover.render(request, style: .plain)
        #expect(
            text
                == """

                ⚠ approve [dangerous] git push origin main
                  part of: git add -A && git push origin main
                  in ~/src/x
                  - changes repository state
                  - \(String(repeating: "r", count: 110))…
                  remembered as: git push *
                  [y]once  [s]ession  [p]roject 30d  [a]lways 30d  [n]o › \u{20}
                """.replacingOccurrences(of: "› \u{20}", with: "› "))
        let same = ApprovalRequest(
            command: "ls", line: "ls", pattern: "ls *", workingDirectory: "/tmp",
            assessment: RiskAssessment(level: .moderate, reasons: [], sources: []))
        #expect(!TerminalApprover.render(same, style: .plain).contains("part of"))
        let styled = TerminalApprover.render(request, style: Style(enabled: true))
        #expect(styled.contains("38;2;255;107;107mdangerous") && Style.stripped(styled) == text)
        #expect(TerminalApprover(style: Style(enabled: true)).style.enabled)
    }
}
