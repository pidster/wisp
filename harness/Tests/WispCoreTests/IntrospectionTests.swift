import Foundation
import FoundationModels
import Testing

@testable import WispCore

@Suite struct IntrospectionTests {
    private func scratchHome() throws -> Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-intro-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        return home
    }

    /// Where each `Config` field appears in the rendered configuration, as a path of keys; a field the file
    /// has and the rendering does not is a bug the next test catches.
    private static let rendered: [String: [String]] = [
        "systemPromptExtension": ["systemPromptExtension"], "instructions": ["systemPromptExtension"],
        "model": ["model"], "commandTimeoutSeconds": ["runCommand", "timeoutSeconds"],
        "commandMaxOutputBytes": ["runCommand", "maxOutputBytes"], "maxThreads": ["maxThreads"],
        "inlineOutputBytes": ["inlineOutputBytes"], "shownOutputLines": ["shownOutputLines"],
        "commandPolicy": ["runCommand", "policy"], "audit": ["audit"], "approval": ["approval"],
        "ollama": ["backends", "ollama"], "coreai": ["backends"], "mlx": ["backends"],
        "notifications": ["notifications"], "tools": ["tools"], "routing": ["routing"], "facts": ["facts"],
        "assessment": ["assessment"], "context": ["context"],
    ]

    private func renderedConfiguration() throws -> JSONValue {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        return Introspection(home: home, config: Config().resolved).configuration
    }

    @Test func configurationShowsEverySectionOfTheConfigFile() throws {
        let top = try renderedConfiguration()
        for field in Mirror(reflecting: Config()).children.compactMap(\.label) {
            guard let path = Self.rendered[field] else {
                Issue.record("Config.\(field) is not in IntrospectionTests.rendered: render it, then list it")
                continue
            }
            let node = path.reduce(Optional(top)) { $0?.objectValue?[$1] }
            #expect(node != nil, "Config.\(field) is not shown at \(path.joined(separator: "."))")
        }
    }

    @Test func configurationShowsEverySettableKeyWithItsDefault() throws {
        let top = try renderedConfiguration()
        let moved: [String: [String]] = [
            "commandTimeoutSeconds": ["runCommand", "timeoutSeconds"],
            "commandMaxOutputBytes": ["runCommand", "maxOutputBytes"],
        ]
        for setting in ConfigSettings.all {
            var path = moved[setting.path] ?? setting.path.split(separator: ".").map(String.init)
            if path.first == "ollama" { path.insert("backends", at: 0) }
            let node = path.reduce(Optional(top)) { $0?.objectValue?[$1] }
            #expect(node != nil, "\(setting.path) is not shown at \(path.joined(separator: "."))")
        }
        let facts = top.objectValue?["facts"]?.objectValue
        #expect(facts?["enabled"] == true && facts?["share"] == .double(0.1))
        #expect(top.objectValue?["assessment"]?.objectValue?["tools"] == "request")
        #expect(top.objectValue?["context"]?.objectValue?["target"] == .double(0.5))
        #expect(Introspection.render(top).utf8.count < 6_000, "the configuration view stays bounded")
    }

    @Test func configurationShowsEffectiveValuesAndPaths() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let config = Config(
            systemPromptExtension: "be terse", model: .ollama("q"), commandTimeoutSeconds: 5,
            approval: .init(threshold: .never, useModel: false, timeoutSeconds: 0),
            tools: .init(
                disabled: ["notify"],
                custom: [
                    .init(
                        name: "issue", description: "Shows an issue.", arguments: ["number": .init(type: "integer")],
                        command: "gh issue view {number}")
                ]),
            routing: .init(ladder: [.system, .ollama("big")])
        ).resolved
        let views = Introspection(home: home, config: config)
        guard case .object(let top) = views.configuration else { Issue.record("shape"); return }
        #expect(top["version"] == .string(WispVersion.current))
        #expect(top["model"] == "ollama:q")
        #expect(top["systemPromptExtension"] == "be terse")
        #expect(top["home"]?.objectValue?["configFileExists"] == false)
        #expect(top["runCommand"]?.objectValue?["timeoutSeconds"] == 5)
        #expect(top["approval"]?.objectValue?["threshold"] == "never")
        #expect(top["approval"]?.objectValue?["classifier"] == "rules")
        #expect(top["approval"]?.objectValue?["coremlMinimumConfidence"] == .double(0.6))
        #expect(top["approval"]?.objectValue?["timeoutSeconds"] == 0)
        #expect(top["approval"]?.objectValue?["persistDays"] == 30)
        #expect(top["runCommand"]?.objectValue?["policy"]?.objectValue?["sandbox"]?.objectValue?["enabled"] == true)
        #expect(top["notifications"]?.objectValue?["perMinute"] == 5)
        #expect(top["tools"]?.objectValue?["disabled"] == ["notify"])
        #expect(top["tools"]?.objectValue?["custom"]?.arrayValue?.first?.objectValue?["arguments"] == ["number"])
        #expect(top["routing"]?.objectValue?["ladder"] == ["system", "ollama:big"])
        let text = Introspection.render(views.configuration)
        #expect(text.hasPrefix("{\n"))
        #expect(text.contains("\"deny\" : ["))
    }

    @Test func approvalsAndAuditReadTheStores() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ApprovalStore(url: home.approvalsFile)
        _ = try await store.grant(
            pattern: "swift *", directory: "/repo", scope: .project, level: .moderate, source: "chat")
        let sink = try FileAuditSink(url: home.auditFile)
        let log = AuditLog(session: "s1", sink: sink)
        log.beginTurn()
        log.record(.prompt, details: ["text": "hi"])
        log.record(.commandOutcome, details: ["command": "ls", "exitStatus": 0])
        log.log(forSession: "s2").record(.sessionEnd)
        let views = Introspection(home: home, config: Config().resolved, store: store)
        guard case .array(let entries) = await views.approvals(), let first = entries.first?.objectValue else {
            Issue.record("approvals shape")
            return
        }
        #expect(first["pattern"] == "swift *")
        #expect(first["workingDirectory"] == "/repo")
        #expect(first["scope"] == "project")
        #expect(first["source"] == "chat")
        #expect(try views.audit(AuditQuery()).map(\.kind) == [.prompt, .commandOutcome, .sessionEnd])
        #expect(try views.audit(AuditQuery(session: "s2")).count == 1)
        #expect(try views.audit(AuditQuery(kinds: [.commandOutcome], last: 1)).first?.details["command"] == "ls")
        #expect(await Introspection(home: home, config: Config().resolved).approvals() == .array([]))
        let empty = Introspection(home: Home(root: home.root.appending(path: "none")), config: Config().resolved)
        #expect(try empty.audit(AuditQuery()).isEmpty)
    }

    @Test func sessionsAreSummarisedFromTheLogAndAuditTakesASessionFromChat() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = try FileAuditSink(url: home.auditFile)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = AuditLog(session: "c1", sink: sink)
        chat.record(.sessionStart, details: ["entryPoint": "chat"])
        sink.write(AuditEvent(session: "git", kind: .prompt, details: ["text": "status"], time: start))
        sink.write(
            AuditEvent(session: "git", kind: .response, details: ["text": "ok"], time: start.addingTimeInterval(5)))
        let views = Introspection(home: home, config: Config().resolved)
        let sessions = try views.sessions()
        #expect(sessions.map(\.id) == ["git", "c1"] && sessions.map(\.events) == [2, 1])
        #expect(sessions.first?.entryPoint == nil && sessions.last?.entryPoint == "chat")
        #expect(sessions.first?.first == start && sessions.first?.latest == start.addingTimeInterval(5))
        #expect(sessions.first?.line.hasSuffix("  git  -  2 events") == true, "\(sessions.first?.line ?? "")")
        #expect(try views.sessions(last: 1).map(\.id) == ["c1"])
        let tool = InspectTool(introspection: views)
        let listed = await tool.show("audit sessions")
        #expect(listed.contains("git  -  2 events") && listed.contains("c1  chat  1 event"), "\(listed)")
        let one = await tool.show("audit git")
        #expect(one.components(separatedBy: "\n").count == 2 && !one.contains("c1"), "\(one)")
        #expect(await tool.show("audit nobody") == "no matching audit events")
        #expect(await tool.show("status").hasPrefix("{"))
        let empty = InspectTool(
            introspection: Introspection(home: Home(root: home.root.appending(path: "none")), config: Config().resolved)
        )
        #expect(await empty.show("audit sessions") == "no sessions in the audit log")
    }

    @Test func aTailReturnsWhatWasAppendedKeepsAHalfWrittenLineAndSurvivesRotation() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let url = home.auditFile
        var missing = AuditTail(url: url)
        #expect(try missing.read().isEmpty)
        let line = { (text: String) in
            String(
                decoding: try AuditEvent.encoder.encode(
                    AuditEvent(session: "s", kind: .prompt, details: ["text": .string(text)])), as: UTF8.self)
        }
        try Data((try line("one") + "\n").utf8).write(to: url)
        var tail = AuditTail.atEnd(of: url)
        #expect(try tail.read().isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let two = try line("two")
        try handle.write(contentsOf: Data((two + "\n" + two.prefix(10)).utf8))
        #expect(try tail.read().map { $0.details["text"] } == ["two"])
        try handle.write(contentsOf: Data((two.dropFirst(10) + "\n").utf8))
        try handle.close()
        #expect(try tail.read().map { $0.details["text"] } == ["two"])
        #expect(try tail.read().isEmpty)
        // Rotated: a new, shorter file is read from its start.
        try Data((try line("three") + "\n").utf8).write(to: url)
        #expect(try tail.read().map { $0.details["text"] } == ["three"])
    }

    @Test func inspectToolRendersEveryViewAndBoundsOutput() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = try FileAuditSink(url: home.auditFile)
        let log = AuditLog(session: "s", sink: sink)
        for index in 1...30 {
            log.record(.prompt, details: ["text": .string("prompt \(index) " + String(repeating: "x", count: 300))])
        }
        let views = Introspection(
            home: home, config: Config().resolved, store: ApprovalStore(url: nil),
            status: { ["session": "s", "turn": 3] })
        let tool = InspectTool(introspection: views)
        #expect(
            await tool.call(arguments: .init(what: "Config", last: nil, kind: nil, session: nil)).contains(
                "\"version\""))
        #expect(
            await tool.call(arguments: .init(what: "status", last: nil, kind: nil, session: nil)).contains(
                "\"turn\" : 3"))
        #expect(await tool.call(arguments: .init(what: "approvals", last: nil, kind: nil, session: nil)) == "[\n\n]")
        let audit = await tool.call(arguments: .init(what: "audit", last: 30, kind: "prompt", session: "s"))
        #expect(audit.contains("[truncated:"))
        #expect(audit.utf8.count <= InspectTool.maxBytes + 64)
        let two = await tool.call(arguments: .init(what: "audit", last: 2, kind: nil, session: nil))
        #expect(two.components(separatedBy: "\n").count == 2)
        #expect(two.contains("prompt 30"))
        #expect(
            await tool.call(arguments: .init(what: "audit", last: 5, kind: "nope", session: nil)).hasPrefix(
                "error: unknown kind 'nope'"))
        #expect(
            await tool.call(arguments: .init(what: "audit", last: 5, kind: nil, session: "none"))
                == "no matching audit events")
        #expect(
            await tool.call(arguments: .init(what: "everything", last: nil, kind: nil, session: nil)).hasPrefix(
                "error: unknown view"))
        #expect(ToolOutput.bounded("short", maxBytes: 10) == "short")
        #expect(ToolOutput.bounded("héllo wörld", maxBytes: 3).hasPrefix("hé\n[truncated:"))
        #expect(ToolRegistry().all.map(\.name).contains("inspect"))
    }
}
