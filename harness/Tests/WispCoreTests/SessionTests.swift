import Foundation
import Testing

@testable import WispCore

@Suite struct SessionTests {
    private func temporaryHome(config: String? = nil) throws -> Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-session-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        if let config { try Data(config.utf8).write(to: home.configFile) }
        return home
    }

    private func begin(_ request: Session.Request, home: Home) throws -> (Session, MemoryAuditSink) {
        let sink = MemoryAuditSink()
        let session = try Session.begin(request, home: home, dependencies: .testing(sink: sink))
        return (session, sink)
    }

    @Test func appliesOverridesAndRecordsSessionStart() throws {
        let home = try temporaryHome(config: #"{"instructions":"from file","model":"system"}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, sink) = try begin(
            .init(
                entryPoint: .respond, instructions: "override", model: .privateCloud, tools: .named(["current_date"]),
                unsafe: true, autoApprove: true, resume: "chat1"), home: home)
        #expect(session.prompting == Prompting(systemPromptExtension: "from file", instructions: "override"))
        #expect(session.config.model == .privateCloud)
        #expect(session.config.runner.policy == .unrestricted)
        #expect(session.toolNames == ["current_date"])
        #expect(session.notes.count == 2)
        #expect(session.notes.first?.contains("--unsafe") == true)
        #expect(session.notes.last?.contains("leave this Mac") == true)
        let start = sink.events.first
        #expect(start?.kind == .sessionStart)
        #expect(start?.details["entryPoint"] == "respond")
        #expect(start?.details["systemPromptExtension"] == "from file")
        #expect(start?.details["instructions"] == "override")
        #expect(start?.details["model"] == "private-cloud")
        #expect(start?.details["unsafe"] == true)
        #expect(start?.details["autoApprove"] == true)
        #expect(start?.details["resume"] == "chat1")
        session.end()
        #expect(sink.events.last?.kind == .sessionEnd)
    }

    @Test func defaultsComeFromConfigAndAllToolsAreEnabled() throws {
        let home = try temporaryHome(config: #"{"instructions":"from file"}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, _) = try begin(.init(entryPoint: .chat), home: home)
        #expect(session.prompting == Prompting(systemPromptExtension: "from file", instructions: nil))
        #expect(session.prompting.rendered.hasPrefix(Prompting.systemPrompt(memory: false)))
        #expect(session.prompting.rendered.hasSuffix("Guidance for this Mac:\nfrom file"))
        #expect(session.config.model == .system)
        #expect(session.config.runner.policy == .default)
        #expect(session.toolNames == ToolRegistry().all.map(\.name))
        #expect(session.notes.isEmpty)
    }

    @Test func rejectsUnknownToolsAndMalformedConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(throws: Session.Failure.unknownTools(["nope"])) {
            try begin(.init(entryPoint: .respond, tools: .named(["current_date", "nope"])), home: home)
        }
        try Data("{bad".utf8).write(to: home.configFile)
        #expect(throws: Session.Failure.self) { try Session.loadConfig(home: home) }
    }

    @Test func configProblemsStayTyped() throws {
        let home = try temporaryHome(config: #"{"commandPolicy":{"deny":["("]}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(
            throws: Session.Failure.malformedConfig(
                path: home.configFile.path, problem: .invalidPolicy(.invalidPattern("(")))
        ) { try Session.loadConfig(home: home) }
        try Data(#"{"approval":{"threshold":"loud"}}"#.utf8).write(to: home.configFile)
        do {
            _ = try Session.loadConfig(home: home)
            Issue.record("loaded a bad threshold")
        } catch Session.Failure.malformedConfig(_, .invalidJSON(let detail)) {
            #expect(detail.contains("approval.threshold 'loud'"))
        }
    }

    @Test func disabledAuditRecordsNothing() throws {
        let home = try temporaryHome(config: #"{"audit":{"enabled":false}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let session = try Session.begin(
            .init(entryPoint: .respond), home: home,
            dependencies: .init(
                makeClassifier: { _, _ in RuleRiskClassifier.standard },
                makeSink: { _, _ in
                    Issue.record("sink built although the audit log is disabled")
                    return MemoryAuditSink()
                }))
        #expect(session.audit.currentTurn == 0)
    }

    @Test func liveDependenciesFollowTheConfigAndTestingOnesNeverUseTheModel() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let live = Session.Dependencies.live
        #expect(live.makeClassifier(Config().resolved, home) is CompositeRiskClassifier)
        #expect(live.makeClassifier(Config(approval: .init(useModel: false)).resolved, home) is RuleRiskClassifier)
        #expect(Session.Dependencies.testing().makeClassifier(Config().resolved, home) is RuleRiskClassifier)
    }

    @Test func aModelClassifierIsTimedIntoTheSessionsStatsAndTheRulesAreNot() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let timed = try Session.begin(.init(entryPoint: .respond), home: home, dependencies: .testing())
        #expect(timed.classifier is CachingRiskClassifier)
        let rulesHome = try temporaryHome(config: #"{"approval":{"useModel":false}}"#)
        defer { try? FileManager.default.removeItem(at: rulesHome.root) }
        let rules = try Session.begin(.init(entryPoint: .respond), home: rulesHome, dependencies: .testing())
        #expect(rules.classifier is RuleRiskClassifier)
    }

    @Test func yesReplacesTheFacesApproverWithAutoApproval() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, sink) = try begin(.init(entryPoint: .respond, autoApprove: true), home: home)
        let thread = try session.thread(id: "t", approver: DenyingApprover(reason: "must not be asked"))
        try await thread.gate.clear(command: "rm -rf build", workingDirectory: home.root.path)
        #expect(sink.events.last?.details["decision"] == "approved")
    }

    @Test func aThreadRecordsItsOwnSessionStart() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, sink) = try begin(.init(entryPoint: .mcp, unsafe: true), home: home)
        let thread = try session.thread(
            id: "thread-1", approver: DenyingApprover(reason: "x"), instructions: "be brief",
            tools: .named(["read_file"]),
            model: .privateCloud)
        #expect(thread.prompting.instructions == "be brief")
        #expect(thread.model == .privateCloud)
        #expect(thread.tools.map(\.name) == ["read_file"])
        let start = sink.events.last
        #expect(start?.kind == .sessionStart)
        #expect(start?.session == "thread-1")
        #expect(start?.details["entryPoint"] == "mcp-thread")
        #expect(start?.details["parent"] == .string(session.audit.session))
        #expect(start?.details["instructions"] == "be brief")
        #expect(start?.details["tools"] == .array(["read_file"]))
        #expect(start?.details["model"] == "private-cloud")
        #expect(start?.details["unsafe"] == true)
        #expect(start?.details["autoApprove"] == false)
        #expect(start?.details["resume"] == .null)
    }
}
