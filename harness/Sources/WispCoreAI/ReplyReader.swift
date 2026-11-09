import Foundation
import Synchronization
import WispCore

/// How a bundle's chat template lays out a reply, read from the template's text
/// ([ADR 0088](../../../docs/decisions/0088-core-ai-through-wisps-executor.md)).
enum ReplyFormat: Equatable, Sendable {
    /// Free text with thinking between tags, when the template marks it, and calls in `<tool_call>` frames
    /// (`ToolCallFrames`): Qwen, Nemotron, and most templates.
    case tagged(ThinkingFormat?)
    /// Messages routed by a header naming who each is for, `<|start|>assistant to=TARGET<|message|>…<|eom|>`:
    /// `self` for thinking, `user` for the reply, a tool's name for a call written in ATEM
    /// (`ToolCallFrames.atem`); the turn ends at `<|eot|>`. Muse Glimmer's template.
    case channels

    /// The format a template states: channels when it routes messages to `self` and ends them with `<|eom|>`,
    /// otherwise tagged, with its thinking tags if it has them.
    ///
    /// - Parameter template: The chat template's text, when the bundle has one.
    /// - Returns: The format.
    static func read(template: String?) -> ReplyFormat {
        if let template, template.contains("to=self"), template.contains(ChannelSplitter.endOfMessage) {
            return .channels
        }
        return .tagged(ThinkingFormat.read(template: template))
    }

    /// Whether the format carries thinking.
    var reasons: Bool {
        switch self {
        case .tagged(let thinking): thinking != nil
        case .channels: true
        }
    }
}

/// Splits a reply written as routed messages into its messages as it streams: each a header, `[<|start|>assistant]
/// to=TARGET<|message|>`, then a body up to `<|eom|>` or `<|eot|>`. The prompt ends with `<|start|>assistant`, so the
/// first header has only its ` to=…` part. A body's text streams as it comes, less the start of a marker the next
/// chunk may complete; a header is held whole.
struct ChannelSplitter: Sendable {
    /// Ends a message.
    static let endOfMessage = "<|eom|>"
    /// Ends the turn.
    static let endOfTurn = "<|eot|>"
    /// Ends a header.
    static let messageStart = "<|message|>"
    /// Starts a message after the first.
    static let start = "<|start|>assistant"
    /// The longest header held before the text is taken as the reply's: a model that writes no header.
    static let headerLimit = 256

    /// A routed piece of the stream.
    enum Piece: Equatable, Sendable {
        /// Part of a message's body, for `target`.
        case body(target: String, text: String)
        /// A message has ended.
        case end(target: String)
    }

    /// The target of the message under way; nil while reading a header.
    private(set) var target: String?
    /// Text held back: a header in progress, or the start of a marker.
    private var held = ""

    /// Creates a splitter at the start of a header, as the prompt leaves it.
    init() {}

    /// Routes one chunk.
    ///
    /// - Parameter chunk: The text as it streamed.
    /// - Returns: The pieces it resolves to, in order.
    mutating func feed(_ chunk: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(held + chunk)
        held = ""
        while !rest.isEmpty {
            guard let target else {
                if let end = rest.range(of: Self.messageStart) {
                    self.target = Self.target(of: rest[..<end.lowerBound])
                    rest = rest[end.upperBound...]
                    continue
                }
                if rest.count > Self.headerLimit {
                    // No header: the text is the reply's.
                    self.target = "user"
                    continue
                }
                held = String(rest)
                return pieces
            }
            let markers = [Self.endOfMessage, Self.endOfTurn]
            if let end = markers.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                let text = String(rest[..<end.lowerBound])
                if !text.isEmpty { pieces.append(.body(target: target, text: text)) }
                pieces.append(.end(target: target))
                self.target = nil
                rest = rest[end.upperBound...]
                continue
            }
            var keep = min(Self.endOfMessage.count - 1, rest.count)
            while keep > 0, !markers.contains(where: { $0.hasPrefix(rest.suffix(keep)) }) { keep -= 1 }
            let emit = String(rest.dropLast(keep))
            if !emit.isEmpty { pieces.append(.body(target: target, text: emit)) }
            held = String(rest.suffix(keep))
            return pieces
        }
        return pieces
    }

    /// Ends the stream: a body under way ends, what was held going out with it; a header never finished is the
    /// reply's text.
    ///
    /// - Returns: The last pieces.
    mutating func finish() -> [Piece] {
        defer {
            held = ""
            target = nil
        }
        guard let target else {
            let text = held.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.body(target: "user", text: held), .end(target: "user")]
        }
        return (held.isEmpty ? [] : [.body(target: target, text: held)]) + [.end(target: target)]
    }

    /// A header's target: what follows `to=`, or `user` when it names none.
    ///
    /// - Parameter header: The header, without `<|message|>`.
    /// - Returns: The target.
    static func target(of header: Substring) -> String {
        guard let to = header.range(of: "to=") else { return "user" }
        let name = header[to.upperBound...].prefix { !$0.isWhitespace && $0 != "<" }
        return name.isEmpty ? "user" : String(name)
    }
}

/// The reply's text routed as it streams, by the bundle's `ReplyFormat`: through the thinking splitter and then the
/// tool-call frame splitter, or through the channel splitter, whose tool messages are read as ATEM. Shared by the
/// engine's token callback, which is `@Sendable` and may not capture mutable state.
final class ReplyReader: Sendable {
    /// The splitters, and what the reply has said so far.
    private struct State {
        /// The thinking splitter, for a tagged format that marks thinking.
        var thinking: ThinkingSplitter?
        /// The frame splitter, for a tagged format.
        var frames = ToolCallFrames.Splitter()
        /// The channel splitter, for a channels format.
        var channels: ChannelSplitter?
        /// The body of the tool message under way, for a channels format.
        var call = ""
        /// The thinking of the block under way, since it opened.
        var thought = ""
        /// Whether the reply has had text other than whitespace, or a tool call.
        var answered = false
        /// Whether a tool message has ended, after which the reply is over.
        var done = false
    }

