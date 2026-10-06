import Foundation
import FoundationModels
import Synchronization

/// Where Ollama is and how long to wait for it, from `config.json`'s `ollama` section.
public struct OllamaSettings: Equatable, Sendable {
    /// The server's base URL.
    public var baseURL: URL
    /// Wall-clock limit for one generation request, including streaming.
    public var timeout: Duration
    /// The context window to ask of the server for every model (`num_ctx`), when configured; nil sizes
    /// each model's window from its shape and the Mac's memory when it is selected (ADR 0043).
    public var contextLength: Int?
    /// Whether a model that can think is asked to (`ollama.think`, ADR 0053); nil sends nothing and leaves it to
    /// Ollama and the model.
    public var think: OllamaThink?

    /// The Ollama defaults: the local server on port 11434, two minutes per request, windows sized per model.
    public static let `default` = OllamaSettings(baseURL: defaultBaseURL, timeout: .seconds(120))

    /// Ollama's own listen address, `http://127.0.0.1:11434`.
    public static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 11434
        return components.url ?? URL(filePath: "/")
    }()

    /// Creates settings.
    public init(baseURL: URL, timeout: Duration, contextLength: Int? = nil, think: OllamaThink? = nil) {
        self.contextLength = contextLength
        self.think = think
        self.baseURL = baseURL
        self.timeout = timeout
    }
}

/// What `/api/chat`'s `think` asks of a model that can think (ADR 0053): `true` or `false`, or a level. The values
/// are the ones Ollama 0.35.1 accepts, read from its own refusal on 2026-10-04 (`invalid think value: %q (must be
/// "high", "medium", "low", "max", true, or false)`, in the installed binary); how a model that has no levels takes a
/// level is Ollama's to decide.
public enum OllamaThink: Equatable, Sendable, Codable {
    /// `true`: think before answering.
    case on
    /// `false`: answer without thinking.
    case off
    /// One of `levels`: think this hard.
    case level(String)

    /// The levels Ollama accepts.
    public static let levels = ["low", "medium", "high", "max"]
    /// Every value `ollama.think` takes, as `/config` offers them.
    public static let choices = ["true", "false"] + levels

    /// The setting `text` names: `true`, `false`, or a level; nil for anything else.
    ///
    /// - Parameter text: The value as written.
    public init?(_ text: String) {
        switch text.lowercased() {
        case "true": self = .on
        case "false": self = .off
        case let level where Self.levels.contains(level): self = .level(level)
        default: return nil
        }
    }

    /// Reads a JSON boolean, or a string `/config` writes (`"true"`, `"false"`, or a level).
    ///
    /// - Throws: `DecodingError.dataCorrupted` for any other value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = flag ? .on : .off
            return
        }
        let text = try container.decode(String.self)
        guard let value = Self(text) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "ollama: think must be true, false, or one of \(Self.levels.joined(separator: ", "))"
                ))
        }
        self = value
    }

    /// Writes a boolean, or the level.
    ///
    /// - Throws: Encoding errors.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .on: try container.encode(true)
        case .off: try container.encode(false)
        case .level(let level): try container.encode(level)
        }
    }

    /// What the request's `think` field carries.
    public var json: JSONValue {
        switch self {
        case .on: true
        case .off: false
        case .level(let level): .string(level)
        }
    }

    /// The value as `/config` shows it.
    public var text: String {
        switch self {
        case .on: "true"
        case .off: "false"
        case .level(let level): level
        }
    }
}

