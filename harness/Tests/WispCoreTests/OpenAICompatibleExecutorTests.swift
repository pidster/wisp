import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A `URLProtocol` that plays an OpenAI-compatible server, llama.cpp's or LM Studio's, for `URLSession.shared`: canned
/// bodies by host and path, in order (the last repeating), with the request's headers and body kept.
final class FakeChatServer: URLProtocol {
    /// One request received.
    struct Received {
        /// The host and path, such as `llama.fakeserver/v1/chat/completions`.
        var key: String
        /// The query, if any.
        var query: String?
        /// The headers sent.
        var headers: [String: String]
        /// The body sent.
        var body: Data
    }

    /// How a response is cut short.
    enum Interruption {
        /// The body is sent, then the connection is lost.
        case drop
        /// The body is sent and the connection held open, with nothing more, until the client gives up.
        case hold
    }

    /// What the next requests get, by host and path: bodies in order, the last repeating.
    static let responses = Mutex<[String: [(status: Int, body: String)]]>([:])
    /// Every request received.
    static let requests = Mutex<[Received]>([])
    /// The interruptions in force, by host and path.
    static let interruptions = Mutex<[String: Interruption]>([:])

    /// Serves `bodies` in order on `host` and `path`, the last repeating.
    static func serve(_ host: String, _ path: String, status: Int = 200, _ bodies: String...) {
        responses.withLock { $0["\(host)\(path)"] = bodies.map { (status, $0) } }
    }

    /// Serves `body`, then cuts the response short.
    static func serve(_ host: String, _ path: String, body: String, then interruption: Interruption) {
        serve(host, path, body)
        interruptions.withLock { $0["\(host)\(path)"] = interruption }
    }

    /// Forgets everything.
    static func reset() {
        responses.withLock { $0 = [:] }
        requests.withLock { $0 = [] }
        interruptions.withLock { $0 = [:] }
    }

    /// The requests to `host` and `path`.
    static func received(_ host: String, _ path: String) -> [Received] {
        requests.withLock { $0 }.filter { $0.key == "\(host)\(path)" }
    }

