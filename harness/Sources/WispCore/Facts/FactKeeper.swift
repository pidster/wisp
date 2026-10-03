import Foundation
import Synchronization

/// Asks the person, through another of wisp's faces, to keep a fact as a permanent fact when an MCP caller asks
/// for one ([ADR 0048](../../../../docs/decisions/0048-permanent-facts-over-mcp.md)). Only the person admits a
/// permanent fact (D2 of [ADR 0045](../../../../docs/decisions/0045-layered-context.md)); the caller can only
/// ask.
///
/// The request is filed in the pending channel (`PendingApprovals`, kind `fact`) and the person is told by a
/// notification naming the fact and the command that answers it (`wisp facts keep ID`); they answer from a
/// terminal with `wisp facts keep|drop`, or in a running `wisp-tui`. The caller's call does not wait: `ask`
/// files the request, starts a watch, and returns. The watch polls the channel until the answer, the bound
/// (`approval.timeoutSeconds`), or the thread's closing, and applies the answer through the closure the server
/// gave: `keep` admits the fact to the shared store as the person's, `drop` leaves it in its thread and is
/// remembered, so the same fact (its subject, name, and value) is not asked about again by that thread. Silence
/// keeps nothing and is not remembered. Every step is audited on the asking thread's log: `approval.pending`,
/// the `notification`, and `approval.settled`, each with `kind` `fact`.
///
/// Every operation is a short critical section, so this is a `final class` with a `Mutex`
/// (`docs/design.md`, "Concurrency"); the watches are tasks it holds so a closing thread can stop its own.
public final class FactKeeper: Sendable {
    /// Where a request stands.
    public enum State: String, Sendable, Equatable {
        /// Filed; no answer yet.
        case pending
        /// The person kept it: the shared store holds it as `Record.kept`.
        case kept
        /// The person dropped it: it stays in its thread, and the thread is not asked about it again.
        case dropped
        /// Nobody answered within the bound; nothing was kept, and the caller may ask again.
        case timedOut = "timed-out"
        /// The thread closed, or the server stopped, before an answer.
        case withdrawn
        /// The answer could not be applied (the fact changed or went, the store could not be written), or
        /// the request could not be filed or watched; `Record.reason` says why.
        case failed
    }

    /// One request and where it stands.
    public struct Record: Sendable, Equatable {
        /// The request as filed.
        public var request: PendingApprovals.Request
        /// The thread that asked.
        public var thread: String
        /// The fact asked about, by its id in the thread or the session.
        public var fact: String
        /// Where it stands.
        public var state: State
        /// The permanent fact's id, once kept.
        public var kept: String?
        /// Where the person answered: `cli` or `tui`.
        public var via: String?
        /// Why it failed.
        public var reason: String?
        /// When it stopped waiting.
        public var settledAt: Date?
    }

    /// What applying an answer did.
    public enum Applied: Sendable, Equatable {
        /// The fact is in the shared store under this id.
        case kept(String)
        /// The fact stays in its thread.
        case dropped
        /// The answer could not be applied.
        case failed(String)
    }

    /// Applies the person's answer, `keep` or `drop`, to the thread's fact; given the request's id for the audit.
    public typealias Apply = @Sendable (_ decision: String, _ request: String) async -> Applied

    /// What `ask` did.
    public enum Asked: Sendable, Equatable {
        /// A request was filed and the person told.
        case filed(Record)
        /// A request for this fact already waits; nothing new was filed.
        case waiting(Record)
        /// The person dropped this fact for this thread before; nobody is asked again.
        case dropped(Record)
    }

    /// The keeper's state.
    private struct Contents {
        /// Every request, oldest first; pending ones are always kept.
        var records: [Record] = []
        /// What each thread's person dropped: `subject`, `name`, and `value`, joined.
        var dropped: [String: [String: Record]] = [:]
        /// The watches, by request id.
        var watches: [String: Task<Void, Never>] = [:]
    }

    /// The contents, behind the lock.
    private let contents = Mutex(Contents())
    /// Where requests are filed.
    public let channel: PendingApprovals
    /// How long a request waits; nil for ever.
    public let timeout: Duration?
    /// The MCP client's name, for the request.
    private let client: @Sendable () -> String?
    /// Posts the notification that a request waits, audited on the thread's log.
    private let notify: @Sendable (Notifier.Message, AuditLog?) -> Void
    /// How often the channel is checked for an answer.
    private let poll: Duration
    /// How many settled records are kept.
    static let historyLimit = 200

    /// Creates a keeper.
    ///
    /// - Parameters:
    ///   - channel: The pending channel.
    ///   - timeout: How long a request waits (`approval.timeoutSeconds`); nil for ever.
    ///   - client: The MCP client's name.
    ///   - notify: Posts a notification (the host's routes, source `approval`).
    ///   - poll: How often to look for an answer.
    public init(
        channel: PendingApprovals, timeout: Duration?, client: @escaping @Sendable () -> String? = { nil },
        notify: @escaping @Sendable (Notifier.Message, AuditLog?) -> Void, poll: Duration = .milliseconds(200)
    ) {
        self.channel = channel
        self.timeout = timeout
        self.client = client
        self.notify = notify
        self.poll = poll
    }

