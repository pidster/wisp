import Foundation

/// Eight lowercase hex characters from a UUID: the ids for sessions, tool calls, MCP calls, and
/// standing approvals. Short enough to read in a log line, random enough not to collide in one.
public enum ShortID {
    /// A fresh id.
    ///
    /// - Returns: Eight lowercase hex characters, a safe name (`SafeName`).
    public static func make() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
