import Foundation
import FoundationModels

/// The model's context as a person reads it, at no cost to the model
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), decision D12): the
/// context the next request carries, or the one composed at the start of an earlier turn, entry by entry
/// under its store id, and a list of the conversation's turns with what changed at each. Chat's `/context`,
/// `wisp-tui`'s live view, and the MCP `wisp://threads/{thread_id}/context` resources all render it here.
public enum ContextView {
    /// One turn of the conversation, as the turn list shows it.
    public struct Turn: Equatable, Sendable {
        /// The turn's number, as its audit events carry it.
        public var number: Int
        /// When its prompt was sent, when known.
        public var time: Date?
        /// The start of its prompt, on one line.
        public var prompt: String
        /// Tokens its first request carried, the prompt included, estimated at four bytes a token
        /// (`estimatedTokens`).
        public var tokens: Int
        /// Entries a condensation dropped ahead of it (or before its retry).
        public var condensed: Int
        /// Replies of the turn before whose presentational text was cut from it on.
        public var cut: Int
        /// Tool outputs sent as references from it on.
        public var referenced: Int
        /// Versions of the running summary written during it, when condensing dropped turns.
        public var summarised = 0

        /// What changed since the turn before, in words: `condensed 6`, `cut 1`, `referenced 2`, `summarised 1`,
        /// or `none`.
        public var changes: String {
            let parts = [
                ("condensed", condensed), ("cut", cut), ("referenced", referenced), ("summarised", summarised),
            ].filter { $0.1 > 0 }
            return parts.isEmpty ? "none" : parts.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }
    }

    /// How many characters of a prompt a turn row shows.
    static let promptCharacters = 60

    /// The turns `agent`'s store can show, oldest first: those since its first (`ThreadRecord.firstTurn`)
    /// up to the current one.
    ///
    /// - Parameter agent: The conversation.
    /// - Returns: The turns.
    public static func turns(of agent: Agent) -> [Turn] {
        let store = agent.store
        guard agent.turns.current > store.firstTurn else { return [] }
        return ((store.firstTurn + 1)...agent.turns.current).map { number in
            let prompt = store.entries.first { $0.origin == .turn && $0.turn == number && $0.kind == .prompt }
            let text = prompt.map { ThreadRecord.text(of: $0.value) } ?? ""
            let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            let before = (agent.composition(atTurn: number) ?? []).filter { !$0.own || $0.entry.kind == .prompt }
            return Turn(
                number: number, time: prompt?.time,
                prompt: flat.count > promptCharacters ? String(flat.prefix(promptCharacters)) + "…" : flat,
                tokens: estimatedTokens(before.map(\.sent)),
                condensed: store.entries.filter { $0.droppedAt == number }.count,
                cut: store.entries.filter { $0.origin == .turn && $0.turn == number - 1 && !$0.cuts.isEmpty }.count,
                referenced: store.entries.filter { $0.referencedAt == number }.count,
                summarised: store.summaries.filter { $0.turn == number }.count)
        }
    }

    /// Tokens `entries` come to at four bytes a token: their text, and each tool call's name and arguments.
    /// An estimate for comparing turns; the instructions' tool definitions are not counted.
    ///
    /// - Parameter entries: The entries.
    /// - Returns: The estimate.
    static func estimatedTokens(_ entries: [Transcript.Entry]) -> Int {
        entries.reduce(0) { total, entry in
            var bytes = ThreadRecord.text(of: entry).utf8.count
            switch entry {
            case .instructions(let instructions): bytes += ContextArchive.text(instructions.segments).utf8.count
            case .toolCalls(let calls):
                bytes += calls.reduce(0) { $0 + $1.toolName.utf8.count + $1.arguments.jsonString.utf8.count }
            default: break
            }
            return total + bytes / ContextComposer.bytesPerToken
        }
    }

    /// A composition as Markdown: a heading, then each entry under its store id, turn, and kind, its text
    /// as the request carries it, with a note where a reply is cut or an output is a reference, and the
    /// turn's own entries marked.
    ///
    /// - Parameters:
    ///   - composition: The entries (`Agent.composition(atTurn:)`).
    ///   - title: What it is, such as `The next request` or `The start of turn 4`.
    /// - Returns: The text.
    public static func markdown(_ composition: [ContextComposer.Composed], title: String) -> String {
        let sent = composition.map(\.sent)
        let turns = Set(composition.compactMap { $0.entry.origin == .turn ? $0.entry.turn : nil }).count
        var sections = [
            "# \(title)",
            "\(composition.count) entr\(composition.count == 1 ? "y" : "ies") from \(turns) turn\(turns == 1 ? "" : "s"), "
                + "about \(estimatedTokens(sent)) tokens at four bytes a token (tool definitions not counted).",
        ]
        for item in composition {
            let entry = item.entry
            if entry.kind == .facts {
                sections.append(
                    "## facts · a record on the prompt side, not instructions\n\n"
                        + ThreadRecord.text(of: item.sent))
                continue
            }
            var head = "## \(entry.id)"
            if let turn = entry.turn { head += " · turn \(turn)\(entry.origin == .resumed ? " (resumed)" : "")" }
            var body: String
            switch item.sent {
            case .prompt where entry.kind == .command:
                head += " · the person's command"
                body = ThreadRecord.text(of: item.sent)
            case .instructions(let instructions):
                head += " · instructions"
                body = ContextArchive.text(instructions.segments)
            case .prompt:
                head += " · prompt"
                body = ThreadRecord.text(of: item.sent)
            case .toolCalls(let calls):
                head += " · tool call" + (calls.count == 1 ? "" : "s")
                body = calls.map { "\($0.toolName) \($0.arguments.jsonString)" }.joined(separator: "\n")
            case .toolOutput(let output):
                head += " · tool output: \(output.toolName)"
                if item.referenced { head += " (sent as a reference)" }
                body = ThreadRecord.text(of: item.sent)
            case .response:
                head += " · reply"
                if item.cut { head += " (presentational text cut)" }
                body = ThreadRecord.text(of: item.sent)
            default:
                head += " · \(entry.kind.rawValue)"
                body = ""
            }
            if item.own { head += " · this turn's" }
            sections.append(head + (body.isEmpty ? "" : "\n\n" + body))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// The turn list as Markdown lines: one row per turn with its time, tokens, changes, and prompt, and
    /// for each the link `link` makes of its number, when given.
    ///
    /// - Parameters:
    ///   - turns: The turns (`turns(of:)`).
    ///   - link: The address of a turn's context, or nil for none.
    /// - Returns: The text.
    public static func table(_ turns: [Turn], link: ((Int) -> String)? = nil) -> String {
        var rows = ["| Turn | Time | Tokens | Changed | Prompt |" + (link == nil ? "" : " Context |")]
        rows.append("| --- | --- | --- | --- | --- |" + (link == nil ? "" : " --- |"))
        for turn in turns {
            let time = turn.time.map { $0.ISO8601Format() } ?? "-"
            let prompt = turn.prompt.replacingOccurrences(of: "|", with: "\\|")
            rows.append(
                "| \(turn.number) | \(time) | \(turn.tokens) | \(turn.changes) | \(prompt) |"
                    + (link.map { " \($0(turn.number)) |" } ?? ""))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
