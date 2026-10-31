import FoundationModels

/// The spellings of model capabilities in `config.json` and the audit, and their framework values.
///
/// A declared model's capabilities are written by name in `config.json` (`declared`), and the check on enabling a
/// model records what it found by the same names
/// ([ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md)); this one set of spellings keeps the
/// two, and the audit, from drifting apart.
public enum CapabilityName: String, CaseIterable, Sendable, Codable {
    /// May call wisp's tools.
    case toolCalling
    /// May produce schema-shaped output.
    case guidedGeneration
    /// Emits a reasoning trace.
    case reasoning
    /// Accepts images.
    case vision

    /// The framework's value.
    public var capability: LanguageModelCapabilities.Capability {
        switch self {
        case .toolCalling: .toolCalling
        case .guidedGeneration: .guidedGeneration
        case .reasoning: .reasoning
        case .vision: .vision
        }
    }

    /// Parses a list of names, refusing any that is not one of the four, so a misspelt capability in `config.json`
    /// fails when the model is resolved rather than silently leaving the capability out.
    ///
    /// - Parameters:
    ///   - names: The names as written in `config.json`.
    ///   - model: The model they are declared for, named in the error.
    /// - Returns: The framework capabilities, in the order given.
    /// - Throws: `ModelSelection.Failure.unavailable` naming the bad entry and the accepted spellings.
    public static func parse(_ names: [String], forModel model: String) throws -> [LanguageModelCapabilities.Capability]
    {
        try names.map { name in
            guard let known = CapabilityName(rawValue: name) else {
                throw ModelSelection.Failure.unavailable(
                    model: model,
                    reason:
                        "unknown capability '\(name)' in config.json; use \(allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            return known.capability
        }
    }
}
