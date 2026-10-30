import Foundation

extension ModelActions {
    /// How an uninstall asks the person: whether anyone can answer, where lines go, and the typed confirmation.
    public struct UninstallDialog {
        /// Whether a person can type here.
        public var interactive: Bool
        /// Shows a line: the plan, then each step as it is done.
        public var show: (String) -> Void
        /// Asks the person to type, with the prompt given; nil when nothing was typed.
        public var typed: (String) async -> String?

        /// Creates a dialog.
        public init(
            interactive: Bool, show: @escaping (String) -> Void, typed: @escaping (String) async -> String?
        ) {
            self.interactive = interactive
            self.show = show
            self.typed = typed
        }
    }

    /// Why an uninstall did not go ahead.
    public enum UninstallFailure: Error, CustomStringConvertible, Equatable {
        /// No one can type the confirmation here, and `--yes` was not given.
        case notInteractive(String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .notInteractive(let model):
                "nothing removed: uninstalling \(model) asks you to type its name, so run it in a terminal, or pass "
                    + "--yes"
            }
        }
    }

    /// Removes a model where wisp knows its files, and clears its entries in `config.json`
    /// ([ADR 0075](../../../../docs/decisions/0075-wisp-models-uninstall.md)): shows what goes (the backend's plan, the
    /// bytes, the settings cleared, and a warning when it is the default), asks the person to type its name unless
    /// `yes`, then removes it, recorded as `model.uninstall` and a `config.change` per setting. The person's alone.
    ///
    /// - Parameters:
    ///   - name: The model, as `--model` spells it.
    ///   - purgeCache: Whether an MLX model's folder in the Hugging Face cache goes too.
    ///   - yes: Whether to go ahead without the typed confirmation.
    ///   - dialog: How the person is shown the plan and asked.
    /// - Returns: Whether the model was removed: false when the person did not confirm.
    /// - Throws: `Failure.notForTheModel` from the tool; `ModelSelection.Failure` for a name that does not parse;
    ///   `ModelRemoval.Failure` for a model wisp does not keep or that is not installed; `UninstallFailure` with no one
    ///   to confirm; a step's or the configuration's failure.
    public func uninstall(_ name: String, purgeCache: Bool, yes: Bool, dialog: UninstallDialog) async throws -> Bool {
        guard face != .tool else { throw Failure.notForTheModel("uninstall") }
        let selection = try ModelSelection(parsing: name)
        guard case .local(let scheme, let local) = selection else {
            throw ModelRemoval.Failure.notWisps(
                model: selection.description, reason: "Apple's models are part of macOS; there is nothing to remove")
        }
        guard let backend = ModelBackends.backend(for: scheme) else { throw Failure.unknownModel(name) }
        let config = session.config
        let home = session.home
        let plan = try await backend.removal(local, config: config, home: home, purgeCache: purgeCache)
        let data = FileManager.default.contents(atPath: home.configFile.path)
        let settings = try Self.settings(of: local, backend: backend, config: config, home: home, in: data)
        let disabled = selection.isAmong(session.disabledModels.all, config: config, home: home)
        let configured = try ConfigEdit.current("model", in: data)?.stringValue.map { try ModelSelection(parsing: $0) }
        let isDefault = selection.names(configured ?? .default, config: config, home: home)

        dialog.show("uninstalling \(plan.model) removes:")
        for step in plan.steps { dialog.show("  \(step.described)") }
        let cleared = settings.map { $0.joined(separator: ".") } + (disabled ? ["its models.disabled entry"] : [])
        if !cleared.isEmpty { dialog.show("  from config.json: \(cleared.joined(separator: ", "))") }
        dialog.show(plan.bytes > 0 ? "  freeing \(ModelRemoval.formatted(plan.bytes))" : "  freeing no space")
        for line in plan.kept { dialog.show(line) }
        if isDefault {
            dialog.show(
                "warning: \(plan.model) is the default model (model in config.json); wisp falls back to system until "
                    + "you choose another with wisp config set model")
        }

        func record(_ outcome: String, reason: String?) {
            audit.record(
                .modelUninstall,
                details: [
                    "model": .string(plan.model), "steps": .array(plan.steps.map { .string($0.described) }),
                    "bytes": .int(Int(plan.bytes)), "purgeCache": .bool(purgeCache),
                    "settings": .array(cleared.map { .string($0) }), "default": .bool(isDefault),
                    "outcome": .string(outcome), "reason": reason.map { .string($0) } ?? .null,
                    "source": .string(face.rawValue),
                ])
        }
        if !yes {
            guard dialog.interactive else {
                record("declined", reason: "no terminal to confirm, and --yes not given")
                throw UninstallFailure.notInteractive(plan.model)
            }
            let answer = await dialog.typed("Type \(name) to remove it; anything else leaves it")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let answer, answer == name || answer == plan.model || answer == local else {
                record("declined", reason: "the name was not typed")
                dialog.show("left \(plan.model) as it was")
                return false
            }
        }
        do {
            try await plan.perform(ollama: config.ollama, report: { dialog.show($0) })
            for keys in settings {
                let current = FileManager.default.contents(atPath: home.configFile.path)
                let outcome = try ConfigEdit.set(keys: keys, to: nil, in: current)
                try ConfigEdit.write(outcome, to: home.configFile)
                audit.record(
                    .configChange,
                    details: AuditEvent.Details.configChange(outcome, source: face.rawValue, approval: nil))
                dialog.show("cleared \(keys.joined(separator: ".")) from config.json")
            }
            if disabled {
                try session.setDisabled(selection, false, source: face.rawValue, log: audit)
                dialog.show("cleared \(plan.model) from models.disabled")
            }
        } catch {
            record("failed", reason: "\(error)")
            throw error
        }
        record("removed", reason: nil)
        // wisp's own llama.cpp server reads its models when it starts, so it starts again without the link.
        if scheme == OpenAICompatibleDialect.llamaCpp.scheme, config.llamacpp.server == .wisp {
            LlamaCppAgent.follow(
                .models(plan.model), server: .wisp, control: LlamaCppAgent.control(home: home), audit: audit,
                source: face.rawValue, say: { dialog.show($0) })
        }
        return true
    }

    /// The model's own settings `config.json` holds, under any of its spellings: `<scheme>.models.<name>` (Ollama's
    /// with and without `:latest`), and an MLX declaration.
    ///
    /// - Parameters:
    ///   - name: The part after the scheme.
    ///   - backend: Its backend.
    ///   - config: The effective configuration.
    ///   - home: wisp's home.
    ///   - data: The file's contents.
    /// - Returns: Each setting's keys.
    /// - Throws: `ConfigEdit.Failure.unreadableFile`.
    static func settings(
        of name: String, backend: any ModelBackend, config: Config.Resolved, home: Home, in data: Data?
    ) throws -> [[String]] {
        let canonical = backend.canonicalName(name, config: config, home: home)
        var spellings = [name, canonical]
        if backend.scheme == "ollama" { spellings += OllamaSettings.keys(for: canonical) }
        var candidates = spellings.map { [backend.scheme, "models", $0] }
        if let declared = backend.declarationKeys(for: name) { candidates.append(declared) }
        var found: [[String]] = []
        for keys in candidates where !found.contains(keys) {
            if try ConfigEdit.current(keys: keys, in: data) != nil { found.append(keys) }
        }
        return found
    }
}