    /// The bodies sent to `host` and `path`, as text.
    static func bodies(_ host: String, _ path: String) -> [String] {
        received(host, path).map { String(decoding: $0.body, as: UTF8.self) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".fakeserver") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.url?.host() ?? "")\(request.url?.path() ?? "")"
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        } else if let body = request.httpBody {
            data = body
        }
        Self.requests.withLock {
            $0.append(
                Received(key: key, query: request.url?.query(), headers: request.allHTTPHeaderFields ?? [:], body: data)
            )
        }
        let canned: (status: Int, body: String)? = Self.responses.withLock { responses in
            guard var queue = responses[key], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                responses[key] = queue
            }
            return first
        }
        guard let canned, let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !canned.body.isEmpty { client?.urlProtocol(self, didLoad: Data(canned.body.utf8)) }
        switch Self.interruptions.withLock({ $0[key] }) {
        case .drop: perform(#selector(loseConnection), with: nil, afterDelay: 0.05)
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

/// The shared HTTP executor over both dialects, with a fake server (ADR 0058): streamed text, tool calls whole and in
/// fragments, schema replies, thinking, usage, a stream cut short, a silent server, the key, listings and windows.
@Suite(.serialized) struct OpenAICompatibleExecutorTests {
    static let llama = "llama.fakeserver"
    static let studio = "studio.fakeserver"
    static let chat = "/v1/chat/completions"

    /// llama.cpp's listing of one model, loaded from a path, and its props.
    static let llamaModels =
        #"{"object":"list","data":[{"id":"/models/Qwen3-8B-Q4_K_M.gguf","object":"model","owned_by":"llamacpp","meta":{"n_params":8190735360,"size":5027783488,"n_ctx_train":40960}}]}"#
    static let llamaProps =
        #"{"default_generation_settings":{"n_ctx":16384},"total_slots":1,"model_path":"/models/Qwen3-8B-Q4_K_M.gguf","modalities":{"vision":false}}"#
    /// LM Studio's listing: one model loaded, one not, an embedding model.
    static let studioModels = #"""
        {"models":[
         {"type":"llm","publisher":"qwen","key":"qwen/qwen3-8b","display_name":"Qwen3 8B","architecture":"qwen3",
          "quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":5027783488,"params_string":"8B",
          "loaded_instances":[{"id":"qwen/qwen3-8b","config":{"context_length":32768}}],"max_context_length":40960,
          "format":"gguf","capabilities":{"vision":false,"trained_for_tool_use":true,
          "reasoning":{"allowed_options":["off","on"],"default":"on"}}},
         {"type":"llm","publisher":"google","key":"google/gemma-3-1b","architecture":"gemma3",
          "quantization":{"name":"4bit"},"size_bytes":700000000,"params_string":"1B","loaded_instances":[],
          "max_context_length":32768,"format":"mlx","capabilities":{"vision":false,"trained_for_tool_use":false}},
         {"type":"embedding","publisher":"nomic","key":"text-embedding-nomic","size_bytes":80000000,
          "loaded_instances":[],"max_context_length":2048}
        ]}
        """#

    static let llamaConfig = Config(llamacpp: .init(baseURL: "http://\(llama):1", timeoutSeconds: 5)).resolved
    static let studioConfig = Config(lmstudio: .init(baseURL: "http://\(studio):1", timeoutSeconds: 5)).resolved

    init() {
        URLProtocol.registerClass(FakeChatServer.self)
        FakeChatServer.reset()
        FakeChatServer.serve(Self.llama, "/v1/models", Self.llamaModels)
        FakeChatServer.serve(Self.llama, "/props", Self.llamaProps)
        FakeChatServer.serve(Self.studio, "/api/v1/models", Self.studioModels)
    }

    // MARK: - Streams

    /// One event's line of a server-sent stream.
    static func event(_ json: JSONValue) -> String {
        let data = (try? JSONEncoder().encode(json)) ?? Data()
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }

    /// A chunk whose one choice adds `delta`, finishing when `finish` is set.
    static func chunk(_ delta: JSONValue, finish: String? = nil) -> String {
        event([
            "id": "c", "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { .string($0) } ?? .null]],
        ])
    }

    /// The usage chunk `include_usage` asks for: no choices.
    static func usage(prompt: Int, completion: Int, cached: Int? = nil, reasoning: Int? = nil) -> String {
        var usage: [String: JSONValue] = ["prompt_tokens": .int(prompt), "completion_tokens": .int(completion)]
        if let cached { usage["prompt_tokens_details"] = ["cached_tokens": .int(cached)] }
        if let reasoning { usage["completion_tokens_details"] = ["reasoning_tokens": .int(reasoning)] }
        return event(["choices": [], "usage": .object(usage)])
    }

    /// The end of a stream.
    static let done = "data: [DONE]\n\n"

    /// A whole streamed reply of `pieces`, finished, with usage.
    static func reply(_ pieces: [String], usage: String = Self.usage(prompt: 10, completion: 2)) -> String {
        pieces.map { chunk(["content": .string($0)]) }.joined() + chunk([:], finish: "stop") + usage + done
    }

    /// A streamed tool call, whole in one fragment.
    static func call(_ name: String, _ arguments: String, index: Int = 0, id: String = "call_1") -> String {
        chunk([
            "tool_calls": [
                [
                    "index": .int(index), "id": .string(id), "type": "function",
                    "function": ["name": .string(name), "arguments": .string(arguments)],
                ]
            ]
        ])
    }

    /// A model on `scheme`, resolved through its backend against the fake.
    static func resolved(_ dialect: OpenAICompatibleDialect, _ name: String) throws -> ResolvedModel {
        let config = dialect == .llamaCpp ? llamaConfig : studioConfig
        return try ModelSelection.local(backend: dialect.scheme, name: name).resolve(config: config)
    }

    /// The host a dialect's fake serves on.
    static func host(_ dialect: OpenAICompatibleDialect) -> String { dialect == .llamaCpp ? llama : studio }

    /// The name each dialect's fake serves a tool-calling model under.
    static func toolModel(_ dialect: OpenAICompatibleDialect) -> String {
        dialect == .llamaCpp ? "Qwen3-8B-Q4_K_M" : "qwen/qwen3-8b"
    }

    /// A model that may call tools: LM Studio's reports it; llama.cpp's is declared, as wisp's check records it.
    static func toolCapable(_ dialect: OpenAICompatibleDialect) throws -> ResolvedModel {
        guard dialect == .llamaCpp else { return try resolved(dialect, toolModel(dialect)) }
        var config = llamaConfig
        config.llamacpp.declared["Qwen3-8B-Q4_K_M"] = .init(capabilities: ["toolCalling"])
        return try ModelSelection.local(backend: "llamacpp", name: "Qwen3-8B-Q4_K_M").resolve(config: config)
    }

    /// A `read_file` that says what it read.
    struct PathTool: Tool {
        let name = "read_file"
        let description = "Reads a file."
        @Generable struct Arguments {
            @Guide(description: "The path.") var path: String
        }
        func call(arguments: Arguments) async throws -> String { "contents of \(arguments.path)" }
    }

    @Test(arguments: OpenAICompatibleDialect.all)
    func textStreamsInDeltasAndTheBodyAsksForAStreamWithUsage(_ dialect: OpenAICompatibleDialect) async throws {
        let host = Self.host(dialect)
        FakeChatServer.serve(host, Self.chat, Self.reply(["The ", "answer", "."]))
        let model = try Self.resolved(dialect, Self.toolModel(dialect))
        let agent = Agent(instructions: "Be brief.", tools: [], model: model)
        var deltas: [String] = []
        let reply = try await agent.stream("question") { deltas.append($0) }
        #expect(reply.text == "The answer.")
        #expect(deltas.count >= 1)
        let body = try #require(FakeChatServer.bodies(host, Self.chat).last)
        #expect(body.contains(#""stream":true"#) && body.contains(#""include_usage":true"#), "\(body)")
        #expect(body.contains(#""role":"system""#) && body.contains(#""content":"question""#), "\(body)")
        // The model is named as the server knows it: llama.cpp's by the path it lists.
        let id = dialect == .llamaCpp ? "/models/Qwen3-8B-Q4_K_M.gguf" : "qwen/qwen3-8b"
        #expect(body.contains(#""model":"\#(id)""#), "\(body)")
        #expect(!body.contains("tools") && !body.contains("response_format"), "\(body)")
        // Usage reached the model, for condensing ahead of the window.
        #expect(model.reportedInputTokens() == 10)
    }

    @Test(arguments: OpenAICompatibleDialect.all)
    func aToolCallRunsThroughTheFrameworkLoopAndItsOutputAnswersItsID(_ dialect: OpenAICompatibleDialect) async throws {
        let host = Self.host(dialect)
        FakeChatServer.serve(
            host, Self.chat,
            Self.call("read_file", #"{"path":"/tmp/a"}"#) + Self.chunk([:], finish: "tool_calls") + Self.done,
            Self.reply(["Read."]))
        let agent = Agent(instructions: "x", tools: [PathTool()], model: try Self.toolCapable(dialect))
        #expect(try await agent.stream("read a") { _ in }.text == "Read.")
        let bodies = FakeChatServer.bodies(host, Self.chat)
        #expect(bodies.count == 2)
        #expect(bodies[0].contains(#""tools":[{"function":{"description":"Reads a file.","name":"read_file""#))
        // The second request carries the call with a positional id and the output answering it.
        let second = try #require(bodies.last)
        #expect(
            second.contains(
                #""tool_calls":[{"function":{"arguments":"{\"path\":\"/tmp/a\"}","name":"read_file"},"id":"call00001","type":"function"}]"#
            ), "\(second)")
        #expect(
            second.contains(#""content":"contents of /tmp/a","role":"tool","tool_call_id":"call00001""#), "\(second)")
        #expect(second.contains(#""content":null"#), "\(second)")
    }

    @Test func severalCallsSplitAcrossChunksAreGatheredByIndexAndMadeInOrder() async throws {
        let host = Self.llama
        // Two calls, their names first, their arguments in pieces, interleaved as a server may send them.
        let fragments = [
            Self.chunk(["tool_calls": [["index": 0, "id": "a", "function": ["name": "read_file", "arguments": ""]]]]),
            Self.chunk(["tool_calls": [["index": 0, "function": ["arguments": #"{"pa"#]]]]),
            Self.chunk([
                "tool_calls": [["index": 1, "id": "b", "function": ["name": "read_file", "arguments": #"{"#]]]
            ]),
            Self.chunk(["tool_calls": [["index": 0, "function": ["arguments": #"th":"/tmp/one"}"#]]]]),
            Self.chunk(["tool_calls": [["index": 1, "function": ["arguments": #""path":"/tmp/two"}"#]]]]),
            Self.chunk([:], finish: "tool_calls"), Self.done,
        ].joined()
        FakeChatServer.serve(host, Self.chat, fragments, Self.reply(["Both."]))
        let agent = Agent(instructions: "x", tools: [PathTool()], model: try Self.toolCapable(.llamaCpp))
        #expect(try await agent.stream("read both") { _ in }.text == "Both.")
        let last = try #require(FakeChatServer.bodies(host, Self.chat).last)
        let one = try #require(last.range(of: "contents of /tmp/one"))
        let two = try #require(last.range(of: "contents of /tmp/two"))
        #expect(one.lowerBound < two.lowerBound, "\(last)")
        #expect(last.contains(#""tool_call_id":"call00001""#) && last.contains(#""tool_call_id":"call00002""#))
    }

    @Test func fragmentsWithoutAnIndexAreGatheredByIdAndName() throws {
        typealias Executor = OpenAICompatibleModel.Executor
        func fragment(_ id: String?, _ name: String?, _ arguments: String?) -> Executor.Chunk.ToolCallDelta {
            .init(index: nil, id: id, function: .init(name: name, arguments: arguments))
        }
        var calls: [Executor.PendingCall] = []
        for piece in [
            fragment("a", "read_file", ""), fragment(nil, "", #"{"path":"#), fragment(nil, nil, #""x"}"#),
            fragment("b", "read_file", nil), fragment(nil, nil, #"{"path":"y"}"#),
        ] {
            Executor.gather(piece, into: &calls)
        }
        #expect(calls.map(\.name) == ["read_file", "read_file"])
        #expect(calls.map(\.arguments) == [#"{"path":"x"}"#, #"{"path":"y"}"#])
        #expect(throws: OpenAICompatibleModel.Failure.self) {
            try Executor.arguments(.init(name: "read_file", arguments: "{not json"), dialect: .llamaCpp)
        }
        #expect(try Executor.arguments(.init(name: "read_file", arguments: " "), dialect: .llamaCpp) == .object([:]))
    }

    @Test(arguments: OpenAICompatibleDialect.all)
    func aSchemaReplyIsAskedForWithResponseFormatAndDecoded(_ dialect: OpenAICompatibleDialect) async throws {
        let host = Self.host(dialect)
        FakeChatServer.serve(host, Self.chat, Self.reply([#"{"colour":"#, #""red","number":7}"#]))
        let model = try Self.resolved(dialect, Self.toolModel(dialect))
        #expect(model.capabilityNames.contains("guidedGeneration"))
        let session = model.session(tools: [], instructions: "Answer with the fields asked for.")
        let answer = try await session.respond(to: "A colour and a number.", generating: ColourAndNumber.self).content
        #expect(answer.colour == "red" && answer.number == 7)
        let body = try #require(FakeChatServer.bodies(host, Self.chat).last)
        #expect(body.contains(#""response_format":{"json_schema":{"name":"reply","schema":{"#), "\(body)")
        #expect(body.contains(#""type":"json_schema""#), "\(body)")
    }

    @Test(arguments: OpenAICompatibleDialect.all)
    func thinkingIsDecodedCountedAuditedAndNeverSentBack(_ dialect: OpenAICompatibleDialect) async throws {
        let host = Self.host(dialect)
        // llama.cpp streams thinking as `reasoning_content`; LM Studio since 0.3.23 as `reasoning`.
        let field = dialect == .llamaCpp ? "reasoning_content" : "reasoning"
        let thinking = ["Is 91", " 7 times", " 13?"].map { Self.chunk([field: .string($0)]) }.joined()
        FakeChatServer.serve(
            host, Self.chat,
            thinking + Self.chunk(["content": "No."]) + Self.chunk([:], finish: "stop")
                + Self.usage(prompt: 20, completion: 5, cached: 4) + Self.done)
        let sink = MemoryAuditSink()
        let trail = ToolEventTrail()
        let agent = Agent(
            instructions: "x", tools: [], model: try Self.resolved(dialect, Self.toolModel(dialect)),
            audit: AuditLog(session: "s", sink: sink).alsoRecording(to: trail))
        agent.toolEvents = trail
        #expect(try await agent.stream("Is 91 prime?") { _ in }.text == "No.")
        // No reasoning count from the server: the chunks are the count, within the output.
        #expect(agent.session.usage.output.reasoningTokenCount == 3)
        #expect(agent.session.usage.input.cachedTokenCount == 4)
        let thoughts = sink.events.filter { $0.kind == .modelReasoning }
        #expect(thoughts.map { $0.details["phase"] } == ["start", "end"])
        #expect(thoughts.last?.details["text"] == "Is 91 7 times 13?")
        FakeChatServer.serve(host, Self.chat, Self.reply(["Yes."]))
        _ = try await agent.respond(to: "and 97?")
        let second = try #require(FakeChatServer.bodies(host, Self.chat).last)
        #expect(!second.contains("7 times") && second.contains("and 97?"), "\(second)")
    }

    @Test func aReasoningCountTheServerReportsIsUsed() async throws {
        FakeChatServer.serve(
            Self.llama, Self.chat,
            Self.chunk(["reasoning_content": "hm"]) + Self.chunk(["content": "ok"]) + Self.chunk([:], finish: "stop")
                + Self.usage(prompt: 7, completion: 30, reasoning: 25) + Self.done)
        let agent = Agent(instructions: "x", tools: [], model: try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M"))
        _ = try await agent.respond(to: "hi")
        #expect(agent.session.usage.output.reasoningTokenCount == 25)
        #expect(agent.session.usage.output.totalTokenCount == 30)
    }

    @Test func thinkIsSentAsTheTemplatesEnableThinkingOnlyForLlamaCppAndOnlyWhenSet() async throws {
        FakeChatServer.serve(Self.llama, Self.chat, Self.reply(["ok"]))
        FakeChatServer.serve(Self.studio, Self.chat, Self.reply(["ok"]))
        func body(_ config: Config, _ dialect: OpenAICompatibleDialect, _ name: String) async throws -> String {
            let model = try ModelSelection.local(backend: dialect.scheme, name: name).resolve(config: config.resolved)
            _ = try await Agent(instructions: "x", tools: [], model: model).respond(to: "hi")
            return FakeChatServer.bodies(Self.host(dialect), Self.chat).last ?? ""
        }
        let off = Config(llamacpp: .init(baseURL: "http://\(Self.llama):1", think: false))
        #expect(
            try await body(off, .llamaCpp, "Qwen3-8B-Q4_K_M").contains(
                #""chat_template_kwargs":{"enable_thinking":false}"#))
        let unset = Config(llamacpp: .init(baseURL: "http://\(Self.llama):1"))
        #expect(!(try await body(unset, .llamaCpp, "Qwen3-8B-Q4_K_M").contains("chat_template_kwargs")))
        // LM Studio sets thinking per model in the app; a `think` in its section is not sent.
        let studio = Config(lmstudio: .init(baseURL: "http://\(Self.studio):1", think: true))
        #expect(!(try await body(studio, .lmStudio, "qwen/qwen3-8b").contains("chat_template_kwargs")))
    }

    @Test func callIDsAreNineLettersAndDigitsAsMistralsTemplatesRequire() {
        let id = OpenAICompatibleModel.Executor.callID(42)
        #expect(id == "call00042" && id.count == 9 && id.allSatisfy { $0.isLetter || $0.isNumber })
    }
}
