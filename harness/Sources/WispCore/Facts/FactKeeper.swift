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
/// files the request, starts a watch, and returns. The request has no time limit (ADR 0048's amendment of
/// 2026-10-12): nothing blocks on it, so nothing needs to give up, and silence keeps nothing. The watch polls the
/// channel until the answer, and applies it through the closure the server gave: `keep` admits the fact to the
/// shared store as the person's, `drop` leaves it in its thread and is remembered, so the same fact (its subject,
/// name, and value) is not asked about again by that thread. Every step is audited on the asking thread's log:
/// `approval.pending`, the `notification`, and `approval.settled`, each with `kind` `fact`.
///
/// A request outlives its thread. When the thread closes (`release`) the watch goes on, and a later `keep` is
/// admitted to the shared store straight from what the request names (`keep(_:in:audit:)`), audited on the
/// keeper's own log; a later `drop` just ends it. When the server stops (`stop`) the request stays filed, and
/// whichever face the person answers in applies the answer itself (`settleUnwatched`), since no server is left to.
///
/// Every operation is a short critical section, so this is a `final class` with a `Mutex`
/// (`docs/design.md`, "Concurrency"); the watches are tasks it holds so a stopping server can end them.
public final class FactKeeper: Sendable {
    /// Where a request stands.
    public enum State: String, Sendable, Equatable {
        /// Filed; no answer yet.
        case pending
        /// The person kept it: the shared store holds it as `Record.kept`.
        case kept
        /// The person dropped it: it stays in its thread, and the thread is not asked about it again.
        case dropped
        /// The server stopped before an answer; the request stays filed for the person, and the face they
        /// answer in applies the answer.
        case handedOver = "handed-over"
        /// The answer could not be applied (the fact changed or went, the store could not be written), or
        /// the request was removed from the channel; `Record.reason` says why.
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
        /// Whether its thread has closed: an answer is then applied to the shared store directly.
        public var released = false
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
    /// The shared store a request whose thread has closed is kept in; nil keeps nothing that way.
    private let store: SharedFacts?
    /// The log for a request whose thread has closed: the server's own.
    private let audit: AuditLog?
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
    ///   - store: The shared store, for a keep that arrives after its thread closed.
    ///   - audit: The server's log, for a request whose thread has closed.
    ///   - client: The MCP client's name.
    ///   - notify: Posts a notification (the host's routes, source `approval`).
    ///   - poll: How often to look for an answer.
    public init(
        channel: PendingApprovals, store: SharedFacts? = nil, audit: AuditLog? = nil,
        client: @escaping @Sendable () -> String? = { nil },
        notify: @escaping @Sendable (Notifier.Message, AuditLog?) -> Void, poll: Duration = .milliseconds(200)
    ) {
        self.channel = channel
        self.store = store
        self.audit = audit
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

    /// The latest request about fact `fact` of the open thread `thread`, or nil. A request of an earlier thread of
    /// the same id, released when it closed, is not this thread's.
    public func record(thread: String, fact: String) -> Record? {
        contents.withLock { $0.records.last { $0.thread == thread && $0.fact == fact && !$0.released } }
    }

    /// The pending requests, oldest first.
    public var pending: [Record] { records.filter { $0.state == .pending } }

    /// Asks the person to keep `fact`, unless a request for it already waits or the person dropped it for this
    /// thread. Returns at once; the answer is applied by `apply` when it comes, however long that takes.
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
        let request = PendingApprovals.request(keeping: proposed, thread: thread, client: client(), timeout: nil)
        let earlier = contents.withLock { contents -> Asked? in
            if let dropped = contents.dropped[thread]?[Self.dropKey(proposed)] { return .dropped(dropped) }
            if let waiting = contents.records.last(where: {
                $0.thread == thread && $0.fact == fact.id && $0.state == .pending && !$0.released
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
            let answer = await watch(request, audit: audit)
            await settle(request, answer: answer, started: started, audit: audit, apply: apply)
        }
        contents.withLock { contents in
            if contents.records.contains(where: { $0.request.id == request.id && $0.state == .pending }) {
                contents.watches[request.id] = task
            }
        }
        return .filed(record)
    }

    /// Whether `request`'s thread has closed.
    private func isReleased(_ request: PendingApprovals.Request) -> Bool {
        contents.withLock { $0.records.contains { $0.request.id == request.id && $0.released } }
    }

    /// The log for `request`: its thread's while the thread is open, the keeper's once it has closed.
    private func log(_ request: PendingApprovals.Request, thread audit: AuditLog?) -> AuditLog? {
        isReleased(request) ? self.audit : audit
    }

    /// What a watch ended with.
    private enum Watched {
        /// The person's answer, taken from the channel.
        case answer(PendingApprovals.Answer)
        /// The request left the channel without an answer.
        case removed
        /// The server is stopping; the request stays filed.
        case stopped
    }

    /// Waits for the answer to `request`, with no time limit: the answer, the request's removal, or cancellation.
    /// An answer not bound to the request is refused and audited, and the wait goes on.
    private func watch(_ request: PendingApprovals.Request, audit: AuditLog?) async -> Watched {
        while !Task.isCancelled {
            switch channel.take(request) {
            case .answer(let answer)?:
                return .answer(answer)
            case .rejected(let reason)?:
                log(request, thread: audit)?.record(
                    .approvalAnswered,
                    details: AuditEvent.Details.approvalAnswered(
                        request: request.id, request, decision: "?", via: "unknown", delivery: "refused",
                        reason: reason))
            case nil:
                break
            }
            if !channel.isFiled(request) { return .removed }
            try? await Task.sleep(for: poll)
        }
        return .stopped
    }

    /// Applies the outcome of a watch and records it: through `apply` while the thread is open, to the shared
    /// store directly once it has closed. A stopping server leaves the request filed.
    private func settle(
        _ request: PendingApprovals.Request, answer watched: Watched, started: Date, audit: AuditLog?, apply: Apply
    ) async {
        let released = isReleased(request)
        var state: State
        var kept: String?
        var reason: String?
        var answer: PendingApprovals.Answer?
        switch watched {
        case .stopped:
            state = .handedOver
            reason = "the server stopped; the request stays filed, and wisp facts keep or wisp-tui applies the answer"
        case .removed:
            state = .failed
            reason = "the pending request was removed"
        case .answer(let given):
            answer = given
            state = given.decision == "keep" ? .kept : .dropped
            let applied: Applied
            if released {
                applied =
                    given.decision == "keep"
                    ? store.map { Self.keep(request, in: $0, audit: self.audit) }
                        ?? .failed("no shared store to keep it in") : .dropped
            } else {
                applied = await apply(given.decision, request.id)
            }
            switch applied {
            case .kept(let id): kept = id
            case .dropped: break
            case .failed(let why):
                state = .failed
                reason = why
            }
        }
        let outcome =
            switch state {
            case .kept, .dropped: "answered"
            case .handedOver: "handed-over"
            case .failed, .pending: "failed"
            }
        (released ? self.audit : audit)?.record(
            .approvalSettled,
            details: AuditEvent.Details.approvalSettled(
                request, outcome: outcome, via: answer?.via, decision: answer?.decision, reason: reason,
                seconds: Date().timeIntervalSince(started), kept: kept))
        finish(request, state: state, kept: kept, via: answer?.via, reason: reason)
    }

    /// Records how a request ended, and remembers a drop while its thread is open.
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
            if state == .dropped, !contents.records[index].released, let fact = request.fact,
                let thread = request.thread
            {
                contents.dropped[thread, default: [:]][Self.dropKey(fact)] = contents.records[index]
            }
            Self.trim(&contents.records)
        }
    }

