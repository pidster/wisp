import CoreAILanguageModels
import Foundation
import FoundationModels
import WispCore

/// Models exported to Apple's Core AI format, run through the `CoreAILanguageModel` bridge from
/// `apple/coreai-models`, selected as `coreai:<name>` ([ADR 0019](../../../docs/decisions/0019-model-backends.md)).
///
/// A name is a bundle directory: absolute, `~`-relative, or a subdirectory of the models directory
/// (`config.json` `coreai.modelsDirectory`, default `<home>/models/coreai`). wisp never exports or
/// downloads; `docs/backends.md` gives the export recipe.
public struct CoreAIBackend: ModelBackend {
    /// `coreai:`.
    public let scheme = "coreai"

    /// Creates the backend.
    public init() {}

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

    /// Checks the bundle exists, loads its metadata and tokenizer, and wraps it with the capabilities
    /// the bridge detected from the asset (tool-call markers in the tokenizer, a thinking format).
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` naming the path looked at and the bundles found.
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
        let window = Self.contextWindow(in: url)
        do {
            let model = try Blocking.run { try await CoreAILanguageModel(resourcesAt: url) }
            return ResolvedModel(
                selection: selection, custom: model, capabilitySource: .runtime, asset: url.path,
                contextSize: window?.window, contextNote: window?.reason)
        } catch {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: "\(error)")
        }
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

    /// Subdirectories of `directory` that hold a `metadata.json`, sorted.
    static func bundles(in directory: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
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

    /// The models directory in force.
    public func settings(in config: Config.Resolved, home: Home) -> JSONValue {
        ["modelsDirectory": .string(Self.modelsDirectory(config: config, home: home).path)]
    }
}
