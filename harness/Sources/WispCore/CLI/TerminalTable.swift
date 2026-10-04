import Foundation

/// The layout of a listing on a terminal, in the style of `wisp --help`: columns padded to their content,
/// the last column wrapped to the terminal's width with a hanging indent. The commands that print
/// listings (`wisp tools`, `models`, `approvals`) use it only when standard output is a terminal and keep
/// their tab-separated lines when it is piped, so scripts reading them keep working. Everything here but
/// the defaults of `detectWidth` is a pure function of its arguments.
public enum TerminalTable {
    /// The width assumed when neither the terminal nor `COLUMNS` says.
    public static let defaultWidth = 80

    /// The narrowest a wrapped column is made, so a very narrow terminal overflows instead of printing a
    /// letter per line.
    static let minimumWrap = 20

    /// Cells between columns.
    static let gap = 2

    /// Columns the right edge is kept clear of, as `--help` does.
    static let margin = 2

    /// The width to lay out for, or nil when output is not a terminal (the caller then prints its plain,
    /// tab-separated form).
    ///
    /// - Parameters:
    ///   - isTerminal: Whether standard output is a terminal; `isatty` by default.
    ///   - ioctlWidth: The terminal's columns from `ioctl(TIOCGWINSZ)`; read from standard output by default.
    ///   - environment: Where `COLUMNS` is read when the ioctl gives no width.
    /// - Returns: The width, or nil when not on a terminal.
    public static func detectWidth(
        isTerminal: Bool = isatty(STDOUT_FILENO) == 1,
        ioctlWidth: Int? = ioctlColumns(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard isTerminal else { return nil }
        return width(ioctlWidth: ioctlWidth, environment: environment)
    }

    /// The width from the ioctl, else `COLUMNS`, else 80; a zero or negative value counts as absent.
    static func width(ioctlWidth: Int?, environment: [String: String]) -> Int {
        if let ioctlWidth, ioctlWidth > 0 { return ioctlWidth }
        if let columns = environment["COLUMNS"].flatMap({ Int($0) }), columns > 0 { return columns }
        return defaultWidth
    }

    /// The columns of the terminal on standard output, or nil when it has none.
    public static func ioctlColumns() -> Int? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }

    /// `text` broken into lines of at most `width` characters at spaces; a word longer than `width` is
    /// split. Runs of whitespace collapse to one space, and empty text gives one empty line.
    static func wrap(_ text: String, width: Int) -> [String] {
        let width = max(width, 1)
        var lines: [String] = []
        var current = ""
        for piece in text.split(whereSeparator: \.isWhitespace) {
            var word = piece
            while word.count > width {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(String(word.prefix(width)))
                word = word.dropFirst(width)
            }
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty || lines.isEmpty { lines.append(current) }
        return lines
    }

    /// Rows laid out in columns, each but the last as wide as its widest cell and the last wrapped to
    /// `width` with its continuation lines under its first.
    ///
    /// - Parameters:
    ///   - header: Column titles, or nil for none; sets the number of columns when given.
    ///   - rows: The cells, one array per line; a short row is padded with empty cells.
    ///   - indent: Spaces before the first column.
    ///   - width: The terminal's width.
    /// - Returns: The lines, without trailing spaces.
    static func render(header: [String]? = nil, rows: [[String]], indent: Int = 0, width: Int) -> [String] {
        renderGroups(header: header, rows: rows, indent: indent, width: width).flatMap { $0 }
    }

    /// `render`, with the lines of each row kept together: the header's first when there is one, then one
    /// group per row, so a caller can put a line after a particular row.
    static func renderGroups(
        header: [String]? = nil, rows: [[String]], indent: Int = 0, width: Int
    ) -> [[String]] {
        let count = header?.count ?? rows.map(\.count).max() ?? 0
        guard count > 0 else { return [] }
        let all = ([header].compactMap { $0 } + rows).map { row in (0..<count).map { $0 < row.count ? row[$0] : "" } }
        let widths = (0..<count - 1).map { column in all.map { $0[column].count }.max() ?? 0 }
        let prefix = indent + widths.reduce(0) { $0 + $1 + gap }
        let room = max(width - margin - prefix, minimumWrap)
        var groups: [[String]] = []
        for cells in all {
            var lines: [String] = []
            let lead =
                String(repeating: " ", count: indent)
                + zip(cells, widths).map { $0 + String(repeating: " ", count: $1 - $0.count + gap) }.joined()
            let wrapped = wrap(cells[count - 1], width: room)
            lines.append((lead + wrapped[0]).replacing(/\s+$/, with: ""))
            for more in wrapped.dropFirst() { lines.append(String(repeating: " ", count: prefix) + more) }
            groups.append(lines)
        }
        return groups
    }

    /// The columns that fit `width`: every one when they do, and otherwise the table without the droppable
    /// columns least worth their room, lowest `drop` rank first, until the columns before the last leave the last
    /// at least `minimumWrap` cells. A column ranked 0 is never dropped; when only those are left the table is
    /// laid out as it is, and the last column wraps as narrow as it must.
    ///
    /// - Parameters:
    ///   - header: Column titles.
    ///   - rows: The cells, one array per line.
    ///   - drop: Each column's rank: 0 never dropped, otherwise the order in which they go, 1 first.
    ///   - indent: Spaces before the first column.
    ///   - width: The terminal's width.
    /// - Returns: The indices of the columns kept, in order.
    static func fitting(header: [String], rows: [[String]], drop: [Int], indent: Int = 0, width: Int) -> [Int] {
        var kept = Array(header.indices)
        func fits() -> Bool {
            let before = kept.dropLast().map { column in
                ([header] + rows).map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
            }
            return indent + before.reduce(0) { $0 + $1 + gap } + minimumWrap + margin <= width
        }
        while !fits() {
            let candidates = kept.filter { $0 < drop.count && drop[$0] > 0 }
            guard let next = candidates.min(by: { drop[$0] < drop[$1] }) else { break }
            kept.removeAll { $0 == next }
        }
        return kept
    }

    /// A help-style section: `heading`, then each name indented two spaces in a column as wide as the
    /// longest, and its text wrapped beside it.
    ///
    /// - Parameters:
    ///   - heading: The section's heading, such as `TOOLS:`.
    ///   - entries: Name and text pairs.
    ///   - width: The terminal's width.
    /// - Returns: The heading and one or more lines per entry.
    static func section(_ heading: String, entries: [(name: String, text: String)], width: Int) -> [String] {
        [heading] + render(rows: entries.map { [$0.name, $0.text] }, indent: 2, width: width)
    }

    /// `text` wrapped to `width` with `indent` spaces before every line, for the notes a listing prints
    /// under its table.
    static func note(_ text: String, indent: Int, width: Int) -> [String] {
        wrap(text, width: max(width - margin - indent, minimumWrap)).map { String(repeating: " ", count: indent) + $0 }
    }
}
