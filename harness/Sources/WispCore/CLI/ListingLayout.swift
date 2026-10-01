import Foundation

/// How `wisp tools` and `wisp approvals` print: the terminal layout of `TerminalTable` when given a
/// width, and the tab-separated lines scripts read when not.
public enum ListingLayout {
    /// The `wisp tools` lines for `tools`.
    ///
    /// - Parameters:
    ///   - tools: Each tool's name and description.
    ///   - width: The terminal's width, or nil when piped.
    /// - Returns: `name<TAB>description` lines when piped; a `TOOLS:` section and a pointer to the full
    ///   catalogue on a terminal.
    public static func tools(_ tools: [(name: String, description: String)], width: Int?) -> [String] {
        guard let width else { return tools.map { "\($0.name)\t\($0.description)" } }
        return TerminalTable.section("TOOLS:", entries: tools.map { ($0.name, $0.description) }, width: width)
            + [""]
            + TerminalTable.note(
                "See 'wisp tools --markdown' (or --json) for parameters and example prompts.", indent: 2, width: width)
    }

    /// The `wisp approvals` lines for `entries`.
    ///
    /// - Parameters:
    ///   - entries: The standing approvals, in the order to print.
    ///   - width: The terminal's width, or nil when piped.
    /// - Returns: Tab-separated lines when piped; aligned columns under a header on a terminal.
    public static func approvals(_ entries: [ApprovalStore.Entry], width: Int?) -> [String] {
        let rows = entries.map { entry in
            let date = entry.expiresAt.formatted(date: .abbreviated, time: .omitted)
            return [
                entry.id, entry.scope.rawValue, width == nil ? "expires \(date)" : date,
                entry.workingDirectory ?? "any directory", entry.pattern,
            ]
        }
        guard let width else { return rows.map { $0.joined(separator: "\t") } }
        return TerminalTable.render(header: ["ID", "SCOPE", "EXPIRES", "WHERE", "PATTERN"], rows: rows, width: width)
    }
}
