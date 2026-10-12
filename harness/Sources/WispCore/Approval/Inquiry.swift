import Foundation
import Synchronization

/// A question the model asks the person mid-turn through its `ask` tool
/// ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md)): free text, or a choice of two to six
/// options. The third host effect beside approval and notification (ADR 0044): each face asks its own way
/// through an `Asker`, and the tool never knows which.
public struct Question: Equatable, Sendable {
    /// Random, fresh for every question; what `wisp questions answer` takes.
    public var id: String
    /// The question, as the model wrote it (shown escaped, `ApprovalRequest.visible`).
    public var text: String
    /// The options, two to six; empty for a free-text question.
    public var options: [String]
    /// The conversation asking: its audit session (the MCP thread's).
    public var thread: String?
    /// How long the person has to answer; nil waits until they do (`inquiry.timeoutSeconds` 0, the default).
    public var timeout: Duration?

    /// Creates a question.
    public init(
        id: String = ShortID.make(), text: String, options: [String] = [], thread: String? = nil,
        timeout: Duration? = nil
    ) {
        self.id = id
        self.text = text
        self.options = options
        self.thread = thread
        self.timeout = timeout
    }

    /// Whether it offers options.
    public var isChoice: Bool { !options.isEmpty }

    /// The answer a person gives when none of the options is theirs.
    public static let noneOfThese = "none of these"

    /// The most characters a question may have.
    public static let textLimit = 300
    /// The most characters an option may have.
    public static let optionLimit = 80
    /// The fewest and most options a choice may offer.
    public static let optionCounts = 2...6
    /// The most bytes of an answer passed to the model; the rest is cut with a note.
    public static let answerBytes = 2000
    /// Questions a turn may ask.
    public static let perTurn = 2

    /// How a question ended.
    public enum Outcome: Equatable, Sendable {
        /// The person typed `text` (a free-text question).
        case answered(String)
        /// The person chose `option`.
        case chose(String)
        /// The person chose none of the options.
        case noneOfThese
        /// The person declined to answer.
        case declined
        /// A deadline was set and passed.
        case unanswered(Duration)
        /// The person stopped the turn (Ctrl-C at the dialog); the question is withdrawn.
        case stopped
        /// Under `wisp mcp`, the dialog's hold lapsed: the question stays filed and the turn parks (D15).
        case parked(waited: Duration)
        /// The call was cancelled while the question waited.
        case abandoned
        /// The thread closed or the server stopped.
        case withdrawn
        /// No person can answer in this face (`wisp respond`, `--yes`), with the face named.
        case nobody(String)
        /// Asking failed.
        case failed(String)

        /// The outcome's name in the audit (`inquiry.settled`'s `outcome`).
        public var name: String {
            switch self {
            case .answered, .chose: "answered"
            case .noneOfThese: "none"
            case .declined: "declined"
            case .unanswered: "unanswered"
            case .stopped: "stopped"
            case .parked: "parked"
            case .abandoned: "abandoned"
            case .withdrawn: "withdrawn"
            case .nobody: "refused"
            case .failed: "failed"
            }
        }

        /// The person's answer, when there is one.
        public var answer: String? {
            switch self {
            case .answered(let text), .chose(let text): text
            default: nil
            }
        }
    }

    /// The outcome for an answer written to the pending channel (`PendingApprovals.Answer`): its `decision`
    /// (`answer`, `chose`, `none`, `decline`) and `text`.
    ///
    /// - Parameters:
    ///   - decision: The answer's decision.
    ///   - text: The answer's text, for `answer` and `chose`.
    /// - Returns: The outcome.
    public static func outcome(decision: String, text: String?) -> Outcome {
        switch decision {
        case "answer": .answered(text ?? "")
        case "chose": .chose(text ?? "")
        case "none": .noneOfThese
        default: .declined
        }
    }

