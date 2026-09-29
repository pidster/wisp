import Foundation

/// Finds presentational text in a reply: stretches the model wrote for the person to read that largely
/// reproduce a tool output of the same turn, such as a retyped file or a table restating a command's result
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "Output handling
/// decouples display from context"). Once shown, such a stretch has done its job, and the composer cuts it
/// from later requests; the output itself is stored and in the audit log.
///
/// The measure is word-sequence overlap, deterministic and without a model:
/// - **Words** are maximal runs of letters and digits, lowercased, so punctuation, Markdown table pipes,
///   and code fences do not matter.
/// - **Blocks** are the units judged: a fenced code block (its fence lines excluded from the words), or a
///   paragraph of consecutive non-blank lines.
/// - **Coverage** of a block against one output is the fraction of the block's word 4-grams
///   (`shingleLength`) that occur anywhere in the output, taken with and without `read_file`'s line
///   numbers. A block reproduces an output when its best coverage reaches `threshold`.
/// - **Runs:** consecutive reproducing blocks of the same output join into one span, with any blank lines
///   and blocks too short to judge (fewer words than a shingle, such as a heading) between them. A run is
///   cut only when it holds at least `minimumWords` words, so one quoted line or a short answer that
///   happens to match stays.
///
/// Analysis, answers, and code the model wrote do not reproduce the output's word sequence, so they stay.
enum Presentation {
    /// Words per shingle. Four keeps common three-word phrases ("the output of", "is set to") from
    /// matching prose that merely discusses the output, while still matching a table whose rows keep
    /// the output's order.
    static let shingleLength = 4
    /// The coverage from which a block counts as reproducing an output.
    static let threshold = 0.5
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
        /// Words in the run's judged blocks.
        var words: Int
        /// The fraction of the run's shingles found in the output.
        var coverage: Double
    }

    /// A unit of a reply that is judged as a whole.
    struct Block: Sendable, Equatable {
        /// UTF-8 offsets of the block in the text.
        var range: Range<Int>
        /// The block's words, fence lines excluded.
        var words: [String]
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

    /// The word `shingleLength`-grams of `words`, joined by a space.
    static func shingles(_ words: [String]) -> [String] {
        guard words.count >= shingleLength else { return [] }
        return (0...(words.count - shingleLength)).map { words[$0..<($0 + shingleLength)].joined(separator: " ") }
    }

    /// The shingles of a tool output, taken twice: as it is, and with `read_file`'s line numbers (a number
    /// and a tab at the start of each line) removed, so a file retyped with or without its numbers matches.
    static func outputShingles(_ output: String) -> Set<String> {
        let unnumbered = output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.firstMatch(of: #/^\d+\t/#).map { line[$0.range.upperBound...] } ?? line
        }
        return Set(shingles(words(output))).union(shingles(words(unnumbered.joined(separator: "\n"))))
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
                var words: [String] = []
                while end < lines.count, !lines[end].text.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    words += Self.words(lines[end].text)
                    end += 1
                }
                let last = min(end, lines.count - 1)
                blocks.append(Block(range: line.range.lowerBound..<lines[last].range.upperBound, words: words))
                index = last + 1
                continue
            }
            var end = index
            var words: [String] = []
            while end < lines.count {
                let next = lines[end].text.trimmingCharacters(in: .whitespaces)
                if next.isEmpty || (end > index && (next.hasPrefix("```") || next.hasPrefix("~~~"))) { break }
                words += Self.words(lines[end].text)
                end += 1
            }
            blocks.append(Block(range: line.range.lowerBound..<lines[end - 1].range.upperBound, words: words))
            index = end
        }
        return blocks
    }

    /// The spans of `reply` to cut, in order: runs of blocks that reproduce one of `outputs`.
    ///
    /// - Parameters:
    ///   - reply: The model's text.
    ///   - outputs: The texts of the turn's tool outputs.
    /// - Returns: The spans, each at least `minimumWords` long.
    static func spans(in reply: String, outputs: [String]) -> [Span] {
        let sets = outputs.map(outputShingles)
        guard sets.contains(where: { !$0.isEmpty }) else { return [] }
        /// A run being built: its output, range, words, and covered and total shingles.
        struct Run {
            var output: Int
            var range: Range<Int>
            var words: Int
            var covered: Int
            var total: Int
        }
        var spans: [Span] = []
        var run: Run?
        func close() {
            if let finished = run, finished.words >= minimumWords {
                spans.append(
                    Span(
                        range: finished.range, output: finished.output, words: finished.words,
                        coverage: Double(finished.covered) / Double(max(finished.total, 1))))
            }
            run = nil
        }
        for block in blocks(reply) {
            let grams = shingles(block.words)
            // Too short to judge: it joins a run only when a reproducing block of the same output follows,
            // since extending a run's range to that block takes in everything between.
            if grams.isEmpty { continue }
            var best: (output: Int, covered: Int)?
            for (index, set) in sets.enumerated() where !set.isEmpty {
                let covered = grams.filter(set.contains).count
                if covered > (best?.covered ?? -1) { best = (index, covered) }
            }
            guard let best, Double(best.covered) / Double(grams.count) >= threshold else {
                close()
                continue
            }
            if var current = run, current.output == best.output {
                current.range = current.range.lowerBound..<block.range.upperBound
                current.words += block.words.count
                current.covered += best.covered
                current.total += grams.count
                run = current
            } else {
                close()
                run = Run(
                    output: best.output, range: block.range, words: block.words.count, covered: best.covered,
                    total: grams.count)
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
