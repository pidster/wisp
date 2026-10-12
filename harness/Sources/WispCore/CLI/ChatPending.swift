import Foundation
import Synchronization

/// The plain terminal chat's view of the requests waiting in `wisp mcp` servers, and its way of answering them
/// ([ADR 0046](../../../../docs/decisions/0046-approval-and-notifications-over-mcp.md), note of 2026-10-12): a command
/// waiting for approval, a fact a caller asked to keep as a permanent fact
/// ([ADR 0048](../../../../docs/decisions/0048-permanent-facts-over-mcp.md)), or a question the model asked
/// ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md)). `wisp-tui` is fed the same requests by
/// `PendingRelay`; plain chat reads a line at a time and has no place for a dialog, so it shows a note for each new
/// request before its next prompt, once, and the person answers with `/approvals approve|deny`, `/facts keep|drop`,
/// or `/questions answer|decline` (the answer typed at a prompt, as `wisp questions answer` asks for it).
///
/// A request seen before and gone now is reported once: how it ended, from the `approval.settled` event its server
/// wrote to the audit log (answered in `wisp-tui`, in the client's dialog, with `wisp approvals`; timed out;
/// withdrawn), or the `inquiry.settled` event for a question, or, when the log has no word of it, that it is no longer waiting. One answered in this chat is not
/// reported again.
///
/// Answers are written with `via: chat` (`tui` under `wisp-tui`, whose input reaches the same commands) and audited
/// as `approval.answered` (`inquiry.answered` for a question) on the chat's own log, through the same channel checks as every other face: the request
/// still waiting, the decision one its kind takes, the file matching its binding, the first answer winning. As
/// `wisp approvals` does, the plain chat answers only when its standard input is a terminal (`canAnswer`), so an
/// agent piping lines into `wisp chat --plain` cannot answer for the person.
public final class ChatPending: Sendable {
    /// The kinds of request plain chat shows, in the order they are listed. A kind added to the channel is added
    /// here and to `describe`, whose switch names every kind.
    static let kinds: [PendingApprovals.Kind] = [.command, .fact, .question]

    /// What the watcher remembers between looks.
    struct State {
        /// The requests shown and still waiting at the last look, by id.
        var shown: [String: PendingApprovals.Request] = [:]
        /// The ids answered in this chat, which are not reported again when they go.
        var answeredHere: Set<String> = []
        /// How requests ended, by id, from the audit log's `approval.settled` and `inquiry.settled` events.
        var settled: [String: String] = [:]
        /// Follows the audit log for `approval.settled` and `inquiry.settled`; nil when there is no log to follow.
        var tail: AuditTail?
        /// The kinds whose answering commands have been named once already.
        var hinted: Set<PendingApprovals.Kind> = []
    }

    /// The channel.
    let channel: PendingApprovals
    /// The shared store, where a fact is kept when the server that asked has stopped.
    let facts: SharedFacts?
    /// Whether this chat may answer: its standard input is a terminal, or it is the person's front end.
    public let canAnswer: Bool
    /// Whether `notes` shows anything: false under `wisp-tui`, which `PendingRelay` shows the requests to.
    let shows: Bool
    /// What an answer written here records as where the person answered: `chat`, or `tui` under `wisp-tui`.
    let via: String
    /// How long an answer waits for its server to take it before saying it has not yet.
    let patience: Duration
    /// The remembered state.
    private let state: Mutex<State>

    /// Creates the watcher.
    ///
    /// - Parameters:
    ///   - channel: The pending channel.
    ///   - facts: The shared store of permanent facts.
    ///   - auditFile: The audit log the servers write to, followed from its end for how requests ended; nil for none.
    ///   - canAnswer: Whether the chat's standard input is a terminal.
    ///   - shows: Whether `notes` shows anything; false where `PendingRelay` shows the requests.
    ///   - via: Where an answer records the person answered: `chat`, or `tui` under `wisp-tui`.
    ///   - patience: How long an answer waits for its server to take it.
    public init(
        channel: PendingApprovals, facts: SharedFacts?, auditFile: URL?, canAnswer: Bool, shows: Bool = true,
        via: String = "chat", patience: Duration = .seconds(3)
    ) {
        self.shows = shows
        self.via = via
        self.channel = channel
        self.facts = facts
        self.canAnswer = canAnswer
        self.patience = patience
        self.state = Mutex(State(tail: auditFile.map(AuditTail.atEnd(of:))))
    }

