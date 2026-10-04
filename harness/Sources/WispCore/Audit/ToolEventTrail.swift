import Synchronization

/// Keeps a conversation's recent tool events in memory, so the agent can link the tool calls and outputs of a
/// turn's transcript to the audit events that recorded them (`ThreadRecord`), and count what the turn ran
/// (`TurnToolSummary`): `tool.call` and `tool.result`, and the `policy.decision`, `command.outcome`, and
/// `error` events that say how a call ended; and `model.reasoning`, whose `end` holds the thinking a reasoning entry
/// refers to (ADR 0053). The tools record their own events, which the agent never sees; a conversation
/// adds this sink to its audit log (`WispThread.setUp`) and hands it to the agent.
///
/// Bounded: only the newest `capacity` events are kept, and taking a turn's events forgets that turn and
/// everything older.
public final class ToolEventTrail: AuditSink, Sendable {
    /// The kept events, oldest first.
    private let events = Mutex<[AuditEvent]>([])
    /// How many events are kept at most.
    public let capacity: Int
    /// The kinds kept.
    static let kinds: Set<AuditEvent.Kind> = [
        .toolCall, .toolResult, .policyDecision, .commandOutcome, .error, .modelReasoning,
    ]

    /// Creates an empty trail.
    ///
    /// - Parameter capacity: How many events to keep; older ones are dropped first.
    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// Keeps a tool event, dropping the oldest beyond the capacity; ignores every other kind.
    public func write(_ event: AuditEvent) {
        guard Self.kinds.contains(event.kind) else { return }
        events.withLock {
            $0.append(event)
            if $0.count > capacity { $0.removeFirst($0.count - capacity) }
        }
    }

    /// The events of `turn`, in the order they were written; forgets that turn and earlier ones.
    func take(turn: Int) -> [AuditEvent] {
        events.withLock { all in
            let mine = all.filter { $0.turn == turn }
            all.removeAll { ($0.turn ?? 0) <= turn }
            return mine
        }
    }
}
