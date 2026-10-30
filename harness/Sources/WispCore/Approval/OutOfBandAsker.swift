import Foundation
import Synchronization

/// Asks the model's question under `wisp mcp` ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md),
/// section 6): the question is filed in the pending channel (`<id>.question.json`, answered by `wisp questions
/// answer|decline` or a running `wisp-tui`) and announced by one notification, and, when the client's dialog is
/// switched on (`inquiry.elicitation`, off until the operator's hand test, D8) and the client has one, asked there
/// too; the first answer wins. The call holds the dialog for `hold` (60 s, fixed, D15); an answer within it is the
/// tool's result. Then the dialog is withdrawn, the question stays filed, and the turn parks: the thread's
/// `InquiryBox` watches the channel and delivers the answer as a note to the thread's next turn. A cancelled call
/// withdraws the question (`abandoned`).
///
/// It mirrors ``OutOfBandApprover``, with one difference: an approval holds its call until answered or timed
/// out, while a question parks the turn after the hold, so an MCP `respond` call is never held longer than a
/// minute by a question.
public struct OutOfBandAsker: Asker {
    /// What the client's dialog came back with.
    public enum Leg: Equatable, Sendable {
        /// The person answered in the dialog (or declined there).
        case answered(Question.Outcome)
        /// The dialog could not be asked; the channel goes on.
        case failed(String)
    }

    /// Asks through the client's dialog. Cancelling the task that runs it withdraws the dialog.
    public typealias Ask = @Sendable (Question) async -> Leg

    /// How long the call holds the dialog before the turn parks (D15).
    ///
    /// Fixed rather than a setting: long enough for a person watching the client to answer inside the turn, and
    /// well inside a client's tool-call timeout.
    public static let hold: Duration = .seconds(60)

    /// Where questions are filed.
    public let channel: PendingApprovals
    /// The client's dialog, when it is switched on and the client has one now; nil asks only through the channel.
    private let alongside: @Sendable () -> Ask?
    /// The MCP client's name, for the request and the dialog.
    private let client: @Sendable () -> String?
    /// Posts the one notification that a question waits, audited on the thread's log.
    private let notify: @Sendable (Notifier.Message, AuditLog?) -> Void
    /// How often the channel is checked for an answer.
    private let poll: Duration
    /// How long the call holds the dialog; `hold` unless a test shortens it.
    let holdFor: Duration

    /// Creates the asker.
    ///
    /// - Parameters:
    ///   - channel: Where questions are filed.
    ///   - alongside: The client's dialog when it is on and the client has one, asked at the same time.
    ///   - client: The MCP client's name.
    ///   - notify: Posts a notification (the host's routes, source `inquiry`).
    ///   - poll: How often to look for an answer.
    ///   - hold: How long the call holds the dialog before parking; `OutOfBandAsker.hold` by default.
    public init(
        channel: PendingApprovals, alongside: @escaping @Sendable () -> Ask? = { nil },
        client: @escaping @Sendable () -> String? = { nil },
        notify: @escaping @Sendable (Notifier.Message, AuditLog?) -> Void, poll: Duration = .milliseconds(200),
        hold: Duration = OutOfBandAsker.hold
    ) {
        self.channel = channel
        self.alongside = alongside
        self.client = client
        self.notify = notify
        self.poll = poll
        holdFor = hold
    }

    /// The channel, and the dialog when it is on.
    public var ways: [String] { alongside() == nil ? ["pending"] : ["elicitation", "pending"] }

