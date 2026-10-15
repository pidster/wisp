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
            model: "ollama:q", directory: "~/src/x", vcs: "git", branch: "main", dirty: false, approval: "--yes",
            contextUsed: 0.137)
        #expect(full.rendered(style: .plain) == "ollama:q 14% used · ~/src/x git(main) · --yes")
        #expect(
            full.rendered(style: .plain, width: 50) == "ollama:q 14% used · ~/src/x git(main)"
                + String(repeating: " ", count: 8) + "--yes")
        #expect(full.rendered(style: .plain, width: 20) == full.rendered(style: .plain))
        let bare = ChatStatus(model: "system", directory: "/tmp", approval: "never asks")
        #expect(bare.rendered(style: .plain) == "system · /tmp · never asks")
        // A model that can think says whether it does, after its name; another system names itself as git does.
        var thinking = full
        thinking.thinking = "off"
        thinking.vcs = "svn"
        thinking.branch = "trunk"
        #expect(thinking.rendered(style: .plain) == "ollama:q (off) 14% used · ~/src/x svn(trunk) · --yes")
        let styled = full.rendered(style: Style(enabled: true))
        #expect(Style.stripped(styled) == full.rendered(style: .plain))
        #expect(styled.contains("\u{1B}[38;2;143;211;244mollama:q") && styled.contains("38;2;134;174;200m14% used"))
        let nearlyFull = ChatStatus(model: "m", directory: "/", approval: "x", contextUsed: 0.85).rendered(
            style: Style(enabled: true))
        #expect(nearlyFull.contains("38;2;242;185;80m85% used"))
        // From half the window the use is bright, below half quiet; the branch is bright too.
        let half = ChatStatus(model: "m", directory: "~/w", branch: "main", approval: "x", contextUsed: 0.6)
            .rendered(style: Style(enabled: true))
        #expect(half.contains("38;2;207;241;255m60% used") && half.contains("38;2;207;241;255mmain"), "\(half)")
        #expect(Style(enabled: true).tokensOut("↑1") == Style(enabled: true).glow("↑1"))
        let changed = ChatStatus(
            model: "m", directory: "~/w", branch: "main", dirty: true, added: 12, removed: 3, approval: "x"
        ).rendered(style: Style(enabled: true))
        #expect(changed.contains("38;2;126;217;143m+12") && changed.contains("38;2;255;107;107m-3"))
        let unborn = ChatStatus(model: "m", directory: "~/w", vcs: "git", branch: "main", dirty: true, approval: "x")
        #expect(unborn.rendered(style: .plain) == "m · ~/w git(main)* · x")
        // A system that cannot tell its branch (svn without its tool) is still named.
        #expect(
            ChatStatus(model: "m", directory: "~/w", vcs: "svn", approval: "x").rendered(style: .plain)
                == "m · ~/w svn · x")
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
        #expect(VersionControl.read(in: dir.appending(path: "wt").path).branch == "chat-config")
        // A relative gitdir is taken from the root.
        try Data("gitdir: ../main/.git/worktrees/wt\n".utf8).write(to: dir.appending(path: "wt/.git"))
        #expect(GitState.gitDirectory(of: dir.appending(path: "wt").path).hasSuffix("main/.git/worktrees/wt"))
    }

    @Test func versionControlReadsThisRepositoryAsGitAndNothingElsewhere() throws {
        let here = FileManager.default.currentDirectoryPath
        let state = VersionControl.read(in: here)
        #expect(state.system == .git && state.branch != nil && state.dirty != nil && state.added != nil, "\(state)")
        #expect(GitState.lineCounts("12\t3\ta.swift\n-\t-\tlogo.png\n0\t0\tscript.sh\n") == (12, 3, 3))
        #expect(GitState.lineCounts("") == (0, 0, 0))
        #expect(
            VersionControl.workingCopy(of: here + "/Sources")?.1 == VersionControl.workingCopy(of: here)?.1)
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(VersionControl.read(in: dir.path) == VersionControl.Summary())
        // A detached HEAD shows a short hash; a branch its name.
        let fake = dir.appending(path: ".git")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/x\n".utf8).write(to: fake.appending(path: "HEAD"))
        #expect(VersionControl.read(in: dir.path).branch == "feature/x")
        try Data("0123456789abcdef\n".utf8).write(to: fake.appending(path: "HEAD"))
        #expect(VersionControl.read(in: dir.path).branch == "01234567")
    }

    @Test func subversionIsFoundByItsMarkerAndReadFromItsOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-svn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: ".svn"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: "src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try #require(VersionControl.workingCopy(of: dir.appending(path: "src").path))
        #expect(
            found.0 == .svn
                && URL(fileURLWithPath: found.1).resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
        // With or without the svn tool, the system is named; this Mac's tool, if any, cannot read a fake working copy.
        #expect(VersionControl.read(in: dir.path).system == .svn)
        #expect(SubversionState.branch(fromRelativeURL: "^/trunk/src\n") == "trunk")
        #expect(SubversionState.branch(fromRelativeURL: "^/branches/release-2/docs") == "release-2")
        #expect(SubversionState.branch(fromRelativeURL: "^/tags/v1.0") == "v1.0")
        #expect(SubversionState.branch(fromRelativeURL: "^/project") == "project")
        #expect(SubversionState.branch(fromRelativeURL: "^/") == nil)
        let diff = """
            Index: a.c
            ===================================================================
            --- a.c\t(revision 4)
            +++ a.c\t(working copy)
            @@ -1,3 +1,4 @@
             keep
            -old
            +new
            +more
            Index: b.c
            ===================================================================
            --- b.c\t(revision 4)
            +++ b.c\t(working copy)
            @@ -1 +0,0 @@
            -gone
            """
        #expect(SubversionState.lineCounts(diff) == (2, 2, 2))
        #expect(SubversionState.lineCounts("") == (0, 0, 0))
        // A clean tree is told by status alone, with no diff; a dirty one is counted, or, when the diff is too slow,
        // shown dirty without counts. Without the tool, only the system is known.
        func read(status: String?, diff: String?) -> (VersionControl.Summary, [String]) {
            let asked = Mutex<[String]>([])
            let summary = SubversionState.read(root: dir.path) { arguments, _, timeout in
                asked.withLock { $0.append("\(arguments[0]) \(Int(timeout))") }
                switch arguments[0] {
                case "info": return "^/branches/release-2\n"
                case "status": return status
                default: return diff
                }
            }
            return (summary, asked.withLock { $0 })
        }
        let clean = read(status: "\n", diff: nil)
        #expect(clean.0 == .init(branch: "release-2", dirty: false, added: 0, removed: 0))
        #expect(clean.1 == ["info 2", "status 2"], "no diff for a clean tree")
        let counted = read(status: "M       a.c\n", diff: diff)
        #expect(counted.0 == .init(branch: "release-2", dirty: true, added: 2, removed: 2))
        #expect(counted.1 == ["info 2", "status 2", "diff 5"], "the diff has longer")
        #expect(read(status: "M       a.c\n", diff: nil).0 == .init(branch: "release-2", dirty: true))
        #expect(read(status: nil, diff: nil).0 == .init(branch: "release-2"))
    }

    @Test func aVersionControlCommandIsStoppedAtItsLimit() throws {
        let dir = FileManager.default.temporaryDirectory.path
        let started = Date()
        #expect(VersionControl.run("sleep", ["5"], in: dir, timeout: 0.2) == nil)
        #expect(Date().timeIntervalSince(started) < 2, "stopped at the limit, not when it ended")
        #expect(VersionControl.run("echo", ["hello"], in: dir) == "hello\n")
        #expect(VersionControl.run("false", [], in: dir) == nil)
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
        #expect(
            event(.approvalDecided, ["decision": "cached-project"]) == "  · allowed by your approval for this project")
        #expect(
            event(.approvalDecided, ["decision": "cached-turn"]) == "  · allowed: approved once earlier in this turn")
        #expect(event(.approvalDecided, ["decision": "something-new"]) == "  · something-new")
        #expect(
            ChatEvents.progress(
                AuditEvent(
                    session: "s", kind: .approvalRequested, details: ["command": "git push", "level": "dangerous"]))
                == "waiting for approval [dangerous]: git push")
        #expect(
            ChatEvents.progress(AuditEvent(session: "s", kind: .approvalDecided, details: ["decision": "denied"]))
                == "· denied")
        #expect(ChatEvents.progress(AuditEvent(session: "s", kind: .prompt, details: [:])) == nil)
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
        activity.apply(event(.condensation, ["reason": "window"]))
        #expect(activity.current?.doing == "condensing the context")
        activity.apply(event(.toolCall, ["tool": "read_file", "arguments": #"{"path":"a.md"}"#]))
        #expect(activity.current?.doing == "read_file a.md")
        activity.end()
        #expect(
            seen.withLock { $0 }
                == [
                    "waiting for the model", "running git status", "waiting for your approval", "waiting for the model",
                    "condensing the context", "read_file a.md", nil,
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
                == "  3.2 s · ↓4,009 ↑79")
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

    @Test func liveToolEventsReachTheChatNotesThroughTheThread() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-events-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing())
        let tap = ChatEvents.Tap()
        let notes = Mutex<[String]>([])
        // The real conversation set-up with the tap observing; the model is scripted through a custom
        // agent over the same tools and audit, as the wire tests do.
        let thread = try WispThread.setUp(
            session: session, audit: session.audit, host: session.host(approver: DenyingApprover(reason: "x")),
            prompting: session.prompting,
            toolNames: ["current_date"], model: .system, observer: tap)
        let agent = Agent(
            instructions: "x", tools: thread.tools,
            model: ResolvedModel(selection: .system, custom: ScriptedModel()), audit: thread.audit)
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
