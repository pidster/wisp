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
/// tag (the template's newlines) is dropped. Thinking that is never closed stays thinking.
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
            let tag = inside ? format.close : format.open
            if let range = rest.range(of: tag) {
                append(String(rest[..<range.lowerBound]), closing: true, to: &pieces)
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
