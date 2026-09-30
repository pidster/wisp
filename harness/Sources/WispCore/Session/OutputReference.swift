import Foundation

/// What the model carries in place of a tool output after the turn that produced it
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), decision D12): a
/// compact, structured reference that says which tool ran, the store entry, when, whether it succeeded,
/// how large the output was, notes on it, and the call's arguments, so the model can run the call again
/// for the full output until `recall` exists (phase 4).
///
/// The notes are mechanical, as D1 extracts facts from tool output: the status (a command's exit status,
/// or `failed` for an `error: …` result), the line and byte counts, and the first and last lines of
/// content. No model is called. Every part is bounded, so a reference stays well under `maxBytes`:
///
/// ```
/// [output of entry 7 not repeated: read_file at 14:05:12, ok, 101 lines, 3612 bytes; call it again to see it]
/// arguments: {"path":"/work/harbour/docs/overview.md"}
/// first line: 1	# harbour sync: overview
/// last line: [end of file]
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
        /// The first line of content, shortened; nil when there is none.
        var first: String?
        /// The last line of content, shortened; nil when it is the first or there is none.
        var last: String?
    }

    /// Lines of a `run_command` result that frame its streams rather than carry content.
    private static let commandFrames = ["stdout:", "stderr:"]

    /// The notes on `output`, from `tool`.
    ///
    /// - Parameters:
    ///   - output: The output's text, as the tool returned it.
    ///   - tool: The tool's name.
    /// - Returns: The notes.
    static func notes(on output: String, tool: String) -> Notes {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var status = output.hasPrefix("error:") ? "failed" : "ok"
        var content = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if tool == "run_command", let head = content.first,
            let match = head.firstMatch(of: #/^exit status: (-?\d+)$/#)
        {
            status = "exit status \(match.1)"
            content = content.dropFirst().filter {
                !commandFrames.contains($0) && !$0.hasPrefix("timed out:") && !$0.hasPrefix("output truncated:")
            }
        }
        let first = content.first.map { shortened($0, to: lineCharacters) }
        let last = content.count > 1 ? content.last.map { shortened($0, to: lineCharacters) } : nil
        return Notes(status: status, lines: lines.count, bytes: output.utf8.count, first: first, last: last)
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
    /// - Returns: The reference, at most `maxBytes` bytes.
    static func text(
        tool: String, entry: Int, time: Date?, arguments: String?, output: String, timeZone: TimeZone = .current
    ) -> String {
        let notes = notes(on: output, tool: tool)
        var clock = ""
        if let time {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
            clock = String(format: " at %02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
        let plural = { (count: Int, noun: String) in "\(count) \(noun)\(count == 1 ? "" : "s")" }
        var lines = [
            "[output of entry \(entry) not repeated: \(shortened(tool, to: 40))\(clock), \(notes.status), "
                + "\(plural(notes.lines, "line")), \(plural(notes.bytes, "byte")); call it again to see it]"
        ]
        if let arguments { lines.append("arguments: " + shortened(flat(arguments), to: argumentCharacters)) }
        if let first = notes.first { lines.append("first line: " + first) }
        if let last = notes.last { lines.append("last line: " + last) }
        return ToolOutput.bounded(lines.joined(separator: "\n"), maxBytes: maxBytes - 64)
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
