import Foundation

extension ModelActions {
    /// Forgets a model wisp remembers that no runtime serves now: it is removed from the registry, so it is no longer
    /// listed, and nothing on disk or in `config.json` changes ([ADR 0092](../../../../docs/decisions/0092-a-model-registry.md),
    /// decision 4). The person's alone; recorded as `model.forget`. A model that is served is refused, since the next
    /// listing would list it again; `uninstall` removes one.
    ///
    /// - Parameter name: The model, as `--model` spells it.
    /// - Returns: A line for the person.
    /// - Throws: `Failure.notForTheModel` from the tool, `ModelSelection.Failure` for a name that does not parse,
    ///   `Failure.unknownModel` for one not listed, `Failure.stillServed` for one a runtime serves, or
    ///   `ModelRegistry.Store.Failure` when the registry cannot be written.
    public func forget(_ name: String) async throws -> String {
        guard face != .tool else { throw Failure.notForTheModel(Action.forget.rawValue) }
        let entry = try await show(name, tools: [])
        let model = entry.selection.description
        guard !entry.available else { throw Failure.stillServed(model) }
        try ModelRegistry.Store(home: session.home).update { $0.forget(entry.selection) }
        audit.record(.modelForget, details: ["model": .string(model), "source": .string(face.rawValue)])
        return "forgot \(model): it is no longer listed; nothing on disk or in config.json changed"
    }
}
