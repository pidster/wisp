import CoreAILanguageModels
import Foundation
import FoundationModels
import WispCore

/// Models exported to Apple's Core AI format, selected as `coreai:<name>`
/// ([ADR 0019](../../../docs/decisions/0019-model-backends.md)), run by wisp's own executor over Core AI's engine
/// (`CoreAIModel`, [ADR 0088](../../../docs/decisions/0088-core-ai-through-wisps-executor.md)) or, with
/// `coreai.executor` `bridge`, by the `CoreAILanguageModel` bridge from `apple/coreai-models`.
///
/// A name is a bundle directory: absolute, `~`-relative, or a subdirectory of the models directory
/// (`config.json` `coreai.modelsDirectory`, default `<home>/models/coreai`). wisp never exports or
/// downloads; `docs/backends.md` gives the export recipe.
public struct CoreAIBackend: ModelBackend {
    /// `coreai:`.
    public let scheme = "coreai"

    /// Creates the backend.
    public init() {}

    /// The real path of the bundle `name` points to (`bundleURL(for:config:home:)`), so a name under the models
    /// directory and the bundle's absolute or `~` path are one model; without a configuration and a home, a path
    /// name's real path, and any other name as it is.
    public func canonicalName(_ name: String, config: Config.Resolved?, home: Home?) -> String {
        guard let config, let home else { return ModelBackends.canonicalPath(name) ?? name }
        return CommandPolicy.canonical(Self.bundleURL(for: name, config: config, home: home).path)
    }

    /// The bundle's entry in the models folder: a link removed, leaving the bundle it points to, or a real bundle
    /// moved to the Bin (ADR 0075). A bundle named by its path is not in the folder, and is the person's to remove.
    ///
    /// - Throws: `ModelRemoval.Failure`.
    public func removal(
        _ name: String, config: Config.Resolved, home: Home, purgeCache: Bool
    ) async throws
        -> ModelRemoval
    {
        guard !name.hasPrefix("/"), !name.hasPrefix("~") else {
            throw ModelRemoval.Failure.notWisps(
                model: "coreai:\(name)",
                reason: "it is named by its path, outside wisp's models folder; remove it yourself")
        }
        return try ModelRemoval.folder(
            model: "coreai:\(name)", entry: Self.bundleURL(for: name, config: config, home: home), cacheRoot: nil,
            purgeCache: purgeCache)
    }

