import Foundation
import Synchronization
import Testing

@testable import WispCore

/// `run_command`'s `outsideSandbox` (ADR 0064): after the policy's lists, the person is asked about the whole line
/// every time, whatever its level, and approved, it runs without wisp's sandbox, this once; nothing held covers it,
/// a channel that asks no person refuses it, the operator can turn it off, and it changes nothing with the sandbox off
/// or inside another sandbox.
@Suite struct OutsideSandboxTests {
    /// The runner's own once-per-process probe; enforcement cannot be asserted when nested.
    static let nested = CommandRunner.isNestedSandbox

    /// Answers each request from a script, in order, keeping each request; once the script runs out it refuses.
    final class Answering: Approver {
        let answers: Mutex<[ApprovalDecision]>
        let asked = Mutex<[ApprovalRequest]>([])

        init(_ answers: [ApprovalDecision]) { self.answers = Mutex(answers) }

        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            asked.withLock { $0.append(request) }
            return answers.withLock { $0.isEmpty ? .denied("no more answers") : $0.removeFirst() }
        }

        var requests: [ApprovalRequest] { asked.withLock { $0 } }
    }

    /// A scratch directory under the temporary directory.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A gate over `approver` at `threshold`, the rules alone judging, recording on `sink`.
    private func gate(
        _ approver: any Approver, threshold: ApprovalThreshold = .default, sink: MemoryAuditSink,
        store: ApprovalStore? = nil, sessionApprovals: SessionApprovals = SessionApprovals()
    ) -> ApprovalGate {
        ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: approver, threshold: threshold,
            audit: AuditLog(session: "t", sink: sink), store: store, sessionApprovals: sessionApprovals)
    }

    /// A runner rooted at `root` over `gate`, its policy `policy`, recording on `sink`.
    private func runner(
        root: URL, gate: ApprovalGate?, sink: MemoryAuditSink, policy: CommandPolicy = .default,
        protected: [String]? = nil
    ) -> CommandRunner {
        CommandRunner(
            options: .init(writableRoot: root.path, policy: policy, protectedPaths: protected),
            audit: AuditLog(session: "t", sink: sink), approval: gate)
    }

    /// The details of the last event of `kind`.
    private func last(_ kind: AuditEvent.Kind, _ sink: MemoryAuditSink) -> [String: JSONValue] {
        sink.events.last { $0.kind == kind }?.details ?? [:]
    }

    // MARK: What a request comes to

    @Test func aRequestAppliesOnlyWithTheSandboxOnTheSwitchOnAndNoOuterSandbox() {
        let on = CommandPolicy.Sandbox()
        typealias Outside = CommandRunner.OutsideSandbox
        #expect(Outside.resolve(requested: false, sandbox: on, nested: false) == .notAsked)
        #expect(Outside.resolve(requested: true, sandbox: on, nested: false) == .asked)
        #expect(Outside.resolve(requested: true, sandbox: on, nested: true) == .unchanged(.nested))
        #expect(
            Outside.resolve(requested: true, sandbox: .init(enabled: false), nested: false)
                == .unchanged(.sandboxOff))
        // The switch is checked whenever the sandbox is on, nested or not.
        let off = CommandPolicy.Sandbox(allowOutsideSandbox: false)
        #expect(Outside.resolve(requested: true, sandbox: off, nested: false) == .turnedOff)
        #expect(Outside.resolve(requested: true, sandbox: off, nested: true) == .turnedOff)
        #expect(Outside.unchanged(.nested).note?.contains("wisp runs inside another sandbox") == true)
        #expect(Outside.unchanged(.sandboxOff).note?.contains("the sandbox is off") == true)
        #expect(Outside.asked.note == "sandbox: ran outside the sandbox, as the person approved, this once")
    }

    // MARK: The gate

    @Test func aReadOnlyCommandIsAskedEvenWhenNothingElseWouldBe() async throws {
        for threshold in [ApprovalThreshold.default, .level(.dangerous), .never] {
            let sink = MemoryAuditSink()
            let approver = Answering([.approved(.once)])
            let gate = gate(approver, threshold: threshold, sink: sink)
            try await gate.clear(outsideSandbox: CommandSplitter.split("ls -la"), line: "ls -la", workingDirectory: "/")
            let request = try #require(approver.requests.first, "\(threshold)")
            #expect(approver.requests.count == 1)
            #expect(request.kind == .outsideSandbox && request.outsideSandbox)
            #expect(request.command == "ls -la" && request.line == "ls -la" && request.pattern == "ls -la")
            #expect(request.assessment.reasons.first == ApprovalRequest.outsideSandboxReason)
            #expect(request.assessment.level == .moderate)
            #expect(last(.approvalRequested, sink)["outsideSandbox"] == true)
            let decided = last(.approvalDecided, sink)
            #expect(decided["decision"] == "approved" && decided["scope"] == "once")
            #expect(decided["outsideSandbox"] == true && decided["downgradedFrom"] == nil)
            // Every part's verdict is still audited.
            #expect(sink.events.contains { $0.kind == .classifierVerdict && $0.details["command"] == "ls -la" })
        }
    }

    @Test func theWholeLineIsAskedOnceAtItsHighestLevel() async throws {
        let sink = MemoryAuditSink()
        let approver = Answering([.approved(.once)])
        let line = "ls && rm -rf build"
        try await gate(approver, sink: sink).clear(
            outsideSandbox: CommandSplitter.split(line), line: line, workingDirectory: "/")
        #expect(approver.requests.count == 1)
        #expect(approver.requests.first?.command == line)
        #expect(approver.requests.first?.assessment.level == .dangerous)
    }

    @Test func aWiderAnswerIsTakenAsOnceAndCoversNothingAfter() async throws {
        let sink = MemoryAuditSink()
        let approver = Answering([.approved(.session), .approved(.always), .approved(.once)])
        let gate = gate(approver, sink: sink)
        let parts = CommandSplitter.split("touch x")
        try await gate.clear(outsideSandbox: parts, line: "touch x", workingDirectory: "/")
        #expect(last(.approvalDecided, sink)["scope"] == "once")
        #expect(last(.approvalDecided, sink)["downgradedFrom"] == "session")
        // Asked again for the same line in the same turn: nothing remembered the answer.
        try await gate.clear(outsideSandbox: parts, line: "touch x", workingDirectory: "/")
        #expect(last(.approvalDecided, sink)["downgradedFrom"] == "always")
        #expect(approver.requests.count == 2)
        // Nor did it leave an approval that covers the sandboxed command: that is asked on its own.
        try await gate.clear(parts: parts, line: "touch x", workingDirectory: "/")
        #expect(approver.requests.count == 3 && approver.requests.last?.kind == .command)
    }

    @Test func noSessionTurnOrStoredApprovalCoversIt() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ApprovalStore(url: dir.appending(path: "approvals.json"))
        try await store.grant(
            pattern: "touch *", directory: dir.path, scope: .project, level: .dangerous, source: "test")
        let sink = MemoryAuditSink()
        let approver = Answering([.approved(.session), .approved(.once), .approved(.once)])
        let gate = gate(approver, sink: sink, store: store)
        let parts = CommandSplitter.split("touch y")
        // The sandboxed line is covered by the stored approval and asks nobody; a session one is added too.
        try await gate.clear(parts: CommandSplitter.split("mkdir z"), line: "mkdir z", workingDirectory: dir.path)
        try await gate.clear(parts: parts, line: "touch y", workingDirectory: dir.path)
        #expect(approver.requests.count == 1, "only mkdir asked")
        #expect(last(.approvalDecided, sink)["decision"] == "cached-project")
        // Asked to run outside the sandbox, the same line is asked, and so is the session-approved one.
        try await gate.clear(outsideSandbox: parts, line: "touch y", workingDirectory: dir.path)
        try await gate.clear(
            outsideSandbox: CommandSplitter.split("mkdir z"), line: "mkdir z", workingDirectory: dir.path)
        #expect(approver.requests.count == 3)
        #expect(approver.requests.dropFirst().allSatisfy { $0.outsideSandbox })
    }

    @Test func aChannelThatAsksNoPersonRefusesItSayingWhy() async throws {
        for approver in [
            AutoApprover() as any Approver, DenyingApprover(reason: "approval required; re-run with --yes"),
        ] {
            let sink = MemoryAuditSink()
            let gate = gate(approver, sink: sink)
            await #expect(throws: ApprovalGate.Failure.self) {
                try await gate.clear(outsideSandbox: CommandSplitter.split("ls"), line: "ls", workingDirectory: "/")
            }
            let decided = last(.approvalDecided, sink)
            let reason = decided["reason"]?.stringValue ?? ""
            #expect(decided["decision"] == "denied" && decided["outsideSandbox"] == true)
            #expect(reason.contains("asked of a person every time, and no one can be asked here"), "\(reason)")
            #expect(reason.contains("--yes does not answer it") == (approver is AutoApprover), "\(reason)")
            #expect(!reason.contains("re-run with --yes"))
            #expect(await gate.takeRefusals().map(\.command) == ["ls"])
        }
    }

    @Test func aDenialOrSilenceRefuses() async throws {
        let sink = MemoryAuditSink()
        let gate = gate(Answering([.denied("not today"), .unanswered(.seconds(5))]), sink: sink)
        await #expect(throws: ApprovalGate.Failure.refused("not today")) {
            try await gate.clear(outsideSandbox: [], line: "brew upgrade", workingDirectory: "/")
        }
        await #expect(throws: ApprovalGate.Failure.self) {
            try await gate.clear(outsideSandbox: [], line: "brew upgrade", workingDirectory: "/")
        }
        #expect(last(.approvalDecided, sink)["decision"] == "timed-out")
    }

    @Test func everyFaceShowsItRunsOutsideTheSandbox() throws {
        let request = ApprovalRequest(
            command: "brew upgrade", pattern: "brew upgrade", workingDirectory: "/tmp",
            assessment: RiskAssessment(
                level: .moderate, reasons: [ApprovalRequest.outsideSandboxReason], sources: ["outside-sandbox"]),
            thread: "t", kind: .outsideSandbox)
        let dialog = TerminalApprover.render(request, style: .plain)
        #expect(dialog.contains("⚠ approve OUTSIDE the sandbox [moderate] brew upgrade"), "\(dialog)")
        #expect(dialog.contains("never remembered") && dialog.contains("[y]once  [n]o"), "\(dialog)")
        #expect(!dialog.contains("[s]ession"))
        #expect(ChatProtocol.approval(id: "a", request)["outsideSandbox"] == true)
        #expect(ChatProtocol.approval(id: "a", approvalRequest())["outsideSandbox"] == nil)
        let pending = PendingApprovals.request(for: request, client: "claude-code", timeout: .seconds(60))
        #expect(pending.outsideSandbox == true)
        #expect(ChatProtocol.approval(id: "mcp-x", pending: pending)["outsideSandbox"] == true)
        #expect(OutOfBandApprover.message(for: pending).title == "wisp: approve OUTSIDE the sandbox")
        #expect(ChatPending.describe(pending).contains("run brew upgrade OUTSIDE THE SANDBOX, this once, in"))
        let table = ListingLayout.pending([pending], width: 160).joined(separator: "\n")
        #expect(table.contains("OUTSIDE THE SANDBOX: brew upgrade"), "\(table)")
        #expect(ListingLayout.pending([pending], width: nil).first?.hasSuffix("\tbrew upgrade") == true)
        #expect(
            PendingAnswer.ending(of: pending, decision: "session", delivery: .taken)
                == .printed("approved once, outside the sandbox (session is taken as once): brew upgrade for thread t"))
        #expect(
            PendingAnswer.ending(of: pending, decision: "no", delivery: .taken)
                == .printed("denied: brew upgrade for thread t"))
    }

    @Test(.timeLimit(.minutes(1))) func filedOutOfBandItIsMarkedAndAnAlwaysAnswerIsOnce() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let posted = Mutex<[Notifier.Message]>([])
        let approver = OutOfBandApprover(
            channel: channel, timeout: .seconds(60), client: { "claude-code" },
            notify: { message, _ in posted.withLock { $0.append(message) } }, poll: .milliseconds(20))
        let sink = MemoryAuditSink()
        let gate = gate(approver, sink: sink)
        let clearing = Task {
            try await gate.clear(
                outsideSandbox: CommandSplitter.split("brew upgrade"), line: "brew upgrade", workingDirectory: "/")
        }
        var filed: PendingApprovals.Request?
        for _ in 0..<250 where filed == nil {
            filed = channel.waiting().first
            if filed == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let request = try #require(filed)
        #expect(request.outsideSandbox == true && request.reasons.first == ApprovalRequest.outsideSandboxReason)
        try channel.answer(request.id, decision: "always", via: "cli")
        try await clearing.value
        let decided = last(.approvalDecided, sink)
        #expect(decided["scope"] == "once" && decided["downgradedFrom"] == "always")
        #expect(last(.approvalPending, sink)["outsideSandbox"] == true)
        #expect(Set(last(.approvalPending, sink).keys).isSubset(of: AuditEvent.fields(for: .approvalPending)))
        #expect(posted.withLock { $0.first?.title } == "wisp: approve OUTSIDE the sandbox")
    }

    @Test func thePendingMarkIsBoundSoAFileWithoutItIsRefused() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        var outside = approvalRequest("brew upgrade")
        outside.kind = .outsideSandbox
        let marked = PendingApprovals.request(for: outside, client: nil, timeout: .seconds(60))
        var plain = marked
        plain.outsideSandbox = nil
        #expect(plain.expectedBinding != marked.binding)
        try channel.file(marked)
        // The mark removed from the file after it was filed: the answer is refused as an altered request.
        let file = channel.directory.appending(path: "\(marked.id).request.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["outsideSandbox"] as? Bool == true)
        object["outsideSandbox"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(throws: PendingApprovals.Failure.altered(marked.id)) {
            try channel.answer(marked.id, decision: "once", via: "cli")
        }
    }

    // MARK: The runner

    @Test func theDenyListStillApplies() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let approver = Answering([.approved(.once)])
        let runner = runner(
            root: dir, gate: gate(approver, sink: sink), sink: sink, policy: CommandPolicy(deny: ["forbidden-word"]))
        let result = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "echo forbidden-word", workingDirectory: dir.path, outsideSandbox: true))
        #expect(result == "error: command denied by policy: command matches deny pattern forbidden-word", "\(result)")
        #expect(approver.requests.isEmpty)
        #expect(!sink.events.contains { $0.kind == .commandOutcome })
    }

    @Test func theOperatorsSwitchOffRefusesItWithText() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let approver = Answering([.approved(.once)])
        let policy = CommandPolicy(sandbox: .init(allowOutsideSandbox: false))
        let runner = runner(root: dir, gate: gate(approver, sink: sink), sink: sink, policy: policy)
        let tool = RunCommandTool(runner: runner)
        let result = await tool.call(arguments: .init(command: "ls", workingDirectory: dir.path, outsideSandbox: true))
        #expect(result.hasPrefix("error: command denied by policy: running outside the sandbox is turned off"))
        #expect(result.contains("allowOutsideSandbox is false"))
        #expect(approver.requests.isEmpty && !sink.events.contains { $0.kind == .commandOutcome })
        let decision = last(.policyDecision, sink)
        #expect(decision["verdict"] == "denied" && decision["outsideSandbox"] == true)
        #expect(tool.limits.contains("Running outside the sandbox is turned off here"))
        // Without the request the same command runs as ever.
        let plain = await tool.call(arguments: .init(command: "echo hi", workingDirectory: dir.path))
        #expect(plain.contains("exit status: 0"), "\(plain)")
    }

    @Test func withoutAGateItIsRefused() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let result = await RunCommandTool(runner: runner(root: dir, gate: nil, sink: sink)).call(
            arguments: .init(command: "ls", workingDirectory: dir.path, outsideSandbox: true))
        if Self.nested {
            #expect(result.contains("outsideSandbox changed nothing"), "\(result)")
        } else {
            #expect(result == "error: command not approved: " + CommandRunner.noGateReason, "\(result)")
        }
    }

    @Test func withTheSandboxOffItChangesNothing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let approver = Answering([])
        let policy = CommandPolicy(sandbox: .init(enabled: false))
        let runner = runner(root: dir, gate: gate(approver, sink: sink), sink: sink, policy: policy)
        let result = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "echo hi", workingDirectory: dir.path, outsideSandbox: true))
        #expect(result.contains("exit status: 0") && result.contains("hi"), "\(result)")
        #expect(result.hasSuffix("sandbox: outsideSandbox changed nothing: the sandbox is off here"), "\(result)")
        #expect(approver.requests.isEmpty, "a safe command asks nothing, as without the request")
        #expect(last(.policyDecision, sink)["outsideSandboxIgnored"] == "sandbox-off")
        #expect(last(.commandOutcome, sink)["outsideSandbox"] == nil)
    }

    @Test func theLimitsAndTheSchemaSayItExists() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let limits = RunCommandTool(runner: runner(root: dir, gate: nil, sink: MemoryAuditSink())).limits
        if Self.nested {
            #expect(limits.contains("outsideSandbox changes nothing here"), "\(limits)")
        } else {
            #expect(limits.contains("outsideSandbox true asks to run one command the sandbox refuses"), "\(limits)")
        }
        let off = RunCommandTool(
            runner: runner(
                root: dir, gate: nil, sink: MemoryAuditSink(), policy: CommandPolicy(sandbox: .init(enabled: false)))
        ).limits
        #expect(!off.contains("outsideSandbox"))
        let tool = ToolRegistry().descriptions.first { $0.name == "run_command" }
        guard case .object(let schema)? = tool?.parameters, case .object(let properties)? = schema["properties"],
            case .object(let outside)? = properties["outsideSandbox"]
        else {
            Issue.record("no outsideSandbox in the schema")
            return
        }
        #expect(outside["type"] == "boolean")
        #expect(outside["description"]?.stringValue?.contains("brew upgrade or cargo install") == true)
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func aWriteOutsideTheRootsSucceedsOnlyApprovedAndOutside() async throws {
        let dir = try scratch()
        // The home directory is outside the writable set; a scratch directory there is the target.
        let target = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "wisp-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: target)
        }
        let file = target.appending(path: "written.txt").path
        let sink = MemoryAuditSink()
        let approver = Answering([.approved(.once), .denied("declined by the user"), .approved(.once)])
        let tool = RunCommandTool(runner: runner(root: dir, gate: gate(approver, sink: sink), sink: sink))
        let command = "touch '\(file)'"
        // Sandboxed (and approved, as touch asks), the write is refused, and the note says the model may ask to run
        // it outside.
        let confined = await tool.call(arguments: .init(command: command, workingDirectory: dir.path))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(confined.contains("sandbox: refused writing to"), "\(confined)")
        #expect(confined.contains(CommandRunner.outsideHint), "\(confined)")
        let asked = approver.requests.count
        // Asked to run outside and declined: nothing runs.
        let declined = await tool.call(
            arguments: .init(command: command, workingDirectory: dir.path, outsideSandbox: true))
        #expect(declined == "error: command not approved: declined by the user", "\(declined)")
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(last(.policyDecision, sink)["verdict"] == "disapproved")
        // Approved: it runs without the sandbox, and the result and the audit say so.
        let ran = await tool.call(arguments: .init(command: command, workingDirectory: dir.path, outsideSandbox: true))
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(ran.contains("exit status: 0"), "\(ran)")
        #expect(ran.hasSuffix("sandbox: ran outside the sandbox, as the person approved, this once"), "\(ran)")
        #expect(approver.requests.count == asked + 2)
        #expect(approver.requests.suffix(2).allSatisfy { $0.outsideSandbox })
        let decision = last(.policyDecision, sink)
        #expect(decision["verdict"] == "allowed" && decision["outsideSandbox"] == true && decision["sandbox"] == false)
        #expect(last(.commandOutcome, sink)["outsideSandbox"] == true)
        #expect(Set(last(.policyDecision, sink).keys).isSubset(of: AuditEvent.fields(for: .policyDecision)))
        #expect(Set(last(.commandOutcome, sink).keys).isSubset(of: AuditEvent.fields(for: .commandOutcome)))
        #expect(Set(last(.approvalDecided, sink).keys).isSubset(of: AuditEvent.fields(for: .approvalDecided)))
        #expect(Set(last(.approvalRequested, sink).keys).isSubset(of: AuditEvent.fields(for: .approvalRequested)))
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func unsandboxedTheProtectionOfWispsHomeIsGone() async throws {
        // A protected directory stands for ~/.wisp: the profile refuses writes to it even inside the writable set.
        let dir = try scratch()
        let protected = dir.appending(path: "home")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = protected.appending(path: "config.json").path
        let sink = MemoryAuditSink()
        let tool = RunCommandTool(
            runner: runner(
                root: dir, gate: gate(Answering([.approved(.once), .approved(.once)]), sink: sink), sink: sink,
                protected: [protected.path]))
        let command = "echo x > '\(file)'"
        _ = await tool.call(arguments: .init(command: command, workingDirectory: dir.path))
        #expect(!FileManager.default.fileExists(atPath: file), "the sandbox protects it")
        _ = await tool.call(arguments: .init(command: command, workingDirectory: dir.path, outsideSandbox: true))
        #expect(FileManager.default.fileExists(atPath: file), "an approved run outside the sandbox does not")
    }

    // A command the person types after `!!` (amended 2026-10-14) is tested in `PersonOutsideSandboxTests`.

    // MARK: Configuration

    @Test func theSwitchIsOnByDefaultAndSetWithWispConfig() throws {
        #expect(CommandPolicy.default.sandbox.allowOutsideSandbox)
        #expect(Config().resolved.runner.policy.sandbox.allowOutsideSandbox)
        #expect(ConfigSettings.defaultValue("commandPolicy.sandbox.allowOutsideSandbox") == true)
        let setting = try #require(ConfigSettings.setting("commandPolicy.sandbox.allowOutsideSandbox"))
        #expect(setting.kind == .flag)
        let set = try ConfigEdit.set("commandPolicy.sandbox.allowOutsideSandbox", to: "false", in: nil)
        #expect(set.new == false)
        let config = try JSONDecoder().decode(Config.self, from: set.data)
        #expect(!config.resolved.runner.policy.sandbox.allowOutsideSandbox)
        // The rest of the policy keeps its defaults.
        #expect(config.resolved.runner.policy.deny == CommandPolicy.defaultDeny)
        #expect(config.resolved.runner.policy.sandbox.enabled)
        // Round trip: the policy encodes the switch and reads it back.
        let policy = CommandPolicy(sandbox: .init(allowOutsideSandbox: false))
        let decoded = try JSONDecoder().decode(CommandPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded == policy)
        #expect(
            try JSONDecoder().decode(CommandPolicy.self, from: Data(#"{"sandbox":{}}"#.utf8)).sandbox
                .allowOutsideSandbox)
    }
}
