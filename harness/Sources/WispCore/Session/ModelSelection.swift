import Foundation
import FoundationModels

/// Which language model a session runs on.
///
/// Parsed from `config.json`'s `model` or `--model`: `system` (default), `private-cloud`, or
/// `<backend>:<name>` for a model served by a local runtime registered in `ModelBackends`
/// (`ollama:`, and whatever the executable adds; ADR 0016, ADR 0019). Custom adapters are obsoleted
/// in macOS 27.
public enum ModelSelection: Equatable, Sendable, CustomStringConvertible, Codable {
    /// Apple's on-device model. Nothing leaves the machine.
    case system
    /// Apple's Private Cloud Compute model. Requests leave the machine under Apple's privacy guarantees.
    case privateCloud
    /// A model served by a local runtime, by the runtime's scheme and the name it knows the model under.
    case local(backend: String, name: String)

    /// `ollama:<name>`, the built-in local backend.
    public static func ollama(_ name: String) -> ModelSelection { .local(backend: "ollama", name: name) }

    /// The default.
    public static let `default` = ModelSelection.system

    /// Parses `system`, `private-cloud` (`pcc` is accepted as a short alias), or `<backend>:<name>`.
    /// The backend is checked against the registry when the model is resolved, not here, so a config
    /// file can name a backend the running binary lacks and get a clear error then.
    ///
    /// - Throws: `Failure.unknownModel` for anything else, including an empty name.
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "system", "": self = .system
        case "private-cloud", "pcc": self = .privateCloud
        case let other:
            guard let colon = other.firstIndex(of: ":") else { throw Failure.unknownModel(other) }
            let backend = String(other[..<colon])
            let name = String(other[other.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !backend.isEmpty, backend.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                !name.isEmpty, !name.contains(where: \.isWhitespace)
            else { throw Failure.unknownModel(other) }
            self = .local(backend: backend.lowercased(), name: name)
        }
    }

    /// The canonical spelling, as accepted by `init(parsing:)`.
    public var description: String {
        switch self {
        case .system: "system"
        case .privateCloud: "private-cloud"
        case .local(let backend, let name): "\(backend):\(name)"
        }
    }

    /// The scheme of a local selection, `system`, or `private-cloud`: what the audit calls the backend.
    public var backend: String {
        switch self {
        case .system: "system"
        case .privateCloud: "private-cloud"
        case .local(let backend, _): backend
        }
    }

    /// Decodes from the canonical spelling.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: text)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    /// Encodes as the canonical spelling.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Whether prompts and transcripts are sent off the machine.
    public var leavesDevice: Bool {
        if case .privateCloud = self { return true }
        return false
    }

    /// Why a selection could not be used.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Not one of the known spellings.
        case unknownModel(String)
        /// The model exists but cannot serve requests right now.
        case unavailable(model: String, reason: String)
        /// The selection names a backend this binary does not have.
        case unknownBackend(String, registered: [String])
        /// The model does not declare a capability the request needs.
        case unsupportedCapability(model: String, capability: String, declaredBy: CapabilitySource, hint: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unknownModel(let text):
                "unknown model '\(text)': use system, private-cloud (alias pcc), or <backend>:<name>"
            case .unavailable(let model, let reason): "model '\(model)' is unavailable: \(reason)"
            case .unknownBackend(let scheme, let registered):
                "no model backend '\(scheme)' in this build; available: \(registered.joined(separator: ", "))"
            case .unsupportedCapability(let model, let capability, let declaredBy, let hint):
                "model '\(model)' does not support \(capability) (capabilities \(declaredBy.rawValue)); \(hint)"
            }
        }
    }

    /// A sentence a user can act on for a system-model unavailability reason.
    public static func explain(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled; turn it on in System Settings and wait for the model to download"
        case .modelNotReady:
            "the model is still downloading or preparing; try again in a few minutes"
        case .deviceNotEligible:
            "this Mac cannot run the on-device model (Apple silicon is required)"
        @unknown default:
            "unavailable (\(reason))"
        }
    }

    /// Why an unentitled binary cannot use Private Cloud Compute.
    public static let missingPrivateCloudEntitlement =
        "this binary lacks the \(Entitlements.privateCloudCompute) entitlement, which Apple grants to App Store apps "
        + "on request and which an ad-hoc signed command-line tool cannot carry; use system or a local backend"

    /// A sentence for a Private Cloud Compute unavailability reason.
    public static func explain(_ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "this Mac is not eligible for Private Cloud Compute"
        case .systemNotReady: "Private Cloud Compute is not ready; try again later"
        @unknown default: "unavailable (\(reason))"
        }
    }

    /// Checks availability and returns a session maker for this model, with its capabilities declared.
    ///
    /// - Parameters:
    ///   - config: The effective configuration; local backends read their settings from it.
    ///   - home: wisp's home, for backends that keep assets under it.
    ///   - entitlements: This process's entitlements; Private Cloud Compute needs one.
    /// - Returns: A session maker over the checked model.
    /// - Throws: `Failure.unavailable`, `Failure.unknownBackend`.
    public func resolve(
        config: Config.Resolved = Config().resolved, home: Home = Home.resolve(),
        entitlements: Entitlements = .process
    ) throws -> ResolvedModel {
        switch self {
        case .local(let scheme, let name):
            guard let backend = ModelBackends.backend(for: scheme) else {
                throw Failure.unknownBackend(scheme, registered: ModelBackends.schemes)
            }
            return try backend.resolve(name, config: config, home: home)
        case .system:
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = model.availability {
                throw Failure.unavailable(model: description, reason: Self.explain(reason))
            }
            return ResolvedModel(selection: self, system: model)
        case .privateCloud:
            // The framework's availability check does not cover the entitlement; a request without it
            // fails inside ModelManagerServices with an opaque error (probed 2026-09-20, docs/backends.md).
            guard entitlements.has(Entitlements.privateCloudCompute) else {
                throw Failure.unavailable(model: description, reason: Self.missingPrivateCloudEntitlement)
            }
            let model = PrivateCloudComputeLanguageModel()
            if case .unavailable(let reason) = model.availability {
                throw Failure.unavailable(model: description, reason: Self.explain(reason))
            }
            return ResolvedModel(selection: self, privateCloud: model)
        }
    }
}

