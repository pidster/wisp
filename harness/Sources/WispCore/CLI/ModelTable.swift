import Foundation

/// How the models listing reads, the same in every face ([ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md)):
/// `wisp models` on a terminal and piped, `--json`, chat's `/models`, and `wisp-tui`'s picker. One column per fact
/// wisp knows about a model, in this order, each under a plain heading; a column no shown model has a value for is
/// left out, and an empty cell stays empty. On a narrow terminal the columns least worth their room go first
/// (`Column.drop`); the model's name, whether it is enabled, and its capabilities always stay. Pure.
public enum ModelTable {
    /// One column: the key it has in `--json`, its heading, and when a narrow terminal drops it.
    public struct Column: Equatable, Sendable {
        /// The field's name in `--json`.
        public var key: String
        /// The heading.
        public var heading: String
        /// 0 never dropped; otherwise the order a narrow terminal drops it in, 1 first.
        public var drop: Int
    }

    /// Every column, in the order shown. The name carries the `*` that marks the default (or, in chat, the model in
    /// use); capabilities come last, so they wrap.
    public static let columns: [Column] = [
        Column(key: "model", heading: "MODEL", drop: 0),
        Column(key: "runtime", heading: "RUNTIME", drop: 2),
        Column(key: "parameters", heading: "PARAMS", drop: 5),
        Column(key: "size", heading: "SIZE", drop: 6),
        Column(key: "format", heading: "FORMAT", drop: 1),
        Column(key: "context", heading: "CONTEXT", drop: 7),
        Column(key: "contextFrom", heading: "FROM", drop: 3),
        Column(key: "location", heading: "WHERE", drop: 4),
        Column(key: "enabled", heading: "ENABLED", drop: 0),
        Column(key: "capabilities", heading: "CAPABILITIES", drop: 0),
    ]

    /// The cell of `column` for `entry`, empty when the fact is not known; the name without its marker.
    static func cell(_ column: Column, _ entry: ModelListing.Entry) -> String {
        switch column.key {
        case "model": entry.selection.description
        case "runtime": entry.runtime
        case "parameters": entry.parameters ?? ""
        case "size": entry.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        case "format": entry.format ?? ""
        case "context": entry.contextSize.map { $0.formatted() } ?? ""
        case "contextFrom": entry.contextFrom ?? ""
        case "location": entry.location?.label ?? ""
        case "enabled": entry.enabled ? "yes" : "no"
        case "capabilities":
            entry.plainCapabilities.joined(separator: ", ")
                + (entry.verified != nil && !entry.plainCapabilities.isEmpty ? " (verified)" : "")
        default: ""
        }
    }

    /// The columns with a value in at least one of `entries`; the name, enabled, and capabilities always.
    static func present(_ entries: [ModelListing.Entry]) -> [Column] {
        columns.filter { column in column.drop == 0 || entries.contains { !cell(column, $0).isEmpty } }
    }

    /// The cells of `entries` under `columns`, the name marked `*` for `current`.
    static func rows(_ entries: [ModelListing.Entry], columns: [Column], current: ModelSelection) -> [[String]] {
        entries.map { entry in
            columns.map { column in
                let text = cell(column, entry)
                return column.key == "model" ? "\(entry.selection == current ? "*" : " ") \(text)" : text
            }
        }
    }

    /// `wisp models` on a terminal and chat's `/models` there: the present columns under their headings, fitted to
    /// `width`, a model that cannot be used followed by its reason, indented and wrapped, then a note per backend
    /// that did not answer.
    ///
    /// - Parameters:
    ///   - listing: The models.
    ///   - current: The model to mark `*`.
    ///   - all: Whether to show the models that cannot be used.
    ///   - width: The terminal's width.
    /// - Returns: The lines.
    public static func terminal(
        _ listing: ModelListing.Listing, current: ModelSelection, all: Bool, width: Int
    ) -> [String] {
        let shown = listing.shown(all: all)
        var lines = [ModelListing.noUsableModel]
        if !shown.isEmpty {
            let present = present(shown)
            let header = present.map { $0.key == "model" ? "  " + $0.heading : $0.heading }
            let rows = rows(shown, columns: present, current: current)
            let kept = TerminalTable.fitting(header: header, rows: rows, drop: present.map(\.drop), width: width)
            let groups = TerminalTable.renderGroups(
                header: kept.map { header[$0] }, rows: rows.map { row in kept.map { row[$0] } }, width: width)
            lines = groups[0]
            for (group, entry) in zip(groups.dropFirst(), shown) {
                lines += group
                if let problem = entry.problem, entry.linked {
                    lines += TerminalTable.note("not usable: \(problem)", indent: 4, width: width)
                }
            }
        }
        for note in listing.unreachable { lines += TerminalTable.note("(\(note))", indent: 2, width: width) }
        return lines
    }

