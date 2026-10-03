import Foundation

/// How `wisp tools`, `wisp approvals`, and `wisp facts` print: the terminal layout of `TerminalTable` when
/// given a width, and the tab-separated lines scripts read when not.
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

    /// The `wisp approvals pending` lines for `requests`.
    ///
    /// - Parameters:
    ///   - requests: The waiting requests, oldest first.
    ///   - width: The terminal's width, or nil when piped.
    ///   - now: The time, for how long each has waited.
    /// - Returns: `id<TAB>level<TAB>seconds<TAB>thread<TAB>directory<TAB>command` lines when piped; aligned
    ///   columns under a header on a terminal, the command last so it takes the room left.
    public static func pending(_ requests: [PendingApprovals.Request], width: Int?, now: Date = Date()) -> [String] {
        let rows = requests.map { request in
            let waited = max(0, Int(now.timeIntervalSince(request.createdAt)))
            let from = [request.client, request.thread].compactMap(\.self).joined(separator: "/")
            return [
                request.id, request.level.rawValue, width == nil ? "\(waited)" : waitedText(waited),
                from.isEmpty ? "-" : from, width == nil ? request.directory : ChatStatus.abbreviated(request.directory),
                request.command,
            ]
        }
        guard let width else { return rows.map { $0.joined(separator: "\t") } }
        return TerminalTable.render(
            header: ["ID", "LEVEL", "WAITING", "FROM", "IN", "COMMAND"], rows: rows, width: width)
    }

    /// The `wisp facts pending` lines for `requests`: facts callers asked to keep as permanent (ADR 0048).
    ///
    /// - Parameters:
    ///   - requests: The waiting fact requests, oldest first.
    ///   - width: The terminal's width, or nil when piped.
    ///   - now: The time, for how long each has waited.
    /// - Returns: `id<TAB>seconds<TAB>from<TAB>fact<TAB>source<TAB>subject<TAB>name<TAB>value` lines when piped;
    ///   aligned columns under a header on a terminal, the fact last so it takes the room left.
    public static func factRequests(
        _ requests: [PendingApprovals.Request], width: Int?, now: Date = Date()
    ) -> [String] {
        let rows = requests.compactMap { request -> [String]? in
            guard let fact = request.fact else { return nil }
            let waited = max(0, Int(now.timeIntervalSince(request.createdAt)))
            let from = [request.client, request.thread].compactMap(\.self).joined(separator: "/")
            let common = [
                request.id, width == nil ? "\(waited)" : waitedText(waited), from.isEmpty ? "-" : from, fact.id,
                fact.source,
            ]
            return common + (width == nil ? [fact.subject, fact.name, fact.value] : [fact.text])
        }
        guard let width else { return rows.map { $0.joined(separator: "\t") } }
        return TerminalTable.render(
            header: ["ID", "WAITING", "FROM", "FACT", "SOURCE", "KEEP AS PERMANENT"], rows: rows, width: width)
    }

    /// `42 s`, `3 min`, or `2 h`.
    static func waitedText(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) s"
        case ..<3600: "\(seconds / 60) min"
        default: "\(seconds / 3600) h"
        }
    }
}
