import Foundation
import Synchronization
import WispCore

/// What the server remembers about each `respond` thread it has opened, open or not, for the
/// `wisp://threads` resources: its model, tools, whether the caller gave it instructions, when it was
/// created and last used, how many turns it has had, whether it is still open, and the audit session its events
/// carry. The thread itself, and its context, go when it is closed or evicted; this record stays, so a caller can
/// still find its output and audit, which the audit log keeps.
///
/// Bounded: at most `capacity` records; beyond it the record of the thread closed longest ago goes first.
/// A `final class` with a `Mutex`, since every operation is a short synchronous critical section.
public final class ThreadDirectory: Sendable {
    /// Whether a thread is still open.
    public enum State: String, Sendable, Equatable {
        /// Live in the server's thread store.
        case open
        /// Closed by `close_thread`.
        case closed
        /// Evicted to make room for another thread.
        case evicted
    }

    /// One thread's record.
    public struct Record: Sendable, Equatable {
        /// The `thread_id`.
        public var id: String
        /// The audit session its events carry: `<thread_id>-<suffix>`, one per opening, so a `thread_id` reused
        /// after `close_thread` has resources of its own (the 2026-10-09 review); the `id` itself for a thread
        /// opened without one.
        public var auditSession: String
        /// The model it runs on, as `ModelSelection` spells it; nil when unknown.
        public var model: String?
        /// The tools its model may call.
        public var tools: [String]
        /// Whether the caller gave it instructions (the conversation layer).
        public var instructions: Bool
        /// The thinking its turns ask of the model, as `respond`'s `think` set it; nil for the model's default.
        public var think: String?
        /// When it was created.
        public var created: Date
        /// When a `respond` last used it.
        public var lastActive: Date
        /// Turns it has had.
        public var turns: Int
        /// Open, closed, or evicted.
        public var state: State
    }

    /// The records, by id.
    private let records = Mutex<[String: Record]>([:])
    /// How many records are kept at most.
    public let capacity: Int

    /// Creates an empty directory.
    ///
    /// - Parameter capacity: How many records to keep; the longest-closed go first beyond it.
    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// The audit session for a thread opened now: the `thread_id` with a fresh eight-character suffix.
    ///
    /// - Parameter id: The `thread_id`.
    /// - Returns: The audit session.
    public static func auditSession(for id: String) -> String { "\(id)-\(ShortID.make())" }

    /// Records a thread just created, replacing any record of a thread with the same id that went before.
    ///
    /// - Parameters:
    ///   - id: The `thread_id`.
    ///   - auditSession: The audit session its events carry; `id` when nil.
    ///   - model: Its model, when known.
    ///   - tools: Its tools.
    ///   - instructions: Whether the caller gave it instructions.
    ///   - think: The thinking `respond`'s `think` set for it, as text; nil for the model's default.
    ///   - now: The time.
    public func opened(
        id: String, auditSession: String? = nil, model: String?, tools: [String], instructions: Bool,
        think: String? = nil, now: Date = Date()
    ) {
        records.withLock { records in
            records[id] = Record(
                id: id, auditSession: auditSession ?? id, model: model, tools: tools, instructions: instructions,
                think: think, created: now, lastActive: now, turns: 0, state: .open)
            let closed = records.values.filter { $0.state != .open }.sorted { $0.lastActive < $1.lastActive }
            for record in closed.prefix(max(0, records.count - capacity)) { records[record.id] = nil }
        }
    }

    /// Notes a turn on a thread: its turn count and the time.
    public func used(id: String, turns: Int, now: Date = Date()) {
        records.withLock { records in
            records[id]?.turns = turns
            records[id]?.lastActive = now
        }
    }

    /// Marks a thread closed or evicted.
    public func ended(id: String, as state: State) {
        records.withLock { $0[id]?.state = state }
    }

    /// The record of `id`, or nil.
    public func record(_ id: String) -> Record? { records.withLock { $0[id] } }

    /// The audit session of thread `id`: its record's, or `id` itself for a thread the directory does not know.
    public func auditSession(of id: String) -> String { record(id)?.auditSession ?? id }

    /// The `thread_id` of the thread whose conversation `conversation` is: a fact proposal names its conversation
    /// by the audit session (`Agent.threadID`, `<thread_id>-<suffix>`, with `.N` after a model switch), not by the
    /// `thread_id` a caller uses. Nil for a conversation that is not a thread this directory knows.
    ///
    /// - Parameter conversation: The conversation's name, as `FactProposal.threadID` holds it.
    /// - Returns: The thread's id, or nil.
    public func thread(ofConversation conversation: String) -> String? {
        records.withLock { records in
            records.values.first { record in
                conversation == record.auditSession || conversation.hasPrefix(record.auditSession + ".")
            }?.id
        }
    }

    /// Whether `session` is the audit session of a thread this directory knows, by id or by suffix.
    public func isThreadSession(_ session: String) -> Bool {
        records.withLock { records in records[session] != nil || records.values.contains { $0.auditSession == session }
        }
    }

    /// Every record, most recently active first.
    public var all: [Record] {
        records.withLock { Array($0.values) }.sorted { ($0.lastActive, $0.id) > ($1.lastActive, $1.id) }
    }
}
