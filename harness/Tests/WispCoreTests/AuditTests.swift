import Foundation
import Testing

@testable import WispCore

@Suite struct AuditEventTests {
    @Test func encodesAsFlatSortedJSONLine() throws {
        let event = AuditEvent(
            session: "s1", kind: .toolCall, turn: 2, call: "c1", details: ["tool": "run_command", "n": 3, "ok": true],
            time: Date(timeIntervalSince1970: 1_700_000_000.5))
        let line = String(decoding: try AuditEvent.encoder.encode(event), as: UTF8.self)
        #expect(
            line.hasPrefix(
                "{\"call\":\"c1\",\"details\":{\"n\":3,\"ok\":true,\"tool\":\"run_command\"},\"kind\":\"tool.call\""))
        #expect(line.contains("\"time\":\"2023-11-14T22:13:20.500Z\""))
        #expect(!line.contains("\n"))
        let decoded = try AuditEvent.decoder.decode(AuditEvent.self, from: Data(line.utf8))
        #expect(decoded == event)
    }

    @Test func summariesAreOneLine() {
        let prompt = AuditEvent(session: "s", kind: .prompt, turn: 1, details: ["text": "hello\nworld"])
        #expect(prompt.summary.hasSuffix(" prompt session=s turn=1: hello\\nworld"))
        let call = AuditEvent(
            session: "s", kind: .toolCall, call: "c", details: ["tool": "read_file", "arguments": "{}"])
        #expect(call.summary.contains("tool.call session=s call=c: read_file {}"))
        let long = AuditEvent(
            session: "s", kind: .response, details: ["text": .string(String(repeating: "x", count: 300))])
        #expect(long.summary.hasSuffix("…"))
        #expect(AuditEvent(session: "s", kind: .sessionEnd).summary.hasSuffix("session.end session=s"))
    }

    @Test func summariesCoverPolicyAndCommandBranches() {
        let decision = AuditEvent(
            session: "s", kind: .policyDecision, details: ["verdict": "denied", "command": "rm -rf /"])
        #expect(decision.summary.hasSuffix("policy.decision session=s: denied rm -rf /"))
        let outcome = AuditEvent(session: "s", kind: .commandOutcome, details: ["exitStatus": 3, "command": "make"])
        #expect(outcome.summary.hasSuffix("command.outcome session=s: exit=3 make"))
        let error = AuditEvent(session: "s", kind: .error, details: ["message": "boom"])
        #expect(error.summary.hasSuffix("error session=s: boom"))
        let generic = AuditEvent(session: "s", kind: .mcpRequest, details: ["tool": "respond", "arguments": "{}"])
        #expect(generic.summary.hasSuffix("mcp.request session=s: arguments={} tool=respond"))
    }

    @Test func jsonValueRoundTrips() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(JSONValue.string("s").stringValue == "s")
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.int(1).intValue == 1)
    }
}

@Suite struct AuditLogTests {
    @Test func numbersTurnsAndStampsSession() {
        let sink = MemoryAuditSink()
        let log = AuditLog(session: "abc", sink: sink)
        log.record(.sessionStart)
        #expect(log.beginTurn() == 1)
        log.record(.prompt, details: ["text": "hi"])
        log.beginTurn()
        log.error(CommandRunner.Failure.denied("x"), call: "c", context: "tool")
        let events = sink.events
        #expect(events.map(\.turn) == [nil, 1, 2])
        #expect(events.allSatisfy { $0.session == "abc" && $0.version == WispVersion.current })
        #expect(events[2].details["message"] == "command denied by policy: x")
        #expect(events[2].details["context"] == "tool")
        #expect(events[2].call == "c")
        let sibling = log.log(forSession: "t1")
        sibling.record(.sessionStart)
        #expect(sink.events.last?.session == "t1")
        #expect(sibling.currentTurn == 0)
    }

