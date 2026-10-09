import Foundation
import Synchronization

/// Asks the person about a command waiting under `wisp mcp` through another of wisp's faces, and through the
/// client's own dialog when it has one, at once; the first answer wins and the other is withdrawn
/// ([ADR 0046](../../../../docs/decisions/0046-approval-and-notifications-over-mcp.md)).
///
/// The request is filed in `PendingApprovals`, where `wisp approvals approve|deny` and a running `wisp-tui`
/// answer it, and the person is told by a notification naming the command and the command that answers it.
/// The calling agent cannot answer: nothing in the MCP conversation approves. The wait is bounded by
/// `approval.timeoutSeconds`; silence is a denial, and a cancelled call withdraws the request. Every step is
/// audited on the asking conversation: `approval.pending`, the `notification`, and `approval.settled`.
public struct OutOfBandApprover: Approver {
    /// What one way of asking came back with.
    public enum Leg: Equatable, Sendable {
        /// The person answered, or the wait ran out (`.unanswered`).
        case answered(ApprovalDecision)
        /// This way could not ask; the other way, if any, goes on.
        case failed(String)
    }

    /// Asks through the client's dialog. Cancelling the task that runs it withdraws the dialog.
    public typealias Ask = @Sendable (ApprovalRequest) async -> Leg

    /// Where requests are filed.
    public let channel: PendingApprovals
    /// How long to wait; nil waits for ever.
    public let timeout: Duration?
    /// The client's dialog, when the client has one now; nil asks only through the channel.
    private let alongside: @Sendable () -> Ask?
    /// The MCP client's name, for the request.
    private let client: @Sendable () -> String?
    /// Posts the notification that a request is waiting, audited on the conversation's log.
    private let notify: @Sendable (Notifier.Message, AuditLog?) -> Void
    /// How often the channel is checked for an answer.
    private let poll: Duration

    /// Creates the approver.
    ///
    /// - Parameters:
    ///   - channel: Where requests are filed.
    ///   - timeout: How long to wait; nil waits for ever.
    ///   - alongside: The client's dialog when it has one, asked at the same time.
    ///   - client: The MCP client's name.
    ///   - notify: Posts a notification (the host's routes, source `approval`).
    ///   - poll: How often to look for an answer.
    public init(
        channel: PendingApprovals, timeout: Duration?, alongside: @escaping @Sendable () -> Ask? = { nil },
        client: @escaping @Sendable () -> String? = { nil },
        notify: @escaping @Sendable (Notifier.Message, AuditLog?) -> Void, poll: Duration = .milliseconds(200)
    ) {
        self.channel = channel
        self.timeout = timeout
        self.alongside = alongside
        self.client = client
        self.notify = notify
        self.poll = poll
    }

