import Foundation

/// Finds presentational text in a reply: stretches the model wrote for the person to read that reproduce a
/// tool output of the same turn exactly, such as a retyped file or a table restating a command's result
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "Output handling
/// decouples display from context", and decision D12). Once shown, such a stretch has done its job, and the
/// composer cuts it from later requests; the output itself is stored and in the audit log.
///
/// Only exact copies are cut (D12): a stretch reproduced with changes, such as a proposed edit shown as a
/// changed copy of a file, carries information the output does not, and is kept. The measure is
/// deterministic and needs no model:
/// - **Lines** are compared after normalising formatting only: `read_file`'s line numbers (a number and a
///   tab at the start) are removed, runs of whitespace become one space, the ends are trimmed, and blank
///   lines are left out. A Markdown table's row is compared as its cells joined by a space, and its header
///   and separator rows are formatting, so a table that restates a command's output line for line matches.
/// - **Blocks** are the units judged: a fenced code block (its fence lines excluded), or a paragraph of
///   consecutive non-blank lines.
/// - A block **reproduces** an output when its normalised lines occur, in order and next to each other,
///   among the output's normalised lines. One changed character in any line, an added line, or a
///   reordered one, and it does not.
/// - **Runs:** consecutive reproducing blocks of the same output join into one span, with the blank lines
///   and wordless blocks between them. A block that does not reproduce the output ends the run. A run is
///   cut only when it holds at least `minimumWords` words, so one quoted line or a short answer that
///   happens to match stays.
///
/// Analysis, answers, code the model wrote, and edited copies do not reproduce the output's lines, so
/// they stay.
enum Presentation {
    /// The fewest words a run must hold to be cut: about two lines of prose. A shorter run saves little
    /// beside its marker and is more likely a deliberate quotation.
    static let minimumWords = 24

    /// One stretch of a reply to cut.
    struct Span: Sendable, Equatable {
        /// UTF-8 offsets into the reply's text, from the start of the run's first line to the end of its
        /// last line (the final newline excluded).
        var range: Range<Int>
        /// The index of the output it reproduces, in the order the outputs were given.
        var output: Int
        /// Words in the run's blocks.
        var words: Int
        /// The fraction of the run's lines found in the output: 1 for every span, since only exact copies
        /// are cut; kept so the `context.cut` event's field keeps its meaning.
        var coverage: Double
    }

    /// A unit of a reply that is judged as a whole.
    struct Block: Sendable, Equatable {
        /// UTF-8 offsets of the block in the text.
        var range: Range<Int>
        /// The block's words, fence lines excluded.
        var words: [String]
        /// The block's lines as compared (`normalised`), fence lines and table formatting excluded.
        var lines: [String] = []
    }

