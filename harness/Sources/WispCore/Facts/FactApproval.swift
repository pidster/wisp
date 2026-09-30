import Foundation

/// One question to the person: keep this proposed permanent fact? The fact-approval host effect of
/// [ADR 0044](../../../../docs/decisions/0044-host-effects.md), a request-and-answer effect beside command
/// approval.
public struct FactApprovalRequest: Sendable, Equatable {
    /// What is proposed, and where.
    public var proposal: FactProposal
    /// Which question of the batch this is, from 1.
    public var position: Int
    /// How many questions the batch asks, one at a time.
    public var count: Int

    /// Creates a request.
    public init(proposal: FactProposal, position: Int = 1, count: Int = 1) {
        self.proposal = proposal
        self.position = position
        self.count = count
    }

    /// A dialog's title: `wisp: keep as a permanent fact? (2 of 3)`.
    public var title: String {
        "wisp: keep as a permanent fact?" + (count > 1 ? " (\(position) of \(count))" : "")
    }

    /// The question in one line: `Keep as a permanent fact? release codename: BLUE HERON (proposed by the
    /// model, from the person's words in turn 3)`.
    public var question: String { "Keep as a permanent fact? \(statement) (\(provenance))" }

    /// What the fact says: `name: value`, or `subject: value` for a kind without names.
    public var statement: String {
        let fact = proposal.fact
        let label = fact.identity.name.isEmpty ? fact.identity.subject : fact.identity.name
        return "\(label): \(fact.value)"
    }

    /// Who proposed it and from what, in words: `proposed by the model, from the person's words in turn 3`,
    /// `proposed by the model, its own conclusion in turns 2-4`, or `proposed by tool read_file in turn 5`.
    public var provenance: String {
        let fact = proposal.fact
        switch fact.source {
        case .model:
            let detail = fact.detail ?? ""
            for (prefix, words) in [
                ("the person said", "from the person's words"), ("the model concluded", "its own conclusion"),
            ] where detail.hasPrefix(prefix) {
                let span = detail.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                return "proposed by the model, \(words)" + (span.isEmpty ? "" : " in \(span)")
            }
            return "proposed by the model" + (fact.turn.map { " in turn \($0)" } ?? "")
        case .tool:
            return "proposed by tool" + (fact.detail.map { " \($0)" } ?? "")
                + (fact.turn.map { " in turn \($0)" } ?? "")
        case .person, .caller:
            return "proposed by the \(fact.source.rawValue)"
        }
    }
}

/// The person's answer to a `FactApprovalRequest`.
public enum FactApprovalDecision: Sendable, Equatable {
    /// Keep it in the shared store.
    case approved
    /// Do not keep it; remember the decline.
    case declined
    /// The dialog was dismissed; treated as a decline.
    case cancelled
    /// Nobody answered within the wait; the proposal keeps waiting and is not remembered as declined.
    case unanswered(Duration)
    /// The dialog could not be shown or answered; the proposal keeps waiting.
    case failed(String)

    /// The word the audit records: `approved`, `declined`, `cancelled`, `timed-out`, or `failed`.
    public var name: String {
        switch self {
        case .approved: "approved"
        case .declined: "declined"
        case .cancelled: "cancelled"
        case .unanswered: "timed-out"
        case .failed: "failed"
        }
    }
}

/// A face's way of asking the person whether to keep a proposed permanent fact: the fact-approval effect a
/// `Host` carries (ADR 0044). The MCP server asks through elicitation; chat asks nothing and leaves the
/// proposal for `/fact approve`.
public protocol FactApprover: Sendable {
    /// Whether the face can ask now; when it cannot, proposals wait to be approved elsewhere and are not
    /// claimed.
    var canAsk: Bool { get }

    /// Asks, within the face's bounded wait. Must not throw: a dialog that fails reports `failed`.
    ///
    /// - Parameter request: The question.
    /// - Returns: The answer.
    func decide(_ request: FactApprovalRequest) async -> FactApprovalDecision
}
