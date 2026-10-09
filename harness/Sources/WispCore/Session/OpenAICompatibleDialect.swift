import Foundation

/// What differs between the runtimes wisp's shared HTTP executor serves
/// ([ADR 0058](../../../../docs/decisions/0058-a-shared-http-executor.md)): llama.cpp's `llama-server` and LM Studio
/// both serve OpenAI's `/v1/chat/completions` with streaming, tools, and `response_format`, and differ in what they
/// say about their models and in a few fields of the stream. Every difference is a value here, read in one place each,
/// rather than a conditional scattered through the executor.
public struct OpenAICompatibleDialect: Hashable, Sendable, CustomStringConvertible {
    /// Where the runtime describes the models it serves.
    public enum Catalog: Hashable, Sendable {
        /// llama.cpp: `/v1/models` lists the model (or, in router mode, the models with a `status`), and `/props`
        /// reports the slot's window (`default_generation_settings.n_ctx`) and what the chat template supports
        /// (`chat_template_caps`).
        case llamaServer
        /// LM Studio 0.4.0 and later: `/api/v1/models` lists every downloaded model with its type, size, parameter
        /// count, quantisation, loaded instances and their window, and capabilities (`trained_for_tool_use`,
        /// `reasoning`); an older server's `/v1/models`, ids only, when that is missing.
        case lmStudio
    }

    /// The selection's scheme, the `config.json` section's name, and the audit's backend.
    public let scheme: String
    /// The runtime's name in the person's words: `llama.cpp`, `LM Studio`.
    public let runtime: String
    /// The port the runtime listens on by default.
    public let defaultPort: Int
    /// How to start the server, for the failure when none answers.
    public let startHint: String
    /// Where the runtime describes its models.
    public let catalog: Catalog
    /// Whether `think` is sent as the chat template's `enable_thinking` (`chat_template_kwargs`), which llama.cpp
    /// takes per request; LM Studio sets thinking per model in the app, so wisp sends nothing.
    public let takesThink: Bool
    /// Whether what a model can do beyond what the server reports is the configuration's to declare, and wisp's to
    /// check on enable (ADR 0056): llama.cpp reports no tool support for a model it serves, only what its chat
    /// template supports, while LM Studio reports `trained_for_tool_use` itself.
    public let declaresCapabilities: Bool

    /// llama.cpp's `llama-server`, on its default port 8080.
    public static let llamaCpp = OpenAICompatibleDialect(
        scheme: "llamacpp", runtime: "llama.cpp", defaultPort: 8080,
        startHint: "start one with llama-server -m <model.gguf>, or set llamacpp.baseURL", catalog: .llamaServer,
        takesThink: true, declaresCapabilities: true)

    /// LM Studio's server, on its default port 1234.
    public static let lmStudio = OpenAICompatibleDialect(
        scheme: "lmstudio", runtime: "LM Studio", defaultPort: 1234,
        startHint: "start it from LM Studio's Developer tab or with lms server start, or set lmstudio.baseURL",
        catalog: .lmStudio, takesThink: false, declaresCapabilities: false)

    /// Every dialect, by scheme.
    public static let all = [llamaCpp, lmStudio]

    /// The dialect for `scheme`, if wisp has one.
    public static func named(_ scheme: String) -> OpenAICompatibleDialect? { all.first { $0.scheme == scheme } }

    /// The runtime's own listen address on this Mac, such as `http://127.0.0.1:8080`.
    public var defaultBaseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = defaultPort
        return components.url ?? URL(filePath: "/")
    }

    /// The environment variable that holds the server's API key, such as `WISP_LLAMACPP_API_KEY`; it wins over
    /// `config.json`'s `apiKey`.
    public var apiKeyVariable: String { "WISP_\(scheme.uppercased())_API_KEY" }

    /// The runtime's name.
    public var description: String { runtime }
}

/// Where an OpenAI-compatible server is, how to authenticate to it, and how long to wait, from `config.json`'s
/// `llamacpp` or `lmstudio` section and the environment.
///
/// The API key is a secret: `description`, `debugDescription`, the backend's settings (`wisp config`, the `inspect`
/// tool), and every failure say only whether one is set and where from, never the key.
public struct OpenAICompatibleSettings: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The server's base URL, without `/v1`.
    public var baseURL: URL
    /// How long a generation request may go with nothing arriving (`URLRequest.timeoutInterval`, an idle limit,
    /// reset by every byte), before it is abandoned; not a limit on the whole request.
    public var timeout: Duration
    /// The bearer token sent as `Authorization`, when the server wants one.
    public var apiKey: String?
    /// Where the key came from: the environment variable's name, or `config.json`.
    public var apiKeySource: String?
    /// Whether a model is asked to think, for a dialect that takes it (`chat_template_kwargs.enable_thinking`); nil
    /// sends nothing and leaves it to the template.
    public var think: Bool?
    /// What `config.json` declares each model can do (`llamacpp.models.<name>`), by the operator or wisp's check.
    public var declared: [String: Config.MLXModelConfig]

    /// Creates settings.
    public init(
        baseURL: URL, timeout: Duration = .seconds(120), apiKey: String? = nil, apiKeySource: String? = nil,
        think: Bool? = nil, declared: [String: Config.MLXModelConfig] = [:]
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.apiKey = apiKey
        self.apiKeySource = apiKey == nil ? nil : (apiKeySource ?? "config.json")
        self.think = think
        self.declared = declared
    }

    /// The defaults for `dialect`: its own port on this Mac, two minutes, no key.
    ///
    /// - Parameter dialect: The runtime.
    /// - Returns: The settings.
    public static func defaults(for dialect: OpenAICompatibleDialect) -> OpenAICompatibleSettings {
        OpenAICompatibleSettings(baseURL: dialect.defaultBaseURL)
    }

    /// The settings a file section and the environment give: the environment's key wins over the file's.
    ///
    /// - Parameters:
    ///   - section: The `llamacpp` or `lmstudio` section, if any.
    ///   - dialect: The runtime.
    ///   - environment: The process environment.
    /// - Returns: The settings.
    static func resolve(
        _ section: Config.OpenAICompatibleConfig?, dialect: OpenAICompatibleDialect, environment: [String: String]
    ) -> OpenAICompatibleSettings {
        let fromEnvironment = environment[dialect.apiKeyVariable].flatMap { $0.isEmpty ? nil : $0 }
        let fromFile = section?.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        return OpenAICompatibleSettings(
            baseURL: section?.baseURL.flatMap(URL.init(string:)) ?? dialect.defaultBaseURL,
            timeout: .seconds(section?.timeoutSeconds ?? 120), apiKey: fromEnvironment ?? fromFile,
            apiKeySource: fromEnvironment != nil ? dialect.apiKeyVariable : "config.json",
            think: dialect.takesThink ? section?.think : nil,
            declared: dialect.declaresCapabilities ? section?.models ?? [:] : [:])
    }

    /// Whether a key is set and where from, never the key: `set (WISP_LLAMACPP_API_KEY)`, `unset`.
    public var apiKeyState: String { apiKeySource.map { "set (\($0))" } ?? "unset" }

    /// The settings with the key left out.
    public var description: String {
        "\(baseURL.absoluteString), timeout \(timeout.components.seconds) s, API key \(apiKeyState)"
    }

    /// As `description`: the key never appears.
    public var debugDescription: String { description }
}