    /// The outcome for what a person typed or picked in a face's dialog: an empty answer declines, a number or
    /// an option's text chooses it, `none of these` is none, and for a free-text question anything else is the
    /// answer. For a choice, text that is no option is nil: the face asks again.
    ///
    /// - Parameter typed: What the person gave.
    /// - Returns: The outcome, or nil for a choice answered with something that is no option.
    public func outcome(typed: String?) -> Outcome? {
        guard let typed else { return .declined }
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .declined }
        guard isChoice else { return .answered(text) }
        if text.lowercased() == Self.noneOfThese { return .noneOfThese }
        if let number = Int(text), options.indices.contains(number - 1) { return .chose(options[number - 1]) }
        if number(ofNone: text) { return .noneOfThese }
        if let option = options.first(where: { $0 == text }) { return .chose(option) }
        return nil
    }

    /// Whether `text` is the number of the "none of these" row, the one after the options.
    private func number(ofNone text: String) -> Bool { Int(text) == options.count + 1 }

    /// The choice a face offers for this question: the options, then `none of these`; typed text taken for a
    /// free-text question. Marked `kind` `question`, so a face shows it as the model's, never as an approval.
    public var choice: ChatChoice {
        var choice = ChatChoice(
            title: ApprovalRequest.visible(text),
            options: options.map { ChatChoice.Option(value: $0, label: ApprovalRequest.visible($0)) }
                + (isChoice ? [ChatChoice.Option(value: Self.noneOfThese)] : []),
            acceptsText: !isChoice)
        choice.kind = ChatChoice.questionKind
        choice.origin = thread.map { ChatChoice.Origin(thread: $0) }
        return choice
    }

    /// Words that ask for a credential; a question holding one is refused by rule (D5).
    static let secretWords = [
        "password", "passphrase", "token", "api key", "apikey", "api-key", "secret", "private key", "pin",
        "one-time code", "one time code", "2fa", "two-factor", "credential", "credentials", "access key",
        "login details",
    ]

    /// Whether `text` asks for a secret, by rule: one of `secretWords` as a word.
    ///
    /// - Parameter text: The question.
    /// - Returns: Whether it is refused.
    public static func asksForSecret(_ text: String) -> Bool {
        let folded = text.lowercased()
        return secretWords.contains { word in
            folded.range(
                of: #"(^|[^a-z0-9])"# + NSRegularExpression.escapedPattern(for: word) + #"([^a-z0-9]|$)"#,
                options: .regularExpression) != nil
        }
    }

    /// Why a question is not asked: a limit, a repeat, or the rule on secrets (D4, D5); the model is told as
    /// `error: …`.
    public enum Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        /// Empty, or over `textLimit`, or more than one paragraph.
        case text(String)
        /// Wrong count, or an option empty or over `optionLimit`.
        case options(String)
        /// The question asks for a credential.
        case secret
        /// A question is already waiting on this thread.
        case waiting
        /// `perTurn` questions were asked this turn.
        case turnLimit
        /// The same question was asked this turn.
        case repeated

        /// What the model is told, after `error: `.
        public var description: String {
            switch self {
            case .text(let why): "question \(why)"
            case .options(let why): "options \(why)"
            case .secret: "ask does not ask for secrets; tell the person what is needed and where to set it"
            case .waiting: "a question is already waiting for the person; do not ask another until it is answered"
            case .turnLimit:
                "you have asked \(perTurn) questions this turn; say in your reply what you still need, and stop"
            case .repeated: "you asked this question already this turn; its answer is in your context"
            }
        }
    }

    /// Checks the question's text and options against the limits (D4) and the rule on secrets (D5).
    ///
    /// - Parameters:
    ///   - text: The question as the model wrote it.
    ///   - options: Its options, if any.
    ///   - thread: The asking conversation, for the dialog and the record.
    ///   - timeout: The deadline the question gets; nil waits until answered.
    /// - Returns: The question, trimmed.
    /// - Throws: `Refusal`.
    public static func validate(
        text: String, options: [String]?, thread: String?, timeout: Duration?
    ) throws(Refusal)
        -> Question
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .text("must say what you need to know") }
        guard trimmed.count <= textLimit else { throw .text("must be at most \(textLimit) characters") }
        guard !trimmed.contains("\n\n") else { throw .text("must be one paragraph") }
        let options = (options ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !options.isEmpty {
            guard optionCounts.contains(options.count) else {
                throw .options(
                    "must be \(optionCounts.lowerBound) to \(optionCounts.upperBound); leave them out for free text")
            }
            guard !options.contains(where: \.isEmpty) else { throw .options("must each say something") }
            guard options.allSatisfy({ $0.count <= optionLimit }) else {
                throw .options("must each be at most \(optionLimit) characters")
            }
            guard Set(options).count == options.count else { throw .options("must differ from one another") }
        }
        guard !asksForSecret(trimmed) else { throw .secret }
        return Question(text: trimmed, options: options, thread: thread, timeout: timeout)
    }
}

