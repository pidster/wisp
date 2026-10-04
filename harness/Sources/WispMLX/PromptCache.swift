import Foundation

/// How much of a slot's processed prompt a new request can keep: the reuse half of wisp's MLX executor
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
///
/// ADR 0045 composes every request afresh (D11), so consecutive requests of a thread share a long prefix:
/// the instructions, the earlier block, and the turns before the newest. An in-process runtime keeps the
/// key-value cache of the last request's prompt and processes only what follows the longest common prefix;
/// when composition changes something early (a condensation, a reference replacing an output), the cache is
/// trimmed back to where the two diverge.
struct PrefixPlan: Equatable, Sendable {
    /// Tokens of the new prompt the cache already holds.
    var reused: Int
    /// Tokens trimmed off the end of the cache before the rest of the prompt is processed.
    var trimmed: Int
    /// Whether the cache is discarded and the whole prompt processed from the start.
    var rebuild: Bool

    /// Nothing kept.
    static let rebuild = PrefixPlan(reused: 0, trimmed: 0, rebuild: true)

    /// The plan for a prompt against what a cache holds.
    ///
    /// At least one token is always processed, since that is what yields the next token's probabilities: a
    /// prompt the cache holds whole keeps all but its last token.
    ///
    /// - Parameters:
    ///   - cached: The tokens the cache holds, in order.
    ///   - prompt: The new request's prompt tokens.
    ///   - trimmable: Whether the cache can drop tokens from its end.
    /// - Returns: The plan.
    static func plan(cached: [Int], prompt: [Int], trimmable: Bool) -> PrefixPlan {
        let common = zip(cached, prompt).prefix { $0 == $1 }.count
        let reused = min(common, max(0, prompt.count - 1))
        guard reused > 0 else { return .rebuild }
        let trimmed = cached.count - reused
        guard trimmed == 0 || trimmable else { return .rebuild }
        return PrefixPlan(reused: reused, trimmed: trimmed, rebuild: false)
    }
}

/// The processed prompts kept between requests, one slot per thread, together never more tokens than one
/// window: the window was sized for one cache of that length (ADR 0043), so the slots share it, and the
/// least recently used is dropped first.
///
/// Generic over the cache so the bookkeeping is tested without MLX; held by `PrefixEngine`, an actor, so the
/// cache need not be `Sendable`.
struct PromptCachePool<Cache> {
    /// One thread's processed prompt.
    struct Slot {
        /// The tokens the cache holds, in order.
        var tokens: [Int]
        /// The runtime's cache.
        var cache: Cache
        /// When it was last used, by the pool's clock.
        var used: Int
    }

    /// The slots, by the thread's slot identity.
    private(set) var slots: [UUID: Slot] = [:]
    /// The pool's clock, advanced at every `put`.
    private var clock = 0

    /// Tokens held across every slot.
    var heldTokens: Int { slots.values.reduce(0) { $0 + $1.tokens.count } }

    /// Removes and returns a slot, so a failed request leaves nothing stale behind.
    ///
    /// - Parameter id: The slot.
    /// - Returns: What it held, or nil.
    mutating func take(_ id: UUID) -> Slot? {
        slots.removeValue(forKey: id)
    }

    /// Keeps a slot's cache, then drops the least recently used others until every slot together holds at
    /// most `capacity` tokens. A slot longer than the capacity on its own is not kept.
    ///
    /// - Parameters:
    ///   - id: The slot.
    ///   - tokens: The tokens its cache holds.
    ///   - cache: The cache.
    ///   - capacity: The most tokens the pool may hold, the window.
    /// - Returns: The slots dropped to make room, oldest first.
    @discardableResult
    mutating func put(_ id: UUID, tokens: [Int], cache: Cache, capacity: Int) -> [UUID] {
        guard tokens.count <= capacity else {
            slots.removeValue(forKey: id)
            return []
        }
        clock += 1
        slots[id] = Slot(tokens: tokens, cache: cache, used: clock)
        var dropped: [UUID] = []
        while heldTokens > capacity,
            let oldest = slots.filter({ $0.key != id }).min(by: { $0.value.used < $1.value.used })?.key
        {
            slots.removeValue(forKey: oldest)
            dropped.append(oldest)
        }
        return dropped
    }

    /// Forgets a slot, as when its thread ends.
    ///
    /// - Parameter id: The slot.
    mutating func remove(_ id: UUID) {
        slots.removeValue(forKey: id)
    }
}
