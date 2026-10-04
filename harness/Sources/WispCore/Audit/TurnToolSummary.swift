import Foundation

/// What one turn actually ran, counted from the turn's own audit events and shown beside the reply
/// ([ADR 0051](../../../../docs/decisions/0051-the-turns-tool-calls-beside-the-reply.md)): chat prints it under
/// the reply, `wisp chat --json` carries it on the turn's end, and `respond` returns it as `ran`.
///
/// It is facts, not a judgement: nothing here reads the reply to decide what the model claimed, and nothing
/// compares the two. A model that says it ran something it did not is answered by the line under its reply.
/// Like `Receipt` and `TurnCalls`, it is derived and never recorded; the audit log stays the one record.
public struct TurnToolSummary: Equatable, Sendable {
    /// How one call ended, as the line counts it.
    public enum Outcome: Equatable, Sendable {
        /// It ran and succeeded.
        case succeeded
        /// It ran and failed: a non-zero exit status, a timeout, a command that could not start, a tool that threw,
        /// or a tool that answered with `error: …`.
        case failed
        /// The policy's patterns turned it away; it never ran.
        case denied
        /// The gate asked and the person declined, or did not answer in time; it never ran.
        case declined
    }

    /// One tool's calls in the turn.
    public struct Tally: Equatable, Sendable {
        /// The tool's name.
        public var tool: String
        /// How many times the model called it.
        public var calls = 0
        /// How many of those failed.
        public var failed = 0
        /// How many the policy denied.
        public var denied = 0
        /// How many the person declined.
        public var declined = 0
    }

    /// The most tools the line names; the rest are counted as `+N more`.
    public static let maxTools = 6

    /// Each tool the turn called, in the order of its first call.
    public var tallies: [Tally] = []

    /// Counts the calls of `turn` in `events`, every one of them (`TurnCalls` with no limit).
    ///
    /// - Parameters:
    ///   - events: Audit events of one session, in the order they were written.
    ///   - turn: The turn to count.
    public init(events: [AuditEvent], turn: Int) {
        self.init(calls: TurnCalls(events: events, turn: turn, limit: .max).calls)
    }

    /// Counts `calls`.
    ///
    /// - Parameter calls: A turn's calls, in order.
    public init(calls: [TurnCalls.Call]) {
        var index: [String: Int] = [:]
        for call in calls {
            if index[call.tool] == nil {
                index[call.tool] = tallies.count
                tallies.append(Tally(tool: call.tool))
            }
            let at = index[call.tool] ?? 0
            tallies[at].calls += 1
            switch Self.outcome(of: call) {
            case .succeeded: break
            case .failed: tallies[at].failed += 1
            case .denied: tallies[at].denied += 1
            case .declined: tallies[at].declined += 1
            }
        }
    }

    /// How `call` ended. A verdict from the policy comes first, since a command turned away never ran; then a
    /// thrown error; then, for a command, its exit status and timeout (one with no `command.outcome` never
    /// started); then, for any other tool, whether it answered with wisp's `error: …` convention (`ToolOutput`).
    ///
    /// - Parameter call: One call of a turn.
    /// - Returns: Its outcome.
    static func outcome(of call: TurnCalls.Call) -> Outcome {
        switch call.verdict {
        case "disapproved"?: return .declined
        case .some: return .denied
        case nil: break
        }
        if call.error != nil { return .failed }
        if call.command != nil {
            guard let status = call.exitStatus else { return .failed }
            return status != 0 || call.timedOut ? .failed : .succeeded
        }
        guard let output = call.output else { return .failed }
        return output.hasPrefix("error:") ? .failed : .succeeded
    }

    /// The line shown beside the reply, such as `ran: read_file ×2 · run_command ×10 (2 failed, 1 denied) ·
    /// notify`, or nil when there is nothing to show.
    ///
    /// A turn that ran no tool shows nothing, unless its reply names one of `tools` as a whole word: then it shows
    /// `ran: no tools`. This is the one heuristic in the summary, and it is deliberately narrow. A reply that
    /// names a tool after running none may be describing work that did not happen (two granite4.1:8b runs on
    /// 2026-10-04 did exactly that, ADR 0051), and a turn that ran nothing has no other line to say so; a reply
    /// that names no tool needs no such line, and showing one under every plain answer would be noise.
    ///
    /// - Parameters:
    ///   - reply: The turn's reply text.
    ///   - tools: The names of the tools the conversation has.
    /// - Returns: The line, or nil.
    public func line(reply: String, tools: [String]) -> String? {
        guard !tallies.isEmpty else {
            return tools.contains { Self.mentions($0, in: reply) } ? "ran: no tools" : nil
        }
        var parts = tallies.prefix(Self.maxTools).map { tally in
            var part = tally.calls > 1 ? "\(tally.tool) ×\(tally.calls)" : tally.tool
            let notes = [(tally.failed, "failed"), (tally.denied, "denied"), (tally.declined, "declined")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            if !notes.isEmpty { part += " (\(notes.joined(separator: ", ")))" }
            return part
        }
        if tallies.count > Self.maxTools { parts.append("+\(tallies.count - Self.maxTools) more") }
        return "ran: " + parts.joined(separator: " · ")
    }

    /// Whether `name` occurs in `text` as a whole word: not inside a longer identifier, so `read_file` is found in
    /// "used read_file()" but not in "unread_files".
    ///
    /// - Parameters:
    ///   - name: A tool's name.
    ///   - text: The reply.
    /// - Returns: Whether it is named.
    static func mentions(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        let isWord = { (character: Character) in character.isLetter || character.isNumber || character == "_" }
        var rest = text[...]
        while let found = rest.range(of: name) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !(before.map(isWord) ?? false), !(after.map(isWord) ?? false) { return true }
            rest = text[found.upperBound...]
        }
        return false
    }
}