/// A model served by a local Ollama, plugged into `LanguageModelSession` through wisp's own executor
/// ([ADR 0016](../../../../docs/decisions/0016-local-runtimes-through-an-executor.md)).
///
/// The framework keeps the tool loop, streaming, transcript, and guided generation; the executor maps
/// the transcript onto Ollama's chat API and streams its chunks back as events.
public struct OllamaModel: LanguageModel, Sendable {
    /// Why Ollama could not serve.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No server answered at the base URL.
        case unreachable(URL, String)
        /// The server has no model by that name; the names it has are listed.
        case noSuchModel(String, installed: [String])
        /// The server answered with an error status.
        case serverError(status: Int, body: String)
        /// A streamed chunk could not be understood.
        case badResponse(String)
        /// The server accepted the request and stopped before the reply was done: the connection was lost, or
        /// the stream ended without the chunk that says `done`. What had arrived is not a reply.
        case interrupted(URL, String)
        /// The server sent nothing for the configured timeout (`ollama.timeoutSeconds`).
        case timedOut(URL, seconds: Int)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unreachable(let url, let detail): "no Ollama server at \(url): \(detail)"
            case .interrupted(let url, let detail):
                "Ollama at \(url) stopped before the reply was done (\(detail)); nothing of it was kept"
            case .timedOut(let url, let seconds):
                "Ollama at \(url) sent nothing for \(seconds) s (ollama.timeoutSeconds); the request was abandoned"
            case .noSuchModel(let name, let installed):
                "Ollama has no model '\(name)'; installed: \(installed.isEmpty ? "none" : installed.joined(separator: ", "))"
            case .serverError(let status, let body): "Ollama returned HTTP \(status): \(body)"
            case .badResponse(let detail): "unexpected Ollama response: \(detail)"
            }
        }
    }

    /// One installed model, as `/api/tags` lists it.
    public struct Installed: Equatable, Sendable, Decodable {
        /// The name, such as `qwen3-coder:latest`.
        public var name: String
        /// Bytes on disk.
        public var size: Int
        /// The parameter count as Ollama reports it, such as `30.5B`.
        public var parameterSize: String?
        /// The model's family as Ollama reports it, such as `granite`.
        public var family: String?
        /// The quantisation as Ollama reports it, such as `Q4_K_M`.
        public var quantization: String?

        private enum CodingKeys: String, CodingKey { case name, size, details }
        private enum Details: String, CodingKey { case parameter_size, family, quantization_level }

        /// Creates a record.
        public init(
            name: String, size: Int, parameterSize: String?, family: String? = nil, quantization: String? = nil
        ) {
            self.name = name
            self.size = size
            self.parameterSize = parameterSize
            self.family = family
            self.quantization = quantization
        }

        /// Decodes one entry of the tags list.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
            let details = try? container.nestedContainer(keyedBy: Details.self, forKey: .details)
            parameterSize = try? details?.decodeIfPresent(String.self, forKey: .parameter_size)
            family = try? details?.decodeIfPresent(String.self, forKey: .family)
            quantization = try? details?.decodeIfPresent(String.self, forKey: .quantization_level)
        }

        /// The family and quantisation, as the listing's format; nil when Ollama reports neither.
        public var format: String? {
            let parts = [family, quantization].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// The model name as Ollama knows it.
    public let name: String
    /// Where the server is.
    public let settings: OllamaSettings
    /// What the server said this model can do (`/api/show` `capabilities`), or nil before `check()`.
    public let reported: [String]?
    /// The context window asked of the server on every request (`num_ctx`), so wisp knows the limit
    /// it condenses against: configured, or sized when the model was checked.
    public let window: Int
    /// Why the window is what it is, for the `model.resolved` audit event.
    public let windowReason: String
    /// The last request's usage, written by the executor; a class so the value survives copies.
    private let usage = UsageRecord()

    /// Creates a model; `resolve` on the selection checks it exists, reads its capabilities, and sizes
    /// its window first. Without a sized `window`, the configured one, else `ContextSizing.floor`.
    public init(
        name: String, settings: OllamaSettings = .default, reported: [String]? = nil, window: Int? = nil,
        windowReason: String? = nil
    ) {
        self.name = name
        self.settings = settings
        self.reported = reported
        self.window = window ?? settings.contextLength ?? ContextSizing.floor
        self.windowReason =
            windowReason
            ?? (settings.contextLength != nil ? "configured as ollama.contextLength" : "the default, not sized")
    }

    /// The `think` value each request sends: the configured `ollama.think`, only for a model that reports `thinking`;
    /// nil otherwise, which leaves it to Ollama.
    var think: JSONValue? {
        guard reported?.contains("thinking") == true else { return nil }
        return settings.think?.json
    }

    /// Input tokens of the last request, from `prompt_eval_count`; nil before the first.
    public var lastInputTokens: Int? { usage.inputTokens.withLock { $0 } }

    /// Holds the last request's input token count behind a mutex.
    final class UsageRecord: Sendable {
        /// The count, or nil before any request.
        let inputTokens = Mutex<Int?>(nil)
    }

    /// What Ollama reported for this model: `tools` gives tool calling, `completion` gives JSON-schema
    /// output through the chat API's `format`. Nothing is declared before `check()`, and an embedding
    /// model declares nothing at all.
    public var capabilities: LanguageModelCapabilities {
        var capabilities: [LanguageModelCapabilities.Capability] = []
        let reported = reported ?? []
        if reported.contains("tools") { capabilities.append(.toolCalling) }
        if reported.contains("completion") { capabilities.append(.guidedGeneration) }
        if reported.contains("thinking") { capabilities.append(.reasoning) }
        if reported.contains("vision") { capabilities.append(.vision) }
        return .init(capabilities)
    }
    /// The executor's configuration: base URL and timeout, as one hashable string.
    public var executorConfiguration: Executor.Configuration {
        .init(baseURL: settings.baseURL, timeoutSeconds: Int(settings.timeout.components.seconds))
    }

    /// Lists the installed models.
    ///
    /// - Throws: `Failure.unreachable`, `Failure.serverError`, or `Failure.badResponse`.
    public static func installed(at settings: OllamaSettings) async throws -> [Installed] {
        struct Tags: Decodable { var models: [Installed] }
        var request = URLRequest(url: settings.baseURL.appending(path: "api/tags"))
        request.timeoutInterval = 5
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(settings.baseURL, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.serverError(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(Tags.self, from: data).models
        } catch {
            throw Failure.badResponse("\(error)")
        }
    }

    /// Whether `name` matches an installed model, allowing the `:latest` tag to be omitted.
    public static func matches(_ name: String, installed: [Installed]) -> Bool {
        installed.contains { $0.name == name || $0.name == "\(name):latest" }
    }

    /// Checks the server is up and has this model and reads what it can do, blocking briefly;
    /// `ModelSelection.resolve` is synchronous because agents are created synchronously.
    ///
    /// - Returns: The model with its reported capabilities.
    /// - Throws: `Failure`.
    public func checked(memory: MemoryState? = nil) throws -> OllamaModel {
        let installed = try Blocking.run { try await Self.installed(at: settings) }
        guard let entry = installed.first(where: { $0.name == name || $0.name == "\(name):latest" }) else {
            throw Failure.noSuchModel(name, installed: installed.map(\.name))
        }
        let shown = try Blocking.run { try await Self.show(name, at: settings) }
        guard settings.contextLength == nil else {
            return OllamaModel(name: name, settings: settings, reported: shown.capabilities)
        }
        guard
            let shape = ContextSizing.shape(
                from: shown.info, drafted: shown.drafted, draftTokens: shown.draftTokens)
        else {
            return OllamaModel(
                name: name, settings: settings, reported: shown.capabilities, window: ContextSizing.floor,
                windowReason:
                    "\(ContextSizing.floor.formatted()), the default: Ollama reported no model shape to size from")
        }
        let held = (try? Blocking.run { try await Self.held(entry.name, at: settings) }) ?? 0
        let decision = ContextSizing.size(
            shape: shape, weights: entry.size, memory: memory ?? .current(), held: held)
        return OllamaModel(
            name: name, settings: settings, reported: shown.capabilities, window: decision.window,
            windowReason: decision.reason)
    }

    /// What `/api/show` says about a model: its capabilities, and its `model_info`, which holds its shape.
    public struct Shown: Equatable, Sendable, Decodable {
        /// `completion`, `tools`, `thinking`, `vision`, `embedding`; empty when the server reports none.
        public var capabilities: [String]
        /// Architecture-prefixed facts such as `granite.context_length`.
        public var info: [String: JSONValue]
        /// Whether Ollama runs a draft model beside this one for speculative decoding: a `DRAFT` line in its
        /// `modelfile` (gemma4 has one), whose cache sizing counts too.
        public var drafted: Bool
        /// Tokens Ollama drafts ahead per step (`PARAMETER draft_num_predict` in its `modelfile`; 4 for
        /// qwen3.8:27b, 3 for gemma4), or 0 when it sets none.
        public var draftTokens: Int

        private enum CodingKeys: String, CodingKey { case capabilities, model_info, modelfile }

        /// Decodes the response, tolerating a server that leaves either part out.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
            info = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .model_info)) ?? [:]
            let modelfile = (try? container.decodeIfPresent(String.self, forKey: .modelfile)) ?? nil
            let lines = (modelfile ?? "").split(whereSeparator: \.isNewline)
            drafted = lines.contains { $0.hasPrefix("DRAFT ") }
            let draft = lines.map { $0.split(separator: " ") }.first { (words: [Substring]) in
                words.count == 3 && words[0] == "PARAMETER" && words[1] == "draft_num_predict"
            }
            draftTokens = draft.flatMap { Int($0[2]) } ?? 0
        }
    }

    /// Bytes Ollama holds in memory for `name` now (`/api/ps`), or 0 when it is not loaded.
    ///
    /// - Throws: `Failure.unreachable` or `Failure.serverError`.
    public static func held(_ name: String, at settings: OllamaSettings) async throws -> Int {
        struct Loaded: Decodable {
            struct Model: Decodable {
                var name: String
                var size: Int?
            }
            var models: [Model]?
        }
        var request = URLRequest(url: settings.baseURL.appending(path: "api/ps"))
        request.timeoutInterval = 5
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(settings.baseURL, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.serverError(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        let loaded = (try? JSONDecoder().decode(Loaded.self, from: data))?.models ?? []
        return loaded.first { $0.name == name }?.size ?? 0
    }

    /// Asks `/api/show` what a model can do and what shape it is.
    ///
    /// - Throws: `Failure.unreachable`, `Failure.serverError`, or `Failure.badResponse`.
    public static func show(_ name: String, at settings: OllamaSettings) async throws -> Shown {
        var request = URLRequest(url: settings.baseURL.appending(path: "api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": name])
        request.timeoutInterval = 5
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(settings.baseURL, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.serverError(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(Shown.self, from: data)
        } catch {
            throw Failure.badResponse("\(error)")
        }
    }

    /// Talks to Ollama's `/api/chat` for one generation request and streams the reply back.
    public struct Executor: LanguageModelExecutor {
        /// What the executor needs: the server and a per-request limit.
        public struct Configuration: Hashable, Sendable {
            /// The server's base URL.
            public var baseURL: URL
            /// Seconds allowed for one request, including streaming.
            public var timeoutSeconds: Int

            /// Creates a configuration.
            public init(baseURL: URL, timeoutSeconds: Int) {
                self.baseURL = baseURL
                self.timeoutSeconds = timeoutSeconds
            }
        }
        /// The model type this executor serves.
        public typealias Model = OllamaModel

        private let configuration: Configuration

        /// Creates an executor; the framework calls this with the model's `executorConfiguration`.
        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// One chat message in Ollama's shape.
        struct Message: Codable, Equatable {
            var role: String
            var content: String
            var tool_calls: [ToolCall]?
            var tool_name: String?
            /// A reasoning model's thinking, streamed before its reply (ADR 0053); never sent back.
            var thinking: String?

            /// A tool call the assistant made.
            struct ToolCall: Codable, Equatable {
                var function: Function
                /// The function name and its arguments as an object.
                struct Function: Codable, Equatable {
                    var name: String
                    var arguments: JSONValue
                }
            }
        }

        /// The chat request body.
        struct ChatRequest: Encodable {
            var model: String
            var messages: [Message]
            var tools: [ToolSpec]?
            var stream: Bool
            var format: JSONValue?
            /// Whether a model that can think is asked to (`OllamaThink`); absent unless configured and the model
            /// reports `thinking`.
            var think: JSONValue?
            /// Server options; `num_ctx` is the context window.
            var options: Options

            /// The options wisp sets.
            struct Options: Encodable {
                var num_ctx: Int
            }

            /// A tool definition in Ollama's (OpenAI-style) shape.
            struct ToolSpec: Encodable {
                var type = "function"
                var function: Function
                /// Name, description, and JSON Schema.
                struct Function: Encodable {
                    var name: String
                    var description: String
                    var parameters: JSONValue
                }
            }
        }

        /// One streamed line of the reply.
        struct Chunk: Decodable {
            var message: Message?
            var done: Bool?
            var error: String?
            var prompt_eval_count: Int?
            var eval_count: Int?
        }

        /// Maps the framework transcript onto Ollama's chat messages, through the mapping every local
        /// executor shares (`ChatMessage.messages(from:)`).
        static func messages(from transcript: Transcript) -> [Message] {
            ChatMessage.messages(from: transcript).map { message in
                let calls = message.toolCalls.map {
                    Message.ToolCall(function: .init(name: $0.name, arguments: $0.arguments))
                }
                return Message(
                    role: message.role, content: message.content, tool_calls: calls.isEmpty ? nil : calls,
                    tool_name: message.toolName)
            }
        }

        /// Re-encodes an `Encodable` (a `GenerationSchema`) as a `JSONValue`.
        private static func json(_ value: some Encodable) -> JSONValue { ChatMessage.json(value) }

        /// A tool call's arguments with each required property the model left out filled with its type's
        /// empty value (`ChatMessage.completed(_:schema:)`).
        ///
        /// - Parameters:
        ///   - arguments: The arguments as the model wrote them.
        ///   - schema: The tool's parameters, as the JSON Schema sent to Ollama.
        /// - Returns: The arguments, completed where that is safe.
        static func completed(_ arguments: JSONValue, schema: JSONValue) -> JSONValue {
            ChatMessage.completed(arguments, schema: schema)
        }

        /// The request body for one generation.
        ///
        /// - Parameters:
        ///   - request: The framework's request.
        ///   - model: The model's name.
        ///   - contextLength: The window to ask for.
        ///   - think: The `think` value to send, or nil to send none.
        /// - Returns: The body.
        static func body(
            for request: LanguageModelExecutorGenerationRequest, model: String, contextLength: Int,
            think: JSONValue? = nil
        ) -> ChatRequest {
            let tools = request.enabledToolDefinitions.map { definition in
                ChatRequest.ToolSpec(
                    function: .init(
                        name: definition.name, description: definition.description,
                        parameters: json(definition.parameters))
                )
            }
            return ChatRequest(
                model: model, messages: messages(from: request.transcript), tools: tools.isEmpty ? nil : tools,
                stream: true, format: request.schema.map { json($0) }, think: think,
                options: .init(num_ctx: contextLength))
        }

        /// Sends the request and streams chunks back as events.
        ///
        /// - Throws: `OllamaModel.Failure`.
        nonisolated(nonsending) public func respond(
            to request: LanguageModelExecutorGenerationRequest, model: OllamaModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            var http = URLRequest(url: configuration.baseURL.appending(path: "api/chat"))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.timeoutInterval = TimeInterval(configuration.timeoutSeconds)
            http.httpBody = try JSONEncoder().encode(
                Self.body(for: request, model: model.name, contextLength: model.window, think: model.think))
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: http)
            } catch {
                throw Self.failure(error, configuration: configuration, streaming: false)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body = ""
                for try await line in bytes.lines where body.count < 200 { body += line }
                throw Failure.serverError(status: status, body: body)
            }
            var calls = 0
            var input = 0
            var output = 0
            var thinking = ThinkingStretch()
            var held = HeldReply(request: request)
            var done = false
            do {
                for try await line in bytes.lines {
                    done = try await relay(
                        line, request: request, status: status, calls: &calls, input: &input, output: &output,
                        thinking: &thinking, held: &held, channel: channel)
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Self.failure(error, configuration: configuration, streaming: true)
            }
            // A stream that ends without `done` was cut short, however cleanly the connection closed: what came is
            // not the whole reply, so it must not be taken for one.
            guard done else {
                throw Failure.interrupted(configuration.baseURL, "the stream ended before Ollama said it was done")
            }
            thinking.end()
            if !held.text.isEmpty {
                // The whole reply was held: calls in Mistral's format when it is exactly that, else the reply.
                if let recovered = TextToolCalls.mistral(held.text, offered: held.offered) {
                    for call in recovered {
                        await send(call.name, call.arguments, request: request, calls: &calls, channel: channel)
                    }
                } else {
                    await channel.send(.response(action: .appendText(held.text, tokenCount: 1)))
                }
                for call in held.calls {
                    await send(
                        call.function.name, call.function.arguments, request: request, calls: &calls, channel: channel)
                }
            }
            model.usage.inputTokens.withLock { $0 = input }
            // Ollama reports no count of its own for the thinking; it streams one token a chunk, so the chunks are
            // the count, within the output's total.
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: input, cachedTokenCount: 0),
                        output: .init(
                            totalTokenCount: max(output, thinking.tokens), reasoningTokenCount: thinking.tokens)
                    )))
        }

        /// The failure for an error from the connection: the timeout when the server went silent, an interruption
        /// once the stream had begun or when the connection was lost, and otherwise no server.
        ///
        /// - Parameters:
        ///   - error: What `URLSession` threw.
        ///   - configuration: The server and its timeout.
        ///   - streaming: Whether the response had begun.
        /// - Returns: The failure to throw.
        static func failure(_ error: any Error, configuration: Configuration, streaming: Bool) -> Failure {
            let code = (error as? URLError)?.code
            if code == .timedOut { return .timedOut(configuration.baseURL, seconds: configuration.timeoutSeconds) }
            if streaming || code == .networkConnectionLost {
                return .interrupted(configuration.baseURL, error.localizedDescription)
            }
            return .unreachable(configuration.baseURL, error.localizedDescription)
        }

        /// Sends one streamed line's content to the channel: thinking, reply text, and tool calls, and the counts.
        ///
        /// - Parameters:
        ///   - line: The NDJSON line.
        ///   - request: The request, for its tools' schemas and id.
        ///   - status: The HTTP status, for an error chunk.
        ///   - calls: Tool calls so far, for their ids.
        ///   - input: The prompt tokens Ollama reported.
        ///   - output: The tokens it generated.
        ///   - thinking: The stretch of thinking under way.
        ///   - held: The reply's text held back while it may be calls written as text.
        ///   - channel: Where events go.
        /// - Returns: Whether the chunk said the reply is done.
        /// - Throws: `Failure.badResponse` or `Failure.serverError`.
        nonisolated(nonsending) private func relay(
            _ line: String, request: LanguageModelExecutorGenerationRequest, status: Int, calls: inout Int,
            input: inout Int, output: inout Int, thinking: inout ThinkingStretch, held: inout HeldReply,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws -> Bool {
            let chunk: Chunk
            do {
                chunk = try JSONDecoder().decode(Chunk.self, from: Data(line.utf8))
            } catch {
                throw Failure.badResponse(String(line.prefix(200)))
            }
            if let error = chunk.error { throw Failure.serverError(status: status, body: error) }
            if let message = chunk.message {
                // Ollama streams a reasoning model's thinking before its reply, one token a chunk, whether or
                // not `think` was sent (probed 2026-10-04, ornith:9b: 42 thinking chunks, then 2 of reply).
                if let thought = message.thinking, !thought.isEmpty {
                    thinking.think(thought)
                    await channel.send(.reasoning(action: .appendText(thought, tokenCount: 1)))
                }
                if !message.content.isEmpty || !(message.tool_calls ?? []).isEmpty { thinking.end() }
                if !message.content.isEmpty {
                    if held.active {
                        // Held while it may be calls written as text (`TextToolCalls.mistral`); sent as the reply,
                        // with any calls Ollama parsed meanwhile, once it plainly is not.
                        held.text += message.content
                        if !TextToolCalls.mayBeMistral(held.text, offered: held.offered) {
                            held.active = false
                            await channel.send(.response(action: .appendText(held.text, tokenCount: 1)))
                            held.text = ""
                            for call in held.calls {
                                await send(
                                    call.function.name, call.function.arguments, request: request, calls: &calls,
                                    channel: channel)
                            }
                            held.calls = []
                        }
                    } else {
                        await channel.send(.response(action: .appendText(message.content, tokenCount: 1)))
                    }
                }
                for call in message.tool_calls ?? [] {
                    // Behind held text, a parsed call waits, so the calls keep the order the model wrote them in.
                    if held.active && !held.text.isEmpty {
                        held.calls.append(call)
                    } else {
                        await send(
                            call.function.name, call.function.arguments, request: request, calls: &calls,
                            channel: channel)
                    }
                }
            }
            input = chunk.prompt_eval_count ?? input
            output = chunk.eval_count ?? output
            return chunk.done == true
        }

        /// Sends one tool call to the channel, its arguments completed against the tool's schema, with the next id.
        ///
        /// - Parameters:
        ///   - name: The tool's name.
        ///   - arguments: The arguments as the model wrote them.
        ///   - request: The request, for its tools' schemas and id.
        ///   - calls: Tool calls so far, for the id.
        ///   - channel: Where the call goes.
        nonisolated(nonsending) private func send(
            _ name: String, _ arguments: JSONValue, request: LanguageModelExecutorGenerationRequest, calls: inout Int,
            channel: LanguageModelExecutorGenerationChannel
        ) async {
            calls += 1
            let schema = request.enabledToolDefinitions.first { $0.name == name }.map { Self.json($0.parameters) }
            let completed = schema.map { Self.completed(arguments, schema: $0) } ?? arguments
            let encoded = (try? JSONEncoder().encode(completed)) ?? Data("{}".utf8)
            await channel.send(
                .toolCalls(
                    action: .toolCall(
                        id: "\(request.id.uuidString.lowercased())-\(calls)", name: name,
                        action: .appendArguments(String(decoding: encoded, as: UTF8.self), tokenCount: 1))))
        }

        /// A reply's text held back while it may be tool calls written as text in Mistral's format, which a Mistral
        /// model's Ollama template can leave in `content` (`TextToolCalls.mistral`), with the calls Ollama parsed
        /// while it was held. Only a request that offers tools and wants no schema reply holds anything.
        struct HeldReply {
            /// The names of the tools the request offers.
            let offered: Set<String>
            /// Whether text is still being held.
            var active: Bool
            /// The text held.
            var text = ""
            /// Ollama's own parsed calls that came while text was held.
            var calls: [Message.ToolCall] = []

            /// The state for a request.
            ///
            /// - Parameter request: The request.
            init(request: LanguageModelExecutorGenerationRequest) {
                offered = Set(request.enabledToolDefinitions.map(\.name))
                active = !offered.isEmpty && request.schema == nil
            }
        }
    }
}

