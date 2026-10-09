import Foundation
import FoundationModels
import Synchronization

/// A model served by a local runtime that speaks OpenAI's chat-completions API, llama.cpp's `llama-server` or LM
/// Studio, plugged into `LanguageModelSession` through wisp's shared HTTP executor
/// ([ADR 0058](../../../../docs/decisions/0058-a-shared-http-executor.md)).
///
/// The framework keeps the tool loop, streaming, transcript, and guided generation, as for Ollama (ADR 0016); the
/// executor maps the transcript onto `/v1/chat/completions` through the mapping every local executor shares
/// (`ChatMessage`), reads the server-sent events back, and relays them through `ReplyRelay`, which Ollama's executor
/// uses too. What differs between the two runtimes is the `dialect`.
public struct OpenAICompatibleModel: LanguageModel, Sendable {
    /// Why the server could not serve.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No server answered at the base URL.
        case unreachable(OpenAICompatibleDialect, URL, String)
        /// The server serves no model by that name; the names it serves are listed.
        case noSuchModel(OpenAICompatibleDialect, String, served: [String])
        /// The server wants an API key, or another one (HTTP 401 or 403).
        case refused(OpenAICompatibleDialect, URL, status: Int, keySet: Bool)
        /// The server answered with an error status.
        case serverError(OpenAICompatibleDialect, status: Int, body: String)
        /// A response could not be understood.
        case badResponse(OpenAICompatibleDialect, String)
        /// The server accepted the request and stopped before the reply was done: the connection was lost, or the
        /// stream ended before a choice finished. What had arrived is not a reply.
        case interrupted(OpenAICompatibleDialect, URL, String)
        /// The server sent nothing for the configured timeout.
        case timedOut(OpenAICompatibleDialect, URL, seconds: Int)
        /// The server reports the model cannot hold a conversation: an embedding model.
        case notConversational(OpenAICompatibleDialect, String)