    /// The requests waiting now, of every kind plain chat shows (or only `kind`), oldest first.
    ///
    /// - Parameters:
    ///   - kind: Only this kind; nil for all.
    ///   - now: The time.
    ///   - alive: Whether a process is running.
    /// - Returns: The requests.
    public func waiting(
        _ kind: PendingApprovals.Kind? = nil, now: Date = Date(), alive: (Int32) -> Bool = PendingApprovals.isAlive
    ) -> [PendingApprovals.Request] {
        channel.waiting(kind, now: now, alive: alive).filter { Self.kinds.contains($0.kind) }
    }

    /// One look at the channel: a note for each request not shown before, and one for each shown before and gone
    /// now, other than those answered here. Nothing when nothing changed.
    ///
    /// - Parameters:
    ///   - style: Styling.
    ///   - now: The time.
    ///   - alive: Whether a process is running.
    /// - Returns: The notes, in order.
    public func notes(
        style: Style = .plain, now: Date = Date(), alive: (Int32) -> Bool = PendingApprovals.isAlive
    ) -> [String] {
        guard shows else { return [] }
        let waiting = waiting(now: now, alive: alive)
        return state.withLock { state -> [String] in
            // Read after listing: a server removes its request before it records how it ended.
            if var tail = state.tail {
                for event in (try? tail.read()) ?? [] {
                    switch event.kind {
                    case .approvalSettled:
                        guard let id = event.details["request"]?.stringValue else { continue }
                        state.settled[id] = Self.ending(event.details)
                    case .inquirySettled:
                        guard let id = event.details["inquiry"]?.stringValue else { continue }
                        state.settled[id] = Self.questionEnding(event.details)
                    default:
                        continue
                    }
                }
                state.tail = tail
            }
            let ids = Set(waiting.map(\.id))
            var lines: [String] = []
            for (id, request) in state.shown.sorted(by: { $0.key < $1.key }) where !ids.contains(id) {
                defer { state.settled[id] = nil }
                guard !state.answeredHere.contains(id) else { continue }
                let how = state.settled[id] ?? "answered elsewhere or withdrawn"
                lines.append(style.muted("· \(id) no longer waiting: \(how) (\(request.subject))"))
            }
            for request in waiting where state.shown[request.id] == nil {
                lines.append(style.amber(Self.describe(request)))
                if !state.hinted.contains(request.kind) {
                    state.hinted.insert(request.kind)
                    lines.append(style.muted("  " + hint(request.kind)))
                }
            }
            state.shown = Dictionary(waiting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            state.answeredHere.formIntersection(ids)
            return lines
        }
    }

    /// The note for a newly waiting request: who asks, what, and its id.
    ///
    /// - Parameter request: The request.
    /// - Returns: The line.
    static func describe(_ request: PendingApprovals.Request) -> String {
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self).joined(separator: ", ")
        let asker = "wisp mcp" + (from.isEmpty ? "" : " (\(from))")
        switch request.kind {
        case .command:
            return "⚠ \(request.id) waiting in \(asker): run \(request.command) in "
                + "\(ChatStatus.abbreviated(request.directory)), \(request.level.rawValue)"
        case .fact:
            let fact = request.fact
            let source = fact.map { ", from \($0.source)" } ?? ""
            return "⚠ \(request.id) waiting in \(asker): keep as a permanent fact "
                + "\(fact.map { "\($0.subject) \($0.text)" } ?? request.subject)\(source)"
        case .question:
            let visible = ApprovalRequest.visible
            let options = request.options ?? []
            let offered = options.isEmpty ? "" : " (" + options.map(visible).joined(separator: " | ") + ")"
            return "? \(request.id) waiting in \(asker): the model asks: \(visible(request.question ?? ""))\(offered)"
        }
    }

    /// How to answer a kind of request, named once a session.
    ///
    /// - Parameter kind: The kind.
    /// - Returns: The line.
    func hint(_ kind: PendingApprovals.Kind) -> String {
        guard canAnswer else {
            return kind == .question
                ? "answer in wisp-tui, or with wisp questions answer ID from a terminal"
                : "answer in wisp-tui, the client's dialog, or with wisp approvals or wisp facts from a terminal"
        }
        switch kind {
        case .command: return "answer with /approvals approve ID [once|session|project|always] or /approvals deny ID"
        case .fact: return "answer with /facts keep ID or /facts drop ID"
        case .question:
            return "answer with /questions answer ID, which prompts for the answer, or /questions decline ID"
        }
    }