extension OllamaModel: UsageReporting {}

/// The built-in backend: Ollama on this Mac.
public struct OllamaBackend: ModelBackend {
    /// `ollama:`.
    public let scheme = "ollama"

    /// Creates the backend.
    public init() {}

    /// Checks the server lists the model, reads its capabilities, and wraps it.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` with the Ollama failure as the reason.
    public func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        do {
            let model = try OllamaModel(name: name, settings: config.ollama).checked()
            // An embedding model (no `completion`) cannot hold a conversation; refuse it here, not at
            // the first prompt, so listings leave it out and `/model` explains.
            guard model.reported?.contains("completion") == true else {
                let reported = (model.reported ?? []).joined(separator: ", ")
                throw ModelSelection.Failure.unavailable(
                    model: "ollama:\(name)",
                    reason:
                        "Ollama reports it cannot hold a conversation (capabilities: \(reported.isEmpty ? "none" : reported))"
                )
            }
            return ResolvedModel(
                selection: .ollama(name), custom: model, capabilitySource: .runtime,
                asset: "\(config.ollama.baseURL.absoluteString) \(name)", contextSize: model.window,
                contextNote: model.windowReason)
        } catch let failure as OllamaModel.Failure {
            throw ModelSelection.Failure.unavailable(model: "ollama:\(name)", reason: failure.description)
        }
    }

    /// The server's tag list.
    public func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        try await OllamaModel.installed(at: config.ollama).map { model in
            let size = ByteCountFormatter.string(fromByteCount: Int64(model.size), countStyle: .file)
            return InstalledModel(
                selection: .ollama(model.name), detail: "\(model.parameterSize ?? "?") \(size)",
                parameters: model.parameterSize, bytes: model.size > 0 ? model.size : nil, format: model.format)
        }
    }

    /// Base URL, timeout, the window, and `think` when set.
    public func settings(in config: Config.Resolved, home: Home) -> JSONValue {
        var settings: [String: JSONValue] = [
            "baseURL": .string(config.ollama.baseURL.absoluteString),
            "timeoutSeconds": .int(Int(config.ollama.timeout.components.seconds)),
            "contextLength": config.ollama.contextLength.map { .int($0) } ?? .string("sized per model (ADR 0043)"),
        ]
        // Unset leaves it to the model (ADR 0053).
        settings["think"] = .string(config.ollama.think?.text ?? "unset")
        return .object(settings)
    }
}