    /// `thread` closed, or was evicted: its requests stay filed and watched, and an answer that comes later is
    /// applied to the shared store directly (a keep needs no live thread); its dropped facts are forgotten with
    /// it, so a new thread of the same id may ask again.
    ///
    /// - Parameter thread: The thread.
    public func release(thread: String) {
        contents.withLock { contents in
            for index in contents.records.indices
            where contents.records[index].thread == thread && contents.records[index].state == .pending {
                contents.records[index].released = true
            }
            contents.dropped[thread] = nil
        }
    }

    /// The facts the person dropped for `thread`, for its `thread.json` (ADR 0066, D9): a resumed thread does not ask
    /// about them again.
    ///
    /// - Parameter thread: The MCP `thread_id`.
    /// - Returns: Each dropped fact with the request that dropped it, oldest request first.
    public func droppedFacts(thread: String) -> [ThreadStore.DroppedFact] {
        let records = contents.withLock { Array(($0.dropped[thread] ?? [:]).values) }
        return records.compactMap { record in
            record.request.fact.map {
                ThreadStore.DroppedFact(
                    fact: $0, request: record.request.id, asked: record.request.createdAt, settled: record.settledAt)
            }
        }.sorted { ($0.asked, $0.request) < ($1.asked, $1.request) }
    }