    @Test func fileSinkAppendsWithUserOnlyPermissionsAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "audit.jsonl")
        let sink = try FileAuditSink(url: url, limits: .init(maxFileBytes: 400, keepFiles: 2))
        let log = AuditLog(session: "s", sink: sink)
        for i in 0..<6 { log.record(.prompt, details: ["text": .string("message \(i)")]) }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["audit.1.jsonl", "audit.2.jsonl", "audit.jsonl"])
        let all = try names.flatMap { AuditQuery.events(in: try Data(contentsOf: dir.appending(path: $0))) }
        #expect(all.count >= 4)
        #expect(all.allSatisfy { $0.kind == .prompt })
        let current = AuditQuery.events(in: try Data(contentsOf: url))
        #expect(current.last?.details["text"] == "message 5")
    }

    @Test func fileSinkReopensExistingFileAtEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "audit.jsonl")
        AuditLog(session: "a", sink: try FileAuditSink(url: url)).record(.sessionStart)
        AuditLog(session: "b", sink: try FileAuditSink(url: url)).record(.sessionStart)
        #expect(AuditQuery.events(in: try Data(contentsOf: url)).map(\.session) == ["a", "b"])
    }

    @Test func concurrentSinksAppendWithoutOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "audit.jsonl")
        let a = AuditLog(session: "a", sink: try FileAuditSink(url: url))
        let b = AuditLog(session: "b", sink: try FileAuditSink(url: url))
        for i in 0..<20 {
            a.record(.prompt, details: ["text": .string("a\(i)")])
            b.record(.prompt, details: ["text": .string("b\(i)")])
        }
        let events = AuditQuery.events(in: try Data(contentsOf: url))
        #expect(events.count == 40)
        #expect(events.filter { $0.session == "a" }.count == 20)
    }

    @Test func queryFilters() {
        let events = [
            AuditEvent(session: "a", kind: .prompt), AuditEvent(session: "a", kind: .toolCall, details: ["tool": "x"]),
            AuditEvent(session: "b", kind: .toolCall, details: ["tool": "y"]),
            AuditEvent(session: "b", kind: .sessionEnd),
        ]
        #expect(AuditQuery(session: "a").filter(events).count == 2)
        #expect(AuditQuery(kinds: [.toolCall]).filter(events).count == 2)
        #expect(AuditQuery(kinds: [.toolCall], tool: "y").filter(events).map(\.session) == ["b"])
        #expect(AuditQuery(last: 1).filter(events).map(\.kind) == [.sessionEnd])
        #expect(AuditQuery.events(in: Data("not json\n".utf8)).isEmpty)
    }

    @Test func diagnosticsLevelParsing() {
        #expect(Diagnostics.Level(environmentValue: "DEBUG") == .debug)
        #expect(Diagnostics.Level(environmentValue: "warn") == .error)
        #expect(Diagnostics.Level(environmentValue: "loud") == nil)
        #expect(Diagnostics.Level.debug < .error)
    }
}

@Suite struct AuditedToolTests {
    @Test func recordsCallAndResultAroundTheBaseTool() async throws {
        let sink = MemoryAuditSink()
        let log = AuditLog(session: "s", sink: sink)
        let tool = AuditedTool(CurrentDateTool(), audit: log)
        #expect(tool.name == "current_date")
        #expect(tool.description == CurrentDateTool().description)
        let output = try await tool.call(arguments: .init(timeZone: "Asia/Tokyo"))
        #expect(output.hasSuffix("(Asia/Tokyo)"))
        let events = sink.events
        #expect(events.map(\.kind) == [.toolCall, .toolResult])
        #expect(events[0].call != nil && events[0].call == events[1].call)
        #expect(events[0].details["tool"] == "current_date")
        #expect(events[0].details["arguments"]?.stringValue?.contains("Asia/Tokyo") == true)
        #expect(events[1].details["output"] == .string(output))
    }

    @Test func commandRunnerRecordsPolicyAndOutcome() async throws {
        let sink = MemoryAuditSink()
        let log = AuditLog(session: "s", sink: sink)
        let runner = CommandRunner(
            options: .init(policy: CommandPolicy(deny: ["nope"], sandbox: .init(enabled: false))), audit: log)
        _ = try await runner.run("printf out")
        await #expect(throws: CommandRunner.Failure.self) { try await runner.run("echo nope") }
        let kinds = sink.events.map(\.kind)
        #expect(kinds == [.policyDecision, .commandOutcome, .policyDecision])
        #expect(sink.events[0].details["verdict"] == "allowed")
        #expect(sink.events[1].details["stdout"] == "out")
        #expect(sink.events[1].details["exitStatus"] == 0)
        #expect(sink.events[2].details["verdict"] == "denied")
    }
}