extension Question {
    /// What an asker came back with: how the question ended, and where the person answered.
    public struct Reply: Equatable, Sendable {
        /// How it ended.
        public var outcome: Outcome
        /// Where the person answered (`terminal`, `json`, `elicitation`, `cli`, `tui`); nil when nobody did.
        public var via: String?

        /// Creates a reply.
        public init(_ outcome: Outcome, via: String? = nil) {
            self.outcome = outcome
            self.via = via
        }
    }
}

/// A channel to the person for the model's questions: the third host effect (ADR 0062). One implementation per
/// face; must not throw.
public protocol Asker: Sendable {
    /// How this face asks, for the audit: `terminal`, `json`, `elicitation`, `pending`; empty when nobody can be
    /// asked.
    var ways: [String] { get }

    /// Asks, and returns how it ended and where the person answered. `box` is the asking thread's inquiry state,
    /// which an asker that parks a question (`wisp mcp`) hands the waiting question to.
    func ask(_ question: Question, box: InquiryBox, audit: AuditLog?) async -> Question.Reply
}

/// Nobody can answer: `wisp respond`, `--yes`, or an MCP server with no way to reach the person.
public struct NobodyAsker: Asker {
    /// The face, named to the model.
    public let face: String

    /// Creates the asker.
    public init(face: String) { self.face = face }

    /// No ways.
    public var ways: [String] { [] }

    /// Nobody.
    public func ask(_ question: Question, box: InquiryBox, audit: AuditLog?) async -> Question.Reply {
        Question.Reply(.nobody(face))
    }
}

/// Asks on the terminal, in plain chat: the question and its numbered options on stderr, then a line read that
/// Ctrl-C (the turn's `TurnStop`) and the deadline, when one is set, can end (`LineReader`).
public struct TerminalAsker: Asker {
    /// Styling for the dialog.
    public let style: Style
    /// Reads one line, or ends on the stop or the deadline; the terminal's by default, injected by tests.
    let read: @Sendable (TurnStop?, Duration?) async -> LineReader.Read
    /// Writes the dialog; stderr by default.
    let write: @Sendable (String) -> Void

    /// Creates the asker over the terminal.
    public init(style: Style = .plain) {
        self.init(
            style: style, read: { stop, timeout in await LineReader.standardInput.read(stop: stop, within: timeout) },
            write: { FileHandle.standardError.write(Data($0.utf8)) })
    }

    /// Creates an asker over an injected reader and writer, for tests.
    init(
        style: Style, read: @escaping @Sendable (TurnStop?, Duration?) async -> LineReader.Read,
        write: @escaping @Sendable (String) -> Void
    ) {
        self.style = style
        self.read = read
        self.write = write
    }

    /// The terminal.
    public var ways: [String] { ["terminal"] }

    /// The dialog: who asks, the question, the numbered options with `none of these` last, and what to type.
    /// Visibly the model's, never an approval's: no risk level, no scope keys.
    ///
    /// - Parameters:
    ///   - question: The question.
    ///   - style: Styling.
    /// - Returns: The dialog, ending with the prompt.
    public static func render(_ question: Question, style: Style) -> String {
        let visible = ApprovalRequest.visible
        var lines = ["", style.bold("? the model asks") + style.muted(question.thread.map { " (thread \($0))" } ?? "")]
        lines.append("  " + visible(question.text))
        let width = String(question.options.count + 1).count
        for (index, option) in (question.options + (question.isChoice ? [Question.noneOfThese] : [])).enumerated() {
            let number = String(index + 1)
            lines.append("  \(String(repeating: " ", count: width - number.count))\(number)  \(visible(option))")
        }
        let how = question.isChoice ? "type a number" : "type your answer"
        let deadline = question.timeout.map { "; \(Self.deadlineText($0)) to answer" } ?? ""
        lines.append(style.muted("  \(how), or press Enter to decline\(deadline)") + " " + style.prompt("›") + " ")
        return lines.joined(separator: "\n")
    }

    /// `30 s`, `5 min`, or `2 h`.
    static func deadlineText(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 60 ? "\(seconds) s" : seconds < 3600 ? "\(seconds / 60) min" : "\(seconds / 3600) h"
    }

    /// Shows the dialog and reads the answer; for a choice, text that is no option is asked again, up to three
    /// times, then taken as declined.
    public func ask(_ question: Question, box: InquiryBox, audit: AuditLog?) async -> Question.Reply {
        Question.Reply(await read(question), via: "terminal")
    }