        /// Human-readable explanation; it never carries the API key.
        public var description: String {
            switch self {
            case .unreachable(let dialect, let url, let detail):
                "no \(dialect.runtime) server at \(url): \(detail); \(dialect.startHint)"
            case .noSuchModel(let dialect, let name, let served):
                "\(dialect.runtime) serves no model '\(name)'; it serves: "
                    + (served.isEmpty ? "none" : served.joined(separator: ", "))
            case .refused(let dialect, let url, let status, let keySet):
                "\(dialect.runtime) at \(url) refused the request (HTTP \(status)): "
                    + (keySet
                        ? "the API key wisp sent is not one it accepts; "
                        : "it wants an API key; ")
                    + "set \(dialect.apiKeyVariable), or \(dialect.scheme).apiKey in config.json"
            case .serverError(let dialect, let status, let body): "\(dialect.runtime) returned HTTP \(status): \(body)"
            case .badResponse(let dialect, let detail): "unexpected \(dialect.runtime) response: \(detail)"
            case .interrupted(let dialect, let url, let detail):
                "\(dialect.runtime) at \(url) stopped before the reply was done (\(detail)); nothing of it was kept"
            case .timedOut(let dialect, let url, let seconds):
                "\(dialect.runtime) at \(url) sent nothing for \(seconds) s (\(dialect.scheme).timeoutSeconds); the "
                    + "request was abandoned"
            case .notConversational(let dialect, let name):
                "\(dialect.runtime) reports '\(name)' is an embedding model, which cannot hold a conversation"
            }
        }
    }

    /// One model the server lists, with what it says about it.
    public struct Served: Equatable, Sendable {
        /// What the server calls it, sent as each request's `model`.
        public var id: String
        /// The name a selection uses: the id, or, for a llama.cpp model listed by its file's path, the file's name
        /// without `.gguf`.
        public var name: String
        /// The parameter count, such as `8.0B`, when reported.
        public var parameters: String?
        /// Bytes of the weights, when reported.
        public var bytes: Int?
        /// The architecture and quantisation, such as `qwen3 Q4_K_M`, when reported.
        public var format: String?
        /// Whether it can hold a conversation: false for an embedding model.
        public var conversational = true
        /// Whether the server reports it calls tools, or nil when it reports nothing either way.
        public var toolCalling: Bool?
        /// Whether the server reports it thinks.
        public var reasoning = false
        /// The window the server holds it loaded at, when loaded and reported (LM Studio).
        public var loadedContext: Int?
        /// The most the model takes, when reported.
        public var maximumContext: Int?
        /// Whether a llama.cpp router serves it among others, so `/props` names it.
        public var routed = false

        /// Creates a record.
        public init(id: String, name: String? = nil) {
            self.id = id
            self.name = name ?? Self.shortName(id)
        }

        /// The name for an id: a `.gguf` file's name without the extension when the id is a path, else the id.
        ///
        /// - Parameter id: The server's id.
        /// - Returns: The name.
        static func shortName(_ id: String) -> String {
            guard id.lowercased().hasSuffix(".gguf"), id.contains("/") else { return id }
            let file = id.split(separator: "/").last.map(String.init) ?? id
            return String(file.dropLast(".gguf".count))
        }

        /// Whether `name` names this model: its name, or the id itself.
        public func matches(_ name: String) -> Bool { name == self.name || name == id }
    }

    /// The runtime.
    public let dialect: OpenAICompatibleDialect
    /// The model as the selection names it.
    public let name: String
    /// What the server calls it, sent as `model`.
    public let serverID: String
    /// Where the server is and how to authenticate.
    public let settings: OpenAICompatibleSettings
    /// What the server reported the model can do, as `CapabilityName`s; empty before `checked()`.
    public let reported: [CapabilityName]
    /// What `config.json` declares it can do (`llamacpp.models.<name>`), or nil when nothing is declared.
    public let declared: [String]?
    /// The context window wisp condenses against: what the server reported it holds, or the floor.
    public let window: Int
    /// Why the window is what it is, for the `model.resolved` audit event.
    public let windowReason: String
    /// The last request's input tokens, written by the executor; a class so the value survives copies.
    let usage = LastInputTokens()

    /// Creates a model; `checked()` asks the server about it first.
    public init(
        dialect: OpenAICompatibleDialect, name: String, settings: OpenAICompatibleSettings, serverID: String? = nil,
        reported: [CapabilityName] = [], window: Int? = nil, windowReason: String? = nil
    ) {
        self.dialect = dialect
        self.name = name
        self.serverID = serverID ?? name
        self.settings = settings
        self.reported = reported
        declared = settings.declared[name]?.capabilities
        self.window = window ?? ContextSizing.floor
        self.windowReason = windowReason ?? "the default, not checked"
    }

    /// Input tokens of the last request, as the server reported them; nil before the first.
    public var lastInputTokens: Int? { usage.value.withLock { $0 } }

    /// What the model can do: schema replies always, since both servers hold the reply to the schema with a grammar
    /// whatever the model, and tool calling and thinking when the server reported them or `config.json` declares
    /// them. The executor maps text only, so `vision` is never declared.
    public var capabilities: LanguageModelCapabilities {
        let names = Set(reported.map(\.rawValue) + (declared ?? []) + [CapabilityName.guidedGeneration.rawValue])
        return .init(
            CapabilityName.allCases.filter { $0 != .vision && names.contains($0.rawValue) }.map(\.capability))
    }

    /// Who declared the capabilities: the configuration when it declares them, else the runtime when it reported
    /// tool calling or thinking, else nobody beyond the server's schema replies.
    public var capabilitySource: CapabilitySource {
        if declared != nil { return .configuration }
        return reported.isEmpty && dialect.declaresCapabilities ? .undeclared : .runtime
    }

    /// The executor's configuration.
    public var executorConfiguration: Executor.Configuration {
        .init(
            dialect: dialect, baseURL: settings.baseURL, timeoutSeconds: Int(settings.timeout.components.seconds),
            apiKey: settings.apiKey)
    }

    /// The `chat_template_kwargs.enable_thinking` value each request sends: the configured `think`, for a dialect that
    /// takes it; nil otherwise.
    var think: Bool? { dialect.takesThink ? settings.think : nil }

    // MARK: - Asking the server

    /// A request to the server at `path`, with the key when one is set.
    ///
    /// - Parameters:
    ///   - path: The path under the base URL.
    ///   - query: Query items.
    ///   - settings: The server.
    ///   - timeout: Seconds to wait.
    /// - Returns: The request.
    static func request(
        _ path: String, query: [URLQueryItem] = [], settings: OpenAICompatibleSettings, timeout: TimeInterval = 5
    ) -> URLRequest {
        var url = settings.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let key = settings.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// GETs `path` and returns the body of a 200.
    ///
    /// - Parameters:
    ///   - path: The path under the base URL.
    ///   - query: Query items.
    ///   - dialect: The runtime, for the failures.
    ///   - settings: The server.
    /// - Returns: The body, or nil for a 404, which a caller may take as a server too old for the path.
    /// - Throws: `Failure.unreachable`, `Failure.refused`, or `Failure.serverError`.
    static func get(
        _ path: String, query: [URLQueryItem] = [], dialect: OpenAICompatibleDialect,
        settings: OpenAICompatibleSettings
    ) async throws -> Data? {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(
                for: request(path, query: query, settings: settings))
        } catch {
            throw Failure.unreachable(dialect, settings.baseURL, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 404: return nil
        case 401, 403:
            throw Failure.refused(dialect, settings.baseURL, status: status, keySet: settings.apiKey != nil)
        default:
            throw Failure.serverError(
                dialect, status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// The models the server lists, with what it says about each.
    ///
    /// - Parameters:
    ///   - dialect: The runtime.
    ///   - settings: The server.
    /// - Returns: The models.
    /// - Throws: `Failure`.
    public static func served(
        by dialect: OpenAICompatibleDialect, at settings: OpenAICompatibleSettings
    ) async throws -> [Served] {
        switch dialect.catalog {
        case .llamaServer:
            guard let data = try await get("v1/models", dialect: dialect, settings: settings) else {
                throw Failure.serverError(dialect, status: 404, body: "no /v1/models")
            }
            return try decode(data, dialect: dialect) { try Catalogs.llamaServer($0) }
        case .lmStudio:
            if let data = try await get("api/v1/models", dialect: dialect, settings: settings) {
                return try decode(data, dialect: dialect) { try Catalogs.lmStudio($0) }
            }
            // A server before 0.4.0 has no `/api/v1`: its OpenAI listing names the models and says nothing more.
            guard let data = try await get("v1/models", dialect: dialect, settings: settings) else {
                throw Failure.serverError(dialect, status: 404, body: "no /api/v1/models or /v1/models")
            }
            return try decode(data, dialect: dialect) { try Catalogs.openAI($0) }
        }
    }

    /// Decodes a listing, a decoding error becoming `Failure.badResponse`.
    ///
    /// - Parameters:
    ///   - data: The body.
    ///   - dialect: The runtime.
    ///   - read: The catalog's reading.
    /// - Returns: The models.
    /// - Throws: `Failure.badResponse`.
    private static func decode(
        _ data: Data, dialect: OpenAICompatibleDialect, _ read: (JSONValue) throws -> [Served]
    ) throws -> [Served] {
        do {
            return try read(try JSONDecoder().decode(JSONValue.self, from: data))
        } catch {
            throw Failure.badResponse(dialect, String(String(decoding: data.prefix(200), as: UTF8.self)))
        }
    }

    /// What llama.cpp's `/props` says: the slot's window and whether the chat template takes tool calls.
    public struct Props: Equatable, Sendable {
        /// The window of a slot, which one request gets (`default_generation_settings.n_ctx`).
        public var window: Int?
        /// Whether the chat template supports tool calls (`chat_template_caps`), or nil when not reported.
        public var toolCalls: Bool?

        /// Reads the response.
        ///
        /// - Parameter json: The body.
        init(_ json: JSONValue) {
            let object = json.objectValue ?? [:]
            window =
                object["default_generation_settings"]?.objectValue?["n_ctx"]?.intValue ?? object["n_ctx"]?.intValue
            let caps = object["chat_template_caps"]?.objectValue
            toolCalls = caps?["supports_tool_calls"]?.boolValue ?? caps?["supports_tools"]?.boolValue
        }
    }

    /// Asks llama.cpp's `/props` about the model, naming it when a router serves it among others.
    ///
    /// - Throws: `Failure`.
    static func props(of served: Served, at settings: OpenAICompatibleSettings) async throws -> Props {
        let query = served.routed ? [URLQueryItem(name: "model", value: served.id)] : []
        guard let data = try await get("props", query: query, dialect: .llamaCpp, settings: settings) else {
            throw Failure.serverError(.llamaCpp, status: 404, body: "no /props")
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Failure.badResponse(.llamaCpp, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return Props(json)
    }

    /// Checks the server is up and serves this model and reads what it says about it, blocking briefly;
    /// `ModelSelection.resolve` is synchronous because agents are created synchronously.
    ///
    /// - Returns: The model with what the server reported, and its window.
    /// - Throws: `Failure`.
    public func checked() throws -> OpenAICompatibleModel {
        let (dialect, settings) = (self.dialect, self.settings)
        let served = try Blocking.run { try await Self.served(by: dialect, at: settings) }
        guard let entry = served.first(where: { $0.matches(name) }) else {
            throw Failure.noSuchModel(dialect, name, served: served.map(\.name))
        }
        guard entry.conversational else {
            throw Failure.notConversational(dialect, entry.name)
        }
        var reported: [CapabilityName] = []
        if entry.toolCalling == true { reported.append(.toolCalling) }
        if entry.reasoning { reported.append(.reasoning) }
        let window: (size: Int, reason: String)
        switch dialect.catalog {
        case .llamaServer:
            do {
                let props = try Blocking.run { try await Self.props(of: entry, at: settings) }
                if props.toolCalls == true { reported.append(.toolCalling) }
                window = Self.window(llamaServer: props.window, problem: nil)
            } catch {
                window = Self.window(llamaServer: nil, problem: "\(error)")
            }
        case .lmStudio:
            window = Self.window(lmStudio: entry)
        }
        return OpenAICompatibleModel(
            dialect: dialect, name: name, settings: settings, serverID: entry.id, reported: reported,
            window: window.size, windowReason: window.reason)
    }

    /// llama.cpp's window: the slot's, which the server allocated when it loaded the model, so it is the server's to
    /// size and wisp's to read; the floor when it reported none.
    ///
    /// - Parameters:
    ///   - reported: `/props`'s `n_ctx`.
    ///   - problem: Why `/props` could not be read.
    /// - Returns: The window and why.
    static func window(llamaServer reported: Int?, problem: String?) -> (size: Int, reason: String) {
        if let reported, reported > 0 {
            return (reported, "reported by llama.cpp (/props n_ctx): the server holds the model at this window")
        }
        let why = problem.map { "/props could not be read (\($0))" } ?? "/props reported no n_ctx"
        return (ContextSizing.floor, "\(ContextSizing.floor.formatted()), the default: llama.cpp \(why)")
    }

    /// LM Studio's window: the one it holds the model loaded at; for a model not loaded, the floor (or the model's
    /// maximum when smaller), since LM Studio loads it at its own default when the first request comes.
    ///
    /// - Parameter served: The model as LM Studio lists it.
    /// - Returns: The window and why.
    static func window(lmStudio served: Served) -> (size: Int, reason: String) {
        let maximum = served.maximumContext.map { " of \($0.formatted())" } ?? ""
        if let loaded = served.loadedContext, loaded > 0 {
            return (loaded, "reported by LM Studio: loaded at \(loaded.formatted())\(maximum)")
        }
        let size = min(ContextSizing.floor, served.maximumContext ?? ContextSizing.floor)
        return (
            size,
            "\(size.formatted()), the default: LM Studio has not loaded it and loads it at its own default window; "
                + "load it at the window you want and choose it again"
        )
    }
}

extension OpenAICompatibleModel: UsageReporting {}

/// How each catalog's listing reads into `Served` records.
enum Catalogs {
    /// llama.cpp's `/v1/models`: `data` of `id`, `meta` (`n_params`, `size`), and in router mode `status`.
    ///
    /// - Throws: `DecodingError` when the shape is wrong.
    static func llamaServer(_ json: JSONValue) throws -> [Served] {
        try entries(json, key: "data").map { entry in
            var served = OpenAICompatibleModel.Served(id: try string(entry, "id"))
            let meta = entry["meta"]?.objectValue
            served.parameters = meta?["n_params"]?.intValue.map(parameterCount)
            served.bytes = meta?["size"]?.intValue
            served.maximumContext = meta?["n_ctx_train"]?.intValue
            served.routed = entry["status"] != nil
            return served
        }
    }

    /// LM Studio's `/api/v1/models`: `models` of `type`, `key`, `architecture`, `quantization.name`, `size_bytes`,
    /// `params_string`, `loaded_instances[].config.context_length`, `max_context_length`, and `capabilities`
    /// (`trained_for_tool_use`, `reasoning`).
    ///
    /// - Throws: `DecodingError` when the shape is wrong.
    static func lmStudio(_ json: JSONValue) throws -> [Served] {
        try entries(json, key: "models").map { entry in
            var served = OpenAICompatibleModel.Served(id: try string(entry, "key"), name: try string(entry, "key"))
            served.conversational = entry["type"]?.stringValue != "embedding"
            served.parameters = entry["params_string"]?.stringValue
            served.bytes = entry["size_bytes"]?.intValue
            let parts = [entry["architecture"]?.stringValue, entry["quantization"]?.objectValue?["name"]?.stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }
            served.format = parts.isEmpty ? nil : parts.joined(separator: " ")
            served.loadedContext =
                entry["loaded_instances"]?.arrayValue?.first?.objectValue?["config"]?.objectValue?["context_length"]?
                .intValue
            served.maximumContext = entry["max_context_length"]?.intValue
            let capabilities = entry["capabilities"]?.objectValue
            served.toolCalling = capabilities?["trained_for_tool_use"]?.boolValue
            served.reasoning = capabilities?["reasoning"].map { $0 != .null } ?? false
            return served
        }
    }

    /// An OpenAI `/v1/models`: `data` of `id`, and nothing more.
    ///
    /// - Throws: `DecodingError` when the shape is wrong.
    static func openAI(_ json: JSONValue) throws -> [Served] {
        try entries(json, key: "data").map { OpenAICompatibleModel.Served(id: try string($0, "id"), name: nil) }
    }

    /// The objects in `json[key]`.
    ///
    /// - Throws: `DecodingError.dataCorrupted` when it is not an array of objects.
    private static func entries(_ json: JSONValue, key: String) throws -> [[String: JSONValue]] {
        guard let array = json.objectValue?[key]?.arrayValue else { throw corrupted("no \(key) array") }
        return try array.map { value in
            guard let object = value.objectValue else { throw corrupted("an entry is not an object") }
            return object
        }
    }

    /// The string at `key`.
    ///
    /// - Throws: `DecodingError.dataCorrupted` when there is none.
    private static func string(_ object: [String: JSONValue], _ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else { throw corrupted("an entry has no \(key)") }
        return value
    }

    /// A decoding error saying `why`.
    private static func corrupted(_ why: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: why))
    }

    /// A parameter count in the listing's words: `8.0B`, `620M`.
    ///
    /// - Parameter count: The parameters.
    /// - Returns: The words.
    static func parameterCount(_ count: Int) -> String {
        count >= 1_000_000_000
            ? String(format: "%.1fB", Double(count) / 1e9) : String(format: "%.0fM", Double(count) / 1e6)
    }

    /// The record type.
    typealias Served = OpenAICompatibleModel.Served
}
