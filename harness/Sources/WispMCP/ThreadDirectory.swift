import Foundation
import Synchronization
import WispCore

/// What the server remembers about each `respond` thread it has opened, open or not, for the
/// `wisp://threads` resources: its model, tools, whether the caller gave it instructions, when it was
/// created and last used, how many turns it has had, and whether it is still open. The thread itself, and
/// its context, go when it is closed or evicted; this record stays, so a caller can still find its output
/// and audit, which the audit log keeps.
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
        /// The model it runs on, as `ModelSelection` spells it; nil when unknown.
        public var model: String?
        /// The tools its model may call.
        public var tools: [String]
        /// Whether the caller gave it instructions (the conversation layer).
        public var instructions: Bool
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

    /// Records a thread just created, replacing any record of a thread with the same id that went before.
    ///
    /// - Parameters:
    ///   - id: The `thread_id`.
    ///   - model: Its model, when known.
    ///   - tools: Its tools.
    ///   - instructions: Whether the caller gave it instructions.
    ///   - now: The time.
    public func opened(id: String, model: String?, tools: [String], instructions: Bool, now: Date = Date()) {
        records.withLock { records in
            records[id] = Record(
                id: id, model: model, tools: tools, instructions: instructions, created: now, lastActive: now,
                turns: 0, state: .open)
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

    /// Every record, most recently active first.
    public var all: [Record] {
        records.withLock { Array($0.values) }.sorted { ($0.lastActive, $0.id) > ($1.lastActive, $1.id) }
    }
}
