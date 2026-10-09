import Foundation

/// The Hugging Face organisations `wisp models pull` fetches from without asking, `mlx.trustedPublishers`
/// ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md), amended 2026-10-09). Any organisation
/// can be pulled; one outside the list is put to the person first. `mlx-community`, the organisation that publishes
/// MLX conversions, is trusted whatever the list holds, so the list only ever adds to it.
public enum TrustedPublishers {
    /// The organisation trusted always, and the default list's only entry.
    public static let builtIn = "mlx-community"
    /// The setting's path.
    public static let setting = "mlx.trustedPublishers"
    /// The longest name Hugging Face accepts for an organisation or a repository.
    public static let maxNameLength = 96

    /// Whether `text` is a name Hugging Face accepts for an organisation or a repository, as `huggingface_hub`'s
    /// `validate_repo_id` checks one: 1 to 96 of `A`–`Z`, `a`–`z`, `0`–`9`, `.`, `_`, and `-`, starting and ending
    /// with a letter, a digit, or `_`, and with no `--` or `..`. Such a name is safe as a path component (no `/`, no
    /// leading dot) and in the cache's `models--<organisation>--<name>`, which `--` would make ambiguous.
    ///
    /// - Parameter text: The name.
    /// - Returns: Whether it is one.
    public static func isHubName(_ text: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let edges = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard (1...maxNameLength).contains(text.count), text.allSatisfy(allowed.contains),
            let first = text.first, let last = text.last, edges.contains(first), edges.contains(last)
        else { return false }
        return !text.contains("--") && !text.contains("..")
    }

    /// The trusted publishers a file's `mlx.trustedPublishers` gives: the list, or the default when unset, with
    /// `mlx-community` first whatever the list holds, and names Hugging Face would not accept left out (they could
    /// never match a repository the pull accepts).
    ///
    /// - Parameter configured: The file's list; nil when unset.
    /// - Returns: The publishers, each once, in order.
    public static func resolve(_ configured: [String]?) -> [String] {
        var publishers = [builtIn]
        for name in configured ?? [] where isHubName(name) && !publishers.contains(name) {
            publishers.append(name)
        }
        return publishers
    }

    /// Whether `publisher` is trusted under `config`. Names are compared exactly, case included, so a spelling the
    /// list does not hold is asked about rather than trusted.
    ///
    /// - Parameters:
    ///   - publisher: The organisation, as the repository names it.
    ///   - config: The resolved configuration.
    /// - Returns: Whether it is trusted.
    public static func trusts(_ publisher: String, config: Config.Resolved) -> Bool {
        publisher == builtIn || config.mlxTrustedPublishers.contains(publisher)
    }
}

extension Session {
    /// Adds `publisher` to `mlx.trustedPublishers` in `config.json` through `ConfigEdit`, recorded as
    /// `config.change`, when the person chose to trust it from now on (ADR 0052, amended 2026-10-09). An unset list
    /// starts from its default, so `mlx-community` stays named in the file; a publisher already trusted changes
    /// nothing.
    ///
    /// - Parameters:
    ///   - publisher: The organisation.
    ///   - source: `chat` or `cli`, for the audit.
    /// - Returns: The change written, nil when there was none.
    /// - Throws: `ConfigEdit.Failure` for a name Hugging Face would not accept or a file that would not load, or the
    ///   file system's error.
    @discardableResult
    public func trustPublisher(_ publisher: String, source: String) throws -> ConfigEdit.Outcome? {
        let data = FileManager.default.contents(atPath: home.configFile.path)
        let listed =
            try ConfigEdit.current(TrustedPublishers.setting, in: data)?.arrayValue?.compactMap(\.stringValue)
            ?? [TrustedPublishers.builtIn]
        guard !listed.contains(publisher) else { return nil }
        let outcome = try ConfigEdit.set(
            TrustedPublishers.setting, to: ChatChoice.answer(values: listed + [publisher]), in: data)
        try ConfigEdit.write(outcome, to: home.configFile)
        audit.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: source))
        return outcome
    }
}
