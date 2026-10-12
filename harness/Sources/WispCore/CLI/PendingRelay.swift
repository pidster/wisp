import Foundation
import Synchronization

/// Shows a front end the questions waiting in `wisp mcp` servers, and writes the person's answers back to the
/// pending channel: commands waiting for approval (ADR 0046) when the front end's `hello` declares
/// `approve-mcp`, facts a caller asked to keep as permanent (ADR 0048) when it declares `keep-facts`, and the
/// model's questions (ADR 0062) when it declares `answer-questions`. `wisp chat --json` runs one when any is
/// declared; `wisp-tui` declares all three.
///
/// Each pass lists the channel: a request not yet shown is sent as an `approval` line with `source: "mcp"`
/// (and, for a fact, `kind: "fact"` and the `fact`), or for a question as a `choice` line with `kind` `question`
/// and `source: "mcp"`, under the protocol id `mcp-<id>`, and a task waits for
/// the answer; a request shown before and gone now (answered elsewhere, withdrawn, expired) is sent as
/// `withdrawn`, and its wait is dropped. An answer is written with `via: tui` and audited as
/// `approval.answered` (or `inquiry.answered`) on the chat's own log.
public final class PendingRelay: Sendable {
    /// The channel.
    private let channel: PendingApprovals
    /// The kinds of request the front end declared it answers.
    private let kinds: Set<PendingApprovals.Kind>
    /// Where answers arrive.
    private let router: LineRouter
    /// Writes one protocol line.
    private let send: @Sendable (String) -> Void
    /// The chat's log, for `approval.answered`.
    private let audit: AuditLog?
    /// The requests shown and still waiting, by request id.
    private let shown = Mutex<Set<String>>([])
    /// The shared store, for a fact kept after the server that asked has stopped; nil leaves that to the server.
    private let facts: SharedFacts?

    /// Creates a relay.
    ///
    /// - Parameters:
    ///   - channel: The pending channel.
    ///   - router: Where the front end's answers arrive.
    ///   - audit: The chat's log.
    ///   - kinds: The kinds of request to show: commands for `approve-mcp`, facts for `keep-facts`.
    ///   - facts: The shared store, where a fact is kept when the server that asked has stopped.
    ///   - send: Writes one protocol line.
    public init(
        channel: PendingApprovals, router: LineRouter, audit: AuditLog?,
        kinds: Set<PendingApprovals.Kind> = [.command], facts: SharedFacts? = nil,
        send: @escaping @Sendable (String) -> Void
    ) {
        self.channel = channel
        self.facts = facts
        self.kinds = kinds
        self.router = router
        self.audit = audit
        self.send = send
    }

    /// The kinds of request a front end answers, from the effects its `hello` declared: commands for
    /// `approve-mcp`, facts for `keep-facts`.
    ///
    /// - Parameter declared: Whether the `hello` declared an effect.
    /// - Returns: The kinds; empty when it declared neither, and no relay runs.
    public static func kinds(declared: (String) -> Bool) -> Set<PendingApprovals.Kind> {
        var kinds: Set<PendingApprovals.Kind> = []
        if declared("approve-mcp") { kinds.insert(.command) }
        if declared("keep-facts") { kinds.insert(.fact) }
        if declared("answer-questions") { kinds.insert(.question) }
        return kinds
    }

    /// The protocol id for a pending request.
    static func protocolID(_ id: String) -> String { "mcp-\(id)" }

