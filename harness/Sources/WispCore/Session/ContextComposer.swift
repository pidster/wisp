import FoundationModels

/// Builds each request's transcript from a conversation's store, within the model's window
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "What changes in
/// wisp").
///
/// This is phase 2 of the proposal: literal turns only, which reproduces what `Agent` did when it continued
/// one session. A request carries the store's active entries, in order. Condensing keeps the instructions
/// and the policy's last turns (`Transcript.condensed(keepTurns:)`), ahead of the window at `budget` or on
/// overflow, and the store marks the rest dropped rather than forgetting them. The composer is pure: it
/// decides, and `Agent` counts tokens, saves the archive, records the audit event, and applies the result.
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
    public func compose(_ store: ConversationStore) -> Transcript { store.active }

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
