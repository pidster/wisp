import Foundation
import FoundationModels
import WispCore

/// Everything the server keeps for one open `thread_id`: the thread, the gate its tools consult, and
/// the audit log its events go to. Created together by the thread factory and dropped together.
public struct OpenThread: Sendable {
    /// Answers prompts on this thread.
    public let thread: any RespondingThread
    /// The gate, kept so a turn's refusals can be reported in the result.
    public let gate: ApprovalGate
    /// The thread's audit session.
    public let audit: AuditLog
    /// The turn's events, folded into the result's `receipt`.
    public let receipts: ReceiptCollector
    /// The same events as they happen, relayed to a caller that asked for progress.
    public let relay: EventRelay
    /// The model the thread runs on, as `ModelSelection` spells it; nil when unknown.
    public let model: String?
    /// The tools its model may call.
    public let tools: [String]
    /// Serialises its turns, so concurrent calls on one `thread_id` take turns and each gets its own receipt.
    public let turns = TurnQueue()

    /// Creates the record.
    public init(
        thread: any RespondingThread, gate: ApprovalGate, audit: AuditLog,
        receipts: ReceiptCollector = ReceiptCollector(), relay: EventRelay = EventRelay(), model: String? = nil,
        tools: [String] = []
    ) {
        self.model = model
        self.tools = tools
        self.thread = thread
        self.gate = gate
        self.audit = audit
        self.receipts = receipts
        self.relay = relay
    }
}

/// Keeps live threads by id with a bounded, least-recently-used capacity.
///
/// Generic over the thread type so the eviction policy is testable without a model.
public actor ThreadRegistry<Thread: Sendable> {
    /// Why a thread could not be opened or found.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A thread with this id already exists.
        case alreadyExists(String)
        /// No thread has this id.
        case notFound(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .alreadyExists(let id): "thread already exists: \(id)"
            case .notFound(let id): "no such thread: \(id)"
            }
        }
    }

    /// Maximum live threads before eviction.
    private let capacity: Int
    /// Live threads by id.
    private var threads: [String: Thread] = [:]
    /// Ids ordered least recently used first.
    private var recency: [String] = []

    /// Creates a store that keeps at most `capacity` threads, evicting the least recently used.
    public init(capacity: Int = 32) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Ids of live threads, most recently used first.
    public var ids: [String] { recency.reversed() }

    /// The outcome of `findOrCreate`.
    public struct Opened: Sendable {
        /// The thread, found or new.
        public let thread: Thread
        /// Whether it was created by this call.
        public let created: Bool
        /// The thread evicted to make room, if any.
        public let evicted: Evicted?
    }

    /// A thread dropped to make room for another.
    public struct Evicted: Sendable {
        /// Its id.
        public let id: String
        /// The thread itself, so the caller can close it down.
        public let thread: Thread
    }

    /// Creates and stores a thread, evicting the least recently used one if at capacity.
    ///
    /// - Returns: The thread and the evicted thread, if any.
    /// - Throws: `Failure.alreadyExists`, or whatever `make` throws.
    public func create(id: String, _ make: () throws -> Thread) throws -> (thread: Thread, evicted: Evicted?) {
        guard threads[id] == nil else { throw Failure.alreadyExists(id) }
        let thread = try make()
        var evicted: Evicted?
        if threads.count >= capacity, let oldest = recency.first, let dropped = threads[oldest] {
            threads[oldest] = nil
            recency.removeFirst()
            evicted = Evicted(id: oldest, thread: dropped)
        }
        threads[id] = thread
        recency.append(id)
        return (thread, evicted)
    }

    /// Finds the thread with `id`, marking it used, or creates it in one actor step so concurrent
    /// callers naming the same new id cannot race each other into `alreadyExists`.
    ///
    /// - Throws: Whatever `make` throws.
    public func findOrCreate(id: String, _ make: () throws -> Thread) throws -> Opened {
        if let existing = find(id) { return Opened(thread: existing, created: false, evicted: nil) }
        let made = try create(id: id, make)
        return Opened(thread: made.thread, created: true, evicted: made.evicted)
    }

    /// Returns the thread with `id` without marking it used, or nil: for reading about a thread, which is
    /// not using it.
    public func peek(_ id: String) -> Thread? { threads[id] }

    /// Returns the thread with `id`, marking it most recently used, or nil.
    public func find(_ id: String) -> Thread? {
        guard let thread = threads[id] else { return nil }
        recency.removeAll { $0 == id }
        recency.append(id)
        return thread
    }

    /// Removes and returns the thread with `id`.
    ///
    /// - Throws: `Failure.notFound` if there is none.
    @discardableResult
    public func close(_ id: String) throws -> Thread {
        guard let thread = threads.removeValue(forKey: id) else { throw Failure.notFound(id) }
        recency.removeAll { $0 == id }
        return thread
    }
}
