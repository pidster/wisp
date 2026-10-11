import Foundation

/// How tools render text for the model.
///
/// Tools return failures as text rather than throwing, because a thrown error aborts the whole
/// response with a raw framework message; the model can react to `error: …` and try another way.
/// Every tool result is bounded to the tool-output budget (`ToolBudget`, an eighth of the model's window),
/// and what does not fit is kept whole in the conversation's output store and marked, never dropped
/// ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)).
enum ToolOutput {
    /// `error: <description>`.
    static func error(_ error: some Error) -> String {
        "error: \(error)"
    }

    /// `text`, or its first `maxBytes` (on a character boundary) followed by a marker saying so. For the small
    /// fixed-size texts that must never grow (a reference, a notice, one over-long line of a page); a tool's result
    /// goes through `fitted` instead.
    static func bounded(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while end > text.startIndex, !text.indices.contains(end) { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "\n[truncated: \(text.utf8.count) bytes, showing \(maxBytes)]"
    }

    /// What one fit held back: a run of whole lines, numbered in the whole output.
    struct HeldBack: Equatable, Sendable {
        /// The first line held back, from 1.
        var firstLine: Int
        /// The last line held back.
        var lastLine: Int
        /// Bytes held back.
        var bytes: Int

        /// How many lines.
        var lines: Int { lastLine - firstLine + 1 }

        /// `lines 44–2,313 (180 KiB)`.
        var span: String { "lines \(firstLine.formatted())–\(lastLine.formatted()) (\(ToolOutput.size(bytes)))" }
    }

    /// One fit: what the model is shown, and what was held back, if anything.
    struct Fit: Equatable, Sendable {
        /// The text shown: the whole, or the head, a marker, and the tail.
        var shown: String
        /// What the marker stands for; nil when the whole fit.
        var held: HeldBack?
    }

    /// Fits an output within `bytes`: whole when it is no larger; otherwise its first lines and its last lines,
    /// about half the room each, with a one-line marker between them saying what lies between. Cuts fall on line
    /// ends; a single line longer than its half is cut on a character boundary and marked with `…`.
    ///
    /// The output may be given whole (`head` and `tail` the same text, `total` nil), or as two pieces when only
    /// its head and its tail were kept in memory (a command's streams): then `total` says how many lines and
    /// bytes the whole had, and the tail's first line, which may be a fragment, is not shown.
    ///
    /// - Parameters:
    ///   - head: The output's start: the whole output, or its first bytes.
    ///   - tail: Its end: the same whole output, or its last bytes.
    ///   - total: The whole output's line and byte counts when `head` and `tail` are pieces; nil when `head` is
    ///     the whole.
    ///   - bytes: The room.
    ///   - lineOffset: Added to the line numbers in the marker, for an output stored after other lines.
    /// - Returns: The fit.
    static func fit(
        head: String, tail: String, total: (lines: Int, bytes: Int)? = nil, within bytes: Int, lineOffset: Int = 0
    )
        -> Fit
    {
        let whole = total == nil
        let totalBytes = total?.bytes ?? head.utf8.count
        if whole, totalBytes <= bytes { return Fit(shown: head, held: nil) }
        var headLines = lines(head)
        var tailLines = lines(tail)
        if !whole, totalBytes > tail.utf8.count, !tailLines.isEmpty { tailLines.removeFirst() }
        if !whole, totalBytes > head.utf8.count, !head.hasSuffix("\n"), !headLines.isEmpty { headLines.removeLast() }
        let totalLines = total?.lines ?? headLines.count
        let half = max(64, (bytes - 96) / 2)
        let top = prefix(headLines, within: half)
        var bottom = suffix(tailLines, within: half)
        if top.count + bottom.count >= totalLines {
            // The ends meet. Whole, that is the output within a few bytes of the room, shown entire; in pieces, the
            // middle is not in memory, so the tail gives way until one line is held back.
            guard !whole else { return Fit(shown: headLines.joined(separator: "\n"), held: nil) }
            let count = max(0, totalLines - top.count - 1)
            bottom = (Array(bottom.lines.suffix(count)), count)
        }
        let firstHeld = top.count + 1
        let lastHeld = totalLines - bottom.count
        guard firstHeld <= lastHeld else {
            return Fit(shown: (top.lines + bottom.lines).joined(separator: "\n"), held: nil)
        }
        let shownBytes = (top.lines + bottom.lines).reduce(0) { $0 + $1.utf8.count + 1 }
        let held = HeldBack(
            firstLine: firstHeld + lineOffset, lastLine: lastHeld + lineOffset, bytes: max(0, totalBytes - shownBytes))
        let marker = "[… \(held.lines.formatted()) line\(held.lines == 1 ? "" : "s") (\(size(held.bytes))) held back …]"
        return Fit(shown: (top.lines + [marker] + bottom.lines).joined(separator: "\n"), held: held)
    }

    /// `text`'s lines, without newlines; a trailing newline adds no empty line.
    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The first whole lines of `lines` within `bytes`, and how many whole lines they are. A first line longer
    /// than the room is cut and marked, and counts as none kept whole (so it is held back too).
    private static func prefix(_ lines: [String], within bytes: Int) -> (lines: [String], count: Int) {
        var kept: [String] = []
        var used = 0
        for line in lines {
            guard used + line.utf8.count + 1 <= bytes else { break }
            kept.append(line)
            used += line.utf8.count + 1
        }
        if kept.isEmpty, let first = lines.first, !first.isEmpty {
            return ([FileReader.utf8Prefix(Data(first.utf8), maxBytes: max(16, bytes - 4)) + "…"], 0)
        }
        return (kept, kept.count)
    }

    /// The last whole lines of `lines` within `bytes`, and how many they are; a last line longer than the room is
    /// cut from its start and marked, counting as none.
    private static func suffix(_ lines: [String], within bytes: Int) -> (lines: [String], count: Int) {
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            guard used + line.utf8.count + 1 <= bytes else { break }
            kept.insert(line, at: 0)
            used += line.utf8.count + 1
        }
        if kept.isEmpty, let last = lines.last, !last.isEmpty {
            let data = Data(last.utf8)
            let cut = data.suffix(max(16, bytes - 4))
            return (["…" + String(decoding: cut, as: UTF8.self).drop(while: { $0 == "\u{FFFD}" })], 0)
        }
        return (kept, kept.count)
    }

