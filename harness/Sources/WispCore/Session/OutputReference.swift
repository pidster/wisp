import Foundation

/// What the model carries in place of a tool output after the turn that produced it
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), decision D12): a
/// compact, structured reference that says which tool ran, the store entry, when, whether it succeeded,
/// how large the output was, notes on it, and the call's arguments. A conversation with the `memory` tool
/// (phase 4c) is told the call that recalls the entry in full; one without it, to run the call again.
///
/// The notes are mechanical, as D1 extracts facts from tool output: the status (a command's exit status,
/// or `failed` for an `error: …` result), the line and byte counts, and the first and last lines of
/// content. No model is called. Every part is bounded, so a reference stays well under `maxBytes`:
///
/// ```
/// [output of entry 7 not repeated: read_file at 14:05:12, ok, 101 lines, 3612 bytes; to see it: memory "recall entry 7"]
/// arguments: {"path":"/work/harbour/docs/overview.md"}
/// first line: 1	# harbour sync: overview
/// last line: 100\tthe last whole line of the page
/// paging: more from offset 101
/// ```
enum OutputReference {
    /// The longest a note line's quoted text may be, in characters.
    static let lineCharacters = 100
    /// The longest the arguments line may be, in characters.
    static let argumentCharacters = 200
    /// An upper bound on a reference's size in UTF-8 bytes, whatever the output.
    static let maxBytes = 640

    /// The mechanical notes on one output.
    struct Notes: Equatable, Sendable {
        /// `ok`, `failed`, or `exit status N` for a command.
        var status: String
        /// Lines in the output.
        var lines: Int
        /// UTF-8 bytes in the output.
        var bytes: Int
        /// The first line of content, shortened; nil when there is none. Written with a leading `…` when
        /// the output was bounded so that the line may be a fragment.
        var first: String?
        /// The last line of content, shortened; nil when it is the first or there is none. Written with a
        /// trailing `…` when the output was cut after it.
        var last: String?
        /// Where the tool says the output continues (`more from offset 94`), kept apart from the content;
        /// nil when it does not.
        var more: String?
    }

    /// Lines of a `run_command` result that frame its streams rather than carry content.
    private static let commandFrames = ["stdout:", "stderr:"]

    /// What `read_file`'s continuation line starts with; a number and `]` follow.
    private static let pagingPrefix = "[more: call again with offset "
    /// The notes a `system_info` command adds after its output when it timed out.
    private static let partialTrailers = ["(timed out; partial)", "(timed out; sizes are partial)"]