/// A checked model that can make sessions. Erases the concrete `LanguageModel` type
/// so `Agent` need not be generic.
public struct ResolvedModel: Sendable {
    /// What was selected.
    public let selection: ModelSelection
    /// What the model declares it can do. Checked before a session is opened; never inferred.
    public let capabilities: LanguageModelCapabilities
    /// Who declared the capabilities.
    public let capabilitySource: CapabilitySource
    /// The asset behind a local model (a path, a runtime's model id), for the audit; nil for Apple's.
    public let asset: String?
    /// The context window in tokens when the model or its settings state it; nil when only an
    /// overflow error will tell. `Agent` condenses ahead of it from the usage each turn reports.
    public let contextSize: Int?
    /// Why the window is what it is, when the backend chose it (ADR 0043); nil when it is the model's own.
    public let contextNote: String?
    private let makeFromInstructions: @Sendable ([any Tool], String) -> LanguageModelSession
    private let makeFromTranscript: @Sendable ([any Tool], Transcript) -> LanguageModelSession
    private let countTokens: (@Sendable (Transcript) async throws -> Int)?
    private let reportedInput: (@Sendable () -> Int?)?

    /// Wraps the on-device model.
    init(selection: ModelSelection, system model: SystemLanguageModel) {
        self.selection = selection
        capabilities = model.capabilities
        capabilitySource = .framework
        asset = nil
        contextSize = model.contextSize
        contextNote = nil
        makeFromInstructions = { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        makeFromTranscript = { tools, transcript in
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        countTokens = { transcript in try await model.tokenCount(for: transcript) }
        reportedInput = nil
    }

    /// Reads a context window that only an async, throwing call can give, without ever failing resolution.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait for the reading before giving up.
    ///   - read: The reading, such as Private Cloud Compute's `contextSize`.
    /// - Returns: The window, or nil when the reading throws, times out, or is not positive.
    static func readWindow(
        timeout: Duration = .seconds(5), _ read: @escaping @Sendable () async throws -> Int
    ) async -> Int? {
        // `Timeout.run`, not a task group: a group waits for a reading that ignores cancellation, so a
        // hung framework call would hang resolution with it.
        let window = try? await Timeout.run(timeout, read)
        return window.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Wraps Private Cloud Compute, which offers no token counting.
    init(selection: ModelSelection, privateCloud model: PrivateCloudComputeLanguageModel) {
        self.selection = selection
        capabilities = model.capabilities
        capabilitySource = .framework
        asset = nil
        // An async, throwing property on this model; nil (learned from the first overflow) if it fails.
        contextSize = (try? Blocking.run { await Self.readWindow { try await model.contextSize } }) ?? nil
        contextNote = nil
        makeFromInstructions = { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        makeFromTranscript = { tools, transcript in
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        countTokens = nil
        reportedInput = nil
    }

    /// Wraps any `LanguageModel`, such as one backed by a wisp-supplied executor over a local runtime.
    /// Token counting is not part of the protocol, so `tokenCount(for:)` returns nil.
    ///
    /// - Parameters:
    ///   - selection: What to report as the selection in audit events.
    ///   - model: The model; its executor does the generation. Its `capabilities` are what it declares.
    ///   - capabilitySource: Who declared them; `.runtime` by default.
    ///   - asset: The asset behind it, for the audit.
    ///   - contextSize: The window the runtime was asked for, when known.
    ///   - countTokens: Counts a transcript's tokens, for a model that can; nil when it cannot.
    ///   - contextNote: Why the window is `contextSize`, when the backend chose it (ADR 0043).
    public init(
        selection: ModelSelection, custom model: some LanguageModel, capabilitySource: CapabilitySource = .runtime,
        asset: String? = nil, contextSize: Int? = nil,
        countTokens: (@Sendable (Transcript) async throws -> Int)? = nil, contextNote: String? = nil
    ) {
        self.selection = selection
        capabilities = model.capabilities
        self.capabilitySource = capabilitySource
        self.asset = asset
        self.contextSize = contextSize
        makeFromInstructions = { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        makeFromTranscript = { tools, transcript in
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        self.countTokens = countTokens
        self.contextNote = contextNote
        if let reporting = model as? any UsageReporting {
            reportedInput = { reporting.lastInputTokens }
        } else {
            reportedInput = nil
        }
    }

    /// A new session with instructions.
    public func session(tools: [any Tool], instructions: String) -> LanguageModelSession {
        makeFromInstructions(tools, instructions)
    }

    /// A session continuing a transcript.
    public func session(tools: [any Tool], transcript: Transcript) -> LanguageModelSession {
        makeFromTranscript(tools, transcript)
    }

    /// The names of the declared capabilities, for the audit and the models listing.
    public var capabilityNames: [String] {
        var names: [String] = []
        if capabilities.contains(.toolCalling) { names.append("toolCalling") }
        if capabilities.contains(.guidedGeneration) { names.append("guidedGeneration") }
        if capabilities.contains(.reasoning) { names.append("reasoning") }
        if capabilities.contains(.vision) { names.append("vision") }
        return names
    }

    /// Refuses a request for schema-shaped output when the model does not declare guided generation.
    ///
    /// - Throws: `ModelSelection.Failure.unsupportedCapability` with a hint for the declaring source.
    public func checkGuidedGeneration() throws {
        guard !capabilities.contains(.guidedGeneration) else { return }
        let hint =
            switch capabilitySource {
            case .framework: "choose another model"
            case .runtime:
                "the runtime reports this model cannot follow a schema; drop the schema or choose another model"
            case .configuration:
                "add \"guidedGeneration\" to this model's capabilities in config.json if it really can, or drop the schema"
            case .undeclared: "declare the model's capabilities in config.json, or drop the schema"
            }
        throw ModelSelection.Failure.unsupportedCapability(
            model: selection.description, capability: "guided generation", declaredBy: capabilitySource, hint: hint)
    }

    /// Refuses a request that needs what the model did not declare, before any generation.
    ///
    /// - Parameter tools: The tools the conversation wants; empty needs nothing.
    /// - Throws: `ModelSelection.Failure.unsupportedCapability` with a hint that names the fix.
    public func check(tools: [any Tool]) throws {
        guard !tools.isEmpty, !capabilities.contains(.toolCalling) else { return }
        let hint: String
        switch capabilitySource {
        case .framework: hint = "choose another model"
        case .runtime:
            hint =
                "the runtime reports this model cannot call tools; open the conversation with no tools or choose a tool-capable model"
        case .configuration:
            hint =
                "add \"toolCalling\" to this model's capabilities in config.json if it really supports tools, or open the conversation with no tools"
        case .undeclared:
            hint =
                "declare its capabilities in config.json, or open the conversation with no tools (--no-tools, or tools: [] over MCP)"
        }
        throw ModelSelection.Failure.unsupportedCapability(
            model: selection.description, capability: "tool calling", declaredBy: capabilitySource, hint: hint)
    }

    /// Input tokens of the last request as the runtime reported them, for models whose executor keeps
    /// the figure (`UsageReporting`); nil otherwise or before the first request.
    public func reportedInputTokens() -> Int? { reportedInput?() ?? nil }

    /// Tokens a transcript occupies, or nil when this model cannot count.
    ///
    /// - Throws: Framework errors if counting fails.
    public func tokenCount(for transcript: Transcript) async throws -> Int? {
        try await countTokens?(transcript)
    }
}