@Suite struct AuditDetailsTests {
    /// Every constructor's keys are within the documented field set for its kind.
    @Test func constructorsStayWithinTheDocumentedFields() {
        typealias D = AuditEvent.Details
        let outcome = CommandRunner.Outcome(exitStatus: 0, stdout: "o", stderr: "e", timedOut: false, truncated: true)
        let assessment = RiskAssessment(
            level: .moderate, reasons: ["r"], sources: ["rules"], metadata: ["coreml.label": "moderate"])
        let samples: [(AuditEvent.Kind, [String: JSONValue])] = [
            (
                .sessionStart,
                D.sessionStart(
                    entryPoint: .mcpThread, prompting: .init(systemPromptExtension: "e", instructions: "i"),
                    tools: ["t"], model: .system, unsafe: true,
                    autoApprove: false, resume: "r", parent: "p")
            ),
            (.sessionStart, D.sessionRestart(tools: ["t"], model: .system)),
            (.sessionEnd, D.sessionEnd(reason: "closed")),
            (
                .modelResolved,
                D.modelResolved(
                    model: .ollama("q"), backend: "ollama", asset: "a", capabilities: ["toolCalling"],
                    capabilitySource: .runtime, tools: ["run_command"])
            ),
            (.prompt, D.prompt(text: "hi")),
            (.response, D.response(text: "yo", condensed: true, seconds: 1)),
            (.toolCall, D.toolCall(tool: "t", arguments: "{}")),
            (.toolResult, D.toolResult(tool: "t", output: "out", seconds: 1)),
            (
                .policyDecision,
                D.policyDecision(
                    command: "c", workingDirectory: "/", verdict: .denied, reason: "why", sandbox: true, network: false,
                    nested: false)
            ),
            (.commandOutcome, D.commandOutcome(command: "c", outcome: outcome, seconds: 1)),
            (
                .condensation,
                D.condensation(turnsBefore: 5, turnsAfter: 4, contextSize: 4096, tokenCount: 5000, reason: "overflow")
            ),
            (.mcpRequest, D.mcpRequest(tool: "respond", arguments: "{}")),
            (.mcpResult, D.mcpResult(tool: "respond", isError: false, text: "t", seconds: 1)),
            (.error, D.error(message: "m", context: "c")),
            (
                .classifierVerdict,
                D.classifierVerdict(command: "c", pattern: "c *", line: "a && c", assessment: assessment, seconds: 1)
            ),
            (.approvalRequested, D.approvalRequested(command: "c", pattern: "c *", line: "c", level: .moderate)),
            (
                .approvalDecided,
                D.approvalDecided(
                    command: "c", pattern: "c *", line: "a && c", decision: "approved", scope: .session, reason: nil,
                    approvalID: "id", expiresAt: Date(), downgradedFrom: .project, persistError: "disk")
            ),
            (
                .secretScan,
                D.secretScan(
                    .init(
                        source: nil, bytes: 1, diff: false, chunks: 1, failedChunks: [1], findings: [], more: false,
                        classifier: "personal@1"))
            ),
            (
                .redaction,
                D.redaction(
                    .init(source: nil, bytes: 1, text: "", truncated: false, counts: [:], chunks: 1, failedChunks: [1]))
            ),
        ]
        for (kind, details) in samples {
            let extra = Set(details.keys).subtracting(AuditEvent.fields(for: kind))
            #expect(extra.isEmpty, "\(kind.rawValue) has undocumented fields \(extra.sorted())")
        }
        #expect(D.approvalRequested(command: "c", pattern: "c *", line: "c", level: .safe)["line"] == nil)
        #expect(
            D.sessionStart(
                entryPoint: .respond, prompting: .init(), tools: [], model: .system, unsafe: false, autoApprove: false,
                resume: nil)["resume"] == .null)
    }
}
