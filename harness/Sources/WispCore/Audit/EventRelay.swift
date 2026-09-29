import Foundation
import Synchronization

/// Passes a conversation's audit events, as they are recorded, to whoever is listening for the moment:
/// the MCP server relays them to a caller as progress while one of its calls runs. Listeners come and
/// go; with none, events pass through untouched.
public final class EventRelay: AuditSink, Sendable {
    private let listeners = Mutex<[UUID: @Sendable (AuditEvent) -> Void]>([:])

    /// Creates a relay with no listeners.
    public init() {}

    /// Starts passing events to `handler`; stop with the returned id.
    public func listen(_ handler: @escaping @Sendable (AuditEvent) -> Void) -> UUID {
        let id = UUID()
        listeners.withLock { $0[id] = handler }
        return id
    }

    /// Stops passing events to the listener `id`.
    public func stop(_ id: UUID) {
        _ = listeners.withLock { $0.removeValue(forKey: id) }
    }

    /// Passes the event to every listener.
    public func write(_ event: AuditEvent) {
        for handler in listeners.withLock({ Array($0.values) }) { handler(event) }
    }
}