    /// One look at the channel: new requests are shown, gone ones withdrawn.
    ///
    /// - Parameters:
    ///   - now: The time.
    ///   - alive: Whether a process is running.
    public func poll(now: Date = Date(), alive: (Int32) -> Bool = PendingApprovals.isAlive) {
        let waiting = channel.waiting(now: now, alive: alive).filter { kinds.contains($0.kind) }
        let ids = Set(waiting.map(\.id))
        let (new, gone) = shown.withLock { shown -> ([PendingApprovals.Request], Set<String>) in
            let new = waiting.filter { !shown.contains($0.id) }
            let gone = shown.subtracting(ids)
            shown = ids
            return (new, gone)
        }
        for id in gone.sorted() {
            router.withdraw(Self.protocolID(id))
            send(ChatProtocol.encode("withdrawn", ["id": .string(Self.protocolID(id))]))
        }
        for request in new {
            if let question = request.asked {
                var choice = question.choice
                choice.origin = ChatChoice.Origin(
                    thread: request.thread, source: "mcp", client: request.client, request: request.id)
                send(ChatProtocol.encode("choice", ChatProtocol.choice(id: Self.protocolID(request.id), choice)))
            } else {
                send(
                    ChatProtocol.encode(
                        "approval", ChatProtocol.approval(id: Self.protocolID(request.id), pending: request)))
            }
            Task { await self.awaitAnswer(request) }
        }
    }

    /// Waits for the front end's answer to `request` and writes it to the channel. A fact request whose server
    /// has stopped is applied here, since no server is left to take the answer (ADR 0048, amended 2026-10-12).
    ///
    /// - Parameters:
    ///   - request: The request shown.
    ///   - alive: Whether a process is running.
    func awaitAnswer(
        _ request: PendingApprovals.Request, alive: (Int32) -> Bool = PendingApprovals.isAlive
    ) async {
        guard let answer = await router.answerUnlessWithdrawn(for: Self.protocolID(request.id)) else { return }
        if let question = request.asked { return await answerQuestion(question, request: request, typed: answer) }
        let refusal = request.kind == .fact ? "drop" : "no"
        let decision = request.kind.decisions.contains(answer) ? answer : refusal
        do {
            try channel.answer(request.id, decision: decision, via: "tui")
            let applied = facts.flatMap {
                FactKeeper.settleUnwatched(request, channel: channel, store: $0, audit: audit, alive: alive)
            }
            audit?.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: request.id, request, decision: decision, via: "tui",
                    delivery: applied == nil ? "waiting" : "applied"))
            if case .failed(let why)? = applied {
                send(ChatProtocol.encode("note", ["text": .string("\(request.subject) was not kept: \(why)")]))
            }
        } catch {
            audit?.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: request.id, request, decision: decision, via: "tui", delivery: "refused",
                    reason: "\(error)"))
            send(ChatProtocol.encode("note", ["text": .string("the answer was not used: \(error)")]))
        }
    }

    /// Writes the front end's answer to a question (ADR 0062): what it chose or typed, mapped as the chat's own dialog
    /// maps it, audited as `inquiry.answered`.
    private func answerQuestion(_ question: Question, request: PendingApprovals.Request, typed: String) async {
        let outcome = question.outcome(typed: typed) ?? .declined
        let (decision, text): (String, String?) =
            switch outcome {
            case .answered(let text): ("answer", text)
            case .chose(let text): ("chose", text)
            case .noneOfThese: ("none", nil)
            default: ("decline", nil)
            }
        do {
            try channel.answer(request.id, decision: decision, text: text, via: "tui")
            audit?.record(
                .inquiryAnswered,
                details: AuditEvent.Details.inquiryAnswered(request.id, via: "tui", delivery: "waiting"))
        } catch {
            audit?.record(
                .inquiryAnswered,
                details: AuditEvent.Details.inquiryAnswered(
                    request.id, via: "tui", delivery: "refused", reason: "\(error)"))
            send(ChatProtocol.encode("note", ["text": .string("the answer was not used: \(error)")]))
        }
    }

    /// Polls every `interval` until the task is cancelled.
    ///
    /// - Parameter interval: Between looks.
    public func run(every interval: Duration = .milliseconds(500)) async {
        while !Task.isCancelled {
            poll()
            try? await Task.sleep(for: interval)
        }
    }
}
