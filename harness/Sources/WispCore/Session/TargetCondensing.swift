import Foundation
import FoundationModels

/// What a condensation to a target works on: the conversation's store and composer, and the agent's effects
/// (distilling, recomputing the facts, auditing references). `Agent` is the one host; the invariant tests drive
/// the loop through a host of their own, with no model.
protocol CondensingHost: AnyObject {
    /// The conversation's record, which the loop condenses.
    var store: ThreadRecord { get set }
    /// The composer that renders it.
    var composer: ContextComposer { get set }
    /// The turn a drop is recorded against (`ThreadRecord.Entry.droppedAt`).
    var condensingTurn: Int { get }

    /// Hands the turns about to be dropped to the distiller (facts and, when a batch is due, the summary).
    ///
    /// - Parameters:
    ///   - leaving: The entries about to be dropped.
    ///   - staying: The entries kept.
    /// - Returns: Whether they were distilled.
    nonisolated(nonsending) func distil(leaving: [ThreadRecord.Entry], staying: [ThreadRecord.Entry]) async -> Bool
    /// Recomputes the facts the next request carries (`ContextComposer.facts`) from the store as it now is.
    func refreshFrame()
    /// Marks outputs as sent by reference from now on, and audits each.
    ///
    /// - Parameter found: The outputs.
    func referenced(_ found: [ContextComposer.Referencing])
}

/// Condensing to a token target (phase 5 of the layered-context proposal): the guarantees phase 2's fixed four
/// turns lacked. A condensation takes the cheapest steps first and measures the composed context after each:
///
/// 1. **References.** Every earlier tool output still sent whole is sent as its reference (D12). The agent
///    references outputs at the start of the turn after theirs, so this normally finds none; it is the guarantee
///    that none is left whole. With `referencesOutput` off, a switch kept for comparison, outputs stay whole and
///    condensing goes on to the next step.
/// 2. **Distil, then drop.** The fewest oldest turns whose dropping brings the estimate to the goal, with the
///    earlier block as it stands, are handed to the distiller (facts, and the summary when a batch is due), then
///    dropped. Distilling adds to the earlier block and removes nothing, so it is measured with the drop it
///    precedes; when what it added, or a fact the dropped turns no longer show, puts the context back above the
///    goal, the next pass drops more. Never below `ContextTarget.floorTurns` literal turns.
/// 3. **The floor.** When only the floor is left and it is still above the goal, the earlier block is squeezed
///    below its cap (the facts to their 1 KiB floor, no summary), D5's second cut; the floor turn's tool output
///    is already at its slice, its reference, after step 1 (whole only with references off). The request and
///    the instructions are never cut. If it is still above the goal, the outcome says so (`floor`), and the
///    agent audits it and tells the person.
///
/// Each measurement is the model's count when it can count, otherwise an estimate anchored on the last known
/// figure (the runtime's report, or the overflow's count): that figure plus the change in bytes at four bytes a
/// token. Every pass of the loop drops at least one turn or stops, so it terminates.
enum TargetCondensing {
    /// One step a condensation took.
    enum Step: Sendable, Equatable {
        /// Earlier outputs switched to references.
        case referenced(Int)
        /// Turns handed to the distiller before they were dropped.
        case distilled(Int)
        /// The oldest turns dropped.
        case dropped(Int)
        /// The earlier block squeezed below its cap, at the floor.
        case squeezed

        /// In words, for the audit: `referenced 2`, `distilled 3 turns`, `dropped 3 turns`, `squeezed earlier`.
        var words: String {
            switch self {
            case .referenced(let count): "referenced \(count)"
            case .distilled(let turns): "distilled \(turns) turn\(turns == 1 ? "" : "s")"
            case .dropped(let turns): "dropped \(turns) turn\(turns == 1 ? "" : "s")"
            case .squeezed: "squeezed earlier"
            }
        }
    }

    /// What a condensation did.
    struct Outcome: Sendable {
        /// The steps, in order; empty when nothing could change.
        var steps: [Step]
        /// Tokens the composed context took before.
        var before: Int
        /// Tokens it takes after.
        var after: Int
        /// The goal it condensed to, in tokens.
        var goal: Int
        /// Whether it is still above the goal at the floor.
        var floor: Bool
        /// The literal view before, for the archive and the turn count.
        var beforeView: Transcript
        /// The literal view after.
        var afterView: Transcript
        /// The store ids of the entries it dropped.
        var dropped: [Int]