    /// How an `approval.settled` event says a request ended, as the chat reports it.
    ///
    /// - Parameter details: The event's details.
    /// - Returns: The phrase.
    static func ending(_ details: [String: JSONValue]) -> String {
        switch details["outcome"]?.stringValue {
        case "answered":
            let via = details["via"]?.stringValue ?? "?"
            let face =
                switch via {
                case "elicitation": "the client's dialog"
                case "cli": details["kind"]?.stringValue == "fact" ? "wisp facts" : "wisp approvals"
                case "tui": "wisp-tui"
                case "chat": "another wisp chat"
                default: via
                }
            return "answered in \(face)"
        case "timed-out": return "its wait ran out unanswered"
        case "abandoned": return "withdrawn: the caller cancelled the call"
        case "stale": return "withdrawn: its server stopped"
        case "handed-over": return "its server stopped; it still waits"
        default: return "withdrawn"
        }
    }

    /// How an `inquiry.settled` event says a question ended, as the chat reports it.
    ///
    /// - Parameter details: The event's details.
    /// - Returns: The phrase.
    static func questionEnding(_ details: [String: JSONValue]) -> String {
        let face: String =
            switch details["via"]?.stringValue {
            case "elicitation": "the client's dialog"
            case "cli": "wisp questions"
            case "tui": "wisp-tui"
            case "chat": "another wisp chat"
            case let other?: other
            case nil: "another face"
            }
        switch details["outcome"]?.stringValue {
        case "answered", "none": return "answered in \(face)"
        case "declined": return "declined in \(face)"
        case "unanswered": return "its wait ran out unanswered"
        case "abandoned": return "withdrawn: the caller cancelled the call"
        default: return "withdrawn"
        }
    }

    /// Answers request `id` for the person and says how it went, as `wisp approvals` and `wisp facts` would: written
    /// to the channel, then, for a fact whose server has stopped, applied here; otherwise waiting up to `patience` for
    /// the server to take it. Audited as `approval.answered` with `via`.
    ///
    /// - Parameters:
    ///   - id: The request.
    ///   - decision: `once`, `session`, `project`, `always`, or `no` for a command; `keep` or `drop` for a fact;
    ///     `answer`, `chose`, `none`, or `decline` for a question.
    ///   - text: For a question answered `answer` or `chose`, the text or the option.
    ///   - audit: The chat's log.
    ///   - alive: Whether a process is running.
    /// - Returns: How it ended: a line to show, or why the answer was not used.
    public func answer(
        _ id: String, decision: String, text: String? = nil, audit: AuditLog?,
        alive: @Sendable (Int32) -> Bool = PendingApprovals.isAlive
    ) async -> PendingAnswer.Ending {
        guard canAnswer else {
            return .failed(
                "this chat's input is not a terminal, so it does not answer for the person; answer in wisp-tui, "
                    + "or with wisp approvals, wisp facts, or wisp questions from a terminal")
        }
        let request: PendingApprovals.Request
        do {
            request = try channel.answer(id, decision: decision, text: text, via: via, alive: alive)
        } catch {
            let failure = error as? PendingApprovals.Failure ?? .io("\(error)")
            let filed = try? channel.request(id: id)
            if filed?.kind == .question {
                audit?.record(
                    .inquiryAnswered,
                    details: AuditEvent.Details.inquiryAnswered(
                        id, via: via, delivery: "refused", reason: "\(failure)"))
            } else {
                audit?.record(
                    .approvalAnswered,
                    details: AuditEvent.Details.approvalAnswered(
                        request: id, filed, decision: decision, via: via, delivery: "refused", reason: "\(failure)"))
            }
            return PendingAnswer.ending(for: failure)
        }
        state.withLock { _ = $0.answeredHere.insert(id) }
        func applyHere() -> PendingAnswer.Ending? {
            guard let facts,
                let applied = FactKeeper.settleUnwatched(
                    request, channel: channel, store: facts, audit: audit, alive: alive)
            else { return nil }
            audit?.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: id, request, decision: decision, via: via, delivery: "applied"))
            return PendingAnswer.ending(of: request, applied: applied)
        }
        if let ending = applyHere() { return ending }
        // The server looks every 200 ms; give it a moment to take the answer.
        let step = Duration.milliseconds(100)
        var delivery = channel.delivery(of: id)
        var waited = Duration.zero
        while delivery == .waiting, waited < patience {
            try? await Task.sleep(for: step)
            waited += step
            delivery = channel.delivery(of: id)
        }
        if delivery == .waiting, let ending = applyHere() { return ending }
        let delivered: String =
            switch delivery {
            case .taken: "taken"
            case .tooLate: "too-late"
            case .waiting: "waiting"
            }
        if request.kind == .question {
            audit?.record(
                .inquiryAnswered, details: AuditEvent.Details.inquiryAnswered(id, via: via, delivery: delivered))
        } else {
            audit?.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: id, request, decision: decision, via: via, delivery: delivered))
        }
        return PendingAnswer.ending(of: request, decision: decision, delivery: delivery)
    }
}
