import Synchronization

/// Keeps a conversation's recent `tool.call` and `tool.result` events in memory, so the agent can link
/// the tool calls and outputs of a turn's transcript to the audit events that recorded them
/// (`ConversationStore`). The tools record their own events, which the agent never sees; a conversation
/// adds this sink to its audit log (`Conversation.setUp`) and hands it to the agent.
///
/// Bounded: only the newest `capacity` events are kept, and taking a turn's events forgets that turn and
/// everything older.
public final class ToolEventTrail: AuditSink, Sendable {
    /// The kept events, oldest first.
    private let events = Mutex<[AuditEvent]>([])
    /// How many events are kept at most.
    public let capacity: Int

    /// Creates an empty trail.
    ///
    /// - Parameter capacity: How many events to keep; older ones are dropped first.
    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// Keeps a tool call or result, dropping the oldest beyond the capacity; ignores every other kind.
    public func write(_ event: AuditEvent) {
        guard event.kind == .toolCall || event.kind == .toolResult else { return }
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
