import Foundation
import FoundationModels
import Synchronization

/// The models the operator turned off (`models.disabled`, [ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md)),
/// as a session holds them: read from the configuration when the session begins, and changed at once when the
/// person enables or disables a model from this session's chat, so `/model` and Tab follow the change without a
/// restart. Other processes see a change from their next session, as every configuration change.
public final class DisabledModels: Sendable {
    /// The models, in the file's order.
    private let models: Mutex<[ModelSelection]>

    /// Creates the set.
    ///
    /// - Parameter models: The disabled models.
    public init(_ models: [ModelSelection] = []) {
        self.models = Mutex(models)
    }

    /// Every disabled model.
    public var all: [ModelSelection] { models.withLock { $0 } }

    /// Whether `selection` is disabled.
    public func contains(_ selection: ModelSelection) -> Bool {
        models.withLock { $0.contains(selection) }
    }

    /// Replaces the set, after the configuration file changed.
    public func replace(with selections: [ModelSelection]) {
        models.withLock { $0 = selections }
    }

    /// Refuses a disabled model.
    ///
    /// - Throws: `ModelSelection.Failure.disabled`.
    public func check(_ selection: ModelSelection) throws {
        if contains(selection) { throw ModelSelection.Failure.disabled(model: selection.description) }
    }
}

/// Chat started on another model because the configured one was unavailable (ADR 0056): what it wanted, why it
/// could not have it, and what it took.
public struct ModelFallback: Equatable, Sendable {
    /// The configured model.
    public var model: ModelSelection
    /// Why it could not be used, as its backend said.
    public var reason: String
    /// The model chat started on instead.
    public var fallback: ModelSelection

    /// Creates a record.
    public init(model: ModelSelection, reason: String, fallback: ModelSelection = .system) {
        self.model = model
        self.reason = reason
        self.fallback = fallback
    }

    /// The note chat shows before the first prompt, such as `ollama:granite4.1:8b is unavailable (no Ollama server
    /// at …); using system. /model ollama:granite4.1:8b once Ollama is running`.
    public var message: String {
        let when = model.backend == "ollama" ? "once Ollama is running" : "once it is available"
        let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return "\(model) is unavailable (\(reason)); using \(fallback). /model \(model) \(when)"
    }

    /// The fallback for a failure to open the configured model, or nil when chat must fail as before: the model was
    /// named for this run (`--model`), it is the fallback itself, or the failure is not about the model's being
    /// there (a missing capability is the configuration's to fix, not a reason to change models).
    ///
    /// - Parameters:
    ///   - failure: Why the model could not be opened.
    ///   - configured: The configured model.
    ///   - named: Whether the person named the model for this run.
    ///   - fallback: The model to fall back to.
    /// - Returns: The fallback, or nil.
    static func after(
        _ failure: ModelSelection.Failure, configured: ModelSelection, named: Bool, fallback: ModelSelection = .system
    ) -> ModelFallback? {
        guard !named, configured != fallback else { return nil }
        switch failure {
        case .unavailable(_, let reason): return ModelFallback(model: configured, reason: reason, fallback: fallback)
        case .unknownBackend: return ModelFallback(model: configured, reason: "\(failure)", fallback: fallback)
        default: return nil
        }
    }
}