        /// Whether any step changed the context.
        var changed: Bool { !steps.isEmpty }
    }

    /// Condenses `host`'s store until the composed context is at or below `goal`, or the floor is reached.
    ///
    /// - Parameters:
    ///   - host: The conversation.
    ///   - fill: Tokens the context takes now, counted or reported.
    ///   - goal: The goal, in tokens (`ContextComposer.goal(window:prompt:headroom:)`).
    ///   - count: The model's count of a transcript, for a model that can count; nil estimates.
    /// - Returns: What it did.
    nonisolated(nonsending) static func run(
        _ host: some CondensingHost, fill: Int, goal: Int,
        count: ((Transcript) async -> Int?)? = nil
    ) async -> Outcome {
        let beforeView = host.composer.literal(host.store)
        var fill = fill
        var anchor = (tokens: fill, bytes: ContextComposer.bytes(of: host.composer.compose(host.store)))
        var steps: [Step] = []
        var dropped: [Int] = []
        let initial = fill

        /// Measures the composition as it now stands and moves the anchor to it.
        nonisolated(nonsending) func verify() async {
            let composed = host.composer.compose(host.store)
            let bytes = ContextComposer.bytes(of: composed)
            if let count, let counted = await count(composed) {
                fill = counted
            } else {
                fill = anchor.tokens + (bytes - anchor.bytes) / ContextComposer.bytesPerToken
            }
            anchor = (fill, bytes)
        }

        let found = host.composer.newReferences(in: host.store)
        if !found.isEmpty {
            host.referenced(found)
            host.refreshFrame()
            steps.append(.referenced(found.count))
            await verify()
        }

        while fill > goal {
            let literal = host.composer.literal(host.store)
            let turns = host.store.turnCount(of: literal)
            let droppable = turns - ContextTarget.floorTurns
            guard droppable > 0 else { break }
            let drop =
                (1...droppable).first { drop in
                    let bytes = ContextComposer.bytes(of: host.composer.dropping(drop, from: host.store))
                    return anchor.tokens + (bytes - anchor.bytes) / ContextComposer.bytesPerToken <= goal
                } ?? droppable
            let after = host.store.condensed(literal, keepTurns: turns - drop)
            let kept = Set(after.map(\.id))
            let active = host.store.entries.filter { $0.state == .active }
            let leaving = active.filter { !kept.contains($0.value.id) }
            if await host.distil(leaving: leaving, staying: active.filter { kept.contains($0.value.id) }) {
                steps.append(.distilled(drop))
            }
            host.store.retain(after, droppedBy: nil, at: host.condensingTurn)
            dropped += leaving.map(\.id)
            steps.append(.dropped(drop))
            host.refreshFrame()
            await verify()
        }

        if fill > goal, host.composer.facts.earlier != nil, !host.composer.squeezesEarlier {
            host.composer.squeezesEarlier = true
            host.refreshFrame()
            steps.append(.squeezed)
            await verify()
        }

        return Outcome(
            steps: steps, before: initial, after: fill, goal: goal, floor: fill > goal, beforeView: beforeView,
            afterView: host.composer.literal(host.store), dropped: dropped)
    }
}

extension ContextComposer {
    /// The UTF-8 bytes of what `entries` carry: text, tool names and arguments, and the instructions' text.
    /// Tool definitions are left out: they are the same in every composition compared.
    ///
    /// - Parameter entries: The entries.
    /// - Returns: The bytes.
    static func bytes(of entries: some Sequence<Transcript.Entry>) -> Int {
        entries.reduce(0) { total, entry in
            switch entry {
            case .instructions(let instructions):
                return total
                    + instructions.segments.reduce(0) {
                        if case .text(let text) = $1 { $0 + text.content.utf8.count } else { $0 }
                    }
            case .toolCalls(let calls):
                return total + calls.reduce(0) { $0 + $1.toolName.utf8.count + $1.arguments.jsonString.utf8.count }
            default:
                return total + ThreadRecord.text(of: entry).utf8.count
            }
        }
    }

