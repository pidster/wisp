import Foundation
import Synchronization

/// What one turn did, summarised from its audit events so the caller of `respond` can verify
/// delegated work without reading the log ([ADR 0021](../../../../docs/decisions/0021-receipts.md)).
///
/// A receipt is derived, never recorded: the audit log stays the single source of truth and the
/// receipt is the same facts folded to what a caller checks. Outputs are left out (the log has them,
/// verbatim); counts, statuses, and timings are kept.
public struct Receipt: Equatable, Sendable {
    /// One tool call the model made.
    public struct ToolUse: Equatable, Sendable {
        /// The tool's name.
        public var name: String
        /// The arguments the model produced, as JSON.
        public var arguments: String
        /// Size of the result the model saw; nil when the call failed.
        public var bytes: Int?
        /// How long the call took; nil when the call failed before a result.
        public var seconds: Double?
        /// The error, when the tool threw.
        public var error: String?
    }

    /// One command that ran.
    public struct Command: Equatable, Sendable {
        /// The command line.
        public var command: String
        /// Its exit status.
        public var exitStatus: Int
        /// Whether the timeout stopped it.
        public var timedOut: Bool
        /// Whether its output was cut to the bound.
        public var truncated: Bool
        /// How long it ran.
        public var seconds: Double
    }

    /// One file the model wrote.
    public struct FileWrite: Equatable, Sendable {
        /// The path as given.
        public var path: String
        /// `write`, `append`, or `replace`.
        public var mode: String
        /// Whether the file was created.
        public var created: Bool
        /// Size after the edit.
        public var bytes: Int
    }

    /// One command the policy or the gate turned away before it ran.
    public struct Denial: Equatable, Sendable {
        /// The command line.
        public var command: String
        /// `denied` (policy) or `disapproved` (gate).
        public var verdict: String
        /// Why, when the policy said.
        public var reason: String?
    }

    /// One approval decision the gate made.
    public struct Approval: Equatable, Sendable {
        /// The simple command judged.
        public var command: String
        /// The risk level it was judged at, when it was asked about.
        public var level: String?
        /// `approved`, `denied`, `timed-out`, or a `cached…` value (`docs/logging.md`).
        public var decision: String
        /// The scope an approval was given at, when it was.
        public var scope: String?
    }

    /// At most this many entries per list; the audit log has the rest.
    public static let maxEntries = 64

    /// The turn summarised.
    public var turn: Int
    /// Tool calls in order.
    public var tools: [ToolUse] = []
    /// Commands that ran, in order.
    public var commands: [Command] = []
    /// Files written, in order.
    public var files: [FileWrite] = []
    /// Commands turned away before running.
    public var denials: [Denial] = []
    /// Approval decisions, in order.
    public var approvals: [Approval] = []
    /// Errors not tied to a tool call, such as a failed turn.
    public var errors: [String] = []
    /// Whether older turns were dropped to fit the window during this turn.
    public var condensed = false
    /// Wall-clock seconds from prompt to response, when the turn completed.
    public var seconds: Double?
    /// The tokens the turn's requests used, as the runtime reported them; nil when it reported none (Apple's
    /// models) or the turn did not complete.
    public var usage: TurnTokens?

    /// Folds the events of `turn` into a receipt. Events of other turns are ignored.
    ///
    /// - Parameters:
    ///   - events: Audit events of one session, in the order they were written.
    ///   - turn: The turn to summarise.
    public init(events: [AuditEvent], turn: Int) {
        self.turn = turn
        var toolIndex: [String: Int] = [:]
        for event in events where event.turn == turn {
            let d = event.details
            switch event.kind {
            case .toolCall:
                if let call = event.call { toolIndex[call] = tools.count }
                append(
                    &tools,
                    ToolUse(
                        name: d["tool"]?.stringValue ?? "", arguments: d["arguments"]?.stringValue ?? "", bytes: nil,
                        seconds: nil, error: nil))
            case .toolResult:
                if let call = event.call, let index = toolIndex[call] {
                    tools[index].bytes = d["bytes"]?.intValue
                    tools[index].seconds = d["seconds"]?.doubleValue
                }
            case .commandOutcome:
                append(
                    &commands,
                    Command(
                        command: d["command"]?.stringValue ?? "", exitStatus: d["exitStatus"]?.intValue ?? -1,
                        timedOut: d["timedOut"]?.boolValue ?? false, truncated: d["truncated"]?.boolValue ?? false,
                        seconds: d["seconds"]?.doubleValue ?? 0))
            case .fileWrite:
                append(
                    &files,
                    FileWrite(
                        path: d["path"]?.stringValue ?? "", mode: d["mode"]?.stringValue ?? "",
                        created: d["created"]?.boolValue ?? false, bytes: d["bytesAfter"]?.intValue ?? 0))
            case .policyDecision:
                let verdict = d["verdict"]?.stringValue ?? ""
                if verdict != "allowed" {
                    append(
                        &denials,
                        Denial(
                            command: d["command"]?.stringValue ?? "", verdict: verdict, reason: d["reason"]?.stringValue
                        ))
                }
            case .approvalRequested:
                if let level = d["level"]?.stringValue { pendingLevels[d["command"]?.stringValue ?? ""] = level }
            case .approvalDecided:
                let command = d["command"]?.stringValue ?? ""
                append(
                    &approvals,
                    Approval(
                        command: command, level: pendingLevels.removeValue(forKey: command),
                        decision: d["decision"]?.stringValue ?? "", scope: d["scope"]?.stringValue))
            case .response:
                condensed = d["condensed"]?.boolValue ?? false
                seconds = d["seconds"]?.doubleValue
                usage = TurnTokens(json: d["usage"])
            case .condensation:
                condensed = true
            case .error:
                let message = d["message"]?.stringValue ?? ""
                if let call = event.call, let index = toolIndex[call] {
                    tools[index].error = message
                } else {
                    append(&errors, message)
                }
            default:
                break
            }
        }
        pendingLevels = [:]
    }