    /// The dialog and its reads.
    private func read(_ question: Question) async -> Question.Outcome {
        let stop = TurnStop.current
        write(Self.render(question, style: style))
        let started = ContinuousClock.now
        for _ in 0..<3 {
            let remaining = question.timeout.map { $0 - started.duration(to: .now) }
            if let remaining, remaining <= .zero { return .unanswered(question.timeout ?? .zero) }
            switch await read(stop, remaining) {
            case .line(let line):
                if let outcome = question.outcome(typed: line) { return outcome }
                write(
                    style.muted("  type a number from 1 to \(question.options.count + 1)") + " " + style.prompt("›")
                        + " ")
            case .end: return .declined
            case .stopped: return .stopped
            case .expired: return .unanswered(question.timeout ?? .zero)
            }
        }
        return .declined
    }
}

/// One thread's questions: the one waiting, how many each turn asked, and every question's record for the
/// thread's resource and `respond`'s `questions`; under `wisp mcp`, the watch for a parked question's answer,
/// which it delivers as a note to the thread's next turn (ADR 0062, section 6). A `final class` with a `Mutex`,
/// the watch a task it holds so a closing thread can end it.
public final class InquiryBox: Sendable {
    /// Where a question stands.
    public enum State: String, Sendable, Equatable {
        /// Asked, not yet answered: the dialog is up, or the turn has parked.
        case waiting
        /// It ended; `Record.outcome` says how.
        case settled
    }

    /// One question and where it stands.
    public struct Record: Sendable, Equatable {
        /// The question.
        public var question: Question
        /// The turn that asked it.
        public var turn: Int
        /// Where it stands.
        public var state: State
        /// How it ended, once settled.
        public var outcome: Question.Outcome?
        /// How the answer reached the model: `tool` (inside the turn) or `notice` (on the next turn after a park).
        public var delivered: String?
        /// Whether the turn parked with it waiting (`wisp mcp`).
        public var parked = false
        /// When it was asked.
        public var asked: Date
        /// When it settled.
        public var settledAt: Date?

        /// The record as JSON, for `respond`'s `questions` and `wisp://threads/{thread_id}`.
        public var json: JSONValue {
            var fields: [String: JSONValue] = [
                "id": .string(question.id), "question": .string(question.text),
                "options": .array(question.options.map { .string($0) }), "turn": .int(turn),
                "state": .string(state == .waiting ? "waiting" : outcome?.name ?? "settled"),
                "asked": .string(asked.ISO8601Format()),
            ]
            if let answer = outcome?.answer { fields["answer"] = .string(answer) }
            if let delivered { fields["delivered"] = .string(delivered) }
            if parked { fields["parked"] = true }
            return .object(fields)
        }
    }

    /// The box's state.
    private struct Contents {
        var records: [Record] = []
        /// The questions asked per turn, by their text.
        var asked: [Int: [String]] = [:]
        /// The watch for a parked question, by question id.
        var watches: [String: Task<Void, Never>] = [:]
        /// Pending requests of parked questions, by question id, to withdraw them.
        var pending: [String: (PendingApprovals, PendingApprovals.Request)] = [:]
    }

    private let contents = Mutex(Contents())
    /// Where a parked question's answer waits for the thread's next turn (ADR 0059's notes); nil keeps none.
    private let notices: ConversationNotices?
    /// The conversation the notes are for: its audit session.
    public let conversation: String
    /// What records an answer taken after a park as the thread's fact (D14); set by the face that owns the agent.
    private let onAnswer = Mutex<(@Sendable (Question, String) async -> Void)?>(nil)
    /// How many settled records are kept.
    static let historyLimit = 100

    /// Creates a box for `conversation`.
    ///
    /// - Parameters:
    ///   - conversation: The thread's audit session.
    ///   - notices: Where a parked question's answer waits as a note.
    public init(conversation: String = "", notices: ConversationNotices? = nil) {
        self.conversation = conversation
        self.notices = notices
    }

    /// Sets what records an answer delivered after a park as the thread's `person` fact.
    public func onAnswer(_ record: @escaping @Sendable (Question, String) async -> Void) {
        onAnswer.withLock { $0 = record }
    }

    /// Every record, oldest first.
    public var records: [Record] { contents.withLock { $0.records } }

    /// The question waiting, if one is.
    public var waiting: Question? { contents.withLock { $0.records.last { $0.state == .waiting }?.question } }