    /// The notification for a waiting question: the model asks, the question, and the command that answers it.
    ///
    /// - Parameter request: The filed request.
    /// - Returns: The message; `Notifier` bounds it.
    public static func message(for request: PendingApprovals.Request) -> Notifier.Message {
        let shown = ApprovalRequest.visible(request.question ?? "")
        let question = shown.count > 120 ? String(shown.prefix(119)) + "…" : shown
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self)
            .map(ApprovalRequest.visible).joined(separator: ", ")
        return Notifier.Message(
            title: "wisp: the model asks", body: "\(question) — wisp questions answer \(request.id)",
            subtitle: from.isEmpty ? nil : from)
    }

    /// Files the question, notifies once, and waits for the first answer from the channel or the dialog within
    /// the hold; then parks.
    ///
    /// A deadline shorter than the hold ends the question as `unanswered` instead of parking. When the question
    /// cannot be filed, the dialog alone asks, if there is one. Every ending but a park withdraws the filed
    /// question; a park hands it to `box`, which keeps watching.
    ///
    /// - Parameters:
    ///   - question: The validated question.
    ///   - box: The asking thread's questions, which a park hands the question to.
    ///   - audit: The thread's log.
    /// - Returns: How it ended (`parked` when the hold lapsed), and where the person answered.
    public func ask(_ question: Question, box: InquiryBox, audit: AuditLog?) async -> Question.Reply {
        let ask = alongside()
        let pending = PendingApprovals.request(asking: question, client: client())
        do {
            try channel.file(pending)
        } catch {
            guard let ask else {
                return Question.Reply(.failed("the question could not be filed outside the client: \(error)"))
            }
            switch await ask(question) {
            case .answered(let outcome): return Question.Reply(outcome, via: "elicitation")
            case .failed(let reason):
                return Question.Reply(.failed("the question could not be asked: \(error); \(reason)"))
            }
        }
        notify(Self.message(for: pending), audit)
        let started = ContinuousClock.now
        // A deadline shorter than the hold ends the question before the turn would park.
        let hold = question.timeout.map { min($0, holdFor) } ?? holdFor
        let winner = await race(pending, question: question, ask: ask, hold: hold, audit: audit)
        switch winner {
        case .answered(let via, let outcome):
            channel.withdraw(pending)
            return Question.Reply(outcome, via: via)
        case .abandoned:
            channel.withdraw(pending)
            return Question.Reply(.abandoned)
        case .failed(let reasons):
            channel.withdraw(pending)
            return Question.Reply(.failed(reasons.joined(separator: "; ")))
        case .withdrawn:
            return Question.Reply(.withdrawn)
        case .held:
            if let timeout = question.timeout, hold >= timeout {
                channel.withdraw(pending)
                return Question.Reply(.unanswered(timeout))
            }
            box.park(question, pending: pending, channel: channel, audit: audit, poll: poll)
            return Question.Reply(.parked(waited: started.duration(to: .now)))
        }
    }

    /// How the hold ended.
    enum Winner: Equatable, Sendable {
        /// The person answered, by either way (`elicitation`, `cli`, or `tui`).
        case answered(via: String, Question.Outcome)
        /// The hold lapsed with no answer.
        case held
        /// The request left the channel while the call held it: the thread closed, or the server is stopping.
        case withdrawn
        /// The call was cancelled.
        case abandoned
        /// Every way failed.
        case failed([String])
    }

    /// The race between the channel, the dialog when there is one, and the hold's clock.
    ///
    /// - Parameters:
    ///   - pending: The filed request.
    ///   - question: The question, for the dialog.
    ///   - ask: The client's dialog, if any.
    ///   - hold: How long to hold before parking.
    ///   - audit: The thread's log, for a refused answer file.
    /// - Returns: How the hold ended.
    private func race(
        _ pending: PendingApprovals.Request, question: Question, ask: Ask?, hold: Duration, audit: AuditLog?
    ) async -> Winner {
        let race = Race(legs: ask == nil ? 1 : 2)
        let channel = channel
        let poll = poll
        if let ask {
            race.start {
                switch await ask(question) {
                case .answered(let outcome): race.settle(.answered(via: "elicitation", outcome))
                case .failed(let reason): race.failed("the client's dialog: \(reason)")
                }
            }
        }
        race.start {
            let deadline = ContinuousClock.now + hold
            while !Task.isCancelled {
                switch channel.take(pending) {
                case .answer(let answer)?:
                    race.settle(
                        .answered(via: answer.via, Question.outcome(decision: answer.decision, text: answer.text)))
                    return
                case .rejected(let reason)?:
                    audit?.record(
                        .inquiryAnswered,
                        details: AuditEvent.Details.inquiryAnswered(
                            pending.id, via: "unknown", delivery: "refused", reason: reason))
                case nil:
                    break
                }
                if !channel.isFiled(pending) {
                    race.settle(.withdrawn)
                    return
                }
                if ContinuousClock.now >= deadline {
                    race.settle(.held)
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

    /// The race between the ways of asking: the first to settle wins, the other legs are cancelled, none is awaited
    /// (a dialog in flight may ignore cancellation). The same shape as `OutOfBandApprover.Race`, over this
    /// asker's `Winner`.
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

        /// A race of `legs` legs, all counted before any starts.
        ///
        /// - Parameter legs: The number of ways of asking.
        init(legs: Int) { state = Mutex(State(running: legs)) }

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
}