    /// Levels from `approval.requested` awaiting their `approval.decided`, by command.
    private var pendingLevels: [String: String] = [:]

    /// Appends within the bound.
    private func append<T>(_ list: inout [T], _ element: T) {
        if list.count < Self.maxEntries { list.append(element) }
    }

    /// The receipt as JSON, the shape `respond` returns (`docs/mcp.md`); `usage` only when the runtime reported it.
    public var json: JSONValue {
        guard var fields = fields.objectValue else { return fields }
        if let usage { fields["usage"] = usage.json }
        return .object(fields)
    }

    /// Every field but `usage`.
    private var fields: JSONValue {
        .object([
            "turn": .int(turn),
            "tools": .array(
                tools.map {
                    var fields: [String: JSONValue] = ["name": .string($0.name), "arguments": .string($0.arguments)]
                    if let bytes = $0.bytes { fields["bytes"] = .int(bytes) }
                    if let seconds = $0.seconds { fields["seconds"] = .double(seconds) }
                    if let error = $0.error { fields["error"] = .string(error) }
                    return .object(fields)
                }),
            "commands": .array(
                commands.map {
                    .object([
                        "command": .string($0.command), "exitStatus": .int($0.exitStatus),
                        "timedOut": .bool($0.timedOut),
                        "truncated": .bool($0.truncated), "seconds": .double($0.seconds),
                    ])
                }),
            "files": .array(
                files.map {
                    .object([
                        "path": .string($0.path), "mode": .string($0.mode), "created": .bool($0.created),
                        "bytes": .int($0.bytes),
                    ])
                }),
            "denials": .array(
                denials.map {
                    var fields: [String: JSONValue] = ["command": .string($0.command), "verdict": .string($0.verdict)]
                    if let reason = $0.reason { fields["reason"] = .string(reason) }
                    return .object(fields)
                }),
            "approvals": .array(
                approvals.map {
                    var fields: [String: JSONValue] = [
                        "command": .string($0.command), "decision": .string($0.decision),
                    ]
                    if let level = $0.level { fields["level"] = .string(level) }
                    if let scope = $0.scope { fields["scope"] = .string(scope) }
                    return .object(fields)
                }),
            "errors": .array(errors.map { .string($0) }),
            "condensed": .bool(condensed),
            "seconds": seconds.map { .double($0) } ?? .null,
        ])
    }
}

/// Keeps a conversation's recent audit events in memory so a receipt can be built for the turn that
/// just finished. Bounded: only the newest `capacity` events are kept, and taking a turn's receipt
/// drops that turn and everything older.
public final class ReceiptCollector: AuditSink, Sendable {
    private let events = Mutex<[AuditEvent]>([])
    /// How many events are kept at most.
    public let capacity: Int

    /// Creates an empty collector.
    ///
    /// - Parameter capacity: How many events to keep; older ones are dropped first.
    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// Keeps the event, dropping the oldest beyond the capacity.
    public func write(_ event: AuditEvent) {
        events.withLock {
            $0.append(event)
            if $0.count > capacity { $0.removeFirst($0.count - capacity) }
        }
    }

    /// The receipt for `turn`, and forgets that turn and earlier ones.
    public func take(turn: Int) -> Receipt {
        Receipt(events: takeEvents(turn: turn), turn: turn)
    }

    /// The events of `turn`, in the order they were written, for folding more than a receipt from them
    /// (`TurnCalls`); forgets that turn and earlier ones.
    public func takeEvents(turn: Int) -> [AuditEvent] {
        events.withLock { all in
            let mine = all.filter { $0.turn == turn }
            all.removeAll { ($0.turn ?? 0) <= turn }
            return mine
        }
    }
}

/// Writes every event to each of its sinks, in order.
public struct TeeAuditSink: AuditSink {
    /// The sinks written to.
    public let sinks: [any AuditSink]

    /// Creates a sink over `sinks`.
    public init(_ sinks: [any AuditSink]) {
        self.sinks = sinks
    }

    /// Writes to every sink.
    public func write(_ event: AuditEvent) {
        for sink in sinks { sink.write(event) }
    }
}
