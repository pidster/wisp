import FoundationModels

/// Builds each request's transcript from a conversation's store, within the model's window
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "What changes in
/// wisp").
///
/// A request carries the store's active entries, in order: literal turns, as phase 2 of the proposal built
/// it to reproduce what `Agent` did when it continued one session. Phase 3 adds output handling: with
/// `cutsPresentation` on (the default), a reply's presentational text, a stretch that reproduces a tool
/// output of its turn (`Presentation`), is sent as a short marker in every later request, while the store
/// keeps the reply whole. Condensing keeps the instructions and the policy's last turns
/// (`Transcript.condensed(keepTurns:)`), ahead of the window at `budget` or on overflow, and the store marks
/// the rest dropped rather than forgetting them. The composer is pure: it decides, and `Agent` counts
/// tokens, saves the archive, records the audit events, and applies the result.
public struct ContextComposer: Sendable {
    /// A decision to condense: the active view before and after, and the estimate that prompted it.
    public struct Condensation: Sendable {
        /// The transcript before condensing.
        public let before: Transcript
        /// The transcript after: the instructions and the last turns.
        public let after: Transcript
        /// The estimated tokens of the next request, for a condensation ahead of the window.
        public let estimate: Int?
    }

    /// Bytes of prompt per token assumed when estimating a new prompt's cost.
    static let bytesPerToken = 4

    /// What happens when a prompt no longer fits the context window.
    public let policy: ContextPolicy
    /// The fraction of the context window a turn may start at before the transcript is condensed first.
    public var budget = 0.85
    /// Whether presentational text is cut from later requests. Off, every entry is sent as stored, which
    /// is phase 2's behaviour exactly (`ContextEquivalenceTests` runs with it off).
    public var cutsPresentation = true

    /// A decision to cut one stretch of a reply.
    struct PresentationCut: Sendable, Equatable {
        /// The reply's store id.
        let entry: Int
        /// Where, and which output.
        let cut: ConversationStore.Cut
        /// The audit event that recorded the reply, when it was linked.
        let response: AuditReference?
        /// The `tool.result` event that recorded the output, when it was linked.
        let result: AuditReference?
        /// Words in the stretch.
        let words: Int
        /// The fraction of the stretch's word 4-grams found in the output.
        let coverage: Double
        /// UTF-8 bytes the cut removes, net of its marker.
        let bytes: Int
    }

    /// Creates a composer.
    ///
    /// - Parameter policy: Overflow handling; defaults to condensing to the last four turns.
    public init(policy: ContextPolicy = .default) {
        self.policy = policy
    }

    /// The transcript the next request carries: the store's active entries, in order.
    ///
    /// - Parameter store: The conversation's store.
    /// - Returns: The transcript.
    public func compose(_ store: ConversationStore) -> Transcript {
        guard cutsPresentation else { return store.active }
        return Transcript(entries: store.entries.filter { $0.state == .active }.map(\.presented))
    }

    /// The presentational text in the replies `turn` added: every stretch of a reply's text that reproduces
    /// one of that turn's tool outputs, by `Presentation.spans`. None when `cutsPresentation` is off.
    ///
    /// - Parameters:
    ///   - store: The conversation's store, with the turn's entries recorded.
    ///   - turn: The turn whose replies are judged.
    /// - Returns: The cuts, in store order.
    func presentation(in store: ConversationStore, turn: Int) -> [PresentationCut] {
        guard cutsPresentation else { return [] }
        let mine = store.entries.filter { $0.origin == .turn && $0.turn == turn }
        let outputs = mine.filter { $0.kind == .toolOutput }
        guard !outputs.isEmpty else { return [] }
        let texts = outputs.map { ConversationStore.text(of: $0.value) }
        var found: [PresentationCut] = []
        for entry in mine where entry.kind == .response {
            guard case .response(let response) = entry.value else { continue }
            for (index, segment) in response.segments.enumerated() {
                guard case .text(let text) = segment else { continue }
                for span in Presentation.spans(in: text.content, outputs: texts) {
                    let output = outputs[span.output]
                    var tool = "tool"
                    if case .toolOutput(let value) = output.value { tool = value.toolName }
                    let cut = ConversationStore.Cut(
                        segment: index, start: span.range.lowerBound, end: span.range.upperBound, output: output.id,
                        tool: tool)
                    found.append(
                        PresentationCut(
                            entry: entry.id, cut: cut, response: entry.sources.first, result: output.sources.first,
                            words: span.words, coverage: span.coverage,
                            bytes: span.range.count - cut.marker.utf8.count))
                }
            }
        }
        return found
    }

    /// Whether this composer ever condenses ahead of the window; the agent counts tokens only when it does.
    var condensesAhead: Bool {
        if case .condense = policy { return true }
        return false
    }

    /// Condensing before a prompt, when the tokens the conversation uses plus a rough cost for the prompt
    /// (four bytes a token) reach `budget` of `window`, and condensing would drop a turn; nil otherwise.
    ///
    /// - Parameters:
    ///   - prompt: The prompt about to be sent.
    ///   - store: The conversation's store.
    ///   - used: Tokens the active view occupies: the last request's reported usage, or the model's count.
    ///   - window: The model's context window.
    /// - Returns: The condensation to apply, or nil.
    func ahead(of prompt: String, in store: ConversationStore, used: Int, window: Int) -> Condensation? {
        guard case .condense(let keepTurns) = policy, used > 0 else { return nil }
        let estimate = used + prompt.utf8.count / Self.bytesPerToken
        guard Double(estimate) >= Double(window) * budget else { return nil }
        let before = compose(store)
        let after = before.condensed(keepTurns: keepTurns)
        guard after.turnCount < before.turnCount else { return nil }
        return Condensation(before: before, after: after, estimate: estimate)
    }

    /// Condensing after the window overflowed, to retry the prompt once; nil under `.failFast`. It applies
    /// even when no turn would go, since it also sheds the failed attempt, as a rebuilt session always did.
    ///
    /// - Parameter store: The conversation's store, as it was before the failed prompt.
    /// - Returns: The condensation to apply, or nil.
    func overflow(in store: ConversationStore) -> Condensation? {
        guard case .condense(let keepTurns) = policy else { return nil }
        let before = compose(store)
        return Condensation(before: before, after: before.condensed(keepTurns: keepTurns), estimate: nil)
    }
}