    /// The fact a request names, from `fact` as its thread holds it.
    public static func proposed(_ fact: Fact) -> PendingApprovals.ProposedFact {
        .init(
            id: fact.id, subject: fact.identity.subject, name: fact.identity.name, value: fact.value,
            source: fact.source.rawValue)
    }

    /// The key a dropped fact is remembered under: what it says, not its id, so a later version with the same
    /// value is not asked about again.
    static func dropKey(_ fact: PendingApprovals.ProposedFact) -> String {
        [fact.subject, fact.name, fact.value].joined(separator: "\u{1F}")
    }

    /// The notification for a waiting fact request: the fact, who proposed it, and how to answer it.
    ///
    /// - Parameter request: The filed request.
    /// - Returns: The message; `Notifier` bounds it.
    public static func message(for request: PendingApprovals.Request) -> Notifier.Message {
        let text = request.subject.count > 120 ? String(request.subject.prefix(119)) + "…" : request.subject
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self).joined(separator: ", ")
        let source = request.fact.map { "from the \($0.source)" } ?? ""
        return Notifier.Message(
            title: "wisp: keep as a permanent fact?",
            body: "\(text) — wisp facts keep \(request.id)",
            subtitle: [source, from].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// Every request, oldest first.
    public var records: [Record] { contents.withLock { $0.records } }

    /// The latest request about fact `fact` of `thread`, or nil.
    public func record(thread: String, fact: String) -> Record? {
        contents.withLock { $0.records.last { $0.thread == thread && $0.fact == fact } }
    }

    /// The pending requests, oldest first.
    public var pending: [Record] { records.filter { $0.state == .pending } }

    /// Asks the person to keep `fact`, unless a request for it already waits or the person dropped it for this
    /// thread. Returns at once; the answer is applied by `apply` when it comes.
    ///
    /// - Parameters:
    ///   - fact: The fact as the thread holds it.
    ///   - thread: The MCP `thread_id`.
    ///   - audit: The thread's log.
    ///   - apply: Applies the answer to the thread's fact.
    /// - Returns: What was done.
    /// - Throws: `PendingApprovals.Failure` when the request could not be filed; audited as `approval.pending`
    ///   with outcome `failed`.
    public func ask(_ fact: Fact, thread: String, audit: AuditLog?, apply: @escaping Apply) throws -> Asked {
        let proposed = Self.proposed(fact)
        let request = PendingApprovals.request(keeping: proposed, thread: thread, client: client(), timeout: timeout)
        let earlier = contents.withLock { contents -> Asked? in
            if let dropped = contents.dropped[thread]?[Self.dropKey(proposed)] { return .dropped(dropped) }
            if let waiting = contents.records.last(where: {
                $0.thread == thread && $0.fact == fact.id && $0.state == .pending
            }) {
                return .waiting(waiting)
            }
            return nil
        }
        if let earlier { return earlier }
        do {
            try channel.file(request)
        } catch {
            audit?.record(
                .approvalPending,
                details: AuditEvent.Details.approvalPending(
                    request, outcome: "failed", alongside: nil, reason: "\(error)"))
            throw error
        }
        audit?.record(
            .approvalPending, details: AuditEvent.Details.approvalPending(request, outcome: "filed", alongside: nil))
        let record = Record(request: request, thread: thread, fact: fact.id, state: .pending)
        contents.withLock { $0.records.append(record) }
        notify(Self.message(for: request), audit)
        let started = Date()
        let task = Task { [self] in
            let (state, answer) = await watch(request, audit: audit)
            await settle(request, state: state, answer: answer, started: started, audit: audit, apply: apply)
        }
        contents.withLock { contents in
            if contents.records.contains(where: { $0.request.id == request.id && $0.state == .pending }) {
                contents.watches[request.id] = task
            }
        }
        return .filed(record)
    }

    /// Waits for the answer to `request`: the answer, the bound, the request's removal, or cancellation. An
    /// answer not bound to the request is refused and audited, and the wait goes on.
    private func watch(
        _ request: PendingApprovals.Request, audit: AuditLog?
    ) async -> (State, PendingApprovals.Answer?) {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while !Task.isCancelled {
            switch channel.take(request) {
            case .answer(let answer)?:
                return (answer.decision == "keep" ? .kept : .dropped, answer)
            case .rejected(let reason)?:
                audit?.record(
                    .approvalAnswered,
                    details: AuditEvent.Details.approvalAnswered(
                        request: request.id, request, decision: "?", via: "unknown", delivery: "refused",
                        reason: reason))
            case nil:
                break
            }
            if !channel.isFiled(request) { return (.failed, nil) }
            if let deadline, ContinuousClock.now >= deadline { return (.timedOut, nil) }
            try? await Task.sleep(for: poll)
        }
        return (.withdrawn, nil)
    }

    /// Applies the outcome of a watch and records it.
    private func settle(
        _ request: PendingApprovals.Request, state: State, answer: PendingApprovals.Answer?, started: Date,
        audit: AuditLog?, apply: Apply
    ) async {
        channel.withdraw(request)
        var state = state
        var kept: String?
        var reason: String? = state == .failed ? "the pending request was removed" : nil
        if let answer {
            switch await apply(answer.decision, request.id) {
            case .kept(let id): kept = id
            case .dropped: break
            case .failed(let why):
                state = .failed
                reason = why
            }
        }
        let seconds = Date().timeIntervalSince(started)
        let outcome =
            switch state {
            case .kept, .dropped: "answered"
            case .timedOut: "timed-out"
            case .withdrawn: "withdrawn"
            case .failed, .pending: "failed"
            }
        audit?.record(
            .approvalSettled,
            details: AuditEvent.Details.approvalSettled(
                request, outcome: outcome, via: answer?.via, decision: answer?.decision, reason: reason,
                seconds: seconds, kept: kept))
        finish(request, state: state, kept: kept, via: answer?.via, reason: reason)
    }

    /// Records how a request ended, and remembers a drop.
    private func finish(_ request: PendingApprovals.Request, state: State, kept: String?, via: String?, reason: String?)
    {
        contents.withLock { contents in
            contents.watches[request.id] = nil
            guard let index = contents.records.firstIndex(where: { $0.request.id == request.id }),
                contents.records[index].state == .pending
            else { return }
            contents.records[index].state = state
            contents.records[index].kept = kept
            contents.records[index].via = via
            contents.records[index].reason = reason
            contents.records[index].settledAt = Date()
            if state == .dropped, let fact = request.fact, let thread = request.thread {
                contents.dropped[thread, default: [:]][Self.dropKey(fact)] = contents.records[index]
            }
            Self.trim(&contents.records)
        }
    }

    /// Stops the watches of `thread` (it closed, or was evicted) and withdraws its requests, audited as
    /// `withdrawn`; nil stops every watch (the server is stopping). Its dropped facts are forgotten with it.
    ///
    /// - Parameter thread: The thread, or nil for all.
    public func withdraw(thread: String?) {
        let tasks = contents.withLock { contents -> [Task<Void, Never>] in
            let ids = Set(
                contents.records.filter { $0.state == .pending && (thread == nil || $0.thread == thread) }
                    .map(\.request.id))
            if let thread { contents.dropped[thread] = nil }
            return contents.watches.filter { ids.contains($0.key) }.map(\.value)
        }
        for task in tasks { task.cancel() }
    }

    /// Drops the oldest settled records past `historyLimit`.
    private static func trim(_ records: inout [Record]) {
        let settled = records.indices.filter { records[$0].state != .pending }
        guard settled.count > historyLimit else { return }
        let drop = Set(settled.prefix(settled.count - historyLimit))
        records = records.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}

extension Agent {
    /// The current fact `shown.id`, provided it still says what the person was shown; the person's answer
    /// applies only to that.
    private func asked(_ shown: PendingApprovals.ProposedFact) throws(FactFailure) -> Fact {
        guard facts != nil else { throw .off }
        syncProposals()
        guard let fact = fact(shown.id), fact.state == .current else { throw .changed(shown.id) }
        guard FactKeeper.proposed(fact) == shown else { throw .changed(shown.id) }
        return fact
    }

    /// Keeps the fact the person was asked about as a permanent fact, as the person's (ADR 0048): the move to
    /// `permanent` chat makes, audited as `fact.scope.changed` with `by: person` and the request.
    ///
    /// - Parameters:
    ///   - shown: The fact as the request named it.
    ///   - request: The request the person answered.
    /// - Returns: The fact as the shared store holds it.
    /// - Throws: `FactFailure.changed` when the fact is no longer what the person was shown, or a failure to
    ///   write the shared store.
    public func keepAsked(_ shown: PendingApprovals.ProposedFact, request: String) throws(FactFailure) -> Fact {
        _ = try asked(shown)
        return try setFactScope(shown.id, to: .permanent, by: .person, request: request)
    }

    /// Leaves the fact the person declined to keep where it is (ADR 0048). A proposed permanent fact stops
    /// being proposed, in place, as a move to `thread` does, so it no longer waits in `wisp://facts/proposed`;
    /// a thread or session fact is unchanged.
    ///
    /// - Parameters:
    ///   - shown: The fact as the request named it.
    ///   - request: The request the person answered.
    /// - Returns: The fact as it now stands.
    /// - Throws: `FactFailure.changed` when the fact is no longer what the person was shown.
    @discardableResult
    public func dropAsked(_ shown: PendingApprovals.ProposedFact, request: String) throws(FactFailure) -> Fact {
        let fact = try asked(shown)
        guard fact.proposed else { return fact }
        return try setFactScope(shown.id, to: .thread, by: .person, request: request)
    }
}
