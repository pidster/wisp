import Foundation
import FoundationModels
import Synchronization

/// One model an installed runtime can serve, for `wisp models`.
public struct InstalledModel: Equatable, Sendable {
    /// The selection that names it, such as `ollama:qwen3-coder:latest`.
    public var selection: ModelSelection
    /// Size, parameter count, or whatever the runtime knows, as one line, for a picker's detail.
    public var detail: String
    /// The parameter count as the runtime reports it, such as `8.8B`; nil when it does not.
    public var parameters: String?
    /// Bytes the weights take on disk; nil when unknown.
    public var bytes: Int?
    /// The architecture and quantisation, such as `granite Q4_K_M` or `qwen3 4-bit`; nil when unknown.
    public var format: String?
    /// Where an MLX model lives; nil for runtimes that keep their own models.
    public var location: ModelLocation?
    /// The day wisp last checked the capabilities the configuration declares for it (`YYYY-MM-DD`); nil when it
    /// has not.
    public var verified: String?

    /// Creates a record.
    public init(
        selection: ModelSelection, detail: String, parameters: String? = nil, bytes: Int? = nil,
        format: String? = nil, location: ModelLocation? = nil, verified: String? = nil
    ) {
        self.selection = selection
        self.detail = detail
        self.parameters = parameters
        self.bytes = bytes
        self.format = format
        self.location = location
        self.verified = verified
    }
}

/// Where a model a backend lists lives on this Mac (ADR 0052, 0056).
public enum ModelLocation: String, Equatable, Sendable, CaseIterable {
    /// A directory of its own in the backend's models folder.
    case modelsFolder
    /// The Hugging Face cache, linked from the models folder.
    case hubCache
    /// The Hugging Face cache, complete, and not linked: enabling it links it.
    case hubCacheNotLinked

    /// The words the listing shows.
    public var label: String {
        switch self {
        case .modelsFolder: "models folder"
        case .hubCache: "HF cache"
        case .hubCacheNotLinked: "HF cache, not linked"
        }
    }
}

/// What linking a cached model did, for the person and the `model.pull` event it is recorded as (ADR 0056).
public struct ModelLink: Equatable, Sendable {
    /// The selection it now resolves as.
    public var selection: ModelSelection
    /// The repository, such as `mlx-community/Qwen3-4B-4bit`.
    public var repository: String
    /// The cache's snapshot the link points at.
    public var snapshot: String
    /// The link's path in the models folder.
    public var destination: String
    /// Files in the snapshot.
    public var files: Int
    /// Their bytes.
    public var bytes: Int
    /// What happened at the link's path (`ModelPull.LinkOutcome`'s words).
    public var outcome: String

    /// Creates a record.
    public init(
        selection: ModelSelection, repository: String, snapshot: String, destination: String, files: Int, bytes: Int,
        outcome: String
    ) {
        self.selection = selection
        self.repository = repository
        self.snapshot = snapshot
        self.destination = destination
        self.files = files
        self.bytes = bytes
        self.outcome = outcome
    }
}