    /// The notes on `output`, from `tool`.
    ///
    /// The first and last lines are the first and last whole lines of content: the trailers tools append
    /// (`read_file`'s `[more: …]` and `[end of file]`, the bound's `[truncated: …]`, a timeout note) and a
    /// command's header and stream frames are not content. Where the output was bounded, the line next to
    /// the cut is marked with `…`; `read_file`'s continuation is kept as `more`.
    ///
    /// - Parameters:
    ///   - output: The output's text, as the tool returned it.
    ///   - tool: The tool's name.
    /// - Returns: The notes.
    static func notes(on output: String, tool: String) -> Notes {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var status = output.hasPrefix("error:") ? "failed" : "ok"
        var content = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var cutStart = false
        var cutEnd = false
        var more: String?
        if tool == "run_command", let head = content.first,
            let match = head.firstMatch(of: #/^exit status: (-?\d+)$/#)
        {
            status = "exit status \(match.1)"
            content = content.dropFirst().filter { !commandFrames.contains($0) && !$0.hasPrefix("timed out:") }
            // A command's streams are bounded to their tails, so a stream's first line may be a fragment.
            if let note = content.firstIndex(where: { $0.hasPrefix("output truncated:") }) {
                content.remove(at: note)
                cutStart = true
            }
        }
        // Strip trailers from the end: the bound's `[truncated: …]` marker (`ToolOutput.bounded`), `read_file`'s
        // paging line, and the timeout note `system_info` adds.
        while let last = content.last {
            if last.hasPrefix("[truncated: "), last.hasSuffix("]"), last.contains(" bytes, showing ") {
                cutEnd = true
            } else if tool == "read_file", last.hasPrefix(pagingPrefix), last.hasSuffix("]"),
                let next = Int(last.dropFirst(pagingPrefix.count).dropLast())
            {
                more = "more from offset \(next)"
            } else if !partialTrailers.contains(last), !(tool == "read_file" && last == "[end of file]") {
                break
            }
            content.removeLast()
        }
        var first = content.first.map { shortened($0, to: lineCharacters) }
        if cutStart, let line = first { first = "…" + line }
        var last = content.count > 1 ? content.last.map { shortened($0, to: lineCharacters) } : nil
        if cutEnd, let line = last { last = line + "…" }
        return Notes(
            status: status, lines: lines.count, bytes: output.utf8.count, first: first, last: last, more: more)
    }

    /// The reference's text.
    ///
    /// - Parameters:
    ///   - tool: The tool's name.
    ///   - entry: The output's store id.
    ///   - time: When the output was recorded, when known.
    ///   - arguments: The call's arguments as JSON, when the call is in the store.
    ///   - output: The output's text.
    ///   - timeZone: The zone the time is written in.
    ///   - recallable: Whether the conversation has `memory`, so the reference names the call that recalls it;
    ///     without it, the reference says to run the call again.
    /// - Returns: The reference, at most `maxBytes` bytes.
    static func text(
        tool: String, entry: Int, time: Date?, arguments: String?, output: String, timeZone: TimeZone = .current,
        recallable: Bool = false
    ) -> String {
        let notes = notes(on: output, tool: tool)
        let clock = time.map { " at " + Self.clock($0, in: timeZone) } ?? ""
        let plural = { (count: Int, noun: String) in "\(count) \(noun)\(count == 1 ? "" : "s")" }
        let hint = recallable ? "to see it: memory \"recall entry \(entry)\"" : "call it again to see it"
        var lines = [
            "[output of entry \(entry) not repeated: \(shortened(tool, to: 40))\(clock), \(notes.status), "
                + "\(plural(notes.lines, "line")), \(plural(notes.bytes, "byte")); \(hint)]"
        ]
        if let arguments { lines.append("arguments: " + shortened(flat(arguments), to: argumentCharacters)) }
        if let first = notes.first { lines.append("first line: " + first) }
        if let last = notes.last { lines.append("last line: " + last) }
        if let more = notes.more { lines.append("paging: " + more) }
        return ToolOutput.bounded(lines.joined(separator: "\n"), maxBytes: maxBytes - 64)
    }

    /// Output no longer than this many bytes goes whole with the notice of a person's command, as an output no
    /// longer than its reference goes whole.
    static let personOutputWholeBytes = 320

    /// What the model carries for a command the person ran in chat (ADR 0049): one notice that says the person
    /// ran it, not the model, where, and how it ended, and then the output whole when it is short, or its first
    /// and last lines and how to recall it in full. Bounded like a reference.
    ///
    /// ```
    /// [the person ran `git status --short` themselves in /work/harbour at 14:05:12 (exit status 0, 4 lines); this was not your action; to see the output: memory "recall entry 7"]
    /// first line: M Sources/Sync.swift
    /// last line: ?? notes.txt
    /// ```
    ///
    /// - Parameters:
    ///   - command: What the person ran, where, and how it ended.
    ///   - entry: The entry's store id.
    ///   - time: When it finished, when known.
    ///   - output: What it printed: stdout, then stderr.
    ///   - timeZone: The zone the time is written in.
    ///   - recallable: Whether the conversation has `memory`, so the notice names the call that recalls it.
    /// - Returns: The notice.
    static func personCommand(
        _ command: ThreadRecord.PersonCommand, entry: Int, time: Date?, output: String,
        timeZone: TimeZone = .current, recallable: Bool = false
    ) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let plural = { (count: Int, noun: String) in "\(count) \(noun)\(count == 1 ? "" : "s")" }
        var status = "exit status \(command.exitStatus)"
        if command.timedOut { status += ", timed out" }
        let clock = time.map { " at " + Self.clock($0, in: timeZone) } ?? ""
        let head =
            "[the person ran `\(shortened(flat(command.line), to: argumentCharacters))` themselves in "
            + "\(shortened(command.directory, to: lineCharacters))\(clock) (\(status), \(plural(lines.count, "line")))"
            + "; this was not your action"
        guard !lines.isEmpty else { return head + "; it printed nothing]" }
        if output.utf8.count <= personOutputWholeBytes, !command.truncated {
            return ToolOutput.bounded(
                ([head + "; its output:]"] + lines).joined(separator: "\n"), maxBytes: maxBytes - 64)
        }
        let hint = recallable ? "to see the output: memory \"recall entry \(entry)\"" : "its output is not repeated"
        var notice = [head + "; " + hint + "]"]
        let content = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if var first = content.first.map({ shortened($0, to: lineCharacters) }) {
            if command.truncated { first = "…" + first }
            notice.append("first line: " + first)
        }
        if content.count > 1, let last = content.last {
            notice.append("last line: " + shortened(last, to: lineCharacters))
        }
        return ToolOutput.bounded(notice.joined(separator: "\n"), maxBytes: maxBytes - 64)
    }

    /// `time` as `14:05:12` in `timeZone`.
    ///
    /// - Parameters:
    ///   - time: The time.
    ///   - timeZone: The zone.
    /// - Returns: Hours, minutes, and seconds.
    static func clock(_ time: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// `text` on one line: newlines and tabs written as spaces.
    private static func flat(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    /// `text` cut to `limit` characters with an ellipsis.
    static func shortened(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
