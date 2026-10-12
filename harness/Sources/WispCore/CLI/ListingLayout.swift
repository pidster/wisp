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
    ///   - gone: The ids of those whose directory is gone (`ApprovalStore.Listing.isGone`).
    ///   - width: The terminal's width, or nil when piped.
    /// - Returns: Tab-separated lines when piped, a gone approval's with a sixth field, `gone`; aligned columns
    ///   under a header on a terminal, a gone approval's directory marked `(gone)`, and a note saying how to
    ///   remove them when there are any.
    public static func approvals(_ entries: [ApprovalStore.Entry], gone: Set<String> = [], width: Int?) -> [String] {
        let rows = entries.map { entry in
            let date = entry.expiresAt.formatted(date: .abbreviated, time: .omitted)
            let isGone = gone.contains(entry.id)
            let directory = entry.workingDirectory ?? "any directory"
            return [
                entry.id, entry.scope.rawValue, width == nil ? "expires \(date)" : date,
                width != nil && isGone ? "\(directory) (gone)" : directory, entry.pattern,
            ] + (width == nil && isGone ? ["gone"] : [])
        }
        guard let width else { return rows.map { $0.joined(separator: "\t") } }
        let table = TerminalTable.render(
            header: ["ID", "SCOPE", "EXPIRES", "WHERE", "PATTERN"], rows: rows, width: width)
        let count = entries.filter { gone.contains($0.id) }.count
        guard count > 0 else { return table }
        let which =
            count == 1 ? "1 approval is for a folder that is gone" : "\(count) approvals are for folders that are gone"
        return table + [""]
            + TerminalTable.note(
                "\(which) and can never match again; 'wisp approvals clear --gone' removes them.", indent: 0,
                width: width)
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

    /// The `wisp questions pending` lines for `requests`: the model's questions waiting for the person (ADR 0062).
    ///
    /// - Parameters:
    ///   - requests: The waiting question requests, oldest first.
    ///   - width: The terminal's width, or nil when piped.
    ///   - now: The time, for how long each has waited.
    /// - Returns: `id<TAB>seconds<TAB>from<TAB>options<TAB>question` lines when piped; aligned columns under a header on
    ///   a terminal, the question last so it takes the room left.
    public static func questions(
        _ requests: [PendingApprovals.Request], width: Int?, now: Date = Date()
    ) -> [String] {
        let rows = requests.map { request -> [String] in
            let waited = max(0, Int(now.timeIntervalSince(request.createdAt)))
            let from = [request.client, request.thread].compactMap(\.self).joined(separator: "/")
            let options = (request.options ?? []).map(ApprovalRequest.visible).joined(separator: " | ")
            return [
                request.id, width == nil ? "\(waited)" : waitedText(waited), from.isEmpty ? "-" : from,
                options.isEmpty ? (width == nil ? "" : "free text") : options,
                ApprovalRequest.visible(request.question ?? ""),
            ]
        }
        guard let width else { return rows.map { $0.joined(separator: "\t") } }
        return TerminalTable.render(header: ["ID", "WAITING", "FROM", "OPTIONS", "QUESTION"], rows: rows, width: width)
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