    /// The configured models directory, or the default under the home.
    public static func modelsDirectory(config: Config.Resolved, home: Home) -> URL {
        if let configured = config.coreaiModelsDirectory {
            return URL(filePath: (configured as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return home.models.appending(path: "coreai", directoryHint: .isDirectory)
    }

    /// Where a name points: an absolute or `~` path as given, anything else under the models directory.
    public static func bundleURL(for name: String, config: Config.Resolved, home: Home) -> URL {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return URL(filePath: (name as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return modelsDirectory(config: config, home: home).appending(path: name, directoryHint: .isDirectory)
    }

    /// Where the weights files that matched their hashes are remembered (`BundleIntegrity`).
    ///
    /// - Parameter home: wisp's home.
    /// - Returns: The records file.
    static func integrityRecords(home: Home) -> URL {
        home.cache.appending(path: "coreai-verified.json")
    }

    /// Checks the bundle exists and its weights match the hash exported beside them (`BundleIntegrity`), reads its
    /// metadata, and wraps it for the configured executor: wisp's, with the capabilities its chat template states,
    /// or the bridge's, which loads the tokenizer here and detects them from the asset (tool-call markers in the
    /// tokenizer, a thinking format).
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` naming the path looked at and the bundles found, or the
    ///   weights file that does not match its hash.
    public func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let url = Self.bundleURL(for: name, config: config, home: home)
        let selection = ModelSelection.local(backend: scheme, name: name)
        guard FileManager.default.fileExists(atPath: url.appending(path: "metadata.json").path) else {
            let directory = Self.modelsDirectory(config: config, home: home)
            let found = Self.bundles(in: directory).map(\.lastPathComponent)
            throw ModelSelection.Failure.unavailable(
                model: selection.description,
                reason: "no Core AI bundle at \(url.path) (no metadata.json); bundles under \(directory.path): "
                    + (found.isEmpty ? "none" : found.joined(separator: ", "))
                    + "; export one with `uv run coreai.llm.export <hf-model-id> --output-dir \(directory.path)`")
        }
        // A linked bundle is used by its real directory, as MLX's linked models are: Foundation's listings and a
        // loader do not follow a link at the end of the path.
        let real = url.resolvingSymlinksInPath()
        do {
            _ = try BundleIntegrity.check(bundle: real, records: Self.integrityRecords(home: home))
        } catch let mismatch as BundleIntegrity.Mismatch {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: mismatch.description)
        } catch {
            throw ModelSelection.Failure.unavailable(
                model: selection.description, reason: "cannot check the weights in \(real.path): \(error)")
        }
        let window = Self.contextWindow(in: real)
        do {
            guard config.coreaiExecutor == .wisp else {
                let model = try Blocking.run { try await CoreAILanguageModel(resourcesAt: real) }
                return ResolvedModel(
                    selection: selection, custom: model, capabilitySource: .runtime, asset: real.path,
                    contextSize: window?.window, contextNote: window?.reason)
            }
            let language = try LanguageBundle(at: real)
            let model = Self.model(at: real, window: window?.window ?? language.maxContextLength)
            return ResolvedModel(
                selection: selection, custom: model, capabilitySource: .runtime, asset: real.path,
                contextSize: model.window, countTokens: { try await model.tokenCount(for: $0) },
                contextNote: window?.reason ?? "declared by the bundle (metadata.json)")
        } catch {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: "\(error)")
        }
    }

    /// A bundle as a model run by wisp's executor, over the process's one engine for it, with the capabilities
    /// its chat template states: tool calling when it renders tools, reasoning when it marks thinking or routes
    /// messages to `self`, and guided generation, which the engine is asked for when a request needs it (ADR 0088).
    ///
    /// - Parameters:
    ///   - bundle: The bundle directory, its real path.
    ///   - window: The context window.
    /// - Returns: The model.
    static func model(at bundle: URL, window: Int) -> CoreAIModel {
        let engine = CoreAIEngines.engine(for: bundle) {
            CoreAIEngine(
                loadTokenizer: { try await CoreAITokenizer.load(from: bundle) },
                loadGenerator: {
                    let tokenizer = try await CoreAITokenizer.load(from: bundle)
                    return try await CoreAIGenerator.load(from: bundle, tokenizer: tokenizer)
                })
        }
        let template = chatTemplate(in: bundle)
        let format = ReplyFormat.read(template: template)
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if template?.contains("tools") == true { capabilities.append(.toolCalling) }
        if format.reasons { capabilities.append(.reasoning) }
        return CoreAIModel(engine: engine, window: window, capabilities: capabilities, replyFormat: format)
    }

    /// The bundle's chat template: `tokenizer/chat_template.jinja`, else `chat_template` in
    /// `tokenizer/tokenizer_config.json`, a string or a list of named templates whose `default` (or first) is used.
    ///
    /// - Parameter bundle: The bundle directory.
    /// - Returns: The template's text, or nil when the bundle has none.
    static func chatTemplate(in bundle: URL) -> String? {
        let directory = bundle.appending(path: "tokenizer", directoryHint: .isDirectory)
        if let text = try? String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8) {
            return text
        }
        guard let data = try? Data(contentsOf: directory.appending(path: "tokenizer_config.json")),
            let config = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
            let template = config["chat_template"]
        else { return nil }
        if let text = template.stringValue { return text }
        let named = template.arrayValue?.compactMap(\.objectValue) ?? []
        let chosen = named.first { $0["name"]?.stringValue == "default" } ?? named.first
        return chosen?["template"]?.stringValue
    }

    /// Shuts down every Core AI engine wisp's executor made, waiting for each, so none is torn down beside the
    /// process's exit (ADR 0088). The bridge's engines are not reachable from wisp and are not shut down.
    public func shutdown() async {
        await CoreAIEngines.shutdown()
    }

    /// The window a bundle was exported for, from its `metadata.json`: `language.max_context_length` (metadata
    /// 0.2), or the top-level `max_context_length` of a 0.1 bundle
    /// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)). The export fixes it and Core AI
    /// sizes its own cache within it, so it is taken as it is, not sized from memory.
    ///
    /// - Parameter bundle: The bundle directory.
    /// - Returns: The window and why, or nil when the metadata states none.
    static func contextWindow(in bundle: URL) -> ContextSizing.Decision? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "metadata.json")),
            let metadata = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue
        else { return nil }
        if let nested = metadata["language"]?.objectValue?["max_context_length"]?.intValue, nested > 0 {
            return .init(window: nested, reason: "declared by the bundle (metadata.json language.max_context_length)")
        }
        guard let legacy = metadata["max_context_length"]?.intValue, legacy > 0 else { return nil }
        return .init(window: legacy, reason: "declared by the bundle (metadata.json max_context_length)")
    }

    /// Subdirectories of `directory` (or links to them) that hold a `metadata.json`, sorted; a `directory` that is
    /// itself a link is followed.
    static func bundles(in directory: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
        return entries.filter { FileManager.default.fileExists(atPath: $0.appending(path: "metadata.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every bundle in the models directory, with its kind, compression, size, and window from `metadata.json`.
    public func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        Self.bundles(in: Self.modelsDirectory(config: config, home: home)).map { url in
            let name = url.lastPathComponent
            var detail = "core ai bundle"
            var format: String?
            let bytes = Self.size(of: url)
            if let data = try? Data(contentsOf: url.appending(path: "metadata.json")),
                let metadata = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue
            {
                let kind = metadata["kind"]?.stringValue ?? "?"
                let compression = metadata["compression"]?.stringValue ?? "?"
                let source = metadata["source"]?.objectValue?["hf_model_id"]?.stringValue
                let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                let window = Self.contextWindow(in: url).map { "\($0.window.formatted())-token window" }
                detail = [kind, compression, source, size, window].compactMap { $0 }.joined(separator: " ")
                let parts = [metadata["kind"]?.stringValue, metadata["compression"]?.stringValue].compactMap { $0 }
                format = parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            return InstalledModel(
                selection: .local(backend: scheme, name: name), detail: detail, bytes: bytes.map { Int($0) },
                format: format)
        }
    }

    /// Total bytes under a bundle directory.
    static func size(of directory: URL) -> Int64? {
        let directory = directory.resolvingSymlinksInPath()
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// The models directory and the executor in force.
    public func settings(in config: Config.Resolved, home: Home) -> JSONValue {
        [
            "modelsDirectory": .string(Self.modelsDirectory(config: config, home: home).path),
            "executor": .string(config.coreaiExecutor.rawValue),
        ]
    }
}
