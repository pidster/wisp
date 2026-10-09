import Foundation
import Synchronization

/// How a model's chat template marks its thinking: the tags around the block, and whether the template takes
/// `enable_thinking` ([ADR 0053](../../../docs/decisions/0053-the-models-thinking-shown.md), refined 2026-10-06).
/// Read from the template rather than assumed, so a model whose template has no thinking block is never split.
struct ThinkingFormat: Equatable, Sendable {
    /// The tag that opens the block, such as `<think>`.
    var open: String
    /// The tag that closes it, such as `</think>`.
    var close: String
    /// Whether the template takes `enable_thinking`, which `mlx.think` sets.
    var toggle: Bool

    /// The format a chat template states: the first tag in it with `think` in its name, such as `<think>` (Qwen3,
    /// Falcon-H1R) or `<thinking>`, whose closing tag the template also holds.
    ///
    /// - Parameter template: The chat template's text, when the model has one.
    /// - Returns: The format, or nil when the template marks no thinking block.
    static func read(template: String?) -> ThinkingFormat? {
        guard let template, let pattern = try? Regex(#"<([A-Za-z_|]*think[A-Za-z_|]*)>"#) else { return nil }
        for match in template.matches(of: pattern) {
            guard let name = match.output[1].substring else { continue }
            let open = "<\(name)>"
            let close = "</\(name)>"
            if template.contains(close) {
                return ThinkingFormat(open: open, close: close, toggle: template.contains("enable_thinking"))
            }
        }
        return nil
    }

    /// Whether a rendered prompt ends inside an open block: a template that writes the opening tag into the
    /// generation prompt (`<think>\n`) has the model begin with its thinking and write only the closing tag.
    ///
    /// - Parameter tail: The end of the rendered prompt, as text.
    /// - Returns: Whether the last opening tag in it is not followed by a closing one.
    func promptEndsInside(_ tail: String) -> Bool {
        guard let last = tail.range(of: open, options: .backwards) else { return false }
        return !tail[last.upperBound...].contains(close)
    }
}

/// Splits a reply's streamed text into thinking and reply as it arrives, by the template's tags. The tags are
/// framing, belonging to neither; a tag split across chunks is held back until it is whole; whitespace next to a
/// tag (the template's newlines) is dropped. Thinking that is never closed stays thinking. A reply has one thinking
/// block, at its start: once it closes, everything after it is the reply, an opening tag the model writes later
/// included (a reply that quotes `<think>` is not thinking).
struct ThinkingSplitter: Sendable {
    /// A routed piece of the stream.
    enum Piece: Equatable, Sendable {
        /// Thinking.
        case thought(String)
        /// Reply text.
        case reply(String)
    }

    /// The tags.
    let format: ThinkingFormat
    /// Whether the stream is inside a thinking block.
    private(set) var inside: Bool
    /// Text held back: the start of a tag that the next chunk may complete, or thinking's trailing whitespace.
    private var held = ""
    /// Whether leading whitespace is dropped from what comes next, after a tag.
    private var trimLeading = false
    /// Whether the thinking block has closed, so the rest of the stream is the reply, tags and all.
    private var closed = false

    /// Creates a splitter.
    ///
    /// - Parameters:
    ///   - format: The tags.
    ///   - primed: Whether the prompt left the model inside a block (`ThinkingFormat.promptEndsInside`).
    init(format: ThinkingFormat, primed: Bool) {
        self.format = format
        inside = primed
        trimLeading = primed
    }

    /// Routes one chunk.
    ///
    /// - Parameter chunk: The text as it streamed.
    /// - Returns: The pieces it resolves to, in order; none while it only advances a tag.
    mutating func feed(_ chunk: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(held + chunk)
        held = ""
        while true {
            if closed {
                append(String(rest), closing: false, to: &pieces)
                return pieces
            }
            let tag = inside ? format.close : format.open
            if let range = rest.range(of: tag) {
                append(String(rest[..<range.lowerBound]), closing: true, to: &pieces)
                if inside { closed = true }
                inside.toggle()
                trimLeading = true
                rest = rest[range.upperBound...]
                continue
            }
            // Hold back the longest end of the text that could begin the tag.
            var keep = min(tag.count - 1, rest.count)
            while keep > 0, !tag.hasPrefix(rest.suffix(keep)) { keep -= 1 }
            var emit = String(rest.dropLast(keep))
            var tail = String(rest.suffix(keep))
            // Thinking's trailing whitespace waits too: it is dropped if the closing tag follows.
            if inside {
                let kept = emit.reversed().drop { $0.isWhitespace }.count
                tail = String(emit.dropFirst(kept)) + tail
                emit = String(emit.prefix(kept))
            }
            append(emit, closing: false, to: &pieces)
            held = tail
            return pieces
        }
    }

    /// Ends the stream: what was held back goes out as what it was, thinking's trailing whitespace dropped.
    ///
    /// - Returns: The last pieces.
    mutating func finish() -> [Piece] {
        var pieces: [Piece] = []
        append(held, closing: true, to: &pieces)
        held = ""
        return pieces
    }

    /// Ends a thinking block without its closing tag, as when a tool call follows it directly.
    mutating func leaveThinking() {
        guard inside else { return }
        held = ""
        inside = false
        closed = true
        trimLeading = true
    }

