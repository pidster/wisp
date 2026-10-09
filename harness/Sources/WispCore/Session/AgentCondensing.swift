import Foundation
import FoundationModels

extension Agent: CondensingHost {
    /// The turn a condensation records its drops against.
    var condensingTurn: Int { turns.current }

    /// Hands the turns a condensation is about to drop to the distiller and the running summary
    /// (`handOn(_:staying:)`).
    ///
    /// - Parameters:
    ///   - leaving: The entries about to be dropped.
    ///   - staying: The entries kept.
    /// - Returns: Whether a distillation of the leaving entries ran and succeeded, so the audit's `distilled N turns`
    ///   step is never claimed for a distillation that was off, had no prose, or failed.
    nonisolated(nonsending) func distil(leaving: [ThreadRecord.Entry], staying: [ThreadRecord.Entry]) async -> Bool {
        await handOn(leaving, staying: staying)
    }

    /// Recomputes the facts the next request carries.
    func refreshFrame() { refreshFacts() }

    /// Marks outputs as references and audits each (`markReferenced(_:)`).
    ///
    /// - Parameter found: The outputs.
    func referenced(_ found: [ContextComposer.Referencing]) { markReferenced(found) }

    /// The model's count of `transcript`, or nil when it cannot count or counting fails.
    ///
    /// - Parameter transcript: The transcript.
    /// - Returns: The tokens, or nil.
    nonisolated(nonsending) private func counted(_ transcript: Transcript) async -> Int? {
        (try? await model.tokenCount(for: transcript)) ?? nil
    }

    /// Condenses to the target ahead of a prompt when the context, the prompt, and the next turn's headroom reach
    /// the budget of the window (`ContextComposer.isOverBudget`), then puts the session over the result.
    ///
    /// - Parameters:
    ///   - prompt: The prompt about to be sent.
    ///   - used: Tokens the context takes, reported or counted; 0 when nothing is known, which condenses nothing.
    ///   - window: The model's window.
    /// - Returns: Whether it condensed, or tried to.
    nonisolated(nonsending) func condenseToTarget(before prompt: String, used: Int, window: Int) async -> Bool {
        let tokens = prompt.utf8.count / ContextComposer.bytesPerToken
        let headroom = composer.headroom(in: store)
        guard used > 0, composer.isOverBudget(used: used, prompt: tokens, headroom: headroom, window: window) else {
            return false
        }
        let goal = composer.goal(window: window, prompt: tokens, headroom: headroom)
        let outcome = await TargetCondensing.run(self, fill: used, goal: goal) { await self.counted($0) }
        record(outcome, window: window, tokenCount: used + tokens, headroom: headroom, prompt: tokens, reason: "budget")
        materialise()
        Diagnostics.agent.info(
            "condensed ahead of the window to \(outcome.after) of \(window) tokens (target \(goal))")
        return true
    }

    /// Recovers from an overflow by condensing to the target, then retries the request once on a new session. The
    /// context before the failed request is measured by the model's count, or estimated from the overflow's own
    /// count less the bytes of what the failed request added. It retries even when the estimate says the floor
    /// cannot fit, since the retry is the one exact check; when the retry overflows again, it reports how far over
    /// it was as `ContextFailure.doesNotFit` rather than the framework's error.
    ///
    /// - Parameters:
    ///   - overflow: The window and the failed request's size.
    ///   - operation: The request.
    /// - Returns: The retried request's result.
    /// - Throws: `ContextFailure`, or the retry's own error.
    nonisolated(nonsending) func retryToTarget<T>(
        _ overflow: (contextSize: Int, tokenCount: Int), _ operation: () async throws -> T
    ) async throws -> T {
        let window = overflow.contextSize
        let failed = ContextComposer.bytes(of: Array(session.transcript))
        let prompt = Self.lastPrompt(in: session.transcript)
        let tokens = prompt / ContextComposer.bytesPerToken
        let composed = composer.compose(store)
        var fill = await counted(composed) ?? 0
        if fill == 0 {
            let bytes = ContextComposer.bytes(of: composed)
            fill = max(0, overflow.tokenCount + (bytes - failed) / ContextComposer.bytesPerToken)
        }
        let headroom = composer.headroom(in: store)
        let goal = composer.goal(window: window, prompt: tokens, headroom: headroom)
        let outcome = await TargetCondensing.run(self, fill: fill, goal: goal) { await self.counted($0) }
        record(
            outcome, window: window, tokenCount: overflow.tokenCount, headroom: headroom, prompt: tokens,
            reason: "overflow")
        materialise(fresh: true)
        do {
            return try await operation()
        } catch {
            guard let again = Self.overflow(in: error) else { throw error }
            contextSize = again.contextSize
            throw ContextFailure.doesNotFit(tokens: again.tokenCount, window: again.contextSize)
        }
    }