extension Session {
    /// Opens chat's conversation on the configured model; when that model is unavailable as chat starts, and the
    /// person did not name it with `--model`, on `system` instead, recording `model.fallback`, so the person
    /// reaches the prompt and can `/model` back once it is there (ADR 0056). `respond` and `wisp mcp` never fall
    /// back: a script or a calling agent chooses its own model.
    ///
    /// - Parameters:
    ///   - host: The face's effects.
    ///   - transcript: A saved conversation to resume, or nil to start fresh.
    ///   - links: The store links saved with `transcript`, if any.
    ///   - observer: A sink that also sees every event of the conversation.
    ///   - resolveFallback: Resolves the fallback model; nil resolves it as the session would. Tests pass a scripted
    ///     one.
    /// - Returns: The agent, and the fallback when there was one.
    /// - Throws: The configured model's `ModelSelection.Failure` when there is no fallback, or the fallback is
    ///   unavailable or disabled too.
    public func openChatAgent(
        host: SessionHost, transcript: Transcript? = nil, links: ThreadRecord.Snapshot? = nil,
        observer: (any AuditSink)? = nil,
        resolveFallback: ((ModelSelection) throws -> ResolvedModel)? = nil
    ) throws -> (agent: Agent, fallback: ModelFallback?) {
        let resolve = resolveFallback ?? { [config, home] in try $0.resolve(config: config, home: home) }
        do {
            return (try openAgent(host: host, transcript: transcript, links: links, observer: observer), nil)
        } catch let failure as ModelSelection.Failure {
            guard let fallback = ModelFallback.after(failure, configured: config.model, named: request.model != nil),
                !disabledModels.contains(fallback.fallback),
                let resolved = try? resolve(fallback.fallback)
            else { throw failure }
            let thread = try WispThread.setUp(
                session: self, audit: audit, host: host, prompting: prompting, toolNames: toolNames,
                model: fallback.fallback, observer: observer)
            thread.audit.record(.modelFallback, details: AuditEvent.Details.modelFallback(fallback))
            return (try thread.openAgent(on: resolved, transcript: transcript, links: links), fallback)
        }
    }
}

extension Session {
    /// Turns models on and off for the person (`/models enable|disable`, `wisp models enable|disable`, `wisp-tui`'s
    /// picker; ADR 0056): changes `models.disabled` in `config.json` through `ConfigEdit`, recorded as
    /// `config.change`, and this session's `disabledModels` with it, so the change holds in this chat at once. A
    /// model being enabled that is a complete snapshot in the Hugging Face cache and not linked is linked, fetching
    /// nothing, and recorded as `model.pull` with outcome `linked`. The default cannot be disabled; nothing changes
    /// when one of the models cannot be. With `checking`, a model being enabled whose capabilities are the
    /// configuration's to declare and are undeclared is linked but left as it is: `checkModels`, which the face runs
    /// next, enables it or keeps it disabled by what the model answers (ADR 0056, refined 2026-10-04).
    ///
    /// - Parameters:
    ///   - enable: The models to turn on, as `--model` spells them.
    ///   - disable: The models to turn off.
    ///   - source: `chat` or `cli`, for the audit.
    ///   - checking: Whether the caller checks the enabled models next, so a model to be checked waits for it.
    /// - Returns: A line per model saying what happened, for the person.
    /// - Throws: `ModelSelection.Failure` for a name that does not parse or the default being disabled,
    ///   `ConfigEdit.Failure` when the file would not load, a backend's failure to link, or the file system's.
    public func setModels(
        enable: [String], disable: [String], source: String, checking: Bool = false
    ) throws -> [String] {
        let enabling = try enable.map { try ModelSelection(parsing: $0) }
        let disabling = try disable.map { try ModelSelection(parsing: $0) }.filter { !enabling.contains($0) }
        let data = FileManager.default.contents(atPath: home.configFile.path)
        let before =
            try ConfigEdit.current("models.disabled", in: data)?.arrayValue?.compactMap { value in
                value.stringValue.flatMap { try? ModelSelection(parsing: $0) }
            } ?? []
        let waiting = checking ? try enabling.filter { try needsCheck($0, in: data) } : []
        var after = before.filter { !enabling.contains($0) || waiting.contains($0) }
        for model in disabling where !after.contains(model) { after.append(model) }
        let configured = try ConfigEdit.current("model", in: data)?.stringValue.map { try ModelSelection(parsing: $0) }
        if let model = disabling.first(where: { $0 == configured ?? .default }) {
            throw ModelSelection.Failure.defaultDisabled(model: model.description)
        }
        var lines: [String] = []
        for model in enabling {
            guard case .local(let scheme, let name) = model, let backend = ModelBackends.backend(for: scheme),
                backend.unlinked(config: config, home: home).contains(where: { $0.selection == model })
            else { continue }
            let started = ContinuousClock.now
            let link = try backend.link(name, config: config, home: home)
            let elapsed = ContinuousClock.now - started
            audit.record(
                .modelPull,
                details: AuditEvent.Details.modelPull(
                    model: model.description, repository: link.repository, directory: link.destination,
                    cache: link.snapshot, files: link.files, bytes: link.bytes, reused: link.files, fetchedFiles: 0,
                    fetched: 0, link: link.outcome, outcome: "linked", reason: nil,
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            lines.append(
                "linked \(model): \(link.destination) → \(link.snapshot) in the Hugging Face cache; nothing was "
                    + "downloaded")
        }
        if after != before {
            let outcome =
                after.isEmpty
                ? try ConfigEdit.unset("models.disabled", in: data)
                : try ConfigEdit.set(
                    "models.disabled", to: ChatChoice.answer(values: after.map(\.description)), in: data)
            try ConfigEdit.write(outcome, to: home.configFile)
            audit.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: source))
        }
        disabledModels.replace(with: after)
        for model in enabling where !waiting.contains(model) {
            lines.append(before.contains(model) ? "enabled \(model)" : "\(model) is enabled")
        }
        for model in disabling {
            lines.append(
                before.contains(model)
                    ? "\(model) is disabled" : "disabled \(model): hidden from /model and refused until enabled")
        }
        return lines
    }

