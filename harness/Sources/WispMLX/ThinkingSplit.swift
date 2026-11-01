import Foundation
import Synchronization
import WispCore

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
