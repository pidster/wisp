import FoundationModels

/// How an `Agent` reacts when a prompt no longer fits the model's context window.
public enum ContextPolicy: Sendable, Equatable {
    /// Surface `LanguageModelError.contextSizeExceeded` to the caller.
    case failFast
    /// Phase 2's condensing: keep the instructions and the last `keepTurns` turns, with no check that the result
    /// fits, ahead of the window and on overflow (then retry once). Kept for the equivalence suite and for tests
    /// that pin a turn count; `fixed` is the four turns that were the default.
    case condense(keepTurns: Int)
    /// Condense to a token target (phase 5 of the layered-context proposal): references, then the dropped
    /// turns distilled, then the oldest turns dropped, each step verified, until the context is at or below the
    /// target and the next turn fits under the budget (`TargetCondensing`).
    case target(ContextTarget)

    /// Condense to the default target.
    public static let `default` = ContextPolicy.target(.default)
    /// Phase 2's default: the last four turns.
    public static let fixed = ContextPolicy.condense(keepTurns: 4)
}

/// What condensing to a target aims for (`ContextPolicy.target`).
public struct ContextTarget: Sendable, Equatable {
    /// The low-water mark: the share of the window a condensation brings the context down to. 0.6 by default
    /// since context checkpoint 2 (ADR 0057), which scored it above 0.5 on the on-device model and granite4.1:8b
    /// at the default budget: on the on-device model's 8,192 tokens the instructions with every tool (about 1,200)
    /// and the earlier block at its cap (15%) take under a third of the window, so 0.6 leaves about 2,500 tokens of
    /// literal turns and 25% of the window for the turns before the next condensation; a larger window keeps
    /// proportionally more of both. The guard caps it at the budget less 0.2 (0.65 at the default budget); the
    /// phase-6 checkpoint (ADR 0045) found that a share at or near the budget condenses on nearly every turn.
    public var share: Double
    /// How many of the latest turns the headroom kept for the next turn averages: a condensation is due when
    /// the context, the prompt, and a turn of that average size would pass the budget, and it condenses until
    /// one more such turn fits. 8 by default; 1 makes it D5's floor (the last whole turn); 0 keeps no headroom,
    /// as phase 2 did.
    public var headroomTurns: Int

    /// Creates a target.
    ///
    /// - Parameters:
    ///   - share: The low-water mark, as a share of the window.
    ///   - headroomTurns: How many latest turns the headroom averages.
    public init(share: Double = 0.6, headroomTurns: Int = 8) {
        self.share = share
        self.headroomTurns = headroomTurns
    }

    /// Six tenths of the window, with the average of the last eight turns as headroom.
    public static let `default` = ContextTarget()
    /// The fewest literal turns a condensation keeps: the last whole turn (D5's floor).
    public static let floorTurns = 1
}

extension Transcript {
    /// A copy that keeps the leading instructions entry, if any, and only the last `keepTurns` turns.
    ///
    /// A turn starts at a `.prompt` entry and runs to the next prompt, so tool
    /// calls and outputs stay with the prompt that caused them. Entries before
    /// the first prompt other than instructions are dropped.
    public func condensed(keepTurns: Int) -> Transcript {
        let entries = Array(self)
        return Transcript(entries: Self.kept(entries.map(Kind.init), keepTurns: keepTurns).map { entries[$0] })
    }

    /// What condensing needs to know of an entry.
    enum Kind: Equatable {
        /// An `.instructions` entry.
        case instructions
        /// A `.prompt` entry, which starts a turn.
        case prompt
        /// Anything else, which belongs to the turn before it.
        case other

        /// The kind of `entry`.
        init(_ entry: Entry) {
            switch entry {
            case .instructions: self = .instructions
            case .prompt: self = .prompt
            default: self = .other
            }
        }
    }

    /// The positions `condensed(keepTurns:)` keeps, in order, for entries of these kinds: the first if it is
    /// instructions, then every non-instructions entry of the last `keepTurns` turns. `ThreadRecord`
    /// condenses through the same function, so the two cannot disagree.
    static func kept(_ kinds: [Kind], keepTurns: Int) -> [Int] {
        precondition(keepTurns >= 0, "keepTurns must not be negative")
        var kept: [Int] = []
        if kinds.first == .instructions { kept.append(0) }
        var turns: [[Int]] = []
        for (position, kind) in kinds.enumerated() {
            switch kind {
            case .instructions:
                continue
            case .prompt:
                turns.append([position])
            case .other:
                if turns.isEmpty { continue }
                turns[turns.count - 1].append(position)
            }
        }
        kept.append(contentsOf: turns.suffix(keepTurns).flatMap { $0 })
        return kept
    }

    /// Number of turns, counted as prompt entries.
    public var turnCount: Int {
        reduce(0) { count, entry in
            if case .prompt = entry { return count + 1 }
            return count
        }
    }
}

/// Why a request could not be fitted into the model's window after condensing (phase 5 of the layered-context
/// proposal): the overflow retry either sends something that fits or reports this.
public enum ContextFailure: Error, CustomStringConvertible, Equatable {
    /// Condensed to its floor, the instructions, the last turn, and the request still need `tokens` of a
    /// `window`-token window, as the model counted them or wisp estimated them.
    case doesNotFit(tokens: Int, window: Int)

    /// Human-readable explanation, with what the person can do.
    public var description: String {
        switch self {
        case .doesNotFit(let tokens, let window):
            "the request does not fit the model's context window: with earlier turns condensed, the instructions, "
                + "the last turn, and the request still need about \(tokens) of \(window) tokens; shorten the "
                + "request or start a new conversation"
        }
    }
}
