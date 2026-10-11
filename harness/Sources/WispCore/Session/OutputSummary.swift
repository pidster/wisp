import Foundation

/// A summary of a stored output without a model: its notable lines, or an overview
/// ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)). Exact readers first: the
/// failure formats `triage` reads (`KnownFailures`), a log's severities and templates (`LogDigest`), and JSON's
/// shape (`JSONShape`); every point cites the lines it came from (`L123`), so the model can page to them. A
/// summary names what no reader explained, so the model knows what the `condense` verb could still answer.
/// Pure, and bounded by the caller.
enum OutputSummary {
    /// Which summary.
    enum Kind: String, Equatable, Sendable {
        /// What matters given how the output ended: root causes first.
        case notable
        /// What the output is: its size, how it ended, its sections or kinds of line.
        case overview
    }

    /// The most lines a summary gives to one list.
    static let listLimit = 12
    /// Lines of context after an error's own line.
    static let contextLines = 2

    /// The summary of `lines`, as lines.
    ///
    /// - Parameters:
    ///   - lines: The output, whole.
    ///   - kind: Which summary.
    ///   - tool: The tool that produced it, when known; a command's output is read for its exit status.
    /// - Returns: The summary's lines.
    static func summarise(_ lines: [String], kind: Kind, tool: String?) -> [String] {
        switch kind {
        case .notable: notable(lines, tool: tool)
        case .overview: overview(lines, tool: tool)
        }
    }

    /// The exit status a command's stored output begins with (`exit status: N`), or nil.
    static func exitStatus(of lines: [String]) -> Int? {
        guard let first = lines.first, let match = first.wholeMatch(of: #/exit status: (-?\d+)/#) else { return nil }
        return Int(match.1)
    }

    /// The outcome line: a command's exit status, else the last non-empty line.
    private static func outcome(_ lines: [String], tool: String?) -> String {
        if let status = exitStatus(of: lines) {
            return status == 0 ? "exit status 0 (succeeded)" : "exit status \(status) (failed)"
        }
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "empty"
        }
        return "ended at L\(last + 1): " + OutputReference.shortened(lines[last], to: 120)
    }

    /// The headline: size and outcome.
    private static func headline(_ lines: [String], tool: String?) -> String {
        let bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        return "\(lines.count.formatted()) lines, \(ToolOutput.size(bytes)); \(outcome(lines, tool: tool))"
    }

    /// What matters: for a build or test output in a known format, the first error of each file or test with the
    /// lines after it, the errors that follow it in the same place counted under it, the warnings tallied, and the
    /// test failures; for a log, its severities and the rare or severe messages; for JSON, its shape; else the
    /// error-looking lines, and the first and last lines when there are none.
    static func notable(_ lines: [String], tool: String?) -> [String] {
        var out = ["notable lines (exact readers, no model): " + headline(lines, tool: tool)]
        let text = lines.joined(separator: "\n")
        let scan = KnownFailures.scan(text)
        if !scan.findings.isEmpty {
            out += failures(scan, in: lines)
            if !scan.unexplained.isEmpty {
                out.append(
                    "\(scan.unexplained.count) failure-looking line\(scan.unexplained.count == 1 ? "" : "s") no reader "
                        + "explained, such as: " + OutputReference.shortened(scan.unexplained[0], to: 120))
            }
            return out
        }
        if let shape = try? JSONShape().run(text) {
            out.append("JSON: " + shape.rendered.split(separator: "\n").first.map(String.init).orEmpty)
            out += shape.outline.prefix(listLimit)
            return out
        }
        let digest = LogDigest().run(text)
        let severe = digest.groups.filter { $0.severity <= .warning }
        if !severe.isEmpty || digest.severities.keys.contains(where: { $0 <= .warning }) {
            let counts = LogDigest.Severity.allCases.reversed().compactMap { severity in
                digest.severities[severity].map { "\($0) \(severity.rawValue)" }
            }
            out.append("log: \(counts.joined(separator: ", ")); \(digest.templates) distinct messages")
            for group in digest.groups.prefix(listLimit) where group.severity <= .warning || group.count == 1 {
                let where_ =
                    group.firstLine == group.lastLine ? "L\(group.firstLine)" : "L\(group.firstLine)-\(group.lastLine)"
                out.append(
                    "\(group.severity.rawValue) ×\(group.count) \(where_): "
                        + OutputReference.shortened(group.template, to: 140))
            }
            out.append("no failure format matched; the lines above are the rare or severe messages")
            return out
        }
        let errorish = lines.indices.filter { looksLikeFailure(lines[$0]) }
        if !errorish.isEmpty {
            out.append("\(errorish.count) line\(errorish.count == 1 ? "" : "s") that mention an error or failure:")
            for index in errorish.prefix(listLimit) {
                out.append("L\(index + 1): " + OutputReference.shortened(lines[index], to: 140))
            }
            if errorish.count > listLimit { out.append("… and \(errorish.count - listLimit) more") }
            return out
        }
        out.append(
            "no error lines; no reader explains this output, so \"condense\" with a question is the way to ask about it"
        )
        out += edges(lines)
        return out
    }