    /// Whether enabling `selection` waits for a check: its backend leaves its capabilities to `config.json`, and the
    /// file declares none.
    ///
    /// - Parameters:
    ///   - selection: The model.
    ///   - data: The file's contents.
    /// - Returns: Whether it waits.
    /// - Throws: `ConfigEdit.Failure.unreadableFile`.
    func needsCheck(_ selection: ModelSelection, in data: Data?) throws -> Bool {
        guard case .local(let scheme, let name) = selection, let backend = ModelBackends.backend(for: scheme),
            let keys = backend.declarationKeys(for: name)
        else { return false }
        return try ConfigEdit.current(keys: keys, in: data)?.objectValue?["capabilities"] == nil
    }

    /// Turns one model on or off in `models.disabled`, as `setModels` does, writing and auditing only a change.
    ///
    /// - Parameters:
    ///   - selection: The model.
    ///   - disabled: Whether it is to be disabled.
    ///   - source: `chat` or `cli`, for the audit.
    /// - Throws: `ModelSelection.Failure.defaultDisabled` for the default, `ConfigEdit.Failure`, or the file
    ///   system's.
    func setDisabled(_ selection: ModelSelection, _ disabled: Bool, source: String) throws {
        let data = FileManager.default.contents(atPath: home.configFile.path)
        let before =
            try ConfigEdit.current("models.disabled", in: data)?.arrayValue?.compactMap { value in
                value.stringValue.flatMap { try? ModelSelection(parsing: $0) }
            } ?? []
        var after = before.filter { $0 != selection }
        if disabled { after.append(selection) }
        if disabled {
            let configured = try ConfigEdit.current("model", in: data)?.stringValue.map {
                try ModelSelection(parsing: $0)
            }
            if selection == configured ?? .default {
                throw ModelSelection.Failure.defaultDisabled(model: selection.description)
            }
        }
        guard Set(after) != Set(before) else {
            disabledModels.replace(with: before)
            return
        }
        let outcome =
            after.isEmpty
            ? try ConfigEdit.unset("models.disabled", in: data)
            : try ConfigEdit.set("models.disabled", to: ChatChoice.answer(values: after.map(\.description)), in: data)
        try ConfigEdit.write(outcome, to: home.configFile)
        audit.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: source))
        disabledModels.replace(with: after)
    }
}