    /// Chat's `/models` where the width is not known: the present columns aligned, nothing wrapped or dropped, a
    /// reason after its model as in `terminal`.
    ///
    /// - Parameters:
    ///   - listing: The models.
    ///   - current: The model in use, marked `*`.
    /// - Returns: The lines.
    public static func text(_ listing: ModelListing.Listing, current: ModelSelection) -> [String] {
        let shown = listing.shown(all: false)
        var lines = [ModelListing.noUsableModel]
        if !shown.isEmpty {
            let present = present(shown)
            let rendered = TextTable.render(
                header: present.map { $0.key == "model" ? "  " + $0.heading : $0.heading },
                rows: rows(shown, columns: present, current: current))
            lines = [rendered[0]]
            for (line, entry) in zip(rendered.dropFirst(), shown) {
                lines.append(line)
                if let problem = entry.problem, entry.linked { lines.append("    not usable: \(problem)") }
            }
        }
        return lines + listing.unreachable.map { "  (\($0))" }
    }

    /// `wisp models` piped: one tab-separated line per model, every column in `columns`' order whether or not it has
    /// a value, so a script finds a field at the same position on every line; the first field is the name after
    /// `* ` for the default or two spaces, and a model that cannot be used has its reason as one more field,
    /// `not usable: …`. A backend that did not answer gets a line in parentheses.
    ///
    /// - Parameters:
    ///   - listing: The models.
    ///   - current: The default, marked `*`.
    ///   - all: Whether to show the models that cannot be used.
    /// - Returns: The lines.
    public static func tabSeparated(_ listing: ModelListing.Listing, current: ModelSelection, all: Bool) -> [String] {
        let shown = listing.shown(all: all)
        var lines = zip(shown, rows(shown, columns: columns, current: current)).map { entry, cells in
            (cells + (entry.linked ? entry.problem.map { ["not usable: \($0)"] } ?? [] : []))
                .joined(separator: "\t")
        }
        lines += listing.unreachable.map { "  (\($0))" }
        return lines.isEmpty ? [ModelListing.noUsableModel] : lines
    }

    /// `wisp models --json`: `models`, one object per model with a field per column (`model`, `runtime`,
    /// `parameters`, `size` as text and `bytes`, `format`, `context` as tokens, `contextFrom`, and `contextNote`,
    /// `location` as `modelsFolder`, `hubCache`, or `hubCacheNotLinked`, `enabled`, `capabilities` in plain words
    /// and `capabilitiesFrom`, such as `verified 2026-10-04`, absent facts null), and `default`, `usable`, and `problem`; and `unreachable`, the backends that did not
    /// answer.
    ///
    /// - Parameters:
    ///   - listing: The models.
    ///   - current: The default.
    ///   - all: Whether to include the models that cannot be used.
    /// - Returns: The document.
    public static func json(_ listing: ModelListing.Listing, current: ModelSelection, all: Bool) -> JSONValue {
        func text(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
        let models = listing.shown(all: all).map { entry -> JSONValue in
            .object([
                "model": .string(entry.selection.description), "default": .bool(entry.selection == current),
                "runtime": .string(entry.runtime), "parameters": text(entry.parameters),
                "size": text(
                    entry.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }),
                "bytes": entry.bytes.map { .int($0) } ?? .null, "format": text(entry.format),
                "context": entry.contextSize.map { .int($0) } ?? .null, "contextFrom": text(entry.contextFrom),
                "contextNote": text(entry.contextNote), "location": text(entry.location?.rawValue),
                "enabled": .bool(entry.enabled), "capabilities": .array(entry.plainCapabilities.map { .string($0) }),
                "capabilitiesFrom": text(entry.capabilitiesFrom),
                "usable": .bool(entry.usable), "problem": text(entry.linked ? entry.problem : nil),
            ])
        }
        return .object(["models": .array(models), "unreachable": .array(listing.unreachable.map { .string($0) })])
    }

    /// `wisp-tui`'s `/models`: the listing as a choice with toggles, one row per model it shows, each on when
    /// enabled, under the present columns but `ENABLED`, which the toggle itself shows.
    ///
    /// - Parameters:
    ///   - listing: The models.
    ///   - current: The model in use, which the picker marks.
    /// - Returns: The choice.
    public static func choice(_ listing: ModelListing.Listing, current: ModelSelection) -> ChatChoice {
        let shown = listing.shown(all: false)
        let present = present(shown).filter { $0.key != "enabled" }
        return ChatChoice(
            title: "Models: space turns one on or off, Enter saves",
            options: shown.map { entry in
                ChatChoice.Option(
                    value: entry.selection.description, detail: entry.linked ? entry.problem ?? "" : "",
                    cells: present.map { cell($0, entry) }, on: entry.enabled)
            }, current: current.description,
            columns: present.map { ChatChoice.Column(heading: $0.heading, drop: $0.drop) })
    }
}
