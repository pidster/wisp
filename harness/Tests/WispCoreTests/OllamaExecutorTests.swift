import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A `URLProtocol` that plays Ollama for `URLSession.shared`: canned NDJSON for `/api/chat`, a tags
/// list for `/api/tags`, and whatever status the test asks for.
final class FakeOllama: URLProtocol {
    /// What the next requests get, keyed by path.
    static let responses = Mutex<[String: (status: Int, body: String)]>([:])
    /// Every request received, as path and body, for assertions.
    static let requests = Mutex<[(path: String, body: Data)]>([])

    /// The bodies sent to `path`, as text.
    static func bodies(for path: String) -> [String] {
        requests.withLock { $0 }.filter { $0.path == path }.map { String(decoding: $0.body, as: UTF8.self) }
    }

    static func serve(_ path: String, status: Int = 200, body: String) {
        responses.withLock { $0[path] = (status, body) }
    }

    static func reset() {
        responses.withLock { $0 = [:] }
        requests.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "fake.ollama"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path() ?? ""
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.requests.withLock { $0.append((path, data)) }
        } else if let body = request.httpBody {
            Self.requests.withLock { $0.append((path, body)) }
        }
        guard let canned = Self.responses.withLock({ $0[path] }), let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct OllamaExecutorTests {
    static let settings = OllamaSettings(baseURL: URL(string: "http://fake.ollama:1")!, timeout: .seconds(5))
    static let config = Config(ollama: .init(baseURL: "http://fake.ollama:1", timeoutSeconds: 5)).resolved
    static let tags = #"{"models":[{"name":"q:latest","size":10,"details":{"parameter_size":"3B"}}]}"#
    static let shown = #"{"capabilities":["completion","tools"]}"#

    init() {
        URLProtocol.registerClass(FakeOllama.self)
        FakeOllama.reset()
    }

    @Test func listsAndChecksInstalledModels() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        let installed = try await OllamaModel.installed(at: Self.settings)
        #expect(installed.map(\.name) == ["q:latest"])
        let checked = try OllamaModel(name: "q", settings: Self.settings).checked()
        #expect(checked.reported == ["completion", "tools"])
        #expect(checked.capabilities.contains(.toolCalling) && checked.capabilities.contains(.guidedGeneration))
        #expect(!checked.capabilities.contains(.reasoning))
        #expect(throws: OllamaModel.Failure.noSuchModel("z", installed: ["q:latest"])) {
            try OllamaModel(name: "z", settings: Self.settings).checked()
        }
        // Before a check nothing is declared; an embedding model declares nothing after one either.
        #expect(!OllamaModel(name: "q").capabilities.contains(.toolCalling))
        FakeOllama.serve("/api/show", body: #"{"capabilities":["embedding"]}"#)
        let embedding = try OllamaModel(name: "q", settings: Self.settings).checked()
        #expect(!embedding.capabilities.contains(.toolCalling) && !embedding.capabilities.contains(.guidedGeneration))
        #expect(OllamaModel(name: "q", settings: Self.settings).executorConfiguration.timeoutSeconds == 5)
        // The backend wraps all of it with the source and asset recorded.
        FakeOllama.serve("/api/show", body: Self.shown)
        let resolved = try OllamaBackend().resolve("q", config: Self.config, home: Home.resolve())
        #expect(resolved.capabilitySource == .runtime)
        #expect(resolved.capabilityNames == ["toolCalling", "guidedGeneration"])
        #expect(resolved.asset == "http://fake.ollama:1 q")
        #expect(
            try await OllamaBackend().installed(config: Self.config, home: Home.resolve()).first?.selection
                == .ollama("q:latest"))
        #expect(OllamaBackend().settings(in: Self.config, home: Home.resolve()).objectValue?["timeoutSeconds"] == 5)
        FakeOllama.serve("/api/tags", status: 500, body: "down")
        await #expect(throws: OllamaModel.Failure.serverError(status: 500, body: "down")) {
            _ = try await OllamaModel.installed(at: Self.settings)
        }
        FakeOllama.serve("/api/tags", body: "not json")
        await #expect(throws: OllamaModel.Failure.self) { _ = try await OllamaModel.installed(at: Self.settings) }
    }

    @Test func chatStreamsTextToolCallsAndUsageThroughTheFrameworkLoop() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        // Two responses in order: a tool call, then text once the tool output is in the transcript.
        let call =
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"current_date","arguments":{"timeZone":"UTC"}}}]},"done":false}"#
        let text = [
            #"{"message":{"role":"assistant","content":"The "},"done":false}"#,
            #"{"message":{"role":"assistant","content":"date."},"done":true,"prompt_eval_count":12,"eval_count":3}"#,
        ]
        FakeOllama.serve("/api/chat", body: call + "\n")
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        let agent = Agent(instructions: "x", tools: [CurrentDateTool()], model: model)
        // The fake serves one canned body per path, so swap it once the first request has been made.
        let task = Task { try await agent.stream("date?") { _ in } }
        while FakeOllama.bodies(for: "/api/chat").count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        FakeOllama.serve("/api/chat", body: text.joined(separator: "\n") + "\n")
        let reply = try await task.value
        #expect(reply.text == "The date.")
        let bodies = FakeOllama.bodies(for: "/api/chat")
        #expect(bodies.count >= 2)
        #expect(bodies[0].contains(#""name":"current_date""#))
        #expect(bodies[0].contains(#""stream":true"#))
        #expect(bodies.last?.contains(#""role":"tool""#) == true)
        #expect(bodies.last?.contains("Z (GMT)") == true)  // TimeZone("UTC") reports itself as GMT
    }

    /// A tool with a required string an Ollama model may leave out, as `system_info`'s `process` is.
    struct TopicTool: Tool {
        let name = "topic_tool"
        let description = "Reports a topic."
        @Generable struct Arguments {
            @Guide(description: "The topic.") var topic: String
            @Guide(description: "For one process: its name. Otherwise empty.") var process: String
            @Guide(description: "A port, if any.") var port: Int?
        }
        func call(arguments: Arguments) async throws -> String {
            "topic=\(arguments.topic) process=[\(arguments.process)] port=\(arguments.port.map(String.init) ?? "none")"
        }
    }

    @Test func aRequiredStringTheModelLeftOutIsFilledEmptyInsteadOfEndingTheTurn() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        // granite4.1:8b on 2026-09-29: {"topic": "processes"} for system_info, which requires process.
        let call =
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"topic_tool","arguments":{"topic":"processes"}}}]},"done":false}"#
        FakeOllama.serve("/api/chat", body: call + "\n")
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        let agent = Agent(instructions: "x", tools: [TopicTool()], model: model)
        let task = Task { try await agent.stream("which processes?") { _ in } }
        while FakeOllama.bodies(for: "/api/chat").count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n")
        let reply = try await task.value
        #expect(reply.text == "ok")
        #expect(FakeOllama.bodies(for: "/api/chat").last?.contains("process=[] port=none") == true)
    }

    @Test func onlyStringsArraysAndBooleansAreCompletedAndOnlyWhenRequired() {
        let schema: JSONValue = [
            "type": "object", "required": ["topic", "process", "names", "all", "count", "level"],
            "properties": [
                "topic": ["type": "string"], "process": ["type": "string"], "names": ["type": "array"],
                "all": ["type": "boolean"], "count": ["type": "integer"],
                "level": ["type": "string", "enum": ["low", "high"]], "port": ["type": "integer"],
            ],
        ]
        let completed = OllamaModel.Executor.completed(["topic": "x", "process": "Safari"], schema: schema)
        #expect(completed == ["topic": "x", "process": "Safari", "names": [], "all": false])
        #expect(OllamaModel.Executor.completed("not an object", schema: schema) == "not an object")
        #expect(OllamaModel.Executor.completed(["a": 1], schema: ["type": "object"]) == ["a": 1])
    }

    @Test func serverErrorsAndBadChunksAreTyped() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        FakeOllama.serve("/api/chat", status: 404, body: "no model")
        let agent = Agent(instructions: "x", tools: [], model: model)
        await #expect(throws: OllamaModel.Failure.serverError(status: 404, body: "no model")) {
            _ = try await agent.respond(to: "hi")
        }
        FakeOllama.serve("/api/chat", body: "{not json\n")
        await #expect(throws: OllamaModel.Failure.badResponse("{not json")) { _ = try await agent.respond(to: "hi") }
        FakeOllama.serve("/api/chat", body: #"{"error":"model busy"}"# + "\n")
        await #expect(throws: OllamaModel.Failure.serverError(status: 200, body: "model busy")) {
            _ = try await agent.respond(to: "hi")
        }
        #expect(OllamaModel.Failure.unreachable(Self.settings.baseURL, "x").description.contains("no Ollama server"))
        #expect(OllamaModel.Failure.noSuchModel("m", installed: []).description.contains("installed: none"))
    }

    @Test func aSessionOpensAgentsOnAnOllamaModel() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n")
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-ollama-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        try home.ensure()
        try Data(#"{"model":"ollama:q","ollama":{"baseURL":"http://fake.ollama:1","timeoutSeconds":5}}"#.utf8)
            .write(to: home.configFile)
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
        #expect(session.notes.isEmpty)  // Ollama is local: no egress note
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        #expect(try await agent.respond(to: "hi").text == "ok")
        let resolvedEvent = sink.events.first { $0.kind == .modelResolved }
        #expect(resolvedEvent?.details["backend"] == "ollama")
        #expect(resolvedEvent?.details["capabilitySource"] == "runtime")
        #expect(resolvedEvent?.details["capabilities"] == .array(["toolCalling", "guidedGeneration"]))
        #expect(resolvedEvent?.details["asset"] == "http://fake.ollama:1 q")
        let resumed = try session.openAgent(approver: DenyingApprover(reason: "x"), transcript: agent.transcript)
        #expect(resumed.transcript.turnCount == 1)
        #expect(sink.events.first?.details["model"] == "ollama:q")
        // A thread conversation resolves the same way.
        let thread = try session.conversation(id: "t", approver: DenyingApprover(reason: "x"))
        #expect(try await thread.openAgent().respond(to: "hi").text == "ok")
        // An embedding model cannot hold a conversation: it is refused at resolution, with the reason.
        FakeOllama.serve("/api/show", body: #"{"capabilities":["embedding"]}"#)
        do {
            _ = try session.openAgent(approver: DenyingApprover(reason: "x"))
            Issue.record("an embedding model opened a conversation")
        } catch ModelSelection.Failure.unavailable(let model, let reason) {
            #expect(model == "ollama:q" && reason.contains("cannot hold a conversation (capabilities: embedding)"))
        }
        // A text-only model refuses tools with a hint, and runs with none.
        FakeOllama.serve("/api/show", body: #"{"capabilities":["completion"]}"#)
        #expect(throws: ModelSelection.Failure.self) { try session.openAgent(approver: DenyingApprover(reason: "x")) }
        do {
            _ = try session.openAgent(approver: DenyingApprover(reason: "x"))
        } catch ModelSelection.Failure.unsupportedCapability(let model, let capability, let declaredBy, let hint) {
            #expect(model == "ollama:q" && capability == "tool calling" && declaredBy == .runtime)
            #expect(hint.contains("no tools"))
        }
        let textOnly = try session.conversation(
            id: "t2", approver: DenyingApprover(reason: "x"), tools: ToolSelection.none)
        #expect(textOnly.tools.isEmpty)
        #expect(try await textOnly.openAgent().respond(to: "hi").text == "ok")
    }
}
