import Foundation

/// A built-in backend for a runtime that serves OpenAI's chat-completions API on this Mac: `llamacpp:` for
/// llama.cpp's `llama-server`, `lmstudio:` for LM Studio
/// ([ADR 0058](../../../../docs/decisions/0058-a-shared-http-executor.md)). One type, parameterised by the dialect.
public struct OpenAICompatibleBackend: ModelBackend {
    /// The runtime.
    public let dialect: OpenAICompatibleDialect

    /// The dialect's scheme.
    public var scheme: String { dialect.scheme }

    /// Creates the backend for `dialect`.
    public init(_ dialect: OpenAICompatibleDialect) {
        self.dialect = dialect
    }

    /// The name a listing gives the model (`OpenAICompatibleModel.Served`): for an id that is a `.gguf` file's path,
    /// as llama.cpp lists one, the file's name without `.gguf`, which a selection may use instead; else the id.
    public func canonicalName(_ name: String, config: Config.Resolved?, home: Home?) -> String {
        OpenAICompatibleModel.Served.shortName(name)
    }

    /// Under `llamacpp.server wisp`, the link in wisp's llama.cpp models folder, its GGUF file kept (ADR 0082);
    /// otherwise refuses: the server's models are its own (ADR 0075).
    ///
    /// - Throws: `ModelRemoval.Failure.notInstalled` for a name wisp's folder does not link;
    ///   `ModelRemoval.Failure.notWisps`, saying where to remove it, for another server's model.
    public func removal(
        _ name: String, config: Config.Resolved, home: Home, purgeCache: Bool
    ) async throws
        -> ModelRemoval
    {
        if dialect == .llamaCpp, config.llamacpp.server == .wisp {
            return try LlamaCppModels(home: home).removal(name, purgeCache: purgeCache)
        }
        let reason =
            switch (dialect, config.llamacpp.server) {
            case (.llamaCpp, .llamaApp): "Llama.app keeps its own models; remove it there"
            case (.llamaCpp, _):
                "llama.cpp serves the GGUF file llama-server was started with; delete that file yourself"
            default: "\(dialect.runtime) keeps its own models; remove it there (LM Studio: My Models)"
            }
        throw ModelRemoval.Failure.notWisps(model: "\(scheme):\(name)", reason: reason)
    }

