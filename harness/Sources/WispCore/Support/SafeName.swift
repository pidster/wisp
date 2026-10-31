import Foundation

/// A name safe to use as a file name or an id: 1 to 64 characters from `[A-Za-z0-9._-]`, other than `.` and `..`.
/// Transcript names, MCP thread ids, and the output store's ids and session directories share this rule: no `/`, and
/// neither of the two names that mean a directory itself or its parent, so a name joined to a directory stays a
/// component inside it.
public enum SafeName {
    /// The rule in words, for error messages.
    public static let rule = "1-64 characters from [A-Za-z0-9._-], other than . and .."

    /// Whether `name` follows the rule: ASCII letters and digits only, as the rule says. `CharacterSet.alphanumerics`
    /// would admit every script's letters and digits (`é`, `٣`, fullwidth forms), which look like others in a path
    /// or a URI. `.` and `..` are refused although their characters are allowed: joined to a directory, they name it
    /// or its parent, not a file in it.
    public static func isValid(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return !scalars.isEmpty && scalars.count <= 64 && scalars.allSatisfy(allowed.contains) && name != "."
            && name != ".."
    }

    /// The characters the rule allows.
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars)
}
