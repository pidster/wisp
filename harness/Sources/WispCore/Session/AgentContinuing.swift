import Foundation
import FoundationModels

/// Continuing a turn on a fresh session from what it has already done (ADR 0086, after ADR 0083's empty reply): the
/// framework keeps nothing of a request that threw, so a retry that sent the prompt again would have the model call
/// its tools again, and run their commands twice. The turn is rebuilt from its audit events instead, the prompt and
/// each call with the output it returned, and the session asked to go on from it with a note in place of the prompt.
extension Agent {
    /// The note wisp sends in place of the prompt when it sends a turn's request again on a fresh session after the
    /// turn made tool calls: after an overflow, or after the model called a tool the request had not registered. The
    /// calls and their results go ahead of it, so the model goes on from them and nothing it ran runs again.
    static let continuationNote =
        "[wisp: this turn's request was sent again on a fresh context. Your tool calls so far this turn are above, "
        + "with their results; go on from them to finish the person's request.]"

    /// Whether `entry` is one of wisp's notes in place of a prompt, the empty reply's (``emptyReplyNote``) or a
    /// continued turn's (``continuationNote``), which the store keeps as a notice, never as the person's prompt.
    ///
    /// - Parameter entry: A transcript entry.
    /// - Returns: Whether it is one of the notes.
    static func isWispNote(_ entry: Transcript.Entry) -> Bool {
        guard case .prompt(let prompt) = entry else { return false }
        let text = prompt.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        return text == emptyReplyNote || text == continuationNote
    }

    /// The turn so far, rebuilt from its tool events (``stoppedEntries(prompt:events:)``, ``answered(_:)``), when it
    /// has made at least one call that returned; nil when it has made none, or the agent keeps no event trail, so a
    /// retry sends the prompt as it always has.
    ///
    /// - Parameter prompt: The turn's prompt, the person's or the caller's.
    /// - Returns: The prompt and each answered call with its output, or nil.
    func rebuiltTurn(_ prompt: String) -> [Transcript.Entry]? {
        guard let trail = toolEvents else { return nil }
        let rebuilt = Self.answered(Self.stoppedEntries(prompt: prompt, events: trail.events(turn: turns.current)))
        return rebuilt.contains { if case .toolCalls = $0 { true } else { false } } ? rebuilt : nil
    }

    /// The tool calls `rebuilt` holds.
    ///
    /// - Parameter rebuilt: A rebuilt turn.
    /// - Returns: How many calls it carries.
    static func calls(in rebuilt: [Transcript.Entry]) -> Int {
        rebuilt.reduce(0) { count, entry in
            if case .toolCalls(let calls) = entry { count + calls.count } else { count }
        }
    }

    /// The tokens a continued turn adds to the context it is sent on: the rebuilt turn and the note, estimated from
    /// their bytes, as the target's goal counts a prompt.
    ///
    /// - Parameter rebuilt: The rebuilt turn.
    /// - Returns: The estimate.
    static func continuationTokens(_ rebuilt: [Transcript.Entry]) -> Int {
        (ContextComposer.bytes(of: rebuilt) + continuationNote.utf8.count) / ContextComposer.bytesPerToken
    }

    /// `context` followed by `rebuilt`, less any call or output `context` already holds of the same calls: a session
    /// already continued once carries the turn's earlier calls, which the newer rebuild repeats.
    ///
    /// - Parameters:
    ///   - context: The entries the new session starts from.
    ///   - rebuilt: The rebuilt turn.
    /// - Returns: The entries, in order.
    static func continuing(_ context: [Transcript.Entry], with rebuilt: [Transcript.Entry]) -> [Transcript.Entry] {
        let ids = Set(
            rebuilt.flatMap { entry -> [String] in
                if case .toolCalls(let calls) = entry { calls.map(\.id) } else { [] }
            })
        let kept = context.filter { entry in
            switch entry {
            case .toolCalls(let calls): !calls.contains { ids.contains($0.id) }
            case .toolOutput(let output): !ids.contains(output.id)
            default: true
            }
        }
        return kept + rebuilt
    }

    /// Opens a session on `context` with `rebuilt` after it and the tools the request registers.
    ///
    /// - Parameters:
    ///   - context: The context to start from: what the session holds once it is over the condensed composition.
    ///   - rebuilt: The rebuilt turn.
    func continueTurn(on context: [Transcript.Entry], rebuilt: [Transcript.Entry]) {
        replaceSession(
            with: model.session(
                tools: registeredTools, transcript: Transcript(entries: Self.continuing(context, with: rebuilt))))
    }

    /// Sends a request again once the session is over the condensed context: the prompt as it was when the turn has
    /// made no call (`rebuilt` nil), and otherwise the turn continued from `rebuilt` with ``continuationNote``. A
    /// continued turn whose own entries could not fit the window even alone is not sent; one whose retry overflows
    /// again ends the turn. Either throws `ContextFailure.doesNotFit`, so nothing the turn ran runs again, and the session
    /// is left holding the rebuilt turn, so the failed turn's record keeps what ran.
    ///
    /// - Parameters:
    ///   - prompt: The text the failed request sent: the prompt, or a note.
    ///   - rebuilt: The rebuilt turn, or nil.
    ///   - window: The model's window, when known.
    ///   - operation: The request, sending the text it is given.
    /// - Returns: The request's result.
    /// - Throws: `ContextFailure.doesNotFit`, or the request's own error.
    nonisolated(nonsending) func sendAgain<T>(
        _ prompt: String, rebuilt: [Transcript.Entry]?, window: Int?, _ operation: (String) async throws -> T
    ) async throws -> T {
        guard let rebuilt else { return try await operation(prompt) }
        let tokens = Self.continuationTokens(rebuilt)
        // The session holds the rebuilt turn even when it is not sent, so the failed turn's record keeps what ran.
        continueTurn(on: Array(session.transcript), rebuilt: rebuilt)
        if let window, tokens >= window {
            Diagnostics.agent.info("the turn's own calls take about \(tokens) of \(window) tokens; not sent again")
            throw ContextFailure.doesNotFit(tokens: tokens, window: window)
        }
        Diagnostics.agent.info("continuing the turn after \(Self.calls(in: rebuilt)) call(s)")
        do {
            return try await operation(Self.continuationNote)
        } catch {
            guard let again = Self.overflow(in: error) else { throw error }
            contextSize = again.contextSize
            throw ContextFailure.doesNotFit(tokens: again.tokenCount, window: again.contextSize)
        }
    }
}
