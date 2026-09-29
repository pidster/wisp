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
    public init(baseURL: URL, timeout: Duration, contextLength: Int? = nil) {
        self.contextLength = contextLength
        self.baseURL = baseURL
        self.timeout = timeout
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

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unreachable(let url, let detail): "no Ollama server at \(url): \(detail)"
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

        private enum CodingKeys: String, CodingKey { case name, size, details }
        private enum Details: String, CodingKey { case parameter_size }

        /// Creates a record.
        public init(name: String, size: Int, parameterSize: String?) {
            self.name = name
            self.size = size
            self.parameterSize = parameterSize
        }

        /// Decodes one entry of the tags list.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
            let details = try? container.nestedContainer(keyedBy: Details.self, forKey: .details)
            parameterSize = try details?.decodeIfPresent(String.self, forKey: .parameter_size)
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
        guard let shape = ContextSizing.shape(from: shown.info) else {
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

        private enum CodingKeys: String, CodingKey { case capabilities, model_info }

        /// Decodes the response, tolerating a server that leaves either part out.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
            info = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .model_info)) ?? [:]
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

        /// Maps the framework transcript onto chat messages: instructions become the system message,
        /// prompts and responses alternate, tool calls ride on an assistant message, and tool outputs
        /// are `tool` messages naming the tool.
        static func messages(from transcript: Transcript) -> [Message] {
            func text(_ segments: [Transcript.Segment]) -> String {
                segments.compactMap {
                    switch $0 {
                    case .text(let segment): segment.content
                    case .structure(let segment): segment.content.jsonString
                    default: nil
                    }
                }.joined()
            }
            var messages: [Message] = []
            for entry in transcript {
                switch entry {
                case .instructions(let instructions):
                    messages.append(Message(role: "system", content: text(instructions.segments)))
                case .prompt(let prompt):
                    messages.append(Message(role: "user", content: text(prompt.segments)))
                case .response(let response):
                    messages.append(Message(role: "assistant", content: text(response.segments)))
                case .toolCalls(let calls):
                    let mapped = calls.map { call in
                        Message.ToolCall(
                            function: .init(name: call.toolName, arguments: Self.json(call.arguments.jsonString)))
                    }
                    messages.append(Message(role: "assistant", content: "", tool_calls: mapped))
                case .toolOutput(let output):
                    messages.append(Message(role: "tool", content: text(output.segments), tool_name: output.toolName))
                default:
                    break
                }
            }
            return messages
        }

        /// Parses JSON text into a value, or an empty object.
        private static func json(_ text: String) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .object([:])
        }

        /// Re-encodes an `Encodable` (a `GenerationSchema`) as a `JSONValue`.
        private static func json(_ value: some Encodable) -> JSONValue {
            guard let data = try? JSONEncoder().encode(value) else { return .object([:]) }
            return json(String(decoding: data, as: UTF8.self))
        }

        /// A tool call's arguments with each required property the model left out filled with its type's
        /// empty value: `""` for a string, `[]` for an array, `false` for a boolean. An Ollama model is
        /// not held to the tool's schema when it writes arguments, and the framework refuses a call
        /// missing a required property by ending the whole turn; `system_info`'s `process`, required so the
        /// on-device model always names one, is "otherwise empty" by its own description. A missing
        /// number or choice has no neutral value and is left out.
        ///
        /// - Parameters:
        ///   - arguments: The arguments as the model wrote them.
        ///   - schema: The tool's parameters, as the JSON Schema sent to Ollama.
        /// - Returns: The arguments, completed where that is safe.
        static func completed(_ arguments: JSONValue, schema: JSONValue) -> JSONValue {
            guard var fields = arguments.objectValue, let object = schema.objectValue,
                let properties = object["properties"]?.objectValue, let required = object["required"]?.arrayValue
            else { return arguments }
            for name in required.compactMap(\.stringValue) where fields[name] == nil {
                let property = properties[name]?.objectValue ?? [:]
                guard property["enum"] == nil else { continue }
                switch property["type"]?.stringValue {
                case "string": fields[name] = ""
                case "array": fields[name] = .array([])
                case "boolean": fields[name] = false
                default: continue
                }
            }
            return .object(fields)
        }

        /// The request body for one generation.
        static func body(
            for request: LanguageModelExecutorGenerationRequest, model: String, contextLength: Int
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
                stream: true, format: request.schema.map { json($0) }, options: .init(num_ctx: contextLength))
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
                Self.body(for: request, model: model.name, contextLength: model.window))
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: http)
            } catch {
                throw Failure.unreachable(configuration.baseURL, error.localizedDescription)
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
            for try await line in bytes.lines {
                let chunk: Chunk
                do {
                    chunk = try JSONDecoder().decode(Chunk.self, from: Data(line.utf8))
                } catch {
                    throw Failure.badResponse(String(line.prefix(200)))
                }
                if let error = chunk.error { throw Failure.serverError(status: status, body: error) }
                if let message = chunk.message {
                    if !message.content.isEmpty {
                        await channel.send(.response(action: .appendText(message.content, tokenCount: 1)))
                    }
                    for call in message.tool_calls ?? [] {
                        calls += 1
                        let schema = request.enabledToolDefinitions.first { $0.name == call.function.name }
                            .map { Self.json($0.parameters) }
                        let arguments =
                            schema.map { Self.completed(call.function.arguments, schema: $0) }
                            ?? call.function.arguments
                        let encoded = (try? JSONEncoder().encode(arguments)) ?? Data("{}".utf8)
                        await channel.send(
                            .toolCalls(
                                action: .toolCall(
                                    id: "\(request.id.uuidString.lowercased())-\(calls)", name: call.function.name,
                                    action: .appendArguments(String(decoding: encoded, as: UTF8.self), tokenCount: 1))))
                    }
                }
                input = chunk.prompt_eval_count ?? input
                output = chunk.eval_count ?? output
            }
            model.usage.inputTokens.withLock { $0 = input }
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: input, cachedTokenCount: 0),
                        output: .init(totalTokenCount: output, reasoningTokenCount: 0))))
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
            return InstalledModel(selection: .ollama(model.name), detail: "\(model.parameterSize ?? "?") \(size)")
        }
    }

    /// Base URL and timeout.
    public func settings(in config: Config.Resolved, home: Home) -> JSONValue {
        .object([
            "baseURL": .string(config.ollama.baseURL.absoluteString),
            "timeoutSeconds": .int(Int(config.ollama.timeout.components.seconds)),
            "contextLength": config.ollama.contextLength.map { .int($0) } ?? .string("sized per model (ADR 0043)"),
        ])
    }
}
