import Foundation
import FoundationModels
import Synchronization

/// One model an installed runtime can serve, for `wisp models`.
public struct InstalledModel: Equatable, Sendable {
    /// The selection that names it, such as `ollama:qwen3-coder:latest`.
    public var selection: ModelSelection
    /// Size, parameter count, or whatever the runtime knows.
    public var detail: String

    /// Creates a record.
    public init(selection: ModelSelection, detail: String) {
        self.selection = selection
        self.detail = detail
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
}

extension ModelBackend {
    /// No finding of its own: the configured-model check covers the backend.
    public func doctorFinding() -> Doctor.Finding? { nil }
}

/// The backends this process knows, by scheme. Ollama is built in; the executable registers the
/// others at launch so `WispCore` never links their runtimes.
public enum ModelBackends {
    private static let registry = Mutex<[String: any ModelBackend]>(["ollama": OllamaBackend()])

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
