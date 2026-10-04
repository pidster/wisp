import Foundation
import Synchronization

/// Shows the model's tool activity in chat as it happens: one dim line per call and result, drawn
/// from the same audit events the log records, so what the user sees is what was audited.
public enum ChatEvents {
    /// The line for `event`, or nil for an event chat does not show.
    public static func render(_ event: AuditEvent, style: Style) -> String? {
        let d = event.details
        switch event.kind {
        case .toolCall:
            let tool = d["tool"]?.stringValue ?? "?"
            return style.muted("⚙ \(tool) \(summary(ofArguments: d["arguments"]?.stringValue ?? "", tool: tool))")
        case .toolResult:
            // A command's outcome line already says what happened; its rendered result adds nothing.
            if d["tool"]?.stringValue == "run_command" { return nil }
            let bytes = d["bytes"]?.intValue ?? 0
            let seconds = d["seconds"]?.doubleValue ?? 0
            let head = firstLine(of: d["output"]?.stringValue ?? "")
            return style.muted("  ↳ \(bytes) bytes in \(String(format: "%.1f", seconds)) s: \(head)")
        case .commandOutcome:
            let status = d["exitStatus"]?.intValue ?? 0
            let mark = status == 0 ? style.wisp("exit \(status)") : style.ember("exit \(status)")
            var extras: [String] = []
            if d["timedOut"]?.boolValue == true { extras.append("timed out") }
            if d["truncated"]?.boolValue == true { extras.append("output truncated") }
            return style.muted("  ↳ ") + mark
                + style.muted(extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")
        case .commandTyped:
            return typed(d, style: style)
        case .fileWrite:
            let mode = d["mode"]?.stringValue ?? "?"
            let path = d["path"]?.stringValue ?? "?"
            let after = d["bytesAfter"]?.intValue ?? 0
            return style.muted("  ↳ \(mode) \(path), now \(after) bytes")
        case .error where event.call != nil:
            return style.ember("  ↳ error: \(d["message"]?.stringValue ?? "")")
        case .classifierVerdict:
            return verdict(d, style: style)
        case .approvalDecided:
            return decision(d, style: style)
        case .approvalPending where d["outcome"]?.stringValue == "filed" && d["kind"] == nil:
            return style.muted("  · also waiting in wisp approvals pending and wisp-tui")
        case .approvalSettled where d["outcome"]?.stringValue == "answered" && d["kind"] == nil:
            let via = OutOfBandApprover.face(d["via"]?.stringValue ?? "?")
            return style.muted("  · answered in \(via == "elicitation" ? "the client's dialog" : via)")
        case .policyDecision where d["verdict"]?.stringValue != "allowed":
            let reason = d["reason"]?.stringValue.map { ": \($0)" } ?? ""
            return style.ember("  · blocked by policy\(reason)")
        case .modelRouted:
            return style.muted(
                "  · \(d["task"]?.stringValue ?? "task") runs on \(d["model"]?.stringValue ?? "?"): "
                    + (d["reason"]?.stringValue ?? ""))
        case .condensation:
            return condensation(d, style: style)
        case .modelReasoning where d["phase"]?.stringValue == "end":
            return style.muted(thought(d))
        default:
            return nil
        }
    }

    /// The line for a `model.reasoning` event that ends a stretch of thinking (ADR 0053): `∴ thought for 4.2 s, 42
    /// tokens`, the thinking itself folded under it as a tool's output is.
    ///
    /// - Parameter d: The event's details.
    /// - Returns: The line, unstyled.
    static func thought(_ d: [String: JSONValue]) -> String {
        let tokens = d["tokens"]?.intValue ?? 0
        return "∴ thought for \(String(format: "%.1f", d["seconds"]?.doubleValue ?? 0)) s, \(tokens) token"
            + (tokens == 1 ? "" : "s")
    }

    /// The text an event carries for a face to show folded under its line: a tool's output, what a typed command
    /// printed, or the model's thinking when it ends; nil for any other event.
    ///
    /// - Parameter event: The audit event.
    /// - Returns: The text, or nil.
    static func shownText(of event: AuditEvent) -> String? {
        switch event.kind {
        case .toolResult, .commandTyped: event.details["output"]?.stringValue
        case .modelReasoning where event.details["phase"]?.stringValue == "end": event.details["text"]?.stringValue
        default: nil
        }
    }

    /// The line for a `command.typed` event, when it adds to what `policy.decision` and `command.outcome` show: why
    /// a command that was allowed could not start, or what the sandbox check found (ADR 0054): the write it refused,
    /// that a path inside the roots was refused by something else, or, with no path, that it may have. Nil
    /// otherwise.
    ///
    /// - Parameters:
    ///   - d: The event's details.
    ///   - style: Styling.
    /// - Returns: The line, or nil.
    static func typed(_ d: [String: JSONValue], style: Style) -> String? {
        if let failure = d["failure"]?.stringValue { return style.ember("  · could not run it: \(failure)") }
        let paths = (d["sandboxPaths"]?.arrayValue ?? []).compactMap(\.stringValue)
        let named = paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? " and \(paths.count - 3) more" : "")
        switch d["sandboxRefusal"]?.stringValue {
        case "refused":
            return style.ember(
                "  · the sandbox refused writing to \(named), as it would for the model: commands write only within "
                    + "wisp's writable roots")
        case "not-the-sandbox":
            return style.muted("  · not the sandbox: \(named) is inside wisp's writable roots")
        case "guess":
            return style.ember(
                "  · the sandbox may have refused it (no path to check), as it would the model's; no policy rule "
                    + "denied it")
        default:
            guard d["sandboxRefused"]?.boolValue == true else { return nil }
            return style.ember(
                "  · the sandbox refused it, as it would the model's: commands write only within wisp's writable roots"
            )
        }
    }

    /// The note for a `context.condensation` event: the turns before and after, and for a condensation to a target
    /// the tokens before and after against the window; at the floor, a second line that says the context could not
    /// reach its target and what to do.
    ///
    /// - Parameters:
    ///   - d: The event's details.
    ///   - style: Styling.
    /// - Returns: The note.
    static func condensation(_ d: [String: JSONValue], style: Style) -> String {
        let reason = d["reason"]?.stringValue ?? ""
        let turns = "\(d["turnsBefore"]?.intValue ?? 0) → \(d["turnsAfter"]?.intValue ?? 0) turns"
        guard let after = d["fillAfter"]?.intValue else {
            return style.muted("(context condensed, \(reason): \(turns))")
        }
        let window = d["contextSize"]?.intValue ?? 0
        let fill = "\(d["fillBefore"]?.intValue ?? 0) → \(after) of \(window) tokens"
        let changed = !(d["steps"]?.arrayValue ?? []).isEmpty || reason == "overflow"
        var lines = changed ? [style.muted("(context condensed, \(reason): \(turns), \(fill))")] : []
        if d["floor"]?.boolValue == true {
            lines.append(
                style.ember(
                    "(context at its floor: the instructions and the last turn take \(after) of \(window) tokens, "
                        + "above the \(d["target"]?.intValue ?? 0) that leave room for this request and a reply; this "
                        + "turn may run out of room, and /new starts afresh)"))
        }
        return lines.joined(separator: "\n")
    }

    /// The most bytes of a tool's output chat shows under its note, whatever the line setting.
    public static let shownOutputBytes = 2048

    /// A tool's output as chat shows it under the call's note (decision D12 of the layered-context
    /// proposal): the person sees the output as the tool returned it, so the model need not retype it. A
    /// command the person typed (`command.typed`) shows what it printed the same way (ADR 0049), and the model's
    /// thinking (`model.reasoning`) is shown so too (ADR 0053).
    /// At most `lines` lines and `shownOutputBytes` bytes are shown, each indented; when more remain, a
    /// last line says how much and how to see it all (`/show` with the start of the `tool.result` event's
    /// id, which is also the store's reference for the output). Nil for any other event, an empty output,
    /// or `lines` 0.
    ///
    /// - Parameters:
    ///   - event: The audit event.
    ///   - lines: The most lines to show (`Config.Resolved.shownOutputLines`).
    ///   - style: Styling.
    /// - Returns: The lines, joined, or nil.
    public static func shownOutput(_ event: AuditEvent, lines: Int, style: Style) -> String? {
        guard lines > 0, let output = shownText(of: event), !output.isEmpty else { return nil }
        let fold = folded(output, lines: lines)
        var shown = fold.shown.map { style.muted("    " + $0) }
        if fold.hidden > 0 {
            let handle = event.id.map { " /show \($0.prefix(8))" } ?? " /last"
            shown.append(
                style.muted(
                    "    … \(fold.hidden) more line\(fold.hidden == 1 ? "" : "s"), "
                        + "\(output.utf8.count) bytes in all:\(handle)"))
        }
        return shown.joined(separator: "\n")
    }

    /// The first lines of `output` that fit in `lines` lines and `shownOutputBytes` bytes, and how many lines
    /// are left out. A trailing empty line is not counted.
    ///
    /// - Parameters:
    ///   - output: The whole output.
    ///   - lines: The most lines to show.
    /// - Returns: The lines shown and the count hidden.
    public static func folded(_ output: String, lines: Int) -> (shown: [String], hidden: Int) {
        var all = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.last == "" { all.removeLast() }
        var shown: [String] = []
        var bytes = 0
        for line in all.prefix(max(0, lines)) {
            bytes += line.utf8.count + 1
            guard bytes <= shownOutputBytes || shown.isEmpty else { break }
            shown.append(line.utf8.count > shownOutputBytes ? String(line.prefix(shownOutputBytes / 2)) + "…" : line)
        }
        return (shown, all.count - shown.count)
    }

    /// The output `/show <argument>` asks for, whole: the tool output, a typed command's output, or the model's
    /// thinking (ADR 0053), with that store entry id, or whose `tool.result`, `command.typed`, or `model.reasoning`
    /// event id starts with `argument` (at least four characters), or with no argument the last tool output; nil when
    /// there is none.
    ///
    /// - Parameters:
    ///   - argument: What follows `/show`.
    ///   - store: The thread's record.
    ///   - last: The last tool result chat saw, which a turn not yet stored may hold.
    /// - Returns: The output, or nil.
    public static func output(_ argument: String?, in store: ThreadRecord, last: String?) -> String? {
        let outputs = store.entries.filter { [.toolOutput, .command, .reasoning].contains($0.kind) }
        guard let argument, !argument.isEmpty else {
            return last ?? outputs.last { $0.kind != .reasoning }.map { ThreadRecord.text(of: $0.value) }
        }
        // An event-id prefix can be all digits (one in about forty of eight characters), so a number that names no
        // entry is tried as a prefix too.
        if let id = Int(argument), let entry = outputs.first(where: { $0.id == id }) {
            return ThreadRecord.text(of: entry.value)
        }
        let prefix = argument.lowercased()
        guard prefix.count >= 4 else { return nil }
        let found = outputs.filter { $0.sources.contains { $0.event.hasPrefix(prefix) } }
        guard found.count == 1, let entry = found.first else { return nil }
        return ThreadRecord.text(of: entry.value)
    }

    /// The line a caller waiting on an MCP call is shown for `event` as progress: what chat shows,
    /// unstyled and unindented, and, since the caller cannot see wisp's approval dialog, a line when a
    /// command waits for one. Nil for an event chat does not show.
    public static func progress(_ event: AuditEvent) -> String? {
        if event.kind == .approvalRequested {
            let command = shortened(event.details["command"]?.stringValue ?? "")
            let level = event.details["level"]?.stringValue.map { " [\($0)]" } ?? ""
            return "waiting for approval\(level): \(command)"
        }
        return render(event, style: .plain)?.trimmingCharacters(in: .whitespaces)
    }

    /// The gate's rating of one simple command: `· safe by rules, coreml: a known read-only command
    /// (0.4 ms)`, naming the command when it is one of several in the line.
    static func verdict(_ d: [String: JSONValue], style: Style) -> String {
        let level = d["level"]?.stringValue ?? "?"
        let sources = d["sources"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? ""
        let reason = d["reasons"]?.arrayValue?.first?.stringValue ?? ""
        let milliseconds = (d["seconds"]?.doubleValue ?? 0) * 1000
        let timing =
            milliseconds < 10 ? String(format: "%.1f ms", milliseconds) : String(format: "%.0f ms", milliseconds)
        let cached = d["metadata"]?.objectValue?["classifier.cached"]?.boolValue == true
        let command = d["line"] == nil ? "" : "\(shortened(d["command"]?.stringValue ?? "")): "
        let rated = level == "safe" ? style.muted(level) : level == "dangerous" ? style.ember(level) : level
        return style.muted("  · \(command)") + rated
            + style.muted(
                "\(sources.isEmpty ? "" : " by \(sources)")\(reason.isEmpty ? "" : ": \(reason)")"
                    + " (\(cached ? "remembered" : timing))")
    }

    /// How a command that needed approval got it, or did not: a standing approval it matched, the
    /// person's answer, or silence.
    static func decision(_ d: [String: JSONValue], style: Style) -> String {
        let scope = d["scope"]?.stringValue
        switch d["decision"]?.stringValue ?? "" {
        case "approved": return style.muted("  · approved\(scope.map { " (\($0))" } ?? "")")
        case "denied": return style.ember("  · denied")
        case "timed-out": return style.ember("  · no answer in time, denied")
        case "cached-turn": return style.muted("  · allowed: approved once earlier in this turn")
        case "cached": return style.muted("  · allowed by your approval for this session")
        case "cached-project": return style.muted("  · allowed by your approval for this project")
        case "cached-always": return style.muted("  · allowed by your standing approval")
        case let other: return style.muted("  · \(other)")
        }
    }

    /// The argument that identifies a call, so the line reads `⚙ read_file README.md` or
    /// `⚙ run_command git status`, falling back to the whole JSON shortened.
    static func summary(ofArguments json: String, tool: String) -> String {
        let fields = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.objectValue ?? [:]
        let key: String
        switch tool {
        case "run_command": key = "command"
        case "read_file", "edit_file": key = "path"
        case "inspect": key = "what"
        case "current_date": key = "timeZone"
        default: key = ""
        }
        if let value = fields[key]?.stringValue {
            var parts = [value]
            if tool == "edit_file", let mode = fields["mode"]?.stringValue { parts.insert(mode, at: 0) }
            if tool == "read_file", let offset = fields["offset"]?.intValue { parts.append("from line \(offset)") }
            return shortened(parts.joined(separator: " "))
        }
        return shortened(json)
    }

    /// The first sentence of `text`, for the compact tool list.
    public static func firstSentence(of text: String) -> String {
        if let end = text.firstRange(of: ". ") { return String(text[..<end.lowerBound]) + "." }
        return text
    }

    /// The first line of `text`, shortened.
    static func firstLine(of text: String) -> String {
        shortened(text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "")
    }

    /// `text` cut to 100 characters with an ellipsis.
    static func shortened(_ text: String) -> String {
        text.count > 100 ? String(text.prefix(100)) + "…" : text
    }

    /// The sink chat attaches to its conversation: forwards each event to a handler set once the
    /// loop exists, and keeps the last tool result whole for `/last`.
    public final class Tap: AuditSink, Sendable {
        private let handler = Mutex<(@Sendable (AuditEvent) -> Void)?>(nil)
        private let last = Mutex<String?>(nil)

        /// Creates a tap with no handler yet.
        public init() {}

        /// Sets what happens with each event.
        public func onEvent(_ handle: @escaping @Sendable (AuditEvent) -> Void) {
            handler.withLock { $0 = handle }
        }

        /// The last tool result's full output, or nil before any.
        public var lastToolOutput: String? { last.withLock { $0 } }

        /// Forwards the event and remembers a tool result or a typed command's output.
        public func write(_ event: AuditEvent) {
            if event.kind == .toolResult || event.kind == .commandTyped,
                let output = event.details["output"]?.stringValue
            {
                last.withLock { $0 = output }
            }
            handler.withLock { $0 }?(event)
        }
    }
}