    /// The UTF-8 bytes of the last prompt in `transcript`: the request a failed session was sending.
    ///
    /// - Parameter transcript: The failed session's transcript.
    /// - Returns: The bytes; 0 when it holds no prompt.
    static func lastPrompt(in transcript: Transcript) -> Int {
        for entry in transcript.reversed() {
            if case .prompt = entry, !FactFrame.isFrame(entry) { return ThreadRecord.text(of: entry).utf8.count }
        }
        return 0
    }

    /// Records a condensation to a target: counts it when a step changed the context or it recovers an overflow,
    /// saves the literal view before and after, records the `context.condensation` event with the target's
    /// figures, attributes the entries it dropped to that event, and, at the floor, sets the person's note.
    ///
    /// - Parameters:
    ///   - outcome: What the condensation did.
    ///   - window: The window.
    ///   - tokenCount: The estimate, or the overflowing request's size, that prompted it.
    ///   - headroom: The headroom kept for the next turn.
    ///   - prompt: The prompt's estimated tokens.
    ///   - reason: `budget` or `overflow`.
    private func record(
        _ outcome: TargetCondensing.Outcome, window: Int, tokenCount: Int, headroom: Int, prompt: Int, reason: String
    ) {
        // An overflow counts even when no step changed anything: the retry sheds the failed attempt on a new
        // session, as phase 2's did.
        let condensed = outcome.changed || reason == "overflow"
        if condensed { condensations += 1 }
        var details = AuditEvent.Details.condensation(
            turnsBefore: store.turnCount(of: outcome.beforeView), turnsAfter: store.turnCount(of: outcome.afterView),
            contextSize: window,
            tokenCount: tokenCount, reason: reason,
            saved: condensed ? saveCondensation(outcome.beforeView, outcome.afterView) : nil)
        details.merge(
            AuditEvent.Details.targeting(
                goal: outcome.goal, fillBefore: outcome.before, fillAfter: outcome.after, headroom: headroom,
                steps: outcome.steps.map(\.words), floor: outcome.floor)
        ) { _, new in new }
        let event = audit?.record(.condensation, details: details)
        store.attribute(outcome.dropped, to: event)
        guard outcome.floor else { return }
        contextNote = Self.floorNote(fill: outcome.after + prompt, goal: outcome.goal + prompt, window: window)
        Diagnostics.agent.info("condensing reached its floor at \(outcome.after) of \(window) tokens")
    }

    /// The person's note when condensing reached its floor above the target.
    ///
    /// - Parameters:
    ///   - fill: Tokens the context and the request take.
    ///   - goal: The most they should take, in tokens.
    ///   - window: The window.
    /// - Returns: The note.
    static func floorNote(fill: Int, goal: Int, window: Int) -> String {
        "The context could not be condensed to its target: the instructions, the last turn, and this request "
            + "take about \(fill) of \(window) tokens, more than the \(goal) that leave room for a reply, so this turn "
            + "may run out of room. A shorter request, or a new conversation, would fit."
    }
}
