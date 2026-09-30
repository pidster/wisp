import Foundation
import FoundationModels
import WispCore

/// What `WispServer.respond` needs from a thread, so tests can substitute one without a model.
public protocol RespondingThread: Sendable {
    /// Sends one user turn and returns the reply; with `schema`, the reply's text is JSON of that shape.
    func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply

    /// The model's context as `/inspect context <argument>` shows it (`ChatView.context(_:of:)`): the next
    /// request's for `next`, or the one composed at the start of a numbered turn; nil when the thread cannot
    /// show its context.
    func context(_ argument: String) async -> Result<ChatView, ChatView.Failure>?

    /// The thread's turns with what changed at each (`ContextView.turns(of:)`); nil when it cannot show them.
    func contextTurns() async -> [ContextView.Turn]?

    /// Sets the thread's task as the caller's assertion (decision D6).
    ///
    /// - Parameter task: The task.
    /// - Throws: `FactFailure` when the thread keeps no facts.
    func setTask(_ task: String) async throws

    /// Every fact the thread sees, in any state (`Agent.allFacts`); nil when it keeps none.
    func facts() async -> [Fact]?
}

extension RespondingThread {
    /// None: a thread without a conversation store cannot show its context.
    public func context(_ argument: String) async -> Result<ChatView, ChatView.Failure>? { nil }

    /// None, as for `context(_:)`.
    public func contextTurns() async -> [ContextView.Turn]? { nil }

    /// Refused: a thread without a conversation store keeps no facts.
    public func setTask(_ task: String) async throws { throw FactFailure.off }

    /// None, as for `context(_:)`.
    public func facts() async -> [Fact]? { nil }
}

/// One conversation with the on-device model, addressable by id across MCP calls.
///
/// An actor so that calls on the same thread serialise (a session cannot answer
/// two prompts at once) while different threads run concurrently.
public actor ConversationThread: RespondingThread {
    /// The identifier clients pass as `thread_id`.
    public nonisolated let id: String
    /// The conversation; isolated to this actor because it is not `Sendable`.
    private let agent: Agent

    /// Wraps an agent opened from a `Conversation` the session set up for this thread.
    public init(id: String, agent: Agent) {
        self.id = id
        self.agent = agent
    }

    /// Sends one user turn on this thread's session, shaped by `schema` when given.
    public func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply {
        if let schema { return try await agent.respond(to: prompt, schema: schema) }
        return try await agent.respond(to: prompt)
    }

    /// The agent's context, composed from its store without a model call.
    public func context(_ argument: String) async -> Result<ChatView, ChatView.Failure>? {
        ChatView.context(argument, of: agent)
    }

    /// The agent's turns, from its store.
    public func contextTurns() async -> [ContextView.Turn]? { ContextView.turns(of: agent) }

    /// Sets the agent's task as the caller's.
    public func setTask(_ task: String) async throws { try agent.setTask(task, source: .caller) }

    /// The agent's facts, or nil when it keeps none; proposals approved elsewhere are marked superseded first.
    public func facts() async -> [Fact]? {
        guard agent.facts != nil else { return nil }
        agent.syncProposals()
        return agent.allFacts
    }
}

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
public actor ThreadStore<Thread: Sendable> {
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
