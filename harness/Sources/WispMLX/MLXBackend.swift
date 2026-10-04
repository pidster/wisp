import Foundation
import FoundationModels
import Synchronization
import WispCore

#if MLX
    import Metal
    import MLXFoundationModels
    import MLXHuggingFace
    import MLXLLM
    import MLXLMCommon
    import Tokenizers
#endif

/// Models in MLX or Hugging Face safetensors layout, run in wisp's own process through MLX Swift
/// (`ml-explore/mlx-swift-lm`), selected as `mlx:<name>` ([ADR 0019](../../../docs/decisions/0019-model-backends.md)).
///
/// MLX compiles Metal kernels at build time, so it is behind the `MLX` package trait: a build without the
/// trait registers this backend but every model is `unavailable` with that reason. A name is a model
/// directory (`config.json`, `*.safetensors`, tokenizer files): absolute, `~`-relative, or a subdirectory of
/// the models directory (`config.json` `mlx.modelsDirectory`, default `<home>/models/mlx`).
///
/// Since 0.19.0 wisp's own executor runs them ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)):
/// the window sized from `config.json` and memory as ADR 0043 sizes Ollama's, exact token counts with the
/// model's tokenizer, usage reported, and the processed prefix of a thread's last request reused.
/// `mlx.executor: "bridge"` selects mlx-swift-lm's `MLXLanguageModel` bridge instead, as before.
///
/// MLX never infers what a model can do, so capabilities come from the operator:
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
        let named = Self.modelURL(for: name, config: config, home: home)
        guard FileManager.default.fileExists(atPath: named.appending(path: "config.json").path) else {
            let directory = Self.modelsDirectory(config: config, home: home)
            let found = Self.models(in: directory).map(\.lastPathComponent)
            throw ModelSelection.Failure.unavailable(
                model: selection.description,
                reason: "no MLX model at \(named.path) (no config.json); models under \(directory.path): "
                    + (found.isEmpty ? "none" : found.joined(separator: ", "))
                    + "; put a Hugging Face snapshot or mlx-community model directory there, or link one with "
                    + "wisp models pull mlx-community/<name>")
        }
        // A linked model (a Hugging Face snapshot, as `wisp models pull` makes) is used by its real directory:
        // Foundation's URL listings and the loader do not follow a link at the end of the path.
        let url = named.resolvingSymlinksInPath()
        let (capabilities, declared) = try Self.declaredCapabilities(for: name, config: config)
        let engine = Self.engine(for: url)
        let sizing = Self.window(
            for: url, configured: config.mlxContextLength, memory: .current(), weightsHeld: engine.isLoaded)
        return try Self.make(
            url: url, selection: selection, capabilities: capabilities, declared: declared, engine: engine,
            sizing: sizing, executor: config.mlxExecutor)
    }

    /// What MLX does when even the floor window does not fit, for the reason of a floor decision.
    static let shortfall = "so the cache may not fit in memory and the Mac may swap"

    /// The window for the model in `directory`: configured (`mlx.contextLength`), or sized from its
    /// `config.json` and the weights' size as ADR 0043 sizes an Ollama model's, or the floor when the
    /// configuration gives no shape.
    ///
    /// - Parameters:
    ///   - directory: The model directory.
    ///   - configured: `mlx.contextLength`, when set.
    ///   - memory: The Mac's memory now.
    ///   - weightsHeld: Whether this process already holds the weights, which then count as available.
    /// - Returns: The window and why.
    static func window(
        for directory: URL, configured: Int?, memory: MemoryState, weightsHeld: Bool
    ) -> ContextSizing.Decision {
        if let configured { return .init(window: configured, reason: "configured as mlx.contextLength") }
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
            let json = try? JSONDecoder().decode(WispCore.JSONValue.self, from: data).objectValue,
            let shape = ContextSizing.shape(fromModelConfig: json)
        else {
            return .init(
                window: ContextSizing.floor,
                reason: "\(ContextSizing.floor.formatted()), the default: config.json gives no model shape to size from"
            )
        }
        let weights = weightBytes(in: directory)
        return ContextSizing.size(
            shape: shape, weights: weights, memory: memory, held: weightsHeld ? weights : 0, shortfall: shortfall)
    }

    /// Bytes of the `*.safetensors` files in a model directory, following a link to the directory and a
    /// snapshot's links to its blobs.
    ///
    /// - Parameter directory: The model directory.
    /// - Returns: Their total size.
    static func weightBytes(in directory: URL) -> Int {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "safetensors" }.reduce(0) { total, file in
            let real = file.resolvingSymlinksInPath()
            return total + ((try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// One engine per model directory, so threads on the same model share its weights.
    private static let engines = Mutex<[String: any PromptEngine]>([:])

    /// The engine for a model directory, made on first use.
    ///
    /// - Parameter directory: The model directory.
    /// - Returns: Its engine.
    static func engine(for directory: URL) -> any PromptEngine {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return engines.withLock { engines in
            if let engine = engines[key] { return engine }
            let engine = makeEngine(for: directory)
            engines[key] = engine
            return engine
        }
    }

    /// The resolved model over wisp's executor: the engine's slot for this resolution, the sized window, and
    /// exact counts. `vision` is not offered, since the executor maps text only.
    ///
    /// - Parameters:
    ///   - selection: The selection.
    ///   - engine: The model directory's engine.
    ///   - capabilities: What the operator declared.
    ///   - declared: Whether the operator declared anything.
    ///   - sizing: The window and why.
    ///   - asset: The model directory's path.
    /// - Returns: The resolved model.
    static func resolved(
        selection: ModelSelection, engine: any PromptEngine, capabilities: [LanguageModelCapabilities.Capability],
        declared: Bool, sizing: ContextSizing.Decision, asset: String
    ) -> ResolvedModel {
        let model = MLXModel(engine: engine, window: sizing.window, capabilities: capabilities.filter { $0 != .vision })
        return ResolvedModel(
            selection: selection, custom: model, capabilitySource: declared ? .configuration : .undeclared,
            asset: asset, contextSize: sizing.window, countTokens: { try await model.tokenCount(for: $0) },
            contextNote: sizing.reason)
    }

    #if MLX
        /// The resolved model, over wisp's executor or the bridge.
        ///
        /// - Throws: Nothing in a build with MLX; the signature matches the build without it.
        private static func make(
            url: URL, selection: ModelSelection, capabilities: [LanguageModelCapabilities.Capability], declared: Bool,
            engine: any PromptEngine, sizing: ContextSizing.Decision, executor: MLXExecutorChoice
        ) throws -> ResolvedModel {
            guard executor == .bridge else {
                return resolved(
                    selection: selection, engine: engine, capabilities: capabilities, declared: declared,
                    sizing: sizing, asset: url.path)
            }
            let model = MLXLanguageModel(
                configuration: ModelConfiguration(directory: url), capabilities: capabilities,
                weightsLocation: { _ in url },
                load: { _, _ in try await loadModelContainer(from: url, using: #huggingFaceTokenizerLoader()) })
            let thinking = capabilities.contains(.reasoning)
            return ResolvedModel(
                selection: selection, custom: model, capabilitySource: declared ? .configuration : .undeclared,
                asset: url.path, contextSize: sizing.window,
                countTokens: { try await engine.count(MLXPrompt.counting($0, thinking: thinking)) },
                contextNote: sizing.reason)
        }
    #else
        /// Refuses: this build has no MLX.
        ///
        /// - Throws: `ModelSelection.Failure.unavailable`.
        private static func make(
            url: URL, selection: ModelSelection, capabilities: [LanguageModelCapabilities.Capability], declared: Bool,
            engine: any PromptEngine, sizing: ContextSizing.Decision, executor: MLXExecutorChoice
        ) throws -> ResolvedModel {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: "MLX is not compiled in")
        }

        /// Without MLX there is nothing to run; resolution refuses first, so this engine is never used.
        ///
        /// - Parameter directory: The model directory.
        /// - Returns: An engine that refuses every request.
        static func makeEngine(for directory: URL) -> any PromptEngine {
            UnavailableEngine()
        }
    #endif

    /// Subdirectories of `directory` (or links to them) that hold a `config.json`, sorted.
    static func models(in directory: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
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

    /// The models directory, the declared models, the window, the executor, and whether MLX is compiled in.
    public func settings(in config: Config.Resolved, home: Home) -> WispCore.JSONValue {
        .object([
            "modelsDirectory": .string(Self.modelsDirectory(config: config, home: home).path),
            "compiledIn": .bool(Self.isCompiledIn),
            "contextLength": config.mlxContextLength.map { .int($0) } ?? .string("sized per model (ADR 0052)"),
            "executor": .string(config.mlxExecutor.rawValue),
            "models": .object(
                Dictionary(
                    uniqueKeysWithValues: config.mlxModels.map { name, capabilities in
                        (name, WispCore.JSONValue.object(["capabilities": .array(capabilities.map { .string($0) })]))
                    })),
        ])
    }
}
