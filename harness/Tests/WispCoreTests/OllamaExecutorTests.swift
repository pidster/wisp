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
        interruptions.withLock { $0 = [:] }
    }

    /// How a response to a path is cut short, for the tests of Ollama stopping mid-turn.
    enum Interruption {
        /// The body is sent, then the connection is lost.
        case drop
        /// The body is sent and the connection held open, with nothing more, until the client gives up.
        case hold
    }

    /// The interruptions in force, keyed by path; a path without one is served whole.
    static let interruptions = Mutex<[String: Interruption]>([:])

    /// Serves `body` on `path`, then cuts the response short as `interruption` says.
    static func serve(_ path: String, body: String, then interruption: Interruption) {
        serve(path, body: body)
        interruptions.withLock { $0[path] = interruption }
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
        if !canned.body.isEmpty { client?.urlProtocol(self, didLoad: Data(canned.body.utf8)) }
        switch Self.interruptions.withLock({ $0[path] }) {
        case .drop:
            // Lost a moment later, as a real connection is, so the client has the response and is reading the
            // stream; on the loading thread's run loop, as a URL protocol's own work is.
            perform(#selector(loseConnection), with: nil, afterDelay: 0.05)
        case .hold: break
        case nil: client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// Fails the request as a lost connection does.
    @objc private func loseConnection() {
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct OllamaExecutorTests {
    static let settings = OllamaSettings(baseURL: URL(string: "http://fake.ollama:1")!, timeout: .seconds(5))
    static let config = Config(ollama: .init(baseURL: "http://fake.ollama:1", timeoutSeconds: 5)).resolved
    static let tags = #"{"models":[{"name":"q:latest","size":10,"details":{"parameter_size":"3B"}}]}"#
    static let shown = #"{"capabilities":["completion","tools"]}"#
    /// The last chunk Ollama streams for every reply, a tool call's included: `done`, with nothing more to say.
    static let doneChunk = #"{"message":{"role":"assistant","content":""},"done":true}"# + "\n"

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
        let resolved = try OllamaBackend().resolve("q", config: Self.config, home: OfflineBackends.home)
        #expect(resolved.capabilitySource == .runtime)
        #expect(resolved.capabilityNames == ["toolCalling", "guidedGeneration"])
        #expect(resolved.asset == "http://fake.ollama:1 q")
        #expect(
            try await OllamaBackend().installed(config: Self.config, home: OfflineBackends.home).first?.selection
                == .ollama("q:latest"))
        #expect(
            OllamaBackend().settings(in: Self.config, home: OfflineBackends.home).objectValue?["timeoutSeconds"] == 5)
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
        FakeOllama.serve("/api/chat", body: call + "\n" + Self.doneChunk)
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        let agent = Agent(instructions: "x", tools: [CurrentDateTool()], model: model)
        // The fake serves one canned body per path, so swap it once the first request has been made.
        let task = Task { try await agent.stream("date?") { _ in } }
        try await eventually("the first chat request") { !FakeOllama.bodies(for: "/api/chat").isEmpty }
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
        FakeOllama.serve("/api/chat", body: call + "\n" + Self.doneChunk)
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        let agent = Agent(instructions: "x", tools: [TopicTool()], model: model)
        let task = Task { try await agent.stream("which processes?") { _ in } }
        try await eventually("the first chat request") { !FakeOllama.bodies(for: "/api/chat").isEmpty }
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n")
        let reply = try await task.value
        #expect(reply.text == "ok")
        #expect(FakeOllama.bodies(for: "/api/chat").last?.contains("process=[] port=none") == true)
    }

    /// A `read_file` that says what it read, for the calls written as text.
    struct PathTool: Tool {
        let name = "read_file"
        let description = "Reads a file."
        @Generable struct Arguments {
            @Guide(description: "The path.") var path: String
        }
        func call(arguments: Arguments) async throws -> String { "contents of \(arguments.path)" }
    }

    /// Streamed reply chunks with these contents, then `done`.
    static func chunks(_ contents: [String], then extra: [String] = []) -> String {
        contents.map { content in
            let encoded = String(decoding: (try? JSONEncoder().encode(content)) ?? Data(), as: UTF8.self)
            return #"{"message":{"role":"assistant","content":"# + encoded + #"},"done":false}"#
        }.joined(separator: "\n") + "\n" + extra.map { $0 + "\n" }.joined() + Self.doneChunk
    }

    /// ministral-3:14b's reply on 2026-10-06 to "Read the file /tmp/notes.txt and also the file /tmp/todo.txt." with
    /// read_file offered: the first call written as text in `content`, one token a chunk, the second parsed by Ollama.
    static let ministralTwoReads = chunks(
        ["read", "_file", "[ARGS]", "{\"", "path", "\":", " \"/", "tmp", "/", "notes", ".txt", "\"}"],
        then: [
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_opeea9mb","function":{"index":0,"name":"read_file","arguments":{"path":"/tmp/todo.txt"}}}]},"done":false}"#
        ])

    @Test func mistralCallsWrittenAsTextAreMadeInTheOrderWritten() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        FakeOllama.serve("/api/chat", body: Self.ministralTwoReads)
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        let agent = Agent(instructions: "x", tools: [PathTool()], model: model)
        let task = Task { try await agent.stream("read both") { _ in } }
        try await eventually("the first chat request") { !FakeOllama.bodies(for: "/api/chat").isEmpty }
        FakeOllama.serve("/api/chat", body: Self.chunks(["Both read."]))
        let reply = try await task.value
        #expect(reply.text == "Both read.")
        let last = try #require(FakeOllama.bodies(for: "/api/chat").last)
        let notes = try #require(
            last.range(of: "contents of \\/tmp\\/notes.txt") ?? last.range(of: "contents of /tmp/notes.txt"))
        let todo = try #require(
            last.range(of: "contents of \\/tmp\\/todo.txt") ?? last.range(of: "contents of /tmp/todo.txt"))
        #expect(notes.lowerBound < todo.lowerBound, "\(last)")
        #expect(!last.contains("[ARGS]"), "\(last)")
    }

    @Test func aMistralCallAloneWithTheMarkerIsMade() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        FakeOllama.serve("/api/chat", body: Self.chunks(["[TOOL_CALLS]", "read_file[ARGS]", #"{"path": "/tmp/a"}"#]))
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        let agent = Agent(instructions: "x", tools: [PathTool()], model: model)
        let task = Task { try await agent.stream("read a") { _ in } }
        try await eventually("the first chat request") { !FakeOllama.bodies(for: "/api/chat").isEmpty }
        FakeOllama.serve("/api/chat", body: Self.chunks(["Read."]))
        #expect(try await task.value.text == "Read.")
        #expect(FakeOllama.bodies(for: "/api/chat").last?.contains("contents of") == true)
    }

    @Test func textThatOnlyLooksLikeAMistralCallIsTheReply() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        let model = try ModelSelection.ollama("q").resolve(config: Self.config)
        for (contents, expected) in [
            (
                ["Use ", #"read_file[ARGS]{"path": "x"}"#, " to read it."],
                #"Use read_file[ARGS]{"path": "x"} to read it."#
            ),
            (
                ["read_file", #"[ARGS]{"path": "x"}"#, " would read it."],
                #"read_file[ARGS]{"path": "x"} would read it."#
            ),
            ([#"write_file[ARGS]{"path": "x"}"#], #"write_file[ARGS]{"path": "x"}"#),
            (["read", " the file"], "read the file"),
        ] {
            FakeOllama.serve("/api/chat", body: Self.chunks(contents))
            let agent = Agent(instructions: "x", tools: [PathTool()], model: model)
            let before = FakeOllama.bodies(for: "/api/chat").count
            #expect(try await agent.stream("hi") { _ in }.text == expected)
            // One request: no call was made.
            #expect(FakeOllama.bodies(for: "/api/chat").count == before + 1)
        }
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

    @Test func aModelsWindowIsSizedFromItsShapeUnlessConfiguredAndEveryRequestAsksForIt() async throws {
        FakeOllama.serve("/api/tags", body: #"{"models":[{"name":"g:latest","size":5349000000}]}"#)
        FakeOllama.serve(
            "/api/show",
            body:
                #"{"capabilities":["completion","tools"],"model_info":{"general.architecture":"granite","granite.context_length":131072,"granite.block_count":40,"granite.attention.head_count":32,"granite.attention.head_count_kv":8,"granite.embedding_length":4096}}"#
        )
        FakeOllama.serve("/api/ps", body: #"{"models":[]}"#)
        let memory = MemoryState(installed: 51_539_607_552, available: 20_000_000_000)
        let sized = try OllamaModel(name: "g", settings: Self.settings).checked(memory: memory)
        #expect(sized.window == 24_576 && sized.windowReason.hasPrefix("24,576 of 131,072"), "\(sized.windowReason)")
        // A model Ollama already holds counts its memory as available.
        FakeOllama.serve("/api/ps", body: #"{"models":[{"name":"g:latest","size":10000000000}]}"#)
        let held = try OllamaModel(name: "g", settings: Self.settings).checked(
            memory: .init(installed: 51_539_607_552, available: 10_000_000_000))
        #expect(held.window == 24_576)
        #expect(try await OllamaModel.held("g:latest", at: Self.settings) == 10_000_000_000)
        // A configured window wins; no shape falls back to the floor and says why.
        var configured = Self.settings
        configured.contextLength = 4096
        let fixed = try OllamaModel(name: "g", settings: configured).checked(memory: memory)
        #expect(fixed.window == 4096 && fixed.windowReason == "configured as ollama.contextLength")
        // A model's own window comes before the one for every model, with or without its `:latest` tag.
        configured.modelContextLengths = ["g": 12288]
        let own = try OllamaModel(name: "g:latest", settings: configured).checked(memory: memory)
        #expect(own.window == 12288 && own.windowReason == "configured for this model as ollama.models.g.contextLength")
        var unsized = Self.settings
        unsized.modelContextLengths = ["other": 4096]
        let other = try OllamaModel(name: "g", settings: unsized).checked(memory: memory)
        #expect(!other.windowReason.hasPrefix("configured"), "\(other.windowReason)")
        FakeOllama.serve("/api/show", body: #"{"capabilities":["completion","tools"]}"#)
        let shapeless = try OllamaModel(name: "g", settings: Self.settings).checked(memory: memory)
        #expect(shapeless.window == 8192 && shapeless.windowReason.contains("no model shape"))
        // The window reaches the agent and every request's num_ctx.
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n")
        let resolved = ResolvedModel(
            selection: .ollama("g"), custom: sized, contextSize: sized.window, contextNote: sized.windowReason)
        let agent = Agent(instructions: "x", tools: [], model: resolved)
        #expect(agent.contextSize == 24_576)
        _ = try await agent.respond(to: "hi")
        #expect(FakeOllama.bodies(for: "/api/chat").last?.contains(#""num_ctx":24576"#) == true)
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
        let thread = try session.thread(id: "t", approver: DenyingApprover(reason: "x"))
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
        let textOnly = try session.thread(
            id: "t2", approver: DenyingApprover(reason: "x"), tools: ToolSelection.none)
        #expect(textOnly.tools.isEmpty)
        #expect(try await textOnly.openAgent().respond(to: "hi").text == "ok")
    }

    /// The shape probed on 2026-10-04 with ornith:9b: thinking chunks, then the reply's.
    static let thinkingStream =
        [
            #"{"message":{"role":"assistant","content":"","thinking":"Is 91"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","thinking":" 7 times"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","thinking":" 13?"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"No"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"."},"done":true,"prompt_eval_count":20,"eval_count":5}"#,
        ].joined(separator: "\n") + "\n"

    @Test func aReasoningModelsThinkingIsDecodedCountedAuditedAndNeverSentBack() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: #"{"capabilities":["completion","tools","thinking"]}"#)
        FakeOllama.serve("/api/chat", body: Self.thinkingStream)
        let config = Config(ollama: .init(baseURL: "http://fake.ollama:1", timeoutSeconds: 5, think: .off)).resolved
        let model = try ModelSelection.ollama("q").resolve(config: config)
        #expect(model.capabilityNames.contains("reasoning"))
        let sink = MemoryAuditSink()
        let trail = ToolEventTrail()
        let agent = Agent(
            instructions: "x", tools: [], model: model,
            audit: AuditLog(session: "s", sink: sink).alsoRecording(to: trail))
        agent.toolEvents = trail
        let reply = try await agent.stream("Is 91 prime? One word.") { _ in }
        #expect(reply.text == "No.")
        // The setting reached the body: `think` false, for a model that reports thinking.
        let first = try #require(FakeOllama.bodies(for: "/api/chat").last)
        #expect(first.contains(#""think":false"#), "\(first)")
        // Usage reports the thinking: one token a chunk.
        #expect(agent.session.usage.output.reasoningTokenCount == 3)
        // Audited at both edges, with the text and its tokens.
        let thoughts = sink.events.filter { $0.kind == .modelReasoning }
        #expect(thoughts.map { $0.details["phase"] } == ["start", "end"])
        #expect(thoughts.last?.details["text"] == "Is 91 7 times 13?" && thoughts.last?.details["tokens"] == 3)
        // Kept as the turn's reasoning entry, linked to its event; the next request does not carry it.
        let entry = try #require(agent.store.entries.first { $0.kind == .reasoning })
        #expect(entry.sources.first?.event == thoughts.last?.id)
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"Yes."},"done":true}"# + "\n")
        _ = try await agent.respond(to: "and 97?")
        let second = try #require(FakeOllama.bodies(for: "/api/chat").last)
        #expect(!second.contains("7 times") && second.contains("and 97?"), "\(second)")
    }

    @Test func thinkIsSentOnlyWhenConfiguredAndTheModelCanThink() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n")
        func body(think: OllamaThink?, capabilities: String) async throws -> String {
            FakeOllama.serve("/api/show", body: #"{"capabilities":[\#(capabilities)]}"#)
            let config = Config(ollama: .init(baseURL: "http://fake.ollama:1", timeoutSeconds: 5, think: think))
            let agent = Agent(
                instructions: "x", tools: [], model: try ModelSelection.ollama("q").resolve(config: config.resolved))
            _ = try await agent.respond(to: "hi")
            return FakeOllama.bodies(for: "/api/chat").last ?? ""
        }
        let thinking = #""completion","thinking""#
        #expect(try await body(think: .level("high"), capabilities: thinking).contains(#""think":"high""#))
        #expect(try await body(think: .on, capabilities: thinking).contains(#""think":true"#))
        // Unset leaves it to Ollama; a model that cannot think is never asked.
        #expect(!(try await body(think: nil, capabilities: thinking).contains(#""think""#)))
        #expect(!(try await body(think: .on, capabilities: #""completion""#).contains(#""think""#)))
        #expect(
            OllamaBackend().settings(
                in: Config(ollama: .init(think: .level("low"))).resolved, home: OfflineBackends.home
            )
            .objectValue?["think"] == "low")
    }
}