    /// The tokens kept free for the next turn: the average size of the latest `headroomTurns` turns, each its
    /// tool calls, whole tool output, and reply (the prompt is counted on its own), at four bytes a token; 0 under
    /// any policy but `.target`, or before the first turn.
    ///
    /// - Parameter store: The thread's record.
    /// - Returns: The headroom, in tokens.
    func headroom(in store: ThreadRecord) -> Int {
        guard case .target(let target) = policy, target.headroomTurns > 0 else { return 0 }
        let sizes = store.turnGroups.suffix(target.headroomTurns).map { group in
            Self.bytes(of: group.filter { $0.kind != .prompt }.map(\.value))
        }
        guard !sizes.isEmpty else { return 0 }
        return sizes.reduce(0, +) / sizes.count / Self.bytesPerToken
    }

    /// How far below the budget a target's share is kept, as a share of the window: the room between one
    /// condensation and the next. A share at or near the budget leaves the context just under the point that
    /// triggers the next condensation, so it condenses on almost every turn and each one distils (the phase 6
    /// checkpoint of ADR 0045 measured 70 of 84 gaps at a single turn, and distillations that corrupted facts).
    /// 0.2 of the window is several turns of lasting growth at the on-device model's 8,192 tokens, and leaves the
    /// default share (0.6) alone at the default budget (0.85), whose cap is 0.65.
    static let targetMargin = 0.2

    /// The share of the window a condensation brings the context to: the target's `share`, capped at the budget
    /// less `targetMargin` (never below 0). Applied where the goal is computed, so it covers a `ContextTarget`
    /// built in code as well as one loaded from `context.target`, and follows the budget it is paired with.
    ///
    /// - Parameter target: The configured target.
    /// - Returns: The effective share.
    func effectiveShare(of target: ContextTarget) -> Double {
        // Rounded so 0.85 less 0.2 is 0.65, not 0.6499999999999999.
        let cap = ((budget - Self.targetMargin) * 1_000_000).rounded() / 1_000_000
        return min(target.share, max(0, cap))
    }

    /// The tokens a condensation brings the context to: the target's effective share of the window
    /// (`effectiveShare(of:)`), or less when the prompt and the headroom need more room under the budget; never
    /// below 0.
    ///
    /// - Parameters:
    ///   - window: The model's window.
    ///   - prompt: The prompt's estimated tokens.
    ///   - headroom: The next turn's headroom (`headroom(in:)`).
    /// - Returns: The goal, in tokens.
    func goal(window: Int, prompt: Int, headroom: Int) -> Int {
        guard case .target(let target) = policy else { return window }
        let low = Int(Double(window) * effectiveShare(of: target))
        let room = Int(Double(window) * budget) - prompt - headroom
        return max(0, min(low, room))
    }

    /// Whether a request is due a condensation to the target: the context, the prompt, and the headroom reach the
    /// budget of the window.
    ///
    /// - Parameters:
    ///   - used: Tokens the context takes.
    ///   - prompt: The prompt's estimated tokens.
    ///   - headroom: The next turn's headroom.
    ///   - window: The model's window.
    /// - Returns: Whether to condense.
    func isOverBudget(used: Int, prompt: Int, headroom: Int, window: Int) -> Bool {
        Double(used + prompt + headroom) >= Double(window) * budget
    }

    /// The composition that dropping the oldest `count` literal turns would leave, with the facts as they stand.
    /// The store is not changed.
    ///
    /// - Parameters:
    ///   - count: Turns to drop.
    ///   - store: The thread's record.
    /// - Returns: The composition.
    func dropping(_ count: Int, from store: ThreadRecord) -> Transcript {
        let literal = literal(store)
        var copy = store
        copy.retain(store.condensed(literal, keepTurns: max(0, store.turnCount(of: literal) - count)), droppedBy: nil)
        return compose(copy)
    }
}

extension ThreadRecord {
    /// Every turn the store holds, active or dropped, as its entries in order: a prompt and what followed it up to
    /// the next prompt. Entries before the first prompt (the instructions) belong to no turn, nor does a command the
    /// person ran between turns, which is not the model's work.
    var turnGroups: [[Entry]] {
        var groups: [[Entry]] = []
        for entry in entries {
            switch entry.kind {
            case .prompt: groups.append([entry])
            case .instructions, .facts, .command: continue
            default: if !groups.isEmpty { groups[groups.count - 1].append(entry) }
            }
        }
        return groups
    }
}
