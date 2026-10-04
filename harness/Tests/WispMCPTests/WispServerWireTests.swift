import Foundation
import MCP
import Synchronization
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// Drives `WispServer` over the real protocol: a `Client` on an in-memory transport, so every
/// request and result passes through the SDK's JSON encoding and decoding exactly as it does on
/// stdio. The thread behind `respond` runs a `ScriptedModel` through the framework's tool loop, so the
/// server's tools, gate, audit, and result shapes are exercised end to end with no on-device model.
/// Calls a tool and returns the whole result, structured content included, through the wire.
func call(_ client: Client, _ name: String, _ arguments: [String: Value]? = nil) async throws -> CallTool.Result {
    let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
    return try await context.value
}

@Suite struct WispServerWireTests {
    /// A connected client and server. `steps` scripts what the model does on each thread.
    private func connected(
        steps: [ScriptedModel.Step] = [
            .call(name: "current_date", arguments: #"{"timeZone":"Asia/Tokyo"}"#), .say("The date is {tool}"),
        ],
        approver: any Approver = DenyingApprover(reason: "not in tests"), elicitation: Bool = false,
        triageSteps: [ScriptedModel.Step] = [], config: String? = nil, unopenable: ModelSelection? = nil,
        fileAudit: Bool = false
    ) async throws -> (client: Client, server: WispServer, sink: MemoryAuditSink) {
        let sink = MemoryAuditSink()
        // With `fileAudit`, events also go to the audit file, which the resources that read the log serve.
        let dependencies =
            fileAudit
            ? Session.Dependencies(
                makeClassifier: { _, _ in RuleRiskClassifier.standard },
                makeSink: { home, config in
                    TeeAuditSink([sink, try FileAuditSink(url: home.auditFile, limits: config.auditLimits)])
                }) : .testing(sink: sink)
        let session = try scratchSession(dependencies: dependencies, config: config)
        let triageModel = ScriptedModel(steps: triageSteps, capabilities: [.guidedGeneration])
        let server = WispServer(session: session) { session, _, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: session.host(approver: approver), instructions: instructions, tools: tools, model: model)
            let agent = Agent(
                instructions: thread.prompting.rendered, tools: thread.tools,
                model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)), audit: thread.audit
            )
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        } makeTriageAgent: { thread, model in
            if let model, model == unopenable {
                throw ModelSelection.Failure.unavailable(model: model.description, reason: "no Ollama server")
            }
            return Agent(
                instructions: "x", tools: [], model: ResolvedModel(selection: model ?? .system, custom: triageModel),
                audit: thread.audit)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(
            name: "wire-test", version: "0",
            capabilities: elicitation ? .init(elicitation: .init(form: .init())) : .init())
        _ = try await client.connect(transport: transports.client)
        return (client, server, sink)
    }

    @Test func listsToolsAndResourcesOverTheProtocol() async throws {
        let pair = try await connected()
        let tools = try await pair.client.listTools().tools
        #expect(
            tools.map(\.name) == [
                "respond", "triage", "summarise_diff", "draft_change", "scan_secrets", "redact", "condense_log",
                "json_shape", "dependency_audit", "flaky_tests", "hot_paths", "set_fact_scope", "close_thread",
            ])
        #expect(tools.first?.inputSchema.objectValue?["required"] == .array([.string("prompt")]))
        let resources = try await pair.client.listResources().resources
        #expect(
            resources.map(\.uri) == [
                "wisp://tools", "wisp://tools.md", "wisp://config", "wisp://status", "wisp://threads",
                "wisp://approvals", "wisp://audit", "wisp://facts", "wisp://facts/proposed", "wisp://session/facts",
                "wisp://measurements",
            ])
        let json = try await pair.client.readResource(uri: "wisp://tools")
        #expect(json.first?.mimeType == "application/json")
        #expect(json.first?.text?.contains("run_command") == true)
        let markdown = try await pair.client.readResource(uri: "wisp://tools.md")
        #expect(markdown.first?.text?.hasPrefix("# wisp tools") == true)
        await #expect(throws: MCPError.self) { _ = try await pair.client.readResource(uri: "wisp://nope") }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func introspectionResourcesAndTemplateOverTheProtocol() async throws {
        let pair = try await connected(steps: [.say("one")])
        _ = try await call(pair.client, "respond", ["prompt": .string("a"), "thread_id": .string("intro")])
        let config = try await pair.client.readResource(uri: "wisp://config").first?.text ?? ""
        #expect(config.contains("\"version\" : \"\(WispVersion.current)\""))
        #expect(config.contains("\"threshold\" : \"moderate\""))
        let status = try await pair.client.readResource(uri: "wisp://status").first?.text ?? ""
        #expect(status.contains("\"threadCount\" : 1") && status.contains("\"threadsURI\" : \"wisp://threads\""))
        #expect(status.contains("\"entryPoint\" : \"mcp\""))
        #expect(try await pair.client.readResource(uri: "wisp://approvals").first?.text == "[\n\n]")
        let templates = try await pair.client.send(ListResourceTemplates.request(.init())).value.templates
        #expect(
            templates.map(\.uriTemplate) == [
                "wisp://audit/{session}", "wisp://threads/{thread_id}", "wisp://threads/{thread_id}/output",
                "wisp://threads/{thread_id}/output/{id}", "wisp://threads/{thread_id}/reasoning",
                "wisp://threads/{thread_id}/reasoning/{id}", "wisp://threads/{thread_id}/audit",
                "wisp://threads/{thread_id}/context", "wisp://threads/{thread_id}/context/{turn}",
                "wisp://threads/{thread_id}/context/next", "wisp://threads/{thread_id}/facts",
                "wisp://threads/{thread_id}/facts/{fact_id}", "wisp://threads/{thread_id}/summary",
                "wisp://facts/{fact_id}",
            ])
        // The audit resources read the file, and the test session writes to a memory sink, so they are
        // empty here; the shape and the id check are what the wire test pins. A thread's events are under
        // the thread, not under wisp://audit/{session}.
        let thread = try await pair.client.readResource(uri: "wisp://threads/intro/audit")
        #expect(thread.first?.mimeType == "application/x-ndjson")
        let other = try await pair.client.readResource(uri: "wisp://audit/triage-1234")
        #expect(other.first?.mimeType == "application/x-ndjson")
        await #expect(throws: MCPError.self) { _ = try await pair.client.readResource(uri: "wisp://audit/intro") }
        await #expect(throws: MCPError.self) { _ = try await pair.client.readResource(uri: "wisp://audit/bad id") }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func theModelCanInspectItsOwnStatus() async throws {
        let pair = try await connected(steps: [
            .call(name: "inspect", arguments: #"{"what":"status"}"#), .say("Status: {tool}"),
        ])
        let result = try await call(
            pair.client, "respond", ["prompt": .string("where are you?"), "thread_id": .string("self")])
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("\"session\" : \"self\""), "\(text)")
        #expect(text.contains("\"entryPoint\" : \"mcp-thread\"") == false)  // threads record the session's face
        #expect(text.contains("\"turn\" : 1"))
        #expect(text.contains("\"inspect\""))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func respondRunsTheToolLoopAndReturnsStructuredContent() async throws {
        let pair = try await connected()
        let result = try await call(pair.client, "respond", ["prompt": .string("date?"), "thread_id": .string("t1")])
        #expect(result.isError == false)
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text content"); return }
        #expect(text.hasPrefix("The date is 20"))
        #expect(text.hasSuffix("(Asia/Tokyo)"))
        let structured = result.structuredContent?.objectValue
        #expect(structured?["thread_id"] == .string("t1"))
        #expect(structured?["created"] == .bool(true))
        #expect(structured?["condensed"] == .bool(false))
        #expect(structured?["text"] == .string(text))
        #expect(structured?["refusals"] == .array([]))
        // The receipt folds the turn's audit events for the caller.
        let receipt = structured?["receipt"]?.objectValue
        #expect(receipt?["turn"] == .int(1))
        let tool = receipt?["tools"]?.arrayValue?.first?.objectValue
        #expect(tool?["name"] == .string("current_date"))
        #expect(tool?["arguments"]?.stringValue?.contains("Asia/Tokyo") == true)  // the framework re-serialises
        #expect((tool?["bytes"]?.intValue ?? 0) > 0)
        #expect(receipt?["commands"] == .array([]) && receipt?["errors"] == .array([]))
        #expect(receipt?["condensed"] == .bool(false))
        // The thread's audit session saw the whole loop.
        let thread = pair.sink.events.filter { $0.session == "t1" }.map(\.kind)
        #expect(thread == [.sessionStart, .prompt, .toolCall, .toolResult, .response])
        let server = pair.sink.events.filter { $0.kind == .mcpRequest || $0.kind == .mcpResult }
        #expect(server.count == 2)
        #expect(server.first?.details["arguments"]?.stringValue?.contains("\"prompt\"") == true)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aBangPromptGoesToTheModelAsTextAndRunsNothing() async throws {
        // `!` is chat's (ADR 0049): over MCP a caller types nothing, so `respond` takes the prompt as a message.
        let pair = try await connected(steps: [.say("that is text to me")])
        let result = try await call(
            pair.client, "respond", ["prompt": .string("!touch typed.txt"), "thread_id": .string("bang")])
        #expect(result.isError == false)
        #expect(result.structuredContent?.objectValue?["text"] == .string("that is text to me"))
        let thread = pair.sink.events.filter { $0.session == "bang" }
        #expect(thread.map(\.kind) == [.sessionStart, .prompt, .response])
        #expect(thread.first { $0.kind == .prompt }?.details["text"] == .string("!touch typed.txt"))
        #expect(!pair.sink.events.contains { [.commandTyped, .commandOutcome, .policyDecision].contains($0.kind) })
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func respondListsEachToolCallWithSmallOutputInlineAndLargeOutputByReference() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-calls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appending(path: "small.txt")
        try Data("one line\n".utf8).write(to: small)
        let large = dir.appending(path: "large.txt")
        let lines = (1...60).map { "line \($0) of a file too large to carry inline" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: large)
        let pair = try await connected(
            steps: [
                .call(name: "read_file", arguments: #"{"path":"\#(small.path)"}"#),
                .call(name: "read_file", arguments: #"{"path":"\#(large.path)"}"#),
                .call(name: "run_command", arguments: #"{"command":"echo hello","workingDirectory":"\#(dir.path)"}"#),
                .say("I read two files and ran echo."),
            ], fileAudit: true)
        let result = try await call(
            pair.client, "respond",
            [
                "prompt": .string("read both, then echo"), "thread_id": .string("calls"),
                "tools": .array(
                    [.string("read_file"), .string("run_command")]),
            ])
        #expect(result.isError == false)
        let calls = try #require(result.structuredContent?.objectValue?["calls"]?.arrayValue).compactMap(\.objectValue)
        #expect(calls.map { $0["tool"] } == [.string("read_file"), .string("read_file"), .string("run_command")])
        // Small output is inline, verbatim as the tool returned it.
        #expect(calls[0]["output"] == .string("1\tone line\n[end of file]"))
        #expect(calls[0]["bytes"] == .int(24) && calls[0]["outputURI"] == nil)
        #expect(calls[0]["arguments"]?.stringValue?.contains("small.txt") == true)
        // Large output is a reference to the audit log, which the resource resolves to the same text.
        let id = try #require(calls[1]["id"]?.stringValue)
        #expect(calls[1]["output"] == nil && (calls[1]["bytes"]?.intValue ?? 0) > 1024)
        let uri = try #require(calls[1]["outputURI"]?.stringValue)
        #expect(uri == "wisp://threads/calls/output/\(id)")
        let read = try await pair.client.readResource(uri: uri)
        #expect(read.first?.mimeType == "text/plain")
        #expect(read.first?.text?.hasPrefix("1\tline 1 of a file") == true)
        #expect(read.first?.text?.utf8.count == calls[1]["bytes"]?.intValue)
        // A command carries its line and exit status beside its output.
        #expect(calls[2]["command"] == .string("echo hello") && calls[2]["exitStatus"] == .int(0))
        #expect(calls[2]["output"]?.stringValue?.contains("hello") == true)
        // The receipt is unchanged beside it.
        let receipt = result.structuredContent?.objectValue?["receipt"]?.objectValue
        #expect(receipt?["tools"]?.arrayValue?.count == 3)
        // Unknown ids, other threads, and malformed URIs are protocol errors.
        await #expect(throws: MCPError.self) {
            _ = try await pair.client.readResource(uri: "wisp://threads/calls/output/0123456789abcdef")
        }
        await #expect(throws: MCPError.self) {
            _ = try await pair.client.readResource(uri: "wisp://threads/other/output/\(id)")
        }
        await #expect(throws: MCPError.self) {
            _ = try await pair.client.readResource(uri: "wisp://threads/calls/output/NOPE")
        }
        // The old place is gone.
        await #expect(throws: MCPError.self) {
            _ = try await pair.client.readResource(uri: "wisp://output/calls/\(id)")
        }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func withTheAuditOffLargeOutputHasNoReference() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-noaudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "f.txt")
        try Data(String(repeating: "word ", count: 100).utf8).write(to: file)
        let pair = try await connected(
            steps: [.call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("done")],
            config: #"{"audit":{"enabled":false},"inlineOutputBytes":100}"#)
        let result = try await call(pair.client, "respond", ["prompt": .string("read"), "thread_id": .string("n")])
        let first = result.structuredContent?.objectValue?["calls"]?.arrayValue?.first?.objectValue
        #expect(first?["output"] == nil && first?["outputURI"] == nil && (first?["bytes"]?.intValue ?? 0) > 100)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func refusedCommandsAreReportedInTheResult() async throws {
        // The model asks to touch a file; the gate (rules only, moderate) asks the denying approver.
        let pair = try await connected(steps: [
            .call(name: "run_command", arguments: #"{"command":"touch spike.txt"}"#), .say("It said: {tool}"),
        ])
        let result = try await call(pair.client, "respond", ["prompt": .string("go"), "thread_id": .string("t2")])
        #expect(result.isError == false)
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("not approved"))
        let refusals = result.structuredContent?.objectValue?["refusals"]?.arrayValue
        #expect(refusals?.count == 1)
        #expect(refusals?.first?.objectValue?["command"] == .string("touch spike.txt"))
        #expect(refusals?.first?.objectValue?["reason"] == .string("not in tests"))
        let receipt = result.structuredContent?.objectValue?["receipt"]?.objectValue
        let approval = receipt?["approvals"]?.arrayValue?.first?.objectValue
        #expect(approval?["command"] == .string("touch spike.txt"))
        #expect(approval?["decision"] == .string("denied"))
        #expect(approval?["level"] == .string("moderate"))
        #expect(receipt?["denials"]?.arrayValue?.first?.objectValue?["verdict"] == .string("disapproved"))
        #expect(receipt?["commands"] == .array([]))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aCallerThatAsksForProgressIsToldWhatTheTurnIsDoingInOrder() async throws {
        let pair = try await connected(steps: [
            .call(name: "run_command", arguments: #"{"command":"touch spike.txt"}"#), .say("It said: {tool}"),
        ])
        let received = Mutex<[ProgressNotification.Parameters]>([])
        _ = await pair.client.onNotification(ProgressNotification.self) { message in
            received.withLock { $0.append(message.params) }
        }
        let request = CallTool.request(
            .init(
                name: "respond", arguments: ["prompt": .string("go"), "thread_id": .string("p")],
                meta: Metadata(progressToken: .string("tok"))))
        let result = try await pair.client.send(request).value
        #expect(result.isError == false)
        // Notifications are sent before the result; give the client's handler a moment to run.
        for _ in 0..<50 where received.withLock({ $0.count }) < 4 { try await Task.sleep(for: .milliseconds(10)) }
        let progress = received.withLock { $0 }
        let lines = progress.compactMap(\.message)
        #expect(lines.first == "⚙ run_command touch spike.txt", "\(lines)")
        #expect(lines.contains { $0.hasPrefix("· moderate by rules") }, "\(lines)")
        #expect(lines.contains("waiting for approval [moderate]: touch spike.txt"), "\(lines)")
        #expect(lines.contains("· denied"), "\(lines)")
        #expect(progress.map(\.progress) == (1...progress.count).map(Double.init))
        #expect(progress.allSatisfy { $0.progressToken == .string("tok") })
        // A condensing tool relays through its own conversation; one whose capture fails still ends cleanly.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "a.log")
        try Data("fine\n".utf8).write(to: log)
        let scanned = try await pair.client.send(
            CallTool.request(
                .init(
                    name: "scan_secrets", arguments: ["path": .string(log.path)],
                    meta: Metadata(progressToken: .integer(7))))
        ).value
        #expect(scanned.isError == false)
        let failed = try await pair.client.send(
            CallTool.request(
                .init(
                    name: "scan_secrets", arguments: ["path": .string(dir.appending(path: "missing.log").path)],
                    meta: Metadata(progressToken: .integer(8))))
        ).value
        #expect(failed.isError == true)
        // Without a token, nothing is sent.
        received.withLock { $0.removeAll() }
        _ = try await call(pair.client, "respond", ["prompt": .string("again"), "thread_id": .string("q")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(received.withLock { $0.isEmpty })
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func approvalThroughElicitationRunsTheCommand() async throws {
        // A client that renders elicitation and accepts with scope "session".
        let sink = MemoryAuditSink()
        let session = try scratchSession(dependencies: .testing(sink: sink))
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let steps: [ScriptedModel.Step] = [
            .call(
                name: "run_command",
                arguments: #"{"command":"touch marker.txt && echo approved","workingDirectory":"\#(dir.path)"}"#),
            .say("{tool}"),
        ]
        let server = WispServer(session: session) { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model)
            let agent = Agent(
                instructions: "x", tools: thread.tools,
                model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)), audit: thread.audit
            )
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: "wire-test", version: "0", capabilities: .init(elicitation: .init(form: .init())))
        _ = await client.withElicitationHandler { _ in
            CreateElicitation.Result(action: .accept, content: ["scope": .string("session")])
        }
        _ = try await client.connect(transport: transports.client)
        let result = try await call(client, "respond", ["prompt": .string("go"), "thread_id": .string("t3")])
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("exit status: 0"))
        #expect(text.contains("approved"))
        let decided = sink.events.last { $0.kind == .approvalDecided }
        #expect(decided?.details["decision"] == "approved")
        #expect(decided?.details["scope"] == "session")
        let receipt = result.structuredContent?.objectValue?["receipt"]?.objectValue
        let command = receipt?["commands"]?.arrayValue?.first?.objectValue
        #expect(command?["command"] == .string("touch marker.txt && echo approved"))
        #expect(command?["exitStatus"] == .int(0))
        #expect(receipt?["approvals"]?.arrayValue?.first?.objectValue?["scope"] == .string("session"))
        await client.disconnect()
        await server.stop()
    }

    @Test func aSchemaShapesTheReplyIntoOutputOverTheProtocol() async throws {
        let pair = try await connected(steps: [.say(#"{"verdict":"pass","count":2}"#), .say("prose")])
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "verdict": .object(["type": .string("string"), "enum": .array([.string("pass"), .string("fail")])]),
                "count": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("verdict")]),
        ])
        let result = try await call(
            pair.client, "respond", ["prompt": .string("judge"), "thread_id": .string("t5"), "schema": schema])
        #expect(result.isError == false, "\(result)")
        let output = result.structuredContent?.objectValue?["output"]?.objectValue
        #expect(output?["verdict"] == .string("pass"))
        #expect(output?["count"] == .int(2))
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("\"verdict\""))
        #expect(pair.sink.events.first { $0.kind == .prompt && $0.session == "t5" }?.details["schema"] != nil)
        // The schema is per call: the next turn is prose again, and a bad schema is a tool error.
        let prose = try await call(pair.client, "respond", ["prompt": .string("again"), "thread_id": .string("t5")])
        #expect(prose.structuredContent?.objectValue?["output"] == .null)
        let bad = try await call(
            pair.client, "respond",
            ["prompt": .string("x"), "thread_id": .string("t5"), "schema": .object(["type": .string("string")])])
        #expect(bad.isError == true)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func triageRunsACommandJudgesChunksAndReturnsFindingsOverTheProtocol() async throws {
        // Two chunks, each judged once; the second repeats a finding and adds another.
        let pair = try await connected(
            triageSteps: [
                .say(#"{"failures":[{"kind":"error","location":"A.swift:3:5","message":"cannot find x"}]}"#),
                .say(
                    #"{"failures":[{"kind":"error","location":"A.swift:3:5","message":"cannot find x"},{"kind":"test-failure","location":"FooTests/bar()","message":"expected 1"}]}"#
                ),
            ])
        let lines = (1...120).map { "line \($0) of output that says nothing" }.joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-triage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "build.log")
        try Data(lines.utf8).write(to: log)
        let result = try await call(pair.client, "triage", ["path": .string(log.path)])
        #expect(result.isError == false, "\(result)")
        let structured = result.structuredContent?.objectValue
        #expect(structured?["chunks"] == .int(2))
        #expect(structured?["more"] == .bool(false))
        let findings = structured?["findings"]?.arrayValue
        #expect(findings?.count == 2)
        #expect(findings?.first?.objectValue?["location"] == .string("A.swift:3:5"))
        #expect(findings?.last?.objectValue?["kind"] == .string("test-failure"))
        #expect(structured?["source"]?.objectValue?["path"] == .string(log.path))
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.hasPrefix("2 findings; "))
        #expect(text.contains("test-failure\tFooTests/bar()\texpected 1"))
        // The triage has its own audited session: start, one prompt/response per chunk, end.
        let session = pair.sink.events.filter { $0.session.hasPrefix("triage-") }
        #expect(session.first?.kind == .sessionStart && session.last?.kind == .sessionEnd)
        #expect(session.filter { $0.kind == .prompt }.count == 2)
        #expect(session.first?.details["tools"] == .array([]))
        // A command runs through the runner under the gate; `true` is harmless and prints nothing.
        let quiet = try await call(
            pair.client, "triage", ["command": .string("true"), "working_directory": .string(dir.path)])
        #expect(quiet.isError == false, "\(quiet)")
        #expect(quiet.structuredContent?.objectValue?["chunks"] == .int(0))
        #expect(quiet.structuredContent?.objectValue?["source"]?.objectValue?["exitStatus"] == .int(0))
        // A missing file is a tool error, and bad arguments are protocol errors.
        let missing = try await call(pair.client, "triage", ["path": .string(dir.appending(path: "nope").path)])
        #expect(missing.isError == true)
        await #expect(throws: MCPError.self) { _ = try await call(pair.client, "triage", [:]) }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func summariseDiffReadsADiffJudgesItAndReturnsFilesAndFlagsOverTheProtocol() async throws {
        let pair = try await connected(
            triageSteps: [
                .say(
                    #"{"headline":"Adds a token","files":[{"path":"Sources/New.swift","summary":"new file"}],"flags":[{"kind":"secret","path":"Sources/New.swift","note":"token literal"}]}"#
                )
            ])
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = dir.appending(path: "change.diff")
        try Data(
            """
            diff --git a/Sources/New.swift b/Sources/New.swift
            new file mode 100644
            --- /dev/null
            +++ b/Sources/New.swift
            @@ -0,0 +1,1 @@
            +let token = "abc"
            """.utf8
        ).write(to: diff)
        let result = try await call(pair.client, "summarise_diff", ["path": .string(diff.path)])
        #expect(result.isError == false, "\(result)")
        let structured = result.structuredContent?.objectValue
        #expect(structured?["chunks"] == .int(1))
        #expect(structured?["headline"] == .string("Adds a token"))
        #expect(structured?["added"] == .int(1) && structured?["removed"] == .int(0))
        let file = structured?["files"]?.arrayValue?.first?.objectValue
        #expect(file?["path"] == .string("Sources/New.swift") && file?["change"] == .string("added"))
        #expect(file?["summary"] == .string("new file"))
        #expect(structured?["flags"]?.arrayValue?.first?.objectValue?["kind"] == .string("secret"))
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.hasPrefix("1 file, +1 -0\nAdds a token\nFLAG secret"))
        let session = pair.sink.events.filter { $0.session.hasPrefix("summarise-") }
        #expect(session.first?.kind == .sessionStart && session.last?.kind == .sessionEnd)
        await #expect(throws: MCPError.self) { _ = try await call(pair.client, "summarise_diff", [:]) }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func scanSecretsAndRedactReportMaskedAndReplaceOverTheProtocol() async throws {
        // Two model turns: the thorough redaction's sweep finds a name the rules cannot, then, asked again
        // with the name hidden, nothing more.
        let pair = try await connected(triageSteps: [
            .say(#"{"items":[{"text":"Jane Doe","kind":"name"}]}"#), .say(#"{"items":[]}"#),
        ])
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = "ghp_" + String(repeating: "aB3", count: 12)
        let log = dir.appending(path: "app.log")
        try Data("Jane Doe <jane@acme.co>\ntoken=\(token)\n".utf8).write(to: log)
        let scan = try await call(pair.client, "scan_secrets", ["path": .string(log.path)])
        #expect(scan.isError == false, "\(scan)")
        let finding = scan.structuredContent?.objectValue?["findings"]?.arrayValue?.first?.objectValue
        #expect(finding?["kind"] == .string("github-token") && finding?["location"] == .string("\(log.path):2"))
        guard case .text(let scanText, _, _)? = scan.content.first else { Issue.record("no text"); return }
        #expect(!scanText.contains(token) && scanText.hasPrefix("1 finding in "))
        let recorded = pair.sink.events.first { $0.kind == .secretScan }
        #expect(recorded?.details["kinds"] == ["github-token": 1] && recorded?.session.hasPrefix("scan-") == true)
        let redacted = try await call(pair.client, "redact", ["path": .string(log.path), "thorough": .bool(true)])
        #expect(redacted.isError == false, "\(redacted)")
        let text = redacted.structuredContent?.objectValue?["text"]?.stringValue ?? ""
        #expect(text == "[REDACTED:name#1] <[REDACTED:email#1]>\ntoken=[REDACTED:github-token#1]\n", "\(text)")
        #expect(redacted.structuredContent?.objectValue?["chunks"] == .int(1))
        // The thorough pass ran on the secrets task's measured default; the rules-only scan routed nothing.
        let routed = pair.sink.events.filter { $0.kind == .modelRouted }
        #expect(routed.count == 1 && routed.first?.session.hasPrefix("redact-") == true)
        #expect(routed.first?.details["task"] == "secrets" && routed.first?.details["model"] == "system")
        // Neither the results nor the audit records of either call carry the token.
        let events = pair.sink.events.filter { $0.session.hasPrefix("scan-") || $0.session.hasPrefix("redact-") }
        #expect(
            events.first { $0.kind == .redaction }?.details["replaced"] == ["email": 1, "github-token": 1, "name": 1])
        #expect(!events.contains { $0.kind != .commandOutcome && "\($0.details)".contains(token) })
        await #expect(throws: MCPError.self) { _ = try await call(pair.client, "redact", [:]) }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func dependencyAuditFlakyTestsAndHotPathsWorkWithoutAModelOverTheProtocol() async throws {
        let pair = try await connected()
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-exact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = dir.appending(path: "audit.json")
        try Data(
            #"{"auditReportVersion":2,"vulnerabilities":{"lodash":{"severity":"high","isDirect":true,"range":"<4.17.21","via":[{"title":"Prototype Pollution","url":"https://github.com/advisories/GHSA-p6mc-m468-83gw","severity":"high"}],"fixAvailable":{"name":"lodash","version":"4.17.21"}}}}"#
                .utf8
        ).write(to: audit)
        // An audit exits non-zero when it finds something; that is its answer, not a failed command.
        let deps = try await call(
            pair.client, "dependency_audit",
            ["command": .string("cat \(audit.path); exit 1"), "working_directory": .string(dir.path)])
        #expect(deps.isError == false, "\(deps)")
        #expect(deps.structuredContent?.objectValue?["exitStatus"] == .int(1))
        guard case .text(let text, _, _)? = deps.content.first else { Issue.record("no text"); return }
        #expect(text.hasPrefix("npm audit: 1 advisory (1 high), 1 with a fix"), "\(text)")
        let first = dir.appending(path: "run1.txt")
        let second = dir.appending(path: "run2.txt")
        try Data("test a ... ok\ntest b ... FAILED\n".utf8).write(to: first)
        try Data("test a ... ok\ntest b ... ok\n".utf8).write(to: second)
        let flaky = try await call(
            pair.client, "flaky_tests", ["paths": .array([.string(first.path), .string(second.path)])])
        #expect(flaky.structuredContent?.objectValue?["flaky"]?.arrayValue?.count == 1, "\(flaky)")
        let repeated = try await call(
            pair.client, "flaky_tests",
            ["command": .string("printf 'test a ... ok\\n'"), "runs": .int(2), "working_directory": .string(dir.path)])
        #expect(repeated.structuredContent?.objectValue?["runs"] == .int(2), "\(repeated)")
        await #expect(throws: MCPError.self) {
            _ = try await call(pair.client, "flaky_tests", ["paths": .array([.string(first.path)])])
        }
        let folded = dir.appending(path: "profile.folded")
        try Data("main;work 90\nmain;idle 10\n".utf8).write(to: folded)
        let hot = try await call(pair.client, "hot_paths", ["path": .string(folded.path)])
        #expect(hot.structuredContent?.objectValue?["samples"] == .int(100), "\(hot)")
        #expect(pair.sink.events.contains { $0.session.hasPrefix("flaky-") && $0.kind == .sessionStart })
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func condenseLogAndJSONShapeReadFilesWithoutAModelOverTheProtocol() async throws {
        let pair = try await connected()
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "app.log")
        let lines = (1...50).map { "2026-09-23T10:00:\(String(format: "%02d", $0 % 60))Z request \($0) ok" }
        try Data((lines + ["2026-09-23T10:01:00Z error: disk full"]).joined(separator: "\n").utf8).write(to: log)
        let digest = try await call(pair.client, "condense_log", ["path": .string(log.path)])
        #expect(digest.isError == false, "\(digest)")
        let structured = digest.structuredContent?.objectValue
        #expect(structured?["kind"] == "log" && structured?["lines"] == .int(51) && structured?["templates"] == .int(2))
        #expect(structured?["truncated"] == false)
        let first = structured?["groups"]?.arrayValue?.first?.objectValue
        #expect(first?["severity"] == "error" && first?["template"] == "error: disk full")
        let crash = dir.appending(path: "Demo.ips")
        try Data((#"{"bug_type":"309","app_name":"Demo"}"# + "\n" + #"{"exception":{"type":"EXC_CRASH"}}"#).utf8)
            .write(to: crash)
        let parsed = try await call(pair.client, "condense_log", ["path": .string(crash.path)])
        #expect(parsed.structuredContent?.objectValue?["kind"] == "crash")
        #expect(parsed.structuredContent?.objectValue?["exception"] == "EXC_CRASH")
        let json = dir.appending(path: "items.json")
        try Data(#"{"items":[{"id":1},{"id":2,"tag":"x"}]}"#.utf8).write(to: json)
        let shape = try await call(pair.client, "json_shape", ["path": .string(json.path)])
        #expect(shape.isError == false, "\(shape)")
        #expect(
            shape.structuredContent?.objectValue?["outline"]?.arrayValue?.contains("    tag?: string e.g. \"x\"")
                == true)
        let broken = try await call(pair.client, "json_shape", ["path": .string(log.path)])
        #expect(broken.isError == true)
        // A command that fails is flagged rather than digested as though its error were the log.
        let failing = try await call(
            pair.client, "condense_log",
            ["command": .string("ls /nonexistent-wisp-dir"), "working_directory": .string(dir.path)])
        #expect(failing.structuredContent?.objectValue?["exitStatus"] == .int(1))
        guard case .text(let warned, _, _)? = failing.content.first else { Issue.record("no text"); return }
        #expect(warned.hasPrefix("warning: the command exited 1"), "\(warned)")
        let passing = try await call(
            pair.client, "condense_log", ["command": .string("echo ok"), "working_directory": .string(dir.path)])
        #expect(passing.structuredContent?.objectValue?["exitStatus"] == .int(0))
        if !CommandRunner.isNestedSandbox {
            let unified = try await call(pair.client, "condense_log", ["last": .string("5s")])
            #expect(unified.isError == false && unified.structuredContent?.objectValue?["kind"] == "log", "\(unified)")
        }
        // Each is its own audited session, and neither opened a model.
        #expect(pair.sink.events.contains { $0.session.hasPrefix("log-") && $0.kind == .sessionStart })
        #expect(pair.sink.events.contains { $0.session.hasPrefix("shape-") && $0.kind == .sessionEnd })
        #expect(!pair.sink.events.contains { $0.session.hasPrefix("log-") && $0.kind == .prompt })
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func draftChangeSummarisesThenWritesOverTheProtocol() async throws {
        let pair = try await connected(triageSteps: [
            .say(
                #"{"headline":"Adds retry","files":[{"path":"Sources/Upload.swift","summary":"retries"}],"flags":[]}"#),
            .say(#"{"subject":"retry failed uploads.","points":["Calls retry twice"]}"#),
        ])
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = dir.appending(path: "change.diff")
        try Data(
            "diff --git a/Sources/Upload.swift b/Sources/Upload.swift\n--- a/Sources/Upload.swift\n+++ b/Sources/Upload.swift\n@@ -1 +1,2 @@\n func upload() {\n+    retry(2)\n"
                .utf8
        ).write(to: diff)
        let result = try await call(
            pair.client, "draft_change", ["kind": .string("commit"), "path": .string(diff.path)])
        #expect(result.isError == false, "\(result)")
        #expect(result.structuredContent?.objectValue?["subject"] == "Retry failed uploads")
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.hasPrefix("Retry failed uploads\n\n- Calls retry twice"))
        #expect(pair.sink.events.filter { $0.session.hasPrefix("draft-") && $0.kind == .prompt }.count == 2)
        let empty = dir.appending(path: "empty.diff")
        try Data().write(to: empty)
        let nothing = try await call(pair.client, "draft_change", ["kind": .string("pr"), "path": .string(empty.path)])
        #expect(nothing.isError == true)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func draftChangeRoutesByTheDiffsSizeWhenALadderIsConfigured() async throws {
        let pair = try await connected(
            triageSteps: [
                .say(#"{"headline":"x","files":[{"path":"a.swift","summary":"s"}],"flags":[]}"#),
                .say(#"{"subject":"Change a","points":[]}"#),
            ], config: #"{"routing":{"ladder":["system","ollama:qwen3.8:27b"]}}"#)
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-wire-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = dir.appending(path: "c.diff")
        try Data("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-a\n+b\n".utf8).write(
            to: diff)
        let result = try await call(
            pair.client, "draft_change", ["kind": .string("commit"), "path": .string(diff.path)])
        #expect(result.isError == false, "\(result)")
        // The shipped measurements give the system model no drafting envelope, so the ladder's last rung drafts.
        let fields = result.structuredContent?.objectValue
        #expect(fields?["model"] == "ollama:qwen3.8:27b" && fields?["routing"]?.stringValue?.isEmpty == false)
        let routed = pair.sink.events.first { $0.kind == .modelRouted }
        #expect(routed?.details["model"] == "ollama:qwen3.8:27b" && routed?.details["inputBytes"] != nil)
        await pair.client.disconnect()
        await pair.server.stop()
        // When the chosen rung cannot be opened, the first rung drafts and the reason says so.
        let down = try await connected(
            triageSteps: [
                .say(#"{"headline":"x","files":[{"path":"a.swift","summary":"s"}],"flags":[]}"#),
                .say(#"{"subject":"Change a","points":[]}"#),
            ], config: #"{"routing":{"ladder":["system","ollama:qwen3.8:27b"]}}"#, unopenable: .ollama("qwen3.8:27b"))
        let fallback = try await call(
            down.client, "draft_change", ["kind": .string("commit"), "path": .string(diff.path)])
        #expect(fallback.structuredContent?.objectValue?["model"] == "system", "\(fallback)")
        #expect(fallback.structuredContent?.objectValue?["routing"]?.stringValue?.contains("cannot be opened") == true)
        await down.client.disconnect()
        await down.server.stop()
    }

    @Test func settingsOnAnExistingThreadAndCloseThreadOverTheProtocol() async throws {
        let pair = try await connected(steps: [.say("one"), .say("two")])
        _ = try await call(pair.client, "respond", ["prompt": .string("a"), "thread_id": .string("t4")])
        let again = try await call(
            pair.client, "respond",
            ["prompt": .string("b"), "thread_id": .string("t4"), "model": .string("private-cloud")])
        #expect(again.isError == true)
        let closed = try await call(pair.client, "close_thread", ["thread_id": .string("t4")])
        #expect(closed.isError == false)
        #expect(pair.sink.events.last { $0.session == "t4" }?.kind == .sessionEnd)
        let missing = try await pair.client.callTool(name: "close_thread", arguments: ["thread_id": .string("t4")])
            .value
        #expect(missing.isError == true)
        await #expect(throws: MCPError.self) { _ = try await call(pair.client, "nope") }
        await #expect(throws: MCPError.self) {
            _ = try await call(pair.client, "respond", [:])
        }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func resultsSerialiseToTheWireShape() throws {
        // What a client receives for a respond result, byte for byte.
        let result = CallTool.Result(
            content: [.text(text: "hi", annotations: nil, _meta: nil)],
            structuredContent: .object(["thread_id": .string("t"), "created": .bool(true), "refusals": .array([])]),
            isError: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(result), as: UTF8.self)
        #expect(
            json
                == #"{"content":[{"text":"hi","type":"text"}],"isError":false,"structuredContent":{"created":true,"refusals":[],"thread_id":"t"}}"#
        )
        let decoded = try JSONDecoder().decode(CallTool.Result.self, from: Data(json.utf8))
        #expect(decoded.structuredContent == result.structuredContent)
    }
}
