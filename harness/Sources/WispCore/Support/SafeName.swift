import Foundation

/// A name safe to use as a file name or an id: 1 to 64 characters from `[A-Za-z0-9._-]`.
/// Transcript names and MCP thread ids share this rule.
public enum SafeName {
    /// The rule in words, for error messages.
    public static let rule = "1-64 characters from [A-Za-z0-9._-]"

    /// Whether `name` follows the rule: ASCII letters and digits only, as the rule says. `CharacterSet.alphanumerics`
    /// would admit every script's letters and digits (`é`, `٣`, fullwidth forms), which look like others in a path
    /// or a URI.
    public static func isValid(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return !scalars.isEmpty && scalars.count <= 64 && scalars.allSatisfy(allowed.contains)
    }

    /// The characters the rule allows.
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars)
}