/// A runtime on this Mac that serves models under one scheme (`ollama:`, `coreai:`, `mlx:`), plugged
/// into `LanguageModelSession` through a `LanguageModel` ([ADR 0019](../../../../docs/decisions/0019-model-backends.md)).
///
/// A backend resolves a name into a checked model with declared capabilities; it never downloads.
/// Acquisition of assets is the operator's job, and a missing asset is a clear `unavailable` failure.
public protocol ModelBackend: Sendable {
    /// The prefix before the colon in a selection.
    var scheme: String { get }
    /// Checks the named model can serve and returns it with its capabilities declared.
    ///
    /// - Parameters:
    ///   - name: The part after the scheme.
    ///   - config: The effective configuration, for the backend's settings.
    ///   - home: wisp's home, for backends that keep assets under it.
    /// - Returns: The checked model with its declared capabilities.
    /// - Throws: `ModelSelection.Failure.unavailable` with an actionable reason.
    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel
    /// The models this runtime can serve right now.
    ///
    /// - Throws: A backend failure when the runtime cannot be asked.
    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel]
    /// This backend's effective settings, for `wisp config` and the `inspect` tool.
    func settings(in config: Config.Resolved, home: Home) -> JSONValue
    /// What `wisp doctor` should report about this runtime on this install, or nil for nothing beyond the
    /// configured-model check (MLX reports its Metal library).
    func doctorFinding() -> Doctor.Finding?
    /// Models this runtime could serve once linked, already on this Mac and needing no download (MLX's complete
    /// snapshots in the Hugging Face cache that the models folder does not name).
    func unlinked(config: Config.Resolved, home: Home) -> [InstalledModel]
    /// Links one of `unlinked`'s models so it resolves, fetching nothing (ADR 0056).
    ///
    /// - Throws: A backend failure when it cannot be linked.
    func link(_ name: String, config: Config.Resolved, home: Home) throws -> ModelLink
    /// Where `config.json` declares what `name` can do, when that is the operator's to declare rather than the
    /// runtime's to report (MLX: `mlx.models.<name>`, ADR 0019), so enabling the model checks its capabilities and
    /// records the ones that pass there (ADR 0056, refined 2026-10-04); nil when the runtime reports them.
    func declarationKeys(for name: String) -> [String]?
    /// `config` with `declaration` as `name`'s, as the configuration reads once the file holds it: how a check
    /// resolves the model with the capability it tries declared, and how a session applies what it recorded.
    func declaring(
        _ declaration: Config.MLXModelConfig, for name: String, in config: Config.Resolved
    )
        -> Config.Resolved
}

extension ModelBackend {
    /// No finding of its own: the configured-model check covers the backend.
    public func doctorFinding() -> Doctor.Finding? { nil }

    /// Nothing to link: the runtime keeps its own models.
    public func unlinked(config: Config.Resolved, home: Home) -> [InstalledModel] { [] }

    /// Refuses: the runtime keeps its own models.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable`.
    public func link(_ name: String, config: Config.Resolved, home: Home) throws -> ModelLink {
        throw ModelSelection.Failure.unavailable(
            model: "\(scheme):\(name)", reason: "\(scheme) keeps its own models; there is nothing to link")
    }

    /// None: the runtime reports what its models can do.
    public func declarationKeys(for name: String) -> [String]? { nil }

    /// `config` as it is: nothing is declared for a runtime that reports its models' capabilities.
    public func declaring(
        _ declaration: Config.MLXModelConfig, for name: String, in config: Config.Resolved
    )
        -> Config.Resolved
    { config }
}

/// The backends this process knows, by scheme. Ollama, llama.cpp, and LM Studio are built in, since they are HTTP
/// servers wisp needs no library to talk to (ADR 0016, ADR 0058); the executable registers the others at launch so
/// `WispCore` never links their runtimes.
public enum ModelBackends {
    private static let registry = Mutex<[String: any ModelBackend]>(
        [
            "ollama": OllamaBackend(), "llamacpp": OpenAICompatibleBackend(.llamaCpp),
            "lmstudio": OpenAICompatibleBackend(.lmStudio),
        ])

    /// Adds or replaces a backend under its scheme.
    public static func register(_ backend: any ModelBackend) {
        registry.withLock { $0[backend.scheme] = backend }
    }

    /// The backend for `scheme`, if registered.
    public static func backend(for scheme: String) -> (any ModelBackend)? {
        registry.withLock { $0[scheme] }
    }

    /// Every registered backend, by scheme.
    public static var all: [any ModelBackend] {
        registry.withLock { $0.values.sorted { $0.scheme < $1.scheme } }
    }

    /// The registered schemes, sorted.
    public static var schemes: [String] { all.map(\.scheme) }
}

/// Where a model's declared capabilities came from, so a refusal can say what to change.
public enum CapabilitySource: String, Sendable, Equatable {
    /// Apple's framework reports them for its own models.
    case framework
    /// The runtime reported them for this model (Ollama's show endpoint, a Core AI bundle).
    case runtime
    /// The operator declared them in `config.json`.
    case configuration
    /// Nothing declared them; the model is treated as text only.
    case undeclared
}