    /// The words of `text`: maximal runs of letters and digits, lowercased.
    static func words(_ text: some StringProtocol) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result
    }

    /// `line` as compared: without `read_file`'s line number, whitespace runs as one space, trimmed; a
    /// Markdown table row as its cells joined by a space. Empty for a blank line.
    static func normalised(_ line: some StringProtocol) -> String {
        var text = Substring(line)
        if let number = text.firstMatch(of: #/^\s*\d+\t/#) { text = text[number.range.upperBound...] }
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed =
                trimmed.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether `line` is a Markdown table's separator row, such as `| --- | :-: |`.
    static func isTableSeparator(_ line: some StringProtocol) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// The lines of a tool output as compared: normalised, blank lines left out.
    static func outputLines(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(normalised).filter { !$0.isEmpty }
    }

    /// Whether `lines` occur in `output`, in order and next to each other.
    static func occurs(_ lines: [String], in output: [String]) -> Bool {
        guard !lines.isEmpty, lines.count <= output.count else { return false }
        return (0...(output.count - lines.count)).contains { start in
            lines.indices.allSatisfy { output[start + $0] == lines[$0] }
        }
    }

    /// The blocks of `text`, in order: fenced code blocks and paragraphs.
    static func blocks(_ text: String) -> [Block] {
        var lines: [(range: Range<Int>, text: Substring)] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.utf8.count
            lines.append((offset..<(offset + length), line))
            offset += length + 1
        }
        /// The compared lines of `slice`: a table's header and separator rows dropped, blank lines left out.
        func compared(_ slice: ArraySlice<(range: Range<Int>, text: Substring)>) -> [String] {
            let texts = slice.map(\.text)
            var kept: [String] = []
            for (index, line) in texts.enumerated() {
                if isTableSeparator(line) { continue }
                if index + 1 < texts.count, isTableSeparator(texts[index + 1]) { continue }
                let normal = normalised(line)
                if !normal.isEmpty { kept.append(normal) }
            }
            return kept
        }
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var end = index + 1
                while end < lines.count, !lines[end].text.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    end += 1
                }
                let last = min(end, lines.count - 1)
                let inside = lines[(index + 1)..<max(index + 1, end)]
                blocks.append(
                    Block(
                        range: line.range.lowerBound..<lines[last].range.upperBound,
                        words: inside.flatMap { Self.words($0.text) }, lines: compared(inside)))
                index = last + 1
                continue
            }
            var end = index
            while end < lines.count {
                let next = lines[end].text.trimmingCharacters(in: .whitespaces)
                if next.isEmpty || (end > index && (next.hasPrefix("```") || next.hasPrefix("~~~"))) { break }
                end += 1
            }
            let paragraph = lines[index..<end]
            blocks.append(
                Block(
                    range: line.range.lowerBound..<lines[end - 1].range.upperBound,
                    words: paragraph.flatMap { Self.words($0.text) }, lines: compared(paragraph)))
            index = end
        }
        return blocks
    }

    /// The spans of `reply` to cut, in order: runs of blocks that reproduce one of `outputs` exactly.
    ///
    /// - Parameters:
    ///   - reply: The model's text.
    ///   - outputs: The texts of the turn's tool outputs.
    /// - Returns: The spans, each at least `minimumWords` long.
    static func spans(in reply: String, outputs: [String]) -> [Span] {
        let compared = outputs.map(outputLines)
        guard compared.contains(where: { !$0.isEmpty }) else { return [] }
        /// A run being built: its output, range, and words.
        struct Run {
            var output: Int
            var range: Range<Int>
            var words: Int
        }
        var spans: [Span] = []
        var run: Run?
        func close() {
            if let finished = run, finished.words >= minimumWords {
                spans.append(Span(range: finished.range, output: finished.output, words: finished.words, coverage: 1))
            }
            run = nil
        }
        for block in blocks(reply) {
            // Wordless (a rule, an empty fence): it joins a run only when a reproducing block of the same
            // output follows, since extending a run's range to that block takes in everything between.
            if block.lines.isEmpty { continue }
            let matching = compared.indices.filter { occurs(block.lines, in: compared[$0]) }
            guard let first = matching.first else {
                close()
                continue
            }
            if var current = run, matching.contains(current.output) {
                current.range = current.range.lowerBound..<block.range.upperBound
                current.words += block.words.count
                run = current
            } else {
                close()
                run = Run(output: first, range: block.range, words: block.words.count)
            }
        }
        close()
        return spans
    }

    /// `text` with each of `replacements` put in place of its UTF-8 range. Ranges out of bounds, empty,
    /// or overlapping an earlier one are skipped, so a cut saved by another build cannot break a request.
    ///
    /// - Parameters:
    ///   - text: The original text.
    ///   - replacements: Ranges and what replaces each, in any order.
    /// - Returns: The text with the replacements made.
    static func replacing(_ text: String, _ replacements: [(range: Range<Int>, with: String)]) -> String {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        var position = 0
        for replacement in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let range = replacement.range
            guard range.lowerBound >= position, range.upperBound <= bytes.count, !range.isEmpty else { continue }
            result += bytes[position..<range.lowerBound]
            result += Array(replacement.with.utf8)
            position = range.upperBound
        }
        result += bytes[position...]
        return String(decoding: result, as: UTF8.self)
    }
}