    /// Remembers the facts a saved thread's person dropped, as its `thread.json` holds them, when the thread is resumed
    /// (ADR 0066, D9), so it is not asked about them again; replaces what this keeper held for `thread`.
    ///
    /// - Parameters:
    ///   - dropped: The dropped facts.
    ///   - thread: The MCP `thread_id`.
    public func restoreDropped(_ dropped: [ThreadStore.DroppedFact], thread: String) {
        let client = client()
        var restored: [String: Record] = [:]
        for fact in dropped {
            var request = PendingApprovals.request(
                keeping: fact.fact, thread: thread, client: client, now: fact.asked, timeout: nil)
            request.id = fact.request
            restored[Self.dropKey(fact.fact)] = Record(
                request: request, thread: thread, fact: fact.fact.id, state: .dropped, settledAt: fact.settled)
        }
        contents.withLock { $0.dropped[thread] = restored.isEmpty ? nil : restored }
    }

    /// The server is stopping: every watch ends, and every request waiting stays filed, settled here as
    /// `handed-over`. The person can still answer each; the face they answer in applies it (`settleUnwatched`).
    public func stop() {
        let tasks = contents.withLock { Array($0.watches.values) }
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

extension FactKeeper {
    /// Keeps the fact `request` names in `store` as the person's, with no thread to move it from: its thread
    /// closed, or its server stopped, before the person answered. The fact is admitted as the request names it
    /// (its subject, name, value, and source, which the person was shown and the binding covers), approved now,
    /// and audited as `fact.scope.changed` with `by: person` and the request, as a keep from a live thread is.
    ///
    /// - Parameters:
    ///   - request: The fact request the person answered `keep`.
    ///   - store: The shared store of permanent facts.
    ///   - audit: Where the change is recorded.
    ///   - now: The time of the approval.
    /// - Returns: `kept` with the permanent fact's id, or `failed` when the request names no fact or the store
    ///   could not be written.
    public static func keep(
        _ request: PendingApprovals.Request, in store: SharedFacts, audit: AuditLog?, now: Date = Date()
    ) -> Applied {
        guard request.kind == .fact, let shown = request.fact else { return .failed("the request names no fact") }
        let source = FactSource(rawValue: shown.source) ?? .caller
        let method: FactMethod =
            switch source {
            case .model: .distilled
            case .tool: .extracted
            case .person, .caller: .stated
            }
        let scope: FactScope = shown.id.hasPrefix(FactScope.session.prefix) ? .session : .thread
        let before = Fact(
            id: shown.id, identity: FactIdentity(scope: scope, subject: shown.subject, name: shown.name),
            source: source, version: 1, value: shown.value, temporalClass: .permanent, method: method,
            detail: request.thread.map { "thread \($0)" }, entries: [], audit: [], recorded: request.createdAt,
            turn: nil, supersededBy: nil, state: .current, approved: nil)
        var candidate = before
        candidate.approved = now
        let after: Fact
        do { after = try store.admit(candidate) } catch { return .failed("\(error)") }
        audit?.record(
            .factScopeChanged,
            details: AuditEvent.Details.factScopeChanged(
                named: shown.id, before: before, after: after, to: .permanent, by: .person, request: request.id))
        return .kept(after.id)
    }

    /// Applies the person's answer to a fact request that no server watches any more, its server having stopped:
    /// the answering process (`wisp facts keep|drop`, or `wisp chat --json` for `wisp-tui`) takes the answer it
    /// wrote and applies it itself. A keep is admitted to `store` (`keep(_:in:audit:)`); a drop ends the request,
    /// the thread that asked being gone. Audited as `approval.settled` on `audit`.
    ///
    /// - Parameters:
    ///   - request: The request as the answering process read it.
    ///   - channel: The pending channel.
    ///   - store: The shared store of permanent facts.
    ///   - audit: The answering process's log.
    ///   - alive: Whether a process is running.
    /// - Returns: What was applied, or nil when the request is a command, its server still runs (and takes the
    ///   answer itself), or no answer is there to take.
    public static func settleUnwatched(
        _ request: PendingApprovals.Request, channel: PendingApprovals, store: SharedFacts, audit: AuditLog?,
        alive: (Int32) -> Bool = PendingApprovals.isAlive
    ) -> Applied? {
        guard request.kind == .fact, !alive(request.pid) else { return nil }
        guard case .answer(let answer)? = channel.take(request) else { return nil }
        let applied: Applied = answer.decision == "keep" ? keep(request, in: store, audit: audit) : .dropped
        var kept: String?
        var outcome = "answered"
        var reason = "its server had stopped; applied by the answering process"
        switch applied {
        case .kept(let id): kept = id
        case .dropped: break
        case .failed(let why):
            outcome = "failed"
            reason = why
        }
        audit?.record(
            .approvalSettled,
            details: AuditEvent.Details.approvalSettled(
                request, outcome: outcome, via: answer.via, decision: answer.decision, reason: reason, kept: kept))
        return applied
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
