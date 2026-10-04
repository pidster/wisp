import Foundation

/// A view a chat command shows whole, such as `/context`: the terminal chat prints it, and a front end
/// over `wisp chat --json` gets it as a `view` line to show in a panel of its own.
public struct ChatView: Equatable, Sendable {
    /// What the view is.
    public enum Kind: String, Sendable, Equatable {
        /// A context the model is sent: the next request's, or one composed at a turn's start.
        case context
        /// The list of the conversation's turns.
        case turns
        /// The facts the model is given, `/inspect facts`.
        case facts
        /// The running summary of earlier turns, `/inspect summary`.
        case summary
    }

    /// What it is.
    public var kind: Kind
    /// For a turn's context, the turn; nil for the next request's context and for the turn list.
    public var turn: Int?
    /// How many turns the conversation has had, so a front end can step through them.
    public var turns: Int
    /// The text, Markdown.
    public var text: String

    /// Creates a view.
    public init(kind: Kind, turn: Int?, turns: Int, text: String) {
        self.kind = kind
        self.turn = turn
        self.turns = turns
        self.text = text
    }

    /// The view `/inspect context <argument>` asks for of `agent`: the next request's context for nil or `next`, the
    /// turn list for `turns`, or the context composed at the start of the turn numbered; or a message saying
    /// why there is none.
    ///
    /// - Parameters:
    ///   - argument: What follows `/context`.
    ///   - agent: The conversation.
    /// - Returns: The view, or the message.
    public static func context(_ argument: String?, of agent: Agent) -> Result<ChatView, Failure> {
        let current = agent.turns.current
        switch argument?.lowercased() {
        case nil, "", "next":
            let composition = agent.composition(atTurn: nil) ?? []
            return .success(
                ChatView(
                    kind: .context, turn: nil, turns: current,
                    text: ContextView.markdown(composition, title: "The context the next request carries")))
        case "turns":
            return .success(
                ChatView(kind: .turns, turn: nil, turns: current, text: ContextView.table(ContextView.turns(of: agent)))
            )
        case let word?:
            guard let turn = Int(word) else { return .failure(.usage) }
            guard let composition = agent.composition(atTurn: turn) else {
                return .failure(.noSuchTurn(turn, first: agent.store.firstTurn + 1, last: current))
            }
            return .success(
                ChatView(
                    kind: .context, turn: turn, turns: current,
                    text: ContextView.markdown(composition, title: "The context composed at the start of turn \(turn)"))
            )
        }
    }

    /// Why a view could not be shown.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The argument is not `next`, `turns`, or a number.
        case usage
        /// No such turn in the thread's record.
        case noSuchTurn(Int, first: Int, last: Int)

        /// What chat says.
        public var description: String {
            switch self {
            case .usage: "usage: /inspect context [next|turns|N]"
            case .noSuchTurn(let turn, let first, let last):
                last < first
                    ? "no turn \(turn): this conversation has had no turns yet"
                    : "no turn \(turn): this conversation's turns run from \(first) to \(last)"
            }
        }
    }
}