    /// What the output is: its size, how it ended, its sections (lines that look like headings, with their line
    /// numbers), the kinds of line counted, and its first and last lines.
    static func overview(_ lines: [String], tool: String?) -> [String] {
        var out = ["overview (exact readers, no model): " + headline(lines, tool: tool)]
        let blank = lines.count(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        let failures = lines.count(where: looksLikeFailure)
        let warnings = lines.count(where: { $0.range(of: "warning", options: .caseInsensitive) != nil })
        out.append(
            "lines: \(blank) blank, \(failures) mentioning an error or failure, \(warnings) mentioning a warning")
        let headings = lines.indices.filter { looksLikeHeading(lines[$0]) }
        if !headings.isEmpty {
            out.append("sections (\(headings.count)):")
            for index in headings.prefix(listLimit) {
                out.append("L\(index + 1): " + OutputReference.shortened(lines[index], to: 100))
            }
            if headings.count > listLimit { out.append("… and \(headings.count - listLimit) more") }
        }
        if let shape = try? JSONShape().run(lines.joined(separator: "\n")) {
            out.append("JSON: " + shape.rendered.split(separator: "\n").first.map(String.init).orEmpty)
        }
        out += edges(lines)
        return out
    }

    /// The failures a scan found, grouped: by the file or test of their location, the first error of each with
    /// its line and the lines after it, the later ones in the same place counted; warnings tallied; test failures
    /// listed.
    private static func failures(_ scan: KnownFailures.Scan, in lines: [String]) -> [String] {
        var out: [String] = []
        let errors = scan.findings.filter { $0.kind == "error" || $0.kind == "crash" }
        let tests = scan.findings.filter { $0.kind == "test-failure" }
        let warnings = scan.findings.filter { $0.kind == "warning" }
        var located: [(place: String, finding: Triage.Finding, line: Int?)] = []
        var cursor = 0
        for finding in errors + tests {
            let place = finding.location.map { String($0.split(separator: ":").first ?? Substring($0)) } ?? "?"
            let line = lineNumber(of: finding, in: lines, from: &cursor)
            located.append((place, finding, line))
        }
        var seen: [String: Int] = [:]
        var order: [String] = []
        for item in located {
            if seen[item.place] == nil { order.append(item.place) }
            seen[item.place, default: 0] += 1
        }
        if !errors.isEmpty {
            out.append(
                "\(errors.count) error\(errors.count == 1 ? "" : "s") in \(order.filter { place in located.contains { $0.place == place && $0.finding.kind != "test-failure" } }.count) place\(order.count == 1 ? "" : "s"); the first of each, root causes first:"
            )
        }
        for place in order.prefix(listLimit) {
            guard let first = located.first(where: { $0.place == place }) else { continue }
            let count = seen[place] ?? 1
            let at = first.line.map { "L\($0)" } ?? "L?"
            var line =
                "\(at) \(first.finding.kind) at \(first.finding.location ?? place): "
                + OutputReference.shortened(first.finding.message, to: 160)
            if count > 1 { line += " (+\(count - 1) more in \(place))" }
            out.append(line)
            if let number = first.line {
                for index in number..<min(lines.count, number + contextLines) where !lines[index].isEmpty {
                    out.append("  L\(index + 1): " + OutputReference.shortened(lines[index], to: 140))
                }
            }
        }
        if order.count > listLimit { out.append("… and \(order.count - listLimit) more places") }
        if !warnings.isEmpty {
            var byPlace: [String: Int] = [:]
            for warning in warnings {
                byPlace[
                    warning.location.map { String($0.split(separator: ":").first ?? Substring($0)) } ?? "?", default: 0] +=
                    1
            }
            let places = byPlace.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) ×\($0.value)" }
            out.append(
                "\(warnings.count) warning\(warnings.count == 1 ? "" : "s") (\(places.joined(separator: ", "))\(byPlace.count > 4 ? ", …" : ""))"
            )
        }
        return out
    }

    /// The 1-based line that holds `finding`'s message, searched from `cursor` on so the findings stay in order.
    private static func lineNumber(of finding: Triage.Finding, in lines: [String], from cursor: inout Int) -> Int? {
        let needle =
            finding.message.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? finding.message
        guard !needle.isEmpty else { return nil }
        for index in cursor..<lines.count
        where lines[index].contains(needle) || (finding.location.map { lines[index].contains($0) } ?? false) {
            cursor = index + 1
            return index + 1
        }
        return nil
    }

    /// The first three and last three lines, numbered.
    private static func edges(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        var out = ["first lines:"]
        out += lines.prefix(3).enumerated().map {
            "L\($0.offset + 1): " + OutputReference.shortened($0.element, to: 120)
        }
        if lines.count > 6 {
            out.append("last lines:")
            out += lines.suffix(3).enumerated().map {
                "L\(lines.count - 2 + $0.offset): " + OutputReference.shortened($0.element, to: 120)
            }
        }
        return out
    }

    /// Whether a line mentions an error, a failure, a panic, or a fatal condition.
    static func looksLikeFailure(_ line: String) -> Bool {
        line.firstMatch(of: #/(?i)\b(error|errors|failed|failure|fatal|panic|exception|traceback)\b/#) != nil
    }

    /// Whether a line looks like a heading: `==> x`, `### x`, `[x]`, `*** x`, or a short line ending with a colon.
    static func looksLikeHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        if trimmed.hasPrefix("==> ") || trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ")
            || trimmed.hasPrefix("*** ")
        {
            return true
        }
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains(" held back ") { return true }
        return trimmed.hasSuffix(":") && trimmed.split(separator: " ").count <= 6
    }
}

extension Optional where Wrapped == String {
    /// The string, or empty.
    fileprivate var orEmpty: String { self ?? "" }
}