    /// The records of `turn`.
    public func records(turn: Int) -> [Record] { records.filter { $0.turn == turn } }

    /// Admits `question` for `turn`, or refuses it: one waiting at a time, `Question.perTurn` a turn, never the
    /// same text twice in a turn (D4).
    ///
    /// - Throws: `Question.Refusal`.
    public func begin(_ question: Question, turn: Int) throws(Question.Refusal) {
        try contents.withLock { contents throws(Question.Refusal) in
            guard !contents.records.contains(where: { $0.state == .waiting }) else { throw .waiting }
            let asked = contents.asked[turn] ?? []
            guard !asked.contains(question.text) else { throw .repeated }
            guard asked.count < Question.perTurn else { throw .turnLimit }
            contents.asked = [turn: asked + [question.text]]
            contents.records.append(Record(question: question, turn: turn, state: .waiting, asked: Date()))
        }
    }

    /// Settles `id` with `outcome`, delivered `delivered`; nothing changes for a question not waiting.
    ///
    /// - Returns: The record, or nil when no such question waits.
    @discardableResult
    public func settle(_ id: String, outcome: Question.Outcome, delivered: String? = nil) -> Record? {
        contents.withLock { contents in
            contents.watches[id] = nil
            contents.pending[id] = nil
            guard let index = contents.records.firstIndex(where: { $0.question.id == id && $0.state == .waiting })
            else { return nil }
            contents.records[index].state = .settled
            contents.records[index].outcome = outcome
            contents.records[index].delivered = delivered
            contents.records[index].settledAt = Date()
            let settled = contents.records.indices.filter { contents.records[$0].state == .settled }
            if settled.count > Self.historyLimit {
                let drop = Set(settled.prefix(settled.count - Self.historyLimit))
                contents.records = contents.records.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            }
            return contents.records.first { $0.question.id == id }
        }
    }

    /// The note the thread's next turn carries when its question is still waiting (section 6, step 4).
    public var stillWaitingNote: String? {
        waiting.map {
            "[wisp: your question \"\(ApprovalRequest.visible($0.text))\" (question \($0.id)) still waits for the "
                + "person; do not assume its answer]"
        }
    }

    /// The note the thread's next turn carries for an answer taken after a park.
    ///
    /// - Parameters:
    ///   - question: The question.
    ///   - outcome: How it ended.
    ///   - via: Where the person answered (`cli`, `tui`).
    ///   - time: When.
    /// - Returns: The note.
    public static func note(
        for question: Question, outcome: Question.Outcome, via: String?, time: Date = Date()
    ) -> String {
        let quoted = "\"\(ApprovalRequest.visible(question.text))\""
        let when = Date.FormatStyle(date: .omitted, time: .shortened).format(time)
        let face =
            via.map {
                "via \(OutOfBandApprover.face($0).replacingOccurrences(of: "wisp approvals", with: "wisp questions")), "
            } ?? ""
        switch outcome {
        case .answered(let text): return "[wisp: the person answered your question \(quoted): \(text) (\(face)\(when))]"
        case .chose(let text):
            return "[wisp: the person answered your question \(quoted): they chose \(text) (\(face)\(when))]"
        case .noneOfThese:
            return "[wisp: the person answered your question \(quoted): none of the options (\(face)\(when))]"
        case .declined:
            return
                "[wisp: the person declined to answer your question \(quoted) (\(face)\(when)). Do not ask it again; say in your reply what you needed]"
        case .unanswered:
            return
                "[wisp: your question \(quoted) went unanswered within its deadline (\(when)). Do not guess the answer; say in your reply what you need]"
        default: return "[wisp: your question \(quoted) was withdrawn (\(when))]"
        }
    }

