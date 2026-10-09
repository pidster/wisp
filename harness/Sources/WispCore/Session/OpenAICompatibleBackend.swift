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

    /// Checks the server lists the model, reads what it says about it, and wraps it.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` with the server's failure as the reason, or for a declared
    ///   capability wisp does not know.
    public func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let settings = config[server: dialect]
        let selection = ModelSelection.local(backend: scheme, name: name)
        _ = try CapabilityName.parse(settings.declared[name]?.capabilities ?? [], forModel: selection.description)
        do {
            let model = try OpenAICompatibleModel(dialect: dialect, name: name, settings: settings).checked()
            return ResolvedModel(
                selection: selection, custom: model, capabilitySource: model.capabilitySource,
                asset: "\(settings.baseURL.absoluteString) \(model.serverID)", contextSize: model.window,
                contextNote: model.windowReason)
        } catch let failure as OpenAICompatibleModel.Failure {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: failure.description)
        }
    }

    /// The models the server lists.
    public func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        let settings = config[server: dialect]
        return try await OpenAICompatibleModel.served(by: dialect, at: settings).map { served in
            let size = served.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            return InstalledModel(
                selection: .local(backend: scheme, name: served.name),
                detail: [served.parameters ?? "?", size].compactMap { $0 }.joined(separator: " "),
                parameters: served.parameters, bytes: served.bytes, format: served.format,
                verified: settings.declared[served.name]?.verified?.date)
        }
    }

    /// Base URL, timeout, whether a key is set (never the key), and `think` for llama.cpp.
    public func settings(in config: Config.Resolved, home: Home) -> JSONValue {
        let settings = config[server: dialect]
        var values: [String: JSONValue] = [
            "baseURL": .string(settings.baseURL.absoluteString),
            "timeoutSeconds": .int(Int(settings.timeout.components.seconds)),
            "apiKey": .string(settings.apiKeyState),
            "contextLength": .string("reported by the server (ADR 0058)"),
        ]
        if dialect.takesThink { values["think"] = settings.think.map { .bool($0) } ?? .string("unset") }
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
