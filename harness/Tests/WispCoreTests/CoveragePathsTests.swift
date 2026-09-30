import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// An approver that always gives one answer.
private struct Fixed: Approver {
    let decision: ApprovalDecision
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision { decision }
}

/// A tool that always throws, to exercise the audit wrapper's error path.
private struct Boom: WispTool {
    struct Failure: Error {}
    let name = "boom"
    let description = "throws"
    let limits = "none"
    let examplePrompt = "Use boom"
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { throw Failure() }
}

/// The remaining branches the larger suites do not reach: error paths, renderers, and adapters.
@Suite struct CoveragePathsTests {
    @Test func readFileAsksTheGateAndRendersRefusals() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-cov-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = MemoryAuditSink()
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "no reads"),
            threshold: .level(.safe), audit: AuditLog(session: "s", sink: sink))
        let tool = ReadFileTool(approval: gate)
        let refused = await tool.call(arguments: .init(path: url.path, offset: nil, limit: nil))
        #expect(refused == "error: read not approved: no reads")
        #expect(sink.events.first?.kind == .classifierVerdict)
        #expect(sink.events.first?.details["command"] == .string("cat \(url.path)"))
        let open = ReadFileTool(
            approval: ApprovalGate(classifier: RuleRiskClassifier.standard, approver: AutoApprover(), threshold: .never)
        )
        #expect(
            await open.call(arguments: .init(path: url.path, offset: nil, limit: nil)) == "1\tsecret\n[end of file]")
    }

    @Test func aStoreThatCannotBeWrittenIsAuditedNotFatal() async throws {
        let sink = MemoryAuditSink()
        let unwritable = URL(filePath: "/nonexistent-wisp/approvals.json")
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: Fixed(decision: .approved(.project)),
            threshold: .level(.moderate),
            audit: AuditLog(session: "s", sink: sink), store: ApprovalStore(url: unwritable), source: .chat)
        try await gate.clear(command: "touch a", workingDirectory: "/tmp")
        let decided = sink.events.last
        #expect(decided?.details["decision"] == "approved")
        #expect(decided?.details["persistError"] != nil)
        #expect(decided?.details["approvalID"] == nil)
    }

    @Test func auditedToolRecordsAThrowingBaseTool() async {
        let sink = MemoryAuditSink()
        let tool = AuditedTool(Boom(), audit: AuditLog(session: "s", sink: sink))
        #expect(tool.includesSchemaInInstructions == Boom().includesSchemaInInstructions)
        #expect(tool.limits == "none" && tool.examplePrompt == "Use boom")
        await #expect(throws: Boom.Failure.self) { _ = try await tool.call(arguments: .init()) }
        #expect(sink.events.map(\.kind) == [.toolCall, .error])
        #expect(sink.events.last?.details["context"] == "tool boom")
    }

    @Test func liveDependenciesWriteTheAuditFileAndUnreadableConfigIsTyped() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        let deps = Session.Dependencies(
            makeClassifier: { _, _ in RuleRiskClassifier.standard }, makeSink: Session.Dependencies.live.makeSink)
        let session = try Session.begin(.init(entryPoint: .respond), home: home, dependencies: deps)
        session.end()
        let events = AuditQuery.events(in: try Data(contentsOf: home.auditFile))
        #expect(events.map(\.kind) == [.sessionStart, .sessionEnd])
        // A config that exists but is a directory cannot be read.
        try FileManager.default.createDirectory(at: home.configFile, withIntermediateDirectories: true)
        #expect(throws: Session.Failure.self) { try Session.loadConfig(home: home) }
        do {
            _ = try Session.loadConfig(home: home)
        } catch Session.Failure.malformedConfig(_, let problem) {
            if case .unreadable = problem {} else if case .invalidJSON = problem {} else { Issue.record("\(problem)") }
        }
    }

    @Test func configSectionsInitialiseAndThresholdEncodes() throws {
        let audit = Config.AuditConfig(enabled: false, maxFileBytes: 1, keepFiles: 2)
        #expect(Config(audit: audit).resolved.auditLimits.keepFiles == 2)
        #expect(!Config(audit: audit).resolved.auditEnabled)
        let encoded = String(
            decoding: try JSONEncoder().encode([ApprovalThreshold.never, .level(.dangerous)]), as: UTF8.self)
        #expect(encoded == #"["never","dangerous"]"#)
        #expect(ApprovalThreshold.level(.safe).rawValue == "safe")
    }

    @Test func modelUnavailabilityIsExplained() {
        #expect(
            ModelSelection.explain(SystemLanguageModel.Availability.UnavailableReason.modelNotReady).contains(
                "downloading"))
        #expect(
            ModelSelection.explain(SystemLanguageModel.Availability.UnavailableReason.appleIntelligenceNotEnabled)
                .contains("System Settings"))
        #expect(
            ModelSelection.explain(SystemLanguageModel.Availability.UnavailableReason.deviceNotEligible).contains(
                "Apple silicon"))
        #expect(
            ModelSelection.explain(PrivateCloudComputeLanguageModel.Availability.UnavailableReason.systemNotReady)
                .contains("not ready"))
        #expect(
            ModelSelection.explain(PrivateCloudComputeLanguageModel.Availability.UnavailableReason.deviceNotEligible)
                .contains("not eligible"))
    }

    @Test func doctorReportsAParsingConfigAndAnUnwritableHome() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-doc-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let home = Home(root: root)
        try home.ensure()
        try Data(#"{"maxThreads":4}"#.utf8).write(to: home.configFile)
        let probes = Doctor.Probes(systemModel: { nil }, configuredModel: { _, _, _ in nil })
        var findings = Doctor(home: home, probes: probes).run()
        let config = try #require(findings.first { $0.name == "config" })
        #expect(config.ok && config.detail.hasSuffix("parses"))
        let configured = Doctor(home: home, model: .ollama("q"), probes: probes).run()
        #expect(configured.first { $0.name == "configured model" }?.detail == "ollama:q available")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        findings = Doctor(home: home, probes: probes).run()
        let unwritable = try #require(findings.first { $0.name == "home" })
        #expect(!unwritable.ok && unwritable.detail.contains("not writable"))
    }

    @Test func auditEventDecoderRejectsBadTimesAndRotatedNamesAreOrdered() throws {
        let bad = #"{"schema":1,"time":"yesterday","version":"0","pid":1,"session":"s","kind":"prompt","details":{}}"#
        #expect(throws: DecodingError.self) { try AuditEvent.decoder.decode(AuditEvent.self, from: Data(bad.utf8)) }
        let url = URL(filePath: "/tmp/audit.jsonl")
        #expect(
            FileAuditSink.rotatedFiles(for: url, keep: 2).map(\.lastPathComponent) == [
                "audit.1.jsonl", "audit.2.jsonl",
            ])
        #expect(FileAuditSink.rotatedFiles(for: url, keep: 0).count == 1)
    }

    @Test func diagnosticsLevelsParseAndEmit() {
        #expect(Diagnostics.Level(environmentValue: "DEBUG") == .debug)
        #expect(Diagnostics.Level(environmentValue: "nope") == nil)
        Diagnostics.policy.error("covered")
        Diagnostics.policy.info("covered")
        Diagnostics.policy.debug("covered")
    }

    @Test func terminalApproverParsesEveryAnswer() {
        #expect(TerminalApprover.parse("Y") == .approved(.once))
        #expect(TerminalApprover.parse("session") == .approved(.session))
        #expect(TerminalApprover.parse("p") == .approved(.project))
        #expect(TerminalApprover.parse("always") == .approved(.always))
        #expect(TerminalApprover.parse("") == .denied("declined by the user"))
        #expect(TerminalApprover.parse("maybe") == .denied("unrecognised answer 'maybe'"))
        _ = TerminalApprover()
    }
}