    /// The turn has parked with `pending` filed for `question` (D15): the dialog is gone, and the box watches the
    /// channel for the answer, every `poll`, until it comes, the deadline passes, or the question is withdrawn.
    /// The answer is held as a note for the thread's next turn, recorded as the thread's fact, and audited as
    /// `inquiry.settled` with `delivered` `notice`.
    ///
    /// - Parameters:
    ///   - question: The question.
    ///   - pending: The request filed for it.
    ///   - channel: The channel it is filed in.
    ///   - audit: The thread's log.
    ///   - poll: How often to look.
    public func park(
        _ question: Question, pending: PendingApprovals.Request, channel: PendingApprovals, audit: AuditLog?,
        poll: Duration = .milliseconds(200)
    ) {
        let started = Date()
        let task = Task { [self] in
            let deadline = pending.expiresAt
            while !Task.isCancelled {
                switch channel.take(pending) {
                case .answer(let answer)?:
                    let outcome = Question.outcome(decision: answer.decision, text: answer.text)
                    await deliver(question, outcome: outcome, via: answer.via, started: started, audit: audit)
                    return
                case .rejected(let reason)?:
                    audit?.record(
                        .inquiryAnswered,
                        details: AuditEvent.Details.inquiryAnswered(
                            question.id, via: "unknown", delivery: "refused", reason: reason))
                case nil: break
                }
                if !channel.isFiled(pending) {
                    await deliver(question, outcome: .withdrawn, via: nil, started: started, audit: audit)
                    return
                }
                if let deadline, Date() >= deadline {
                    channel.withdraw(pending)
                    await deliver(
                        question, outcome: .unanswered(question.timeout ?? .zero), via: nil, started: started,
                        audit: audit)
                    return
                }
                try? await Task.sleep(for: poll)
            }
        }
        let stale = contents.withLock { contents -> Bool in
            guard contents.records.contains(where: { $0.question.id == question.id && $0.state == .waiting }) else {
                return true
            }
            if let index = contents.records.firstIndex(where: { $0.question.id == question.id }) {
                contents.records[index].parked = true
            }
            contents.watches[question.id] = task
            contents.pending[question.id] = (channel, pending)
            return false
        }
        if stale { task.cancel() }
    }

    /// Settles a parked question with what the watch found, posts the note, records the fact, and audits it.
    private func deliver(
        _ question: Question, outcome: Question.Outcome, via: String?, started: Date, audit: AuditLog?
    ) async {
        let outcome = outcome.masked().outcome
        guard settle(question.id, outcome: outcome, delivered: "notice") != nil else { return }
        notices?.post(Self.note(for: question, outcome: outcome, via: via), to: conversation)
        if let answer = outcome.answer, let record = onAnswer.withLock({ $0 }) { await record(question, answer) }
        audit?.record(
            .inquirySettled,
            details: AuditEvent.Details.inquirySettled(
                question, outcome: outcome, via: via, delivered: "notice", redacted: [],
                seconds: Date().timeIntervalSince(started)))
    }

    /// Withdraws the question waiting, if one is (the thread closed, was evicted, or the server stopped): its
    /// pending file is removed, its watch ends, and it is settled `withdrawn`.
    ///
    /// - Parameter audit: The thread's log.
    /// - Returns: The question withdrawn, or nil.
    @discardableResult
    public func withdraw(audit: AuditLog?) -> Question? {
        let (question, watch, filed) = contents.withLock {
            contents -> (Question?, Task<Void, Never>?, (PendingApprovals, PendingApprovals.Request)?) in
            guard let question = contents.records.last(where: { $0.state == .waiting })?.question else {
                return (nil, nil, nil)
            }
            return (question, contents.watches[question.id], contents.pending[question.id])
        }
        guard let question else { return nil }
        watch?.cancel()
        if let (channel, pending) = filed { channel.withdraw(pending) }
        guard settle(question.id, outcome: .withdrawn) != nil else { return nil }
        audit?.record(
            .inquirySettled,
            details: AuditEvent.Details.inquirySettled(
                question, outcome: .withdrawn, via: nil, delivered: nil, redacted: []))
        return question
    }
}

extension Question.Outcome {
    /// The outcome with a credential-shaped value in its answer replaced by a numbered marker (D5, through
    /// `SecretScanner`'s `secret` rules and `Redactor`'s markers), and the kinds replaced; an answer longer than
    /// `Question.answerBytes` is cut with a note.
    ///
    /// - Returns: The outcome as the model and the record get it, and the kinds masked.
    public func masked() -> (outcome: Question.Outcome, redacted: [String]) {
        guard let answer else { return (self, []) }
        let matches = SecretScanner.scan(answer, categories: [.secret])
        var text = answer
        var kinds: [String] = []
        if !matches.isEmpty {
            var redactor = Redactor()
            text = redactor.apply(matches, to: answer)
            kinds = matches.map(\.kind)
        }
        if text.utf8.count > Question.answerBytes {
            text = ToolOutput.bounded(text, maxBytes: Question.answerBytes)
        }
        switch self {
        case .answered: return (.answered(text), kinds)
        case .chose: return (.chose(text), kinds)
        default: return (self, kinds)
        }
    }
}