    /// The state.
    private let state: Mutex<State>
    /// The offered tools' parameter schemas by name.
    private let tools: [String: JSONValue]

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - format: How the template lays out a reply.
    ///   - primed: Whether the prompt left the model inside a thinking block (`ThinkingFormat.promptEndsInside`).
    ///   - tools: The offered tools' parameter schemas by name.
    init(format: ReplyFormat, primed: Bool, tools: [String: JSONValue]) {
        var initial = State()
        switch format {
        case .tagged(let thinking): initial.thinking = thinking.map { ThinkingSplitter(format: $0, primed: primed) }
        case .channels: initial.channels = ChannelSplitter()
        }
        state = Mutex(initial)
        self.tools = tools
    }

    /// Whether the reply is over: a tool message has ended, and the framework is to run the call.
    var isDone: Bool { state.withLock { $0.done } }

    /// The events a chunk of text resolves to.
    ///
    /// - Parameter chunk: The text.
    /// - Returns: The events, in order.
    func feed(_ chunk: String) -> [CoreAIEvent] {
        state.withLock { state in
            if state.channels != nil {
                let pieces = state.channels?.feed(chunk) ?? []
                return pieces.flatMap { route($0, state: &state) }
            }
            let pieces = state.thinking?.feed(chunk) ?? [.reply(chunk)]
            return route(pieces, state: &state)
        }
    }

    /// The events what was held back resolves to at the end of the reply. In a tagged format, a reply that ended on
    /// the model's own stop token still inside its thinking block, having said nothing else, is taken to have
    /// answered there: the template opened the block in the prompt and the model wrote its answer without closing
    /// it, as Nemotron-3-Nano-4B does after a tool result (probed 2026-10-08), so the block's text is also the reply.
    /// A reply cut off by its budget keeps it as thinking.
    ///
    /// - Parameter stopped: Whether generation ended on a stop token rather than the budget.
    /// - Returns: The events, in order.
    func finish(stopped: Bool) -> [CoreAIEvent] {
        state.withLock { state in
            if state.channels != nil {
                let pieces = state.channels?.finish() ?? []
                return pieces.flatMap { route($0, state: &state) }
            }
            let inside = state.thinking?.inside == true
            var events = route(state.thinking?.finish() ?? [], state: &state)
            events += state.frames.finish().flatMap { read($0, answered: &state.answered) }
            let answer = state.thought.trimmingCharacters(in: .whitespacesAndNewlines)
            if stopped, inside, !state.answered, !answer.isEmpty {
                events.append(.text(answer))
            }
            return events
        }
    }

    /// A tagged format's pieces: thinking as it is; reply text through the frame splitter.
    ///
    /// - Parameters:
    ///   - pieces: The thinking splitter's pieces.
    ///   - state: The splitters and what the reply has said.
    /// - Returns: The events.
    private func route(_ pieces: [ThinkingSplitter.Piece], state: inout State) -> [CoreAIEvent] {
        var events: [CoreAIEvent] = []
        for piece in pieces {
            switch piece {
            case .thought(let text):
                state.thought += text
                events.append(.reasoning(text))
            case .reply(let text):
                state.thought = ""
                events += state.frames.feed(text).flatMap { read($0, answered: &state.answered) }
            }
        }
        return events
    }

    /// A channels format's piece: `self` as thinking, `user` as reply text, any other target's body gathered and
    /// read as ATEM calls when the message ends, which ends the reply. Nothing after that is kept.
    ///
    /// - Parameters:
    ///   - piece: The channel splitter's piece.
    ///   - state: The state.
    /// - Returns: The events.
    private func route(_ piece: ChannelSplitter.Piece, state: inout State) -> [CoreAIEvent] {
        guard !state.done else { return [] }
        switch piece {
        case .body(let target, let text):
            switch target {
            case "self": return [.reasoning(text)]
            case "user": return [.text(text)]
            default:
                state.call += text
                return []
            }
        case .end(let target):
            guard target != "self", target != "user" else { return [] }
            let body = state.call
            state.call = ""
            state.done = true
            guard let calls = ToolCallFrames.atem(body, schemas: tools) else {
                Diagnostics.agent.info(
                    "Core AI: a message to \(target) held no ATEM call to an offered tool; kept as text")
                return [.text(body)]
            }
            return calls.map { .toolCall(name: $0.name, arguments: $0.arguments) }
        }
    }

    /// A frame's calls, or the frame as text when it holds none the request offers; text as it is.
    ///
    /// - Parameters:
    ///   - piece: The frame splitter's piece.
    ///   - answered: Set when the piece is a call or text other than whitespace.
    /// - Returns: The events.
    private func read(_ piece: ToolCallFrames.Piece, answered: inout Bool) -> [CoreAIEvent] {
        switch piece {
        case .text(let text):
            if text.contains(where: { !$0.isWhitespace }) { answered = true }
            return text.isEmpty ? [] : [.text(text)]
        case .frame(let frame):
            answered = true
            guard let calls = ToolCallFrames.calls(in: frame, schemas: tools) else {
                Diagnostics.agent.info("Core AI: a <tool_call> frame held no call to an offered tool; kept as text")
                return [.text(frame)]
            }
            return calls.map { .toolCall(name: $0.name, arguments: $0.arguments) }
        }
    }
}