    /// `180 KiB`, `2 MiB`, or `640 bytes`.
    static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1024: "\(bytes) bytes"
        case ..<(1 << 20): "\(bytes / 1024) KiB"
        default: String(format: "%.1f MiB", Double(bytes) / Double(1 << 20))
        }
    }

    /// The note that ends a result with held-back output: what is held back, where the whole is kept, and how to
    /// reach it. Every way named reads the stored output; a command is never run again to see what it printed
    /// (ADR 0050).
    ///
    /// - Parameters:
    ///   - held: What was held back, each with the name of its stream when a result has several (`stdout`).
    ///   - kept: The store's record of the whole output; nil when nothing could be kept.
    ///   - memory: Whether the conversation has `memory`, which names the calls that page it.
    ///   - command: Whether the output is a command's, which is never run again to see it.
    /// - Returns: The note, one line.
    static func heldNote(
        _ held: [(stream: String?, held: HeldBack)], kept: OutputStore.Kept?, memory: Bool, command: Bool
    )
        -> String
    {
        let spans = held.map { ($0.stream.map { "\($0) " } ?? "") + $0.held.span }.joined(separator: ", ")
        var note = "held back: \(spans)"
        let again = command ? "; do not run the command again to see it" : ""
        guard let kept else {
            return note + "; not kept: this conversation has no output store" + again
        }
        note += "; the whole output is kept as output \(kept.id) (\(kept.lines.formatted()) lines"
        note += kept.cut ? ", its first \(size(kept.bytes)); the rest past that was not kept)" : ")"
        guard memory else { return note + again }
        let first = held.first?.held.firstLine ?? 1
        note +=
            "; memory \"recall output \(kept.id) from line \(first)\" pages it, \"recall output \(kept.id) matching "
            + "PATTERN\" filters it, \"summarise output \(kept.id)\" gives the notable lines, \"condense output "
            + "\(kept.id): QUESTION\" answers from all of it"
        return note + again
    }

    /// `text` within the budget: whole when it fits; otherwise kept whole in `store` under the current call's id
    /// and shown as its head and tail with a marker and the note. For tools whose result is one text.
    ///
    /// - Parameters:
    ///   - text: The tool's whole result.
    ///   - tool: The tool's name, for the store.
    ///   - budget: The budget.
    ///   - store: The conversation's output store; nil keeps nothing, and the note says so.
    /// - Returns: What the model is given.
    static func fitted(_ text: String, tool: String, budget: ToolBudget, store: OutputStore?) -> String {
        let bytes = budget.bytes
        guard text.utf8.count > bytes else { return text }
        let kept = store?.keep(text, id: ToolCallContext.outputID, tool: tool)
        let room = bytes - 400
        let fit = fit(head: text, tail: text, within: room)
        guard let held = fit.held else { return fit.shown }
        return fit.shown + "\n" + heldNote([(nil, held)], kept: kept, memory: budget.memory, command: false)
    }
}
