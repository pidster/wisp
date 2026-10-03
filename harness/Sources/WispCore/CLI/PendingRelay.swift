import Foundation
import Synchronization

/// Shows a front end the questions waiting in `wisp mcp` servers, and writes the person's answers back to the
/// pending channel: commands waiting for approval (ADR 0046) when the front end's `hello` declares
/// `approve-mcp`, and facts a caller asked to keep as permanent (ADR 0048) when it declares `keep-facts`.
/// `wisp chat --json` runs one when either is declared; `wisp-tui` declares both.
///
/// Each pass lists the channel: a request not yet shown is sent as an `approval` line with `source: "mcp"`
/// (and, for a fact, `kind: "fact"` and the `fact`) under the protocol id `mcp-<id>`, and a task waits for
/// the answer; a request shown before and gone now (answered elsewhere, withdrawn, expired) is sent as
/// `withdrawn`, and its wait is dropped. An answer is written with `via: tui` and audited as
/// `approval.answered` on the chat's own log.
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

    /// Creates a relay.
    ///
    /// - Parameters:
    ///   - channel: The pending channel.
    ///   - router: Where the front end's answers arrive.
    ///   - audit: The chat's log.
    ///   - kinds: The kinds of request to show: commands for `approve-mcp`, facts for `keep-facts`.
    ///   - send: Writes one protocol line.
    public init(
        channel: PendingApprovals, router: LineRouter, audit: AuditLog?,
        kinds: Set<PendingApprovals.Kind> = [.command], send: @escaping @Sendable (String) -> Void
    ) {
        self.channel = channel
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
            send(
                ChatProtocol.encode(
                    "approval", ChatProtocol.approval(id: Self.protocolID(request.id), pending: request)))
            Task { await self.awaitAnswer(request) }
        }
    }

    /// Waits for the front end's answer to `request` and writes it to the channel.
    func awaitAnswer(_ request: PendingApprovals.Request) async {
        guard let answer = await router.answerUnlessWithdrawn(for: Self.protocolID(request.id)) else { return }
        let refusal = request.kind == .fact ? "drop" : "no"
        let decision = request.kind.decisions.contains(answer) ? answer : refusal
        do {
            try channel.answer(request.id, decision: decision, via: "tui")
            audit?.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: request.id, request, decision: decision, via: "tui", delivery: "waiting"))
        } catch {
            audit?.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: request.id, request, decision: decision, via: "tui", delivery: "refused",
                    reason: "\(error)"))
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