    /// Decides without a conversation's log.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        await decide(request, audit: nil)
    }

    /// The notification for a waiting request: the command, where it came from, and how to answer it.
    ///
    /// - Parameter request: The filed request.
    /// - Returns: The message; `Notifier` bounds it.
    public static func message(for request: PendingApprovals.Request) -> Notifier.Message {
        let shown = ApprovalRequest.visible(request.command)
        let command = shown.count > 120 ? String(shown.prefix(119)) + "…" : shown
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self)
            .map(ApprovalRequest.visible).joined(separator: ", ")
        return Notifier.Message(
            title: "wisp: approval needed",
            body: "\(command) — wisp approvals approve \(request.id)",
            subtitle: "\(request.level.rawValue) risk\(from.isEmpty ? "" : " · \(from)")")
    }

    /// Files the request, notifies, and waits for the first answer from the channel or the client's dialog.
    public func decide(_ request: ApprovalRequest, audit: AuditLog?) async -> ApprovalDecision {
        let ask = alongside()
        let pending = PendingApprovals.request(for: request, client: client(), timeout: timeout)
        do {
            try channel.file(pending)
        } catch {
            audit?.record(
                .approvalPending,
                details: AuditEvent.Details.approvalPending(
                    pending, outcome: "failed", alongside: ask == nil ? nil : "elicitation", reason: "\(error)"))
            guard let ask else { return .denied("approval could not be asked outside the client: \(error)") }
            switch await ask(request) {
            case .answered(let decision): return decision
            case .failed(let reason): return .denied("approval request failed: \(reason)")
            }
        }
        audit?.record(
            .approvalPending,
            details: AuditEvent.Details.approvalPending(
                pending, outcome: "filed", alongside: ask == nil ? nil : "elicitation"))
        notify(Self.message(for: pending), audit)
        let started = Date()
        let winner = await race(pending, request: request, ask: ask, audit: audit)
        channel.withdraw(pending)
        let seconds = Date().timeIntervalSince(started)
        let decision: ApprovalDecision
        switch winner {
        case .answered(let via, let answer):
            decision = answer
            let settled: (String, String?) =
                switch answer {
                case .approved(let scope): ("answered", scope.rawValue)
                case .denied: ("answered", "no")
                case .unanswered: ("timed-out", nil)
                }
            audit?.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(
                    pending, outcome: settled.0, via: settled.0 == "answered" ? via : nil, decision: settled.1,
                    seconds: seconds))
        case .abandoned:
            decision = .denied("the call was cancelled while waiting for approval")
            audit?.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(pending, outcome: "abandoned", seconds: seconds))
        case .failed(let reasons):
            let reason = reasons.joined(separator: "; ")
            decision = .denied("approval request failed: \(reason)")
            audit?.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(
                    pending, outcome: "failed", reason: reason, seconds: seconds))
        }
        return decision
    }

    /// How the race ended.
    enum Winner: Equatable, Sendable {
        /// One way answered (`elicitation`, `cli`, `tui`, or `timeout`).
        case answered(via: String, ApprovalDecision)
        /// The caller's task was cancelled.
        case abandoned
        /// Every way failed.
        case failed([String])
    }

    /// The race between the ways of asking. Neither leg is awaited once one has answered: a dialog in flight
    /// may ignore cancellation, and the person's answer must not wait on it (see `Timeout`).
    final class Race: Sendable {
        /// The race's state.
        private struct State {
            var continuation: CheckedContinuation<Winner, Never>?
            var result: Winner?
            var running = 0
            var failures: [String] = []
            var tasks: [Task<Void, Never>] = []
        }

        private let state: Mutex<State>

        /// A race of `legs` legs, all counted before any starts, so one that fails at once cannot end it early.
        init(legs: Int) {
            state = Mutex(State(running: legs))
        }

        /// Starts a leg.
        func start(_ body: @escaping @Sendable () async -> Void) {
            let task = Task { await body() }
            let late = state.withLock { state -> Bool in
                state.tasks.append(task)
                return state.result != nil
            }
            if late { task.cancel() }
        }

        /// Ends the race with `winner`, unless it has ended; the legs are cancelled.
        func settle(_ winner: Winner) {
            let (continuation, tasks) = state.withLock {
                state -> (CheckedContinuation<Winner, Never>?, [Task<Void, Never>]) in
                guard state.result == nil else { return (nil, []) }
                state.result = winner
                defer { state.continuation = nil }
                return (state.continuation, state.tasks)
            }
            for task in tasks { task.cancel() }
            continuation?.resume(returning: winner)
        }

        /// Records that a leg could not ask; when none is left, the race fails.
        func failed(_ reason: String) {
            let all = state.withLock { state -> [String]? in
                state.failures.append(reason)
                state.running -= 1
                return state.running == 0 ? state.failures : nil
            }
            if let all { settle(.failed(all)) }
        }

        /// Waits for the winner.
        func winner() async -> Winner {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Winner? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    /// Runs the channel's wait and, when there is one, the client's dialog, and returns the first answer.
    private func race(
        _ pending: PendingApprovals.Request, request: ApprovalRequest, ask: Ask?, audit: AuditLog?
    ) async -> Winner {
        let race = Race(legs: ask == nil ? 1 : 2)
        let channel = channel
        let timeout = timeout
        let poll = poll
        if let ask {
            race.start {
                switch await ask(request) {
                case .answered(let decision): race.settle(.answered(via: "elicitation", decision))
                case .failed(let reason): race.failed("the client's dialog: \(reason)")
                }
            }
        }
        race.start {
            let deadline = timeout.map { ContinuousClock.now + $0 }
            while !Task.isCancelled {
                switch channel.take(pending) {
                case .answer(let answer)?:
                    let decision: ApprovalDecision =
                        answer.decision == "no"
                        ? .denied("declined by the person (\(Self.face(answer.via)))")
                        : TerminalApprover.parse(answer.decision)
                    race.settle(.answered(via: answer.via, decision))
                    return
                case .rejected(let reason)?:
                    audit?.record(
                        .approvalAnswered,
                        details: AuditEvent.Details.approvalAnswered(
                            request: pending.id, pending, decision: "?", via: "unknown", delivery: "refused",
                            reason: reason))
                case nil:
                    break
                }
                if !channel.isFiled(pending) {
                    race.failed("the pending request was removed")
                    return
                }
                if let deadline, ContinuousClock.now >= deadline, let timeout {
                    race.settle(.answered(via: "timeout", .unanswered(timeout)))
                    return
                }
                try? await Task.sleep(for: poll)
            }
        }
        return await withTaskCancellationHandler {
            await race.winner()
        } onCancel: {
            race.settle(.abandoned)
        }
    }

    /// The face's name for a reason: `wisp approvals` or `wisp-tui`.
    static func face(_ via: String) -> String {
        switch via {
        case "cli": "wisp approvals"
        case "tui": "wisp-tui"
        default: via
        }
    }
}

/// The client's dialog alone, as before ADR 0046: `approval.outOfBand` off. A client without one gets the
/// fallback's answer, a denial that says why.
struct ElicitationOnly: Approver {
    /// The client's dialog now, or nil.
    let ask: @Sendable () -> OutOfBandApprover.Ask?
    /// What decides when the client has no dialog.
    let fallback: any Approver

    /// Asks through the dialog, or defers to the fallback.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let ask = ask() else { return await fallback.decide(request) }
        switch await ask(request) {
        case .answered(let decision): return decision
        case .failed(let reason): return .denied("approval request failed: \(reason)")
        }
    }
}
