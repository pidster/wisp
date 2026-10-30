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
    /// Whether a model is asked to think, for a dialect that takes it (llama.cpp): `true`, `false`, or a level, as
    /// `ollama.think` takes it; nil sends nothing and leaves it to the template.
    public var think: OllamaThink?
    /// The most tokens a model thinks for at each level, for a dialect that takes thinking; a level without one, or
    /// with 0, thinks without a limit.
    public var thinkingBudget: [String: Int]
    /// What `config.json` declares each model can do (`llamacpp.models.<name>`), by the operator or wisp's check.
    public var declared: [String: Config.MLXModelConfig]
    /// Whose server this is, for llama.cpp (`llamacpp.server`, ADR 0082); `off` for LM Studio, which has no choice.
    public var server: LlamaCppServer
    /// The `llama-server` wisp's own server would run, as `llamacpp.serverPath` names it; nil when unset, and for LM
    /// Studio. Approved only with the record `LlamaCppServerBinary` keeps (ADR 0082, decision 5).
    public var serverPath: String?
    /// Where Llama.app is looked for under `llama-app`, so a test need not depend on the Mac it runs on.
    public var llamaApp: LlamaApp
    /// The port and memory settings of wisp's own server, which under `wisp` also give `baseURL` (ADR 0082,
    /// decision 7); the defaults for LM Studio, which has none.
    public var router: LlamaCppRouter.Settings

    /// Creates settings.
    public init(
        baseURL: URL, timeout: Duration = .seconds(120), apiKey: String? = nil, apiKeySource: String? = nil,
        think: OllamaThink? = nil, thinkingBudget: [String: Int] = defaultThinkingBudget,
        declared: [String: Config.MLXModelConfig] = [:], server: LlamaCppServer = .off, serverPath: String? = nil,
        llamaApp: LlamaApp = .standard, router: LlamaCppRouter.Settings = .defaults
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.apiKey = apiKey
        self.apiKeySource = apiKey == nil ? nil : (apiKeySource ?? "config.json")
        self.think = think
        self.thinkingBudget = thinkingBudget
        self.declared = declared
        self.server = server
        self.serverPath = serverPath
        self.llamaApp = llamaApp
        self.router = router
    }

    /// What to do when nothing answers at `baseURL`: the runtime's own way to start a server; under
    /// `llamacpp.server llama-app`, to start Llama.app or that it is not installed; under `wisp`, that `wisp doctor`
    /// says why wisp's own server does not answer (`OpenAICompatibleBackend.resolve` says it in full).
    ///
    /// - Parameter dialect: The runtime.
    /// - Returns: The hint.
    func startHint(for dialect: OpenAICompatibleDialect) -> String {
        guard dialect == .llamaCpp else { return dialect.startHint }
        switch server {
        case .off: return dialect.startHint
        case .llamaApp: return llamaApp.startHint
        case .wisp: return LlamaCppRouter.unansweredHint(router)
        }
    }

    /// The budgets a level thinks within when `llamacpp.thinkingBudget` does not set its own: `low` 1,024 tokens,
    /// `medium` 4,096, `high` 16,384, and `max` without a limit. A reply from a thinking model at its template's
    /// default ran past 3,000 tokens of thinking for a one-word verdict (2026-10-17, docs/backends.md, "Thinking").
    public static let defaultThinkingBudget = ["low": 1024, "medium": 4096, "high": 16_384, "max": 0]

    /// The defaults for `dialect`: its own port on this Mac, two minutes, no key.
    ///
    /// - Parameter dialect: The runtime.
    /// - Returns: The settings.
    public static func defaults(for dialect: OpenAICompatibleDialect) -> OpenAICompatibleSettings {
        OpenAICompatibleSettings(baseURL: dialect.defaultBaseURL)
    }

    /// The settings a file section and the environment give: the environment's key wins over the file's. Under
    /// `llamacpp.server wisp` the base URL is wisp's own server's, `http://127.0.0.1:<llamacpp.serverPort>`, whatever
    /// `llamacpp.baseURL` says, and no key is taken from either: the server's only key is the one in wisp's key file,
    /// which `Session.loadConfig(home:)` reads (`withRouterKey(home:)`), since the server refuses any other.
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
        // Whose server is llama.cpp's choice alone; an explicit `baseURL` wins over the port the choice implies.
        let server = dialect == .llamaCpp ? section?.server ?? .off : .off
        let router = dialect == .llamaCpp ? LlamaCppRouter.Settings.resolve(section) : .defaults
        let configured =
            section?.baseURL.flatMap(URL.init(string:)) ?? server.defaultBaseURL ?? dialect.defaultBaseURL
        return OpenAICompatibleSettings(
            baseURL: server == .wisp ? router.baseURL : configured,
            timeout: .seconds(section?.timeoutSeconds ?? 120),
            apiKey: server == .wisp ? nil : fromEnvironment ?? fromFile,
            apiKeySource: fromEnvironment != nil ? dialect.apiKeyVariable : "config.json",
            think: dialect.takesThink ? section?.think : nil,
            thinkingBudget: defaultThinkingBudget.merging(section?.thinkingBudget ?? [:]) { _, configured in configured
            },
            declared: dialect.declaresCapabilities ? section?.models ?? [:] : [:], server: server,
            serverPath: dialect == .llamaCpp ? section?.serverPath.flatMap { $0.isEmpty ? nil : $0 } : nil,
            router: router)
    }

    /// Where the key is said to come from under `llamacpp.server wisp`.
    static let keyFileSource = "wisp's key file"

    /// These settings with wisp's own server's key, read from its key file in `home`'s support folder, under
    /// `llamacpp.server wisp`; as they are under any other server, or when the file holds no key yet (the server's
    /// first start makes it).
    ///
    /// - Parameter home: wisp's home.
    /// - Returns: The settings.
    func withRouterKey(home: Home) -> OpenAICompatibleSettings {
        guard server == .wisp else { return self }
        var settings = self
        settings.apiKey = LlamaCppRouter.KeyFile(home: home).read()
        settings.apiKeySource = settings.apiKey == nil ? nil : Self.keyFileSource
        return settings
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
