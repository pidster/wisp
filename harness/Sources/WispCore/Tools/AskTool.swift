import Foundation
import FoundationModels

/// Lets the model ask the person one question mid-turn and go on with the answer
/// ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md)): free text, or a choice of two to six
/// options. The question goes through the face's `Asker` (the third host effect): plain chat's and `wisp-tui`'s
/// dialog, which waits as long as the person is away (`inquiry.timeoutSeconds`, 0 by default); under `wisp mcp`
/// the pending channel (`wisp questions answer`) and, behind `inquiry.elicitation`, the client's dialog, held for
/// 60 s before the turn parks and the answer reaches the thread's next turn as a note. Never a permission: no
/// answer runs anything. A question for a secret is refused by rule, and a credential-shaped answer is masked
/// (D5). Off by default: a conversation given every tool gets it with `tools.ask` on, or by naming it (D2).
public struct AskTool: WispTool {
    /// The tool's name, as registries and the prompt name it.
    public static let toolName = "ask"

    /// The identifier the model uses to request this tool.
    public let name = AskTool.toolName
    /// What the model is told this tool does.
    public let description =
        "Ask the person one question when you cannot go on without their answer: which of two things they meant, "
        + "or a value you cannot find. Not for permission (commands ask for themselves), not for secrets. Give "
        + "options when there are few."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The question.
        @Guide(description: "One short question for the person, at most \(Question.textLimit) characters.")
        public var question: String
        /// The options, for a choice.
        @Guide(
            description: "For a choice: 2 to 6 short options; the person picks one or none. Leave out for free text.")
        public var options: [String]?
    }

    /// How this face asks.
    private let asker: any Asker
    /// The thread's questions: the one waiting, the per-turn counts, the records.
    private let box: InquiryBox
    /// The conversation's log, for `inquiry.requested` and `inquiry.settled`.
    private let audit: AuditLog?
    /// The deadline each question gets (`inquiry.timeoutSeconds`); nil waits until answered.
    private let timeout: Duration?

    /// What bounds it.
    public var limits: String {
        "One question waiting at a time, \(Question.perTurn) a turn, never the same twice in a turn; the question up "
            + "to \(Question.textLimit) characters, \(Question.optionCounts.lowerBound) to "
            + "\(Question.optionCounts.upperBound) options of up to \(Question.optionLimit); the answer up to "
            + "\(Question.answerBytes) bytes, credential-shaped values masked. A question asking for a secret is "
            + "refused. \(timeout.map { "The person has \(TerminalAsker.deadlineText($0)) to answer" } ?? "Waits until the person answers")"
            + "; under wisp mcp the call holds for 60 s, then the turn parks and the answer arrives as a note on "
            + "the thread's next turn. Off by default: a conversation gets it with tools.ask on, or by naming it."
    }
    /// How to ask for it.
    public let examplePrompt =
        "Use ask with question `Which config did you mean?` and options `~/.wisp/config.json` and `./wisp.json`."

    /// Creates the tool.
    ///
    /// - Parameters:
    ///   - asker: The face's asker; nobody by default (a catalogue).
    ///   - box: The thread's inquiry state; a fresh one by default.
    ///   - audit: The conversation's log.
    ///   - timeout: The deadline for each question; nil waits until answered.
    public init(
        asker: any Asker = NobodyAsker(face: "no face"), box: InquiryBox = InquiryBox(), audit: AuditLog? = nil,
        timeout: Duration? = nil
    ) {
        self.asker = asker
        self.box = box
        self.audit = audit
        self.timeout = timeout
    }

    /// Asks, and returns the answer in a fixed form the model and the verification readers can read.
    ///
    /// - Parameter arguments: The question and its options.
    /// - Returns: `answer: …`, `chose: …`, or a line saying why there is none; never throws.
    public func call(arguments: Arguments) async -> String {
        let question: Question
        do {
            question = try Question.validate(
                text: arguments.question, options: arguments.options, thread: audit?.session, timeout: timeout)
            try box.begin(question, turn: audit?.currentTurn ?? 0)
        } catch {
            let refused = Question(
                text: arguments.question.prefix(Question.textLimit).description, thread: audit?.session)
            audit?.record(
                .inquirySettled,
                details: AuditEvent.Details.inquirySettled(
                    refused, outcome: .failed("\(error)"), via: nil, delivered: nil, redacted: [], reason: "\(error)"
                ).merging(["outcome": .string("refused")]) { $1 })
            return "error: \(error)"
        }
        audit?.record(
            .inquiryRequested,
            details: AuditEvent.Details.inquiryRequested(question, ways: asker.ways, call: ToolCallContext.call))
        let started = Date()
        let reply = await asker.ask(question, box: box, audit: audit)
        if case .parked(let waited) = reply.outcome {
            audit?.record(
                .inquiryParked,
                details: AuditEvent.Details.inquiryParked(
                    question, waitedSeconds: TimeInterval(waited.components.seconds)))
            return Self.text(for: reply.outcome, question: question)
        }
        let (outcome, redacted) = reply.outcome.masked()
        box.settle(question.id, outcome: outcome, delivered: "tool")
        audit?.record(
            .inquirySettled,
            details: AuditEvent.Details.inquirySettled(
                question, outcome: outcome, via: reply.via, delivered: "tool", redacted: redacted,
                seconds: Date().timeIntervalSince(started)))
        return Self.text(for: outcome, question: question, redacted: redacted)
    }

    /// What the model gets for `outcome` (ADR 0062, section 3).
    ///
    /// - Parameters:
    ///   - outcome: How the question ended.
    ///   - question: The question.
    ///   - redacted: The kinds masked in the answer, which the model is told of.
    /// - Returns: The tool's result.
    public static func text(for outcome: Question.Outcome, question: Question, redacted: [String] = []) -> String {
        let masked =
            redacted.isEmpty
            ? ""
            : "\n(a credential-shaped value in the answer was masked and not passed on: \(redacted.joined(separator: ", ")))"
        switch outcome {
        case .answered(let text): return "answer: \(text)\n(from the person)" + masked
        case .chose(let text): return "chose: \(text)\n(from the person)" + masked
        case .noneOfThese: return "the person chose none of these options"
        case .declined: return "the person declined to answer. Do not ask this again; say in your reply what you needed"
        case .unanswered(let waited):
            return "no answer within \(TerminalAsker.deadlineText(waited)). Do not guess what the person would say. "
                + "Say in your reply what you need, and stop"
        case .stopped: return "the person stopped the turn; the question was withdrawn"
        case .parked:
            return "waiting for the person: \"\(question.text)\" (question \(question.id)). Their answer reaches you "
                + "as a note on a later turn. Do not guess it. Say in your reply what you asked and what depends on "
                + "it, and stop"
        case .abandoned: return "the call was cancelled while the question waited; the question was withdrawn"
        case .withdrawn: return "the question was withdrawn"
        case .nobody(let face): return "no person can answer here (\(face)); say in your reply what you need"
        case .failed(let reason): return "error: the question could not be asked: \(reason)"
        }
    }
}