    /// Checks the server lists the model, reads what it says about it, and wraps it.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` with the server's failure as the reason, or for a declared
    ///   capability wisp does not know.
    public func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let settings = config[server: dialect]
        let selection = ModelSelection.local(backend: scheme, name: name)
        _ = try CapabilityName.parse(settings.declared[name]?.capabilities ?? [], forModel: selection.description)
        if dialect == .llamaCpp, settings.server == .wisp, let reason = Self.notServable(name, home: home) {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: reason)
        }
        do {
            let model = try OpenAICompatibleModel(dialect: dialect, name: name, settings: settings).checked()
            return ResolvedModel(
                selection: selection, custom: model, capabilitySource: model.capabilitySource,
                asset: "\(settings.baseURL.absoluteString) \(model.serverID)", contextSize: model.window,
                contextNote: model.windowReason)
        } catch let failure as OpenAICompatibleModel.Failure {
            let reason =
                dialect == .llamaCpp && settings.server == .wisp
                ? Self.routerReason(failure, settings: settings, home: home, agent: LlamaCppAgent.control(home: home))
                : failure.description
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: reason)
        }
    }

    /// Why wisp's own llama.cpp server did not serve, in plain words with the fix (ADR 0082): for no answer, or no
    /// key yet, what stands in the way (`LlamaCppRouter.diagnosis`); for a refused key, that the server runs with
    /// another; anything else as it is.
    ///
    /// - Parameters:
    ///   - failure: What asking the server met.
    ///   - settings: The `llamacpp` settings.
    ///   - home: wisp's home.
    ///   - agent: The LaunchAgent's control, for its state.
    /// - Returns: The reason.
    static func routerReason(
        _ failure: OpenAICompatibleModel.Failure, settings: OpenAICompatibleSettings, home: Home,
        agent: any LlamaCppAgentControl
    ) -> String {
        func diagnosis(_ detail: String?) -> String {
            LlamaCppRouter.diagnosis(
                binary: Doctor.serverBinary(settings, home: home) ?? .failure(.notSet), agent: agent.state(),
                keyExists: LlamaCppRouter.KeyFile(home: home).read() != nil, settings: settings.router,
                log: LlamaCppRouter.log(home: home), detail: detail)
        }
        switch failure {
        case .unreachable(_, _, let detail, _): return diagnosis(detail)
        case .unusable: return diagnosis(nil)
        case .refused:
            return
                "wisp's llama.cpp server at \(settings.baseURL.absoluteString) refused the key in wisp's key file: it "
                + "runs with another; wisp config set llamacpp.server wisp starts it again"
        default: return failure.description
        }
    }

    /// Why wisp's own server could not serve `name` from its folder (ADR 0082): no link, or a broken one; nil when the
    /// link is there.
    ///
    /// - Parameters:
    ///   - name: The model's name, after `llamacpp:`.
    ///   - home: wisp's home, whose Application Support folder holds the links.
    /// - Returns: The reason.
    static func notServable(_ name: String, home: Home) -> String? {
        let models = LlamaCppModels(home: home)
        guard let link = models.link(named: name) else {
            return "it is not among the models wisp's llama.cpp server serves (\(models.folder.path)); add its GGUF "
                + "file with wisp models add PATH"
        }
        guard link.broken else { return nil }
        return "its link points to \(link.target.path), which is missing; wisp models uninstall llamacpp:\(name) "
            + "removes the link"
    }

    /// The models the server lists; under `llamacpp.server wisp`, the links in wisp's llama.cpp models folder, read
    /// from the folder rather than a server (ADR 0082), a broken one marked so.
    public func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        let settings = config[server: dialect]
        if dialect == .llamaCpp, settings.server == .wisp {
            return LlamaCppModels(home: home).linked().map { link in
                InstalledModel(
                    selection: .local(backend: scheme, name: link.name),
                    detail: link.bytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                    } ?? "broken link: \(link.target.path) is missing",
                    bytes: link.bytes, location: link.broken ? .brokenLink : .linkedFile,
                    verified: settings.declared[link.name]?.verified?.date)
            }
        }
        return try await OpenAICompatibleModel.served(by: dialect, at: settings).map { served in
            let size = served.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            return InstalledModel(
                selection: .local(backend: scheme, name: served.name),
                detail: [served.parameters ?? "?", size].compactMap { $0 }.joined(separator: " "),
                parameters: served.parameters, bytes: served.bytes, format: served.format,
                verified: settings.declared[served.name]?.verified?.date)
        }
    }

    /// Base URL, timeout, whether a key is set (never the key), and, for llama.cpp, whose server it is (`server`), the
    /// `llama-server` it would run (`serverPath`, as set; whether it is approved is `wisp doctor`'s), the port and
    /// memory settings of wisp's own server,
    /// `think`, and the thinking budgets, with each model's own `think`.
    public func settings(in config: Config.Resolved, home: Home) -> JSONValue {
        let settings = config[server: dialect]
        var values: [String: JSONValue] = [
            "baseURL": .string(settings.baseURL.absoluteString),
            "timeoutSeconds": .int(Int(settings.timeout.components.seconds)),
            "apiKey": .string(settings.apiKeyState),
            "contextLength": .string("reported by the server (ADR 0058)"),
        ]
        if dialect == .llamaCpp {
            values["server"] = .string(settings.server.rawValue)
            values["serverPath"] = .string(settings.serverPath ?? "none approved")
            // What wisp's own server runs with, used under `server` `wisp` (ADR 0082, decision 7).
            let router = settings.router
            values["serverPort"] = .int(router.port)
            values["serverContextLength"] = .int(router.contextLength)
            values["serverSlots"] = .int(router.slots)
            values["serverModelsLoaded"] = .int(router.modelsLoaded)
            values["serverIdleSeconds"] = .int(router.idleSeconds)
        }
        if dialect.takesThink {
            values["think"] = settings.think.map { .string($0.text) } ?? .string("unset")
            values["thinkingBudget"] = .object(
                settings.thinkingBudget.mapValues { $0 == 0 ? .string("no limit") : .int($0) })
            let own = settings.declared.compactMapValues(\.think)
            if !own.isEmpty { values["models"] = .object(own.mapValues { .object(["think": .string($0.text)]) }) }
        }
        return .object(values)
    }

    /// `llamacpp.models.<name>` for llama.cpp, whose server does not report whether a model calls tools; nil for LM
    /// Studio, which does.
    public func declarationKeys(for name: String) -> [String]? {
        dialect.declaresCapabilities ? [scheme, "models", name] : nil
    }

    /// `config` with `declaration` as `name`'s, for a dialect whose capabilities are declared.
    public func declaring(
        _ declaration: Config.MLXModelConfig, for name: String, in config: Config.Resolved
    )
        -> Config.Resolved
    {
        guard dialect.declaresCapabilities else { return config }
        var config = config
        config[server: dialect].declared[name] = declaration
        return config
    }
}
