import Foundation
import Synchronization

/// Asks the person about a command waiting under `wisp mcp` through another of wisp's faces, and through the
/// client's own dialog when it has one, at once; the first answer wins and the other is withdrawn
/// ([ADR 0046](../../../../docs/decisions/0046-approval-and-notifications-over-mcp.md)).
///
/// The request is filed in `PendingApprovals`, where `wisp approvals approve|deny` and a running `wisp-tui`
/// answer it, and the person is told by a notification naming the command and the command that answers it. When
/// the client's dialog asks too, the notification waits `bannerDelay` first and is not posted at all if the
/// request is answered (or withdrawn) by then; a client with no dialog, or one whose dialog cannot be sent, is
/// told at once, since nothing else shows the request (ADR 0046, amended 2026-10-12).
/// The calling agent cannot answer: nothing in the MCP conversation approves. The wait is bounded by
/// `approval.timeoutSeconds`; silence is a denial, and a cancelled call withdraws the request. Every step is
/// audited on the asking conversation: `approval.pending`, the `notification`, and `approval.settled`.
///
/// Why two ways at once: the client's dialog alone failed in practice. A client without one (the Claude mobile
/// app, 2026-09-17) let a delegated `git push` wait out the timeout, and Claude Code's dialog stuck in three of
/// eight approvals in one session (2026-09-19 to 23). Asking through the conversation was rejected, since the
/// calling agent is the party being gated.
/// `Session.mcpApprover` builds it from the configuration; with `approval.outOfBand` off, ``ElicitationOnly`` is
/// used instead. `docs/mcp.md`, "Approval", describes it from the client's side.
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
    /// How long a request the client's dialog also asks may wait before the notification is posted; zero posts at
    /// once.
    public let bannerDelay: Duration

    /// Creates the approver.
    ///
    /// - Parameters:
    ///   - channel: Where requests are filed.
    ///   - timeout: How long to wait; nil waits for ever.
    ///   - alongside: The client's dialog when it has one, asked at the same time.
    ///   - client: The MCP client's name.
    ///   - notify: Posts a notification (the host's routes, source `approval`).
    ///   - poll: How often to look for an answer.
    ///   - bannerDelay: How long a request the client's dialog also asks may wait before the notification is
    ///     posted (`approval.bannerDelaySeconds`); zero, the default, posts at once.
    public init(
        channel: PendingApprovals, timeout: Duration?, alongside: @escaping @Sendable () -> Ask? = { nil },
        client: @escaping @Sendable () -> String? = { nil },
        notify: @escaping @Sendable (Notifier.Message, AuditLog?) -> Void, poll: Duration = .milliseconds(200),
        bannerDelay: Duration = .zero
    ) {
        self.bannerDelay = bannerDelay
        self.channel = channel
        self.timeout = timeout
        self.alongside = alongside
        self.client = client
        self.notify = notify
        self.poll = poll
    }

    /// Decides without a conversation's log.
    ///
    /// - Parameter request: What to decide.
    /// - Returns: What ``decide(_:audit:)`` returns.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        await decide(request, audit: nil)
    }

    /// The notification for a waiting request: the command, where it came from, and how to answer it; a request to
    /// run outside the sandbox says so in its title (ADR 0064).
    ///
    /// - Parameter request: The filed request.
    /// - Returns: The message; `Notifier` bounds it.
    public static func message(for request: PendingApprovals.Request) -> Notifier.Message {
        let shown = ApprovalRequest.visible(request.command)
        let command = shown.count > 120 ? String(shown.prefix(119)) + "…" : shown
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self)
            .map(ApprovalRequest.visible).joined(separator: ", ")
        return Notifier.Message(
            title: request.outsideSandbox == true ? "wisp: approve OUTSIDE the sandbox" : "wisp: approval needed",
            body: "\(command) — wisp approvals approve \(request.id)",
            subtitle: "\(request.level.rawValue) risk\(from.isEmpty ? "" : " · \(from)")")
    }

    /// Files the request, notifies, and waits for the first answer from the channel or the client's dialog.
    ///
    /// When the request cannot be filed, the client's dialog alone asks, and without one the request is denied
    /// saying why. Whatever ends the wait, the pending file is withdrawn afterwards, so a later answer finds
    /// nothing to answer.
    ///
    /// - Parameters:
    ///   - request: What to decide.
    ///   - audit: The asking conversation's log: `approval.pending`, the notification, `approval.settled`.
    /// - Returns: The first answer; a denial when the call was cancelled or every way failed; `unanswered` at the
    ///   timeout.
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
        // With nothing else to show the request, the person is told at once; beside the client's dialog, only
        // when the dialog has gone unanswered for the delay.
        let delay = ask == nil ? Duration.zero : bannerDelay
        audit?.record(
            .approvalPending,
            details: AuditEvent.Details.approvalPending(
                pending, outcome: "filed", alongside: ask == nil ? nil : "elicitation",
                bannerDelay: delay > .zero ? delay : nil))
        let message = Self.message(for: pending)
        let notify = notify
        let banner = DelayedNotice(after: delay) { notify(message, audit) }
        let started = Date()
        let winner = await race(pending, request: request, ask: ask, banner: banner, audit: audit)
        let posted = banner.settle()
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
                    seconds: seconds, banner: posted.rawValue))
        case .abandoned:
            decision = .denied("the call was cancelled while waiting for approval")
            audit?.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(
                    pending, outcome: "abandoned", seconds: seconds, banner: posted.rawValue))
        case .failed(let reasons):
            let reason = reasons.joined(separator: "; ")
            decision = .denied("approval request failed: \(reason)")
            audit?.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(
                    pending, outcome: "failed", reason: reason, seconds: seconds, banner: posted.rawValue))
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
            /// Who waits for the winner, until the race ends.
            var continuation: CheckedContinuation<Winner, Never>?
            /// How it ended; nil while running.
            var result: Winner?
            /// Legs still asking.
            var running = 0
            /// Why each failed leg could not ask.
            var failures: [String] = []
            /// The legs' tasks, cancelled when the race ends.
            var tasks: [Task<Void, Never>] = []
        }

        /// The race's state, behind one lock: the legs settle it from their own tasks.
        private let state: Mutex<State>

        /// A race of `legs` legs, all counted before any starts, so one that fails at once cannot end it early.
        ///
        /// - Parameter legs: The number of ways of asking.
        init(legs: Int) {
            state = Mutex(State(running: legs))
        }

        /// Starts a leg; one started after the race ended is cancelled at once.
        ///
        /// - Parameter body: The leg, which settles or fails the race.
        func start(_ body: @escaping @Sendable () async -> Void) {
            let task = Task { await body() }
            let late = state.withLock { state -> Bool in
                state.tasks.append(task)
                return state.result != nil
            }
            if late { task.cancel() }
        }

        /// Ends the race with `winner`, unless it has ended; the legs are cancelled.
        ///
        /// - Parameter winner: How it ended.
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
        ///
        /// - Parameter reason: Why the leg could not ask.
        func failed(_ reason: String) {
            let all = state.withLock { state -> [String]? in
                state.failures.append(reason)
                state.running -= 1
                return state.running == 0 ? state.failures : nil
            }
            if let all { settle(.failed(all)) }
        }

        /// Waits for the winner.
        ///
        /// - Returns: How the race ended, at once when it already has.
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
    ///
    /// - Parameters:
    ///   - pending: The filed request.
    ///   - request: The request as the gate made it.
    ///   - ask: The client's dialog, if any.
    ///   - banner: The notification; posted at once if the dialog cannot be sent, since nothing else then shows it.
    ///   - audit: The conversation's log.
    /// - Returns: How the race ended.
    private func race(
        _ pending: PendingApprovals.Request, request: ApprovalRequest, ask: Ask?, banner: DelayedNotice,
        audit: AuditLog?
    ) async -> Winner {
        let race = Race(legs: ask == nil ? 1 : 2)
        let channel = channel
        let timeout = timeout
        let poll = poll
        if let ask {
            race.start {
                switch await ask(request) {
                case .answered(let decision): race.settle(.answered(via: "elicitation", decision))
                case .failed(let reason):
                    banner.postNow()
                    race.failed("the client's dialog: \(reason)")
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

    /// The face's name for a reason: `wisp approvals`, `wisp-tui`, or `wisp chat`.
    ///
    /// - Parameter via: The answer's `via` (`cli`, `tui`, `chat`).
    /// - Returns: The face's name, or `via` itself for any other.
    static func face(_ via: String) -> String {
        switch via {
        case "cli": "wisp approvals"
        case "tui": "wisp-tui"
        case "chat": "wisp chat"
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
    ///
    /// - Parameter request: What to decide.
    /// - Returns: The dialog's answer, a denial when it failed, or the fallback's decision.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let ask = ask() else { return await fallback.decide(request) }
        switch await ask(request) {
        case .answered(let decision): return decision
        case .failed(let reason): return .denied("approval request failed: \(reason)")
        }
    }
}
