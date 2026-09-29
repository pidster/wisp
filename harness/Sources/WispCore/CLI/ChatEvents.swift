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
        case .policyDecision where d["verdict"]?.stringValue != "allowed":
            let reason = d["reason"]?.stringValue.map { ": \($0)" } ?? ""
            return style.ember("  · blocked by policy\(reason)")
        case .modelRouted:
            return style.muted(
                "  · \(d["task"]?.stringValue ?? "task") runs on \(d["model"]?.stringValue ?? "?"): "
                    + (d["reason"]?.stringValue ?? ""))
        case .condensation:
            let reason = d["reason"]?.stringValue ?? ""
            return style.muted(
                "(context condensed, \(reason): \(d["turnsBefore"]?.intValue ?? 0) → \(d["turnsAfter"]?.intValue ?? 0) turns)"
            )
        default:
            return nil
        }
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

        /// Forwards the event and remembers a tool result.
        public func write(_ event: AuditEvent) {
            if event.kind == .toolResult, let output = event.details["output"]?.stringValue {
                last.withLock { $0 = output }
            }
            handler.withLock { $0 }?(event)
        }
    }
}