    /// Adds `text` in the current mode, trimmed as the tags around it say.
    ///
    /// - Parameters:
    ///   - text: The text.
    ///   - closing: Whether a tag or the end follows it, so its trailing whitespace goes when it is thinking.
    ///   - pieces: Where it goes.
    private mutating func append(_ text: String, closing: Bool, to pieces: inout [Piece]) {
        var text = Substring(text)
        if trimLeading { text = text.drop { $0.isWhitespace } }
        if closing && inside { text = text.dropLast(text.count - text.reversed().drop { $0.isWhitespace }.count) }
        guard !text.isEmpty else { return }
        trimLeading = false
        pieces.append(inside ? .thought(String(text)) : .reply(String(text)))
    }
}

/// A splitter shared by the engine's event callback, which is `@Sendable` and may not capture mutable state.
final class ThinkingSplit: Sendable {
    /// The splitter.
    private let splitter: Mutex<ThinkingSplitter>

    /// Creates one.
    ///
    /// - Parameters:
    ///   - format: The tags.
    ///   - primed: Whether the prompt left the model inside a block.
    init(format: ThinkingFormat, primed: Bool) {
        splitter = Mutex(ThinkingSplitter(format: format, primed: primed))
    }

    /// The events an event from the runtime becomes: text split into thinking and reply; a tool call as it is,
    /// ending any thinking under way.
    ///
    /// - Parameter event: The runtime's event.
    /// - Returns: The events to pass on.
    func route(_ event: EngineEvent) -> [EngineEvent] {
        switch event {
        case .text(let text):
            return splitter.withLock { $0.feed(text) }.map(Self.event)
        case .toolCall:
            splitter.withLock { $0.leaveThinking() }
            return [event]
        case .reasoning:
            return [event]
        }
    }

    /// The events left when the stream ends.
    func finish() -> [EngineEvent] {
        splitter.withLock { $0.finish() }.map(Self.event)
    }

    /// A piece as an engine event.
    private static func event(_ piece: ThinkingSplitter.Piece) -> EngineEvent {
        switch piece {
        case .thought(let text): .reasoning(text)
        case .reply(let text): .text(text)
        }
    }
}

/// The thinking a schema reply starts with, as Ollama lets a model think before it applies a `format`
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-06): the model generates
/// freely until its thinking closes, and the schema's constraint then starts from what it thought. Fed the free
/// generation's text a chunk at a time; says when to stop and how the thinking ended. Shared by the engine's
/// `@Sendable` callback, so the state is behind a lock.
final class ThinkingPhase: Sendable {
    /// How the free generation ended, or that it has not.
    enum Outcome: Equatable, Sendable {
        /// Still going: no tag closed, no reply begun.
        case open
        /// The model closed its thinking; the constraint starts after the closing tag.
        case closed
        /// The model began its reply without thinking; its thinking phase is dropped and the constraint starts
        /// from the prompt.
        case answered
    }

    /// The splitter, whether it has entered a block, and the outcome so far.
    private struct State {
        /// The splitter.
        var splitter: ThinkingSplitter
        /// Whether the stream has been inside a thinking block.
        var entered: Bool
        /// The outcome so far.
        var outcome: Outcome = .open
    }

    /// The state.
    private let state: Mutex<State>

    /// Creates one.
    ///
    /// - Parameters:
    ///   - format: The tags.
    ///   - primed: Whether the prompt left the model inside a block.
    init(format: ThinkingFormat, primed: Bool) {
        state = Mutex(State(splitter: ThinkingSplitter(format: format, primed: primed), entered: primed))
    }

    /// How it ended so far.
    var outcome: Outcome { state.withLock { $0.outcome } }

    /// Whether the stream is inside a thinking block that has not closed: generation stopped there, so the closing
    /// tag must be added before the constraint starts.
    var unclosed: Bool { state.withLock { $0.entered && $0.outcome == .open } }

    /// Routes one chunk of the free generation.
    ///
    /// - Parameter chunk: The text as it streamed.
    /// - Returns: The thinking it holds, as reasoning events, and whether generation should go on.
    func feed(_ chunk: String) -> (events: [EngineEvent], more: Bool) {
        state.withLock { state in
            guard state.outcome == .open else { return ([], false) }
            var events: [EngineEvent] = []
            for piece in state.splitter.feed(chunk) {
                switch piece {
                case .thought(let text):
                    state.entered = true
                    events.append(.reasoning(text))
                case .reply(let text):
                    // Whitespace before the opening tag decides nothing; any other reply text means no thinking.
                    if !state.entered, !text.allSatisfy(\.isWhitespace) { state.outcome = .answered }
                }
            }
            if state.splitter.inside { state.entered = true }
            if state.entered, !state.splitter.inside { state.outcome = .closed }
            return (events, state.outcome == .open)
        }
    }

    /// The thinking still held back when generation ends inside the block.
    ///
    /// - Returns: The last reasoning events.
    func finish() -> [EngineEvent] {
        state.withLock { state in
            guard state.entered, state.outcome == .open else { return [] }
            return state.splitter.finish().compactMap { piece in
                if case .thought(let text) = piece { .reasoning(text) } else { nil }
            }
        }
    }
}
