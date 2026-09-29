import FoundationModels

/// How an `Agent` reacts when a prompt no longer fits the model's context window.
public enum ContextPolicy: Sendable, Equatable {
    /// Surface `LanguageModelError.contextSizeExceeded` to the caller.
    case failFast
    /// Rebuild the session keeping the instructions and the last `keepTurns` turns, then retry once.
    case condense(keepTurns: Int)

    /// Keep the last four turns.
    public static let `default` = ContextPolicy.condense(keepTurns: 4)
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
    /// instructions, then every non-instructions entry of the last `keepTurns` turns. `ConversationStore`
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
