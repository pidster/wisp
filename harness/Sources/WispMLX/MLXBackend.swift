import Foundation
import FoundationModels
import WispCore

#if MLX
    import Metal
    import MLXFoundationModels
    import MLXHuggingFace
    import MLXLLM
    import MLXLMCommon
    import Tokenizers
#endif

/// Models in MLX or Hugging Face safetensors layout, run in wisp's own process through the
/// `MLXLanguageModel` bridge from `ml-explore/mlx-swift-lm`, selected as `mlx:<name>`
/// ([ADR 0019](../../../docs/decisions/0019-model-backends.md)).
///
/// The bridge compiles Metal kernels at build time, so it is behind the `MLX` package trait: a build
/// without the trait registers this backend but every model is `unavailable` with that reason. A name
/// is a model directory (`config.json`, `*.safetensors`, tokenizer files): absolute, `~`-relative, or a
/// subdirectory of the models directory (`config.json` `mlx.modelsDirectory`, default `<home>/models/mlx`).
///
/// The bridge never infers what a model can do, so capabilities come from the operator:
/// `mlx.models.<name>.capabilities` in `config.json`. An undeclared model runs text-only conversations.
public struct MLXBackend: ModelBackend {
    /// `mlx:`.
    public let scheme = "mlx"

    /// Whether this build carries the bridge (built with `--traits MLX`).
    public static var isCompiledIn: Bool {
        #if MLX
            true
        #else
            false
        #endif
    }

    /// Creates the backend.
    public init() {}

    /// The configured models directory, or the default under the home.
    public static func modelsDirectory(config: Config.Resolved, home: Home) -> URL {
        if let configured = config.mlxModelsDirectory {
            return URL(filePath: (configured as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return home.models.appending(path: "mlx", directoryHint: .isDirectory)
    }

    /// Where a name points: an absolute or `~` path as given, anything else under the models directory.
    public static func modelURL(for name: String, config: Config.Resolved, home: Home) -> URL {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return URL(filePath: (name as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return modelsDirectory(config: config, home: home).appending(path: name, directoryHint: .isDirectory)
    }

    /// The capabilities the operator declared for `name` in `config.json`, or none.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` for an unknown capability spelling.
    public static func declaredCapabilities(
        for name: String, config: Config.Resolved
    ) throws
        -> (capabilities: [LanguageModelCapabilities.Capability], declared: Bool)
    {
        guard let names = config.mlxModels[name] else { return ([], false) }
        return (try CapabilityName.parse(names, forModel: "mlx:\(name)"), true)
    }

    /// Checks the directory holds a model, reads the declared capabilities, and wraps the bridge's
    /// model. Weights load on first use.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable` naming the path looked at and what was found.
    public func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let selection = ModelSelection.local(backend: scheme, name: name)
        guard Self.isCompiledIn else {
            throw ModelSelection.Failure.unavailable(
                model: selection.description,
                reason: "this build has no MLX support; build wisp with `swift build --traits MLX` on a Mac with the "
                    + "Metal toolchain (docs/backends.md)")
        }
        let url = Self.modelURL(for: name, config: config, home: home)
        guard FileManager.default.fileExists(atPath: url.appending(path: "config.json").path) else {
            let directory = Self.modelsDirectory(config: config, home: home)
            let found = Self.models(in: directory).map(\.lastPathComponent)
            throw ModelSelection.Failure.unavailable(
                model: selection.description,
                reason: "no MLX model at \(url.path) (no config.json); models under \(directory.path): "
                    + (found.isEmpty ? "none" : found.joined(separator: ", "))
                    + "; put a Hugging Face snapshot or mlx-community model directory there")
        }
        let (capabilities, declared) = try Self.declaredCapabilities(for: name, config: config)
        return try Self.make(url: url, selection: selection, capabilities: capabilities, declared: declared)
    }

    #if MLX
        private static func make(
            url: URL, selection: ModelSelection, capabilities: [LanguageModelCapabilities.Capability], declared: Bool
        ) throws -> ResolvedModel {
            let model = MLXLanguageModel(
                configuration: ModelConfiguration(directory: url), capabilities: capabilities,
                weightsLocation: { _ in url },
                load: { _, _ in try await loadModelContainer(from: url, using: #huggingFaceTokenizerLoader()) })
            return ResolvedModel(
                selection: selection, custom: model, capabilitySource: declared ? .configuration : .undeclared,
                asset: url.path)
        }
    #else
        private static func make(
            url: URL, selection: ModelSelection, capabilities: [LanguageModelCapabilities.Capability], declared: Bool
        ) throws -> ResolvedModel {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: "MLX is not compiled in")
        }
    #endif

    /// Subdirectories of `directory` that hold a `config.json`, sorted.
    static func models(in directory: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { FileManager.default.fileExists(atPath: $0.appending(path: "config.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every model directory under the models directory, with its architecture and declared capabilities.
    public func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        Self.models(in: Self.modelsDirectory(config: config, home: home)).map { url in
            let name = url.lastPathComponent
            var parts: [String] = []
            if let data = try? Data(contentsOf: url.appending(path: "config.json")),
                let json = try? JSONDecoder().decode(WispCore.JSONValue.self, from: data).objectValue
            {
                if let type = json["model_type"]?.stringValue { parts.append(type) }
                if let quantization = json["quantization"]?.objectValue, let bits = quantization["bits"]?.intValue {
                    parts.append("\(bits)-bit")
                }
            }
            parts.append(
                config.mlxModels[name].map { "capabilities: \($0.joined(separator: ", "))" }
                    ?? "capabilities undeclared")
            if !Self.isCompiledIn { parts.append("(MLX not compiled in)") }
            return InstalledModel(selection: .local(backend: scheme, name: name), detail: parts.joined(separator: " "))
        }
    }

    /// The `MLX` finding for `wisp doctor`: whether this build carries MLX and, if so, whether MLX's Metal
    /// library is where MLX looks for it and loads.
    public func doctorFinding() -> Doctor.Finding? {
        #if MLX
            let search = MetalLibrary.Search(
                imageDirectory: MetalLibrary.imageDirectory(), mainBundleDirectory: Bundle.main.bundleURL)
            return MetalLibrary.finding(compiledIn: true, search: search, load: Self.loadMetalLibrary)
        #else
            return MetalLibrary.finding(compiledIn: false, search: nil)
        #endif
    }

    #if MLX
        /// Loads the library at `url` on the default GPU, the step MLX takes first; nil when it loads.
        private static func loadMetalLibrary(_ url: URL) -> String? {
            guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
            do {
                _ = try device.makeLibrary(URL: url)
                return nil
            } catch {
                return "\(error.localizedDescription)"
            }
        }
    #endif

    /// The models directory, the declared models, and whether the bridge is compiled in.
    public func settings(in config: Config.Resolved, home: Home) -> WispCore.JSONValue {
        .object([
            "modelsDirectory": .string(Self.modelsDirectory(config: config, home: home).path),
            "compiledIn": .bool(Self.isCompiledIn),
            "models": .object(
                Dictionary(
                    uniqueKeysWithValues: config.mlxModels.map { name, capabilities in
                        (name, WispCore.JSONValue.object(["capabilities": .array(capabilities.map { .string($0) })]))
                    })),
        ])
    }
}
