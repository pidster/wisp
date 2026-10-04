import Foundation
import FoundationModels

/// Builds each request's transcript from a thread's record, within the model's window
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "What changes in
/// wisp").
///
/// A request carries the store's active entries, in order: literal turns, as phase 2 of the proposal built
/// it to reproduce what `Agent` did when it continued one session. Phase 3 adds output handling: with
/// `cutsPresentation` on (the default), a reply's presentational text, a stretch that reproduces a tool
/// output of its turn (`Presentation`), is sent as a short marker in every later request, while the store
/// keeps the reply whole. Phase 3b (decision D12) adds `referencesOutput` (also on by default): a tool
/// output is sent whole only within the turn that produced it, which the framework's tool loop carries,
/// and every later request carries a compact structured reference in its place (`OutputReference`), under
/// the same entry id. Condensing keeps the instructions and the last turns (`Transcript.condensed(keepTurns:)`),
/// ahead of the window at `budget` or on overflow, and the store marks the rest dropped rather than forgetting
/// them: under phase 2's `.condense(keepTurns:)` a fixed count (`ahead`, `overflow`), under the default
/// `.target` (phase 5) as many as `TargetCondensing` finds bring the context to its goal (`goal`, `headroom`). Phase 4a adds the facts (`facts`, a `FactFrame` the agent
/// renders), and phase 4b the running summary of the dropped turns at the end of the earlier block
/// (`summarises`, `summaryShare`, `summaryBatchTurns`). The composer is pure: it decides, and `Agent` counts
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

    /// What happens when a prompt no longer fits the context window, and how condensing ahead of it works.
    public var policy: ContextPolicy
    /// The fraction of the context window a turn may start at before the transcript is condensed first: the
    /// high-water mark. Under `.target`, the turn's headroom counts toward it (`isOverBudget`).
    public var budget = 0.85
    /// Whether the earlier block is squeezed below its cap for this turn: the facts at their 1 KiB floor and no
    /// summary. Set by a condensation to a target that reached its floor (D5's second cut); the agent clears it
    /// at the start of every turn.
    public var squeezesEarlier = false
    /// Whether presentational text is cut from later requests. Off, every entry is sent as stored, which
    /// is phase 2's behaviour exactly (`ContextEquivalenceTests` runs with it off).
    public var cutsPresentation = true
    /// Whether a tool output is sent as a reference after the turn that produced it (`OutputReference`).
    /// An output no longer than its reference is always sent whole. Off, every output is sent as stored
    /// (`ContextEquivalenceTests` runs with it off).
    public var referencesOutput = true
    /// The zone a reference writes its time in.
    public var timeZone = TimeZone.current
    /// Whether the conversation has the `memory` tool (phase 4c), so a reference tells the model to recall its
    /// entry with it rather than run the call again. Off, the default for a composer whose agent has no memory,
    /// keeps the phase 3b wording.
    public var recalls = false
    /// The facts the next request carries (`FactFrame`), set by the agent before each request; empty, the
    /// default, adds nothing, so a composer without facts composes exactly as before them.
    public var facts = FactFrame.empty
    /// The share of the context window the facts may take (decision D5's cap for the earlier block, with the
    /// now block inside it); the eval can vary it.
    public var factsShare = 0.1
    /// Whether the turns condensing drops are summarised in the earlier block (phase 4b, decision D1): the
    /// running summary, written by the model in batches and carried before the literal turns. Only an agent
    /// that keeps facts writes one; off, nothing is written or carried (`ContextEquivalenceTests` runs with it
    /// off).
    public var summarises = true
    /// The share of the context window the running summary may take, on top of `factsShare`: the earlier
    /// block's cap is the two together, and the summary never takes the facts' room. Its own setting because
    /// the eval showed a summary sharing the facts' 0.1 crowding out the early facts it was meant to add to
    /// ("Summary, 2026-09-30" in the proposal). The eval can vary it.
    public var summaryShare = 0.05
    /// How many dropped turns wait for the summary: a condensation writes a new version only when the turns it
    /// drops and those dropped earlier and not yet summarised come to at least this many. 3: a condensation
    /// with references on drops many turns at once and summarises at once, and without them, when condensing
    /// drops a turn or two before almost every prompt, it bounds the summary's calls to one in every few
    /// condensations and the turns missing from it to two, which the facts cover.
    public var summaryBatchTurns = 3
    /// The terse tool catalogue the instructions carry when requests register only the tools they need (phase 4d,
    /// decision D4), added to the instructions entry as a segment of its own (`ToolCatalogue.segmentID`); nil, the
    /// default, adds nothing. Stable for the conversation, so the prefix stays the same.
    public var catalogue: String?
    /// The tools the next request registers, by name (phase 4d, D4): the instructions entry carries only their
    /// definitions, as the session the agent builds over it registers only them. Nil, the default, keeps the entry's
    /// definitions as stored: every tool.
    public var registered: [String]?

    /// A decision to cut one stretch of a reply.
    struct PresentationCut: Sendable, Equatable {
        /// The reply's store id.
        let entry: Int
        /// Where, and which output.
        let cut: ThreadRecord.Cut
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

    /// One entry of a composition: the stored entry, what the request carries for it, and whether it is
    /// the composed turn's own.
    public struct Composed: Sendable {
        /// The stored entry.
        public let entry: ThreadRecord.Entry
        /// What the request carries: the entry, a reply with its cuts, or a tool output's reference.
        public let sent: Transcript.Entry
        /// Whether it was added during the composed turn, by its tool loop.
        public let own: Bool

        /// Whether a tool output is sent as its reference.
        public var referenced: Bool {
            if case .toolOutput = entry.value { sent != entry.value } else { false }
        }
        /// Whether a reply is sent with its presentational text cut.
        public var cut: Bool {
            if case .response = entry.value { sent != entry.value } else { false }
        }
    }

    /// The transcript the next request carries: the store's active entries, in order, each reply with its
    /// cuts and each tool output as a reference, as the switches say. Every stored turn is over when this
    /// is called (a turn's entries are stored when it ends), so every stored output is referenced.
    ///
    /// - Parameter store: The thread's record.
    /// - Returns: The transcript.
    public func compose(_ store: ThreadRecord) -> Transcript {
        guard !facts.isEmpty else { return literal(store) }
        return Transcript(entries: composition(store, atTurn: nil).map(\.sent))
    }

    /// The literal turns the next request carries, without the facts: what condensing counts and cuts.
    ///
    /// - Parameter store: The thread's record.
    /// - Returns: The transcript.
    func literal(_ store: ThreadRecord) -> Transcript {
        guard cutsPresentation || referencesOutput || catalogue != nil || registered != nil || store.carriesCommands
        else {
            return store.active
        }
        return Transcript(entries: literalComposition(store, atTurn: nil).map(\.sent))
    }

    /// The least the facts may take, in bytes, however small the window: room for the task and a few facts.
    static let factsFloorBytes = 1024

    /// The facts frame for the next request: the facts in force and, when `summarises`, the running summary,
    /// rendered and capped at `factsShare` of `window` at four bytes a token, and never below
    /// `factsFloorBytes`, and the summary within `summaryShare` of `window` on top of that.
    ///
    /// - Parameters:
    ///   - view: The facts in force.
    ///   - store: The thread's record, whose active entries the literal turns carry.
    ///   - window: The model's context window, in tokens.
    /// - Returns: The frame.
    func factFrame(_ view: FactView, store: ThreadRecord, window: Int) -> FactFrame {
        let active = Set(store.entries.filter { $0.state == .active }.map(\.id))
        let share = max(Self.factsFloorBytes, Int(Double(window) * factsShare) * Self.bytesPerToken)
        let budget = squeezesEarlier ? Self.factsFloorBytes : share
        let summary = summarises && !squeezesEarlier ? store.summary : nil
        return FactComposition.frame(
            view, active: active, budgetBytes: budget, summary: summary,
            summaryBytes: SummaryWriter.capBytes(share: summaryShare, window: window))
    }

    /// The context composed for the start of `turn`, rebuilt from the store (`composition(_:atTurn:)`).
    ///
    /// - Parameters:
    ///   - store: The thread's record.
    ///   - turn: The turn, in the store's session's numbering.
    /// - Returns: The transcript, and how many of its entries are the turn's own, at its end.
    func compose(_ store: ThreadRecord, atTurn turn: Int) -> (transcript: Transcript, own: Int) {
        let composed = composition(store, atTurn: turn)
        return (Transcript(entries: composed.map(\.sent)), composed.filter(\.own).count)
    }

    /// A composition, entry by entry. With no turn, the next request's: the active entries, replies cut and
    /// outputs referenced as the switches say. With a turn, the context composed for the start of that
    /// turn, rebuilt from the store: the entries recorded before it, less those a condensation had dropped
    /// by then, with the cuts and references in force then (`Entry.droppedAt`, `Entry.referencedAt`); then
    /// the turn's own entries, as its tool loop carried them. Entries of a resumed store count as recorded
    /// before every turn of this session. A condensation during the turn counts as before it, since it
    /// happens ahead of the request, or before its retry.
    ///
    /// - Parameters:
    ///   - store: The thread's record.
    ///   - turn: The turn, in the store's session's numbering; nil for the next request.
    /// - Returns: The entries, in order.
    public func composition(_ store: ThreadRecord, atTurn turn: Int?) -> [Composed] {
        let literal = literalComposition(store, atTurn: turn)
        let frame = turn.map { store.frames[$0] ?? .empty } ?? facts
        guard !frame.isEmpty else { return literal }
        let (earlier, now) = frame.entries
        func composed(_ value: Transcript.Entry) -> Composed {
            Composed(
                entry: ThreadRecord.Entry(
                    id: 0, kind: .facts, origin: .carried, turn: nil, sources: [], state: .active, value: value),
                sent: value, own: false)
        }
        var result = literal
        if let now {
            result.insert(composed(now), at: result.firstIndex(where: \.own) ?? result.endIndex)
        }
        if let earlier {
            let first = result.first.map { $0.entry.kind == .instructions ? 1 : 0 } ?? 0
            result.insert(composed(earlier), at: first)
        }
        return result
    }

    /// `composition(_:atTurn:)` without the facts: the literal turns alone.
    ///
    /// - Parameters:
    ///   - store: The thread's record.
    ///   - turn: The turn, in the store's session's numbering; nil for the next request.
    /// - Returns: The entries, in order.
    func literalComposition(_ store: ThreadRecord, atTurn turn: Int?) -> [Composed] {
        let calls = referencesOutput ? store.calls : [:]
        guard let turn else {
            return store.entries.filter { $0.state == .active }.map {
                Composed(entry: $0, sent: rendered($0, calls: calls, whole: false, tools: registered), own: false)
            }
        }
        let tools = store.toolSets[turn]
        var composed: [Composed] = []
        for entry in store.entries {
            let recorded = entry.origin == .turn ? entry.turn ?? 0 : 0
            guard recorded <= turn else { continue }
            if entry.state != .active, (entry.droppedAt ?? 0) <= turn { continue }
            // A command the person ran is never a turn's own: it was recorded between turns, for the next.
            if recorded == turn, entry.origin == .turn, entry.kind != .command {
                composed.append(Composed(entry: entry, sent: entry.value, own: true))
                continue
            }
            let referenced = entry.referencedAt.map { $0 <= turn } ?? false
            composed.append(
                Composed(
                    entry: entry, sent: rendered(entry, calls: calls, whole: !referenced, tools: tools), own: false))
        }
        return composed
    }

    /// `entry` as a request after its turn carries it: a reply with its cuts, a tool output as its
    /// reference unless `whole` or it is no longer than the reference, the instructions with the catalogue and only
    /// the registered tools' definitions (`instructed(_:tools:)`), the person's command as its notice
    /// (`OutputReference.personCommand`) whatever the switches, anything else as stored.
    ///
    /// - Parameters:
    ///   - entry: The stored entry.
    ///   - calls: The store's calls by output id (`ThreadRecord.calls`).
    ///   - whole: Whether a tool output goes whole.
    ///   - tools: The tools the request registers; nil for every tool.
    /// - Returns: The entry to send, under the same id.
    func rendered(
        _ entry: ThreadRecord.Entry, calls: [String: (tool: String, arguments: String)], whole: Bool,
        tools: [String]? = nil
    ) -> Transcript.Entry {
        if entry.kind == .command, let command = entry.command, case .prompt(let prompt) = entry.value {
            let notice = OutputReference.personCommand(
                command, entry: entry.id, time: entry.time, output: ThreadRecord.text(of: entry.value),
                timeZone: timeZone, recallable: recalls)
            return .prompt(Transcript.Prompt(id: prompt.id, segments: [.text(.init(content: notice))]))
        }
        switch entry.value {
        case .instructions(let instructions):
            return .instructions(instructed(instructions, tools: tools))
        case .response:
            return cutsPresentation ? entry.presented : entry.value
        case .toolOutput(let output):
            guard referencesOutput, !whole, let reference = reference(for: entry, calls: calls) else {
                return entry.value
            }
            return .toolOutput(
                Transcript.ToolOutput(
                    id: output.id, toolName: output.toolName, segments: [.text(.init(content: reference))]))
        default:
            return entry.value
        }
    }

    /// The instructions entry as a request carries it: the catalogue added as a segment of its own, unless the
    /// entry already carries it (a resumed transcript saved with it), and the tool definitions limited to `tools`.
    /// Unchanged when there is no catalogue and no selection, so a composer without an assessment composes as before.
    ///
    /// - Parameters:
    ///   - instructions: The stored entry.
    ///   - tools: The tools the request registers; nil for every tool.
    /// - Returns: The entry, under the same id.
    func instructed(_ instructions: Transcript.Instructions, tools: [String]?) -> Transcript.Instructions {
        guard catalogue != nil || tools != nil else { return instructions }
        var segments = instructions.segments
        if let catalogue, !segments.contains(where: { $0.id == ToolCatalogue.segmentID }) {
            segments.append(.text(Transcript.TextSegment(id: ToolCatalogue.segmentID, content: "\n\n" + catalogue)))
        }
        let definitions = tools.map { names in instructions.toolDefinitions.filter { names.contains($0.name) } }
        return Transcript.Instructions(
            id: instructions.id, segments: segments, toolDefinitions: definitions ?? instructions.toolDefinitions)
    }

    /// The reference that stands for tool output `entry`, or nil when it is not a tool output or is no
    /// longer than its reference, so sending it whole costs no more.
    ///
    /// - Parameters:
    ///   - entry: The stored entry.
    ///   - calls: The store's calls by output id (`ThreadRecord.calls`).
    /// - Returns: The reference's text, or nil.
    func reference(for entry: ThreadRecord.Entry, calls: [String: (tool: String, arguments: String)]) -> String? {
        guard case .toolOutput(let output) = entry.value else { return nil }
        let text = ThreadRecord.text(of: entry.value)
        let reference = OutputReference.text(
            tool: output.toolName, entry: entry.id, time: entry.time, arguments: calls[output.id]?.arguments,
            output: text, timeZone: timeZone, recallable: recalls)
        return reference.utf8.count < text.utf8.count ? reference : nil
    }

    /// A decision to send one stored tool output as a reference from now on.
    struct Referencing: Sendable, Equatable {
        /// The output's store id.
        let entry: Int
        /// Its tool.
        let tool: String
        /// The `tool.result` event that recorded it, when it was linked.
        let result: AuditReference?
        /// The output's size in UTF-8 bytes.
        let bytes: Int
        /// The reference's size in UTF-8 bytes.
        let referenceBytes: Int
    }

    /// The active tool outputs not yet marked as referenced that a request now sends as references: every
    /// one, since each was stored at the end of an earlier turn, except those no longer than their
    /// reference. None when `referencesOutput` is off.
    ///
    /// - Parameter store: The thread's record.
    /// - Returns: The outputs, in store order.
    func newReferences(in store: ThreadRecord) -> [Referencing] {
        guard referencesOutput else { return [] }
        let calls = store.calls
        return store.entries.compactMap { entry in
            guard entry.state == .active, entry.referencedAt == nil, case .toolOutput(let output) = entry.value,
                let reference = reference(for: entry, calls: calls)
            else { return nil }
            return Referencing(
                entry: entry.id, tool: output.toolName, result: entry.sources.first,
                bytes: ThreadRecord.text(of: entry.value).utf8.count, referenceBytes: reference.utf8.count)
        }
    }

    /// The presentational text in the replies `turn` added: every stretch of a reply's text that reproduces
    /// one of that turn's tool outputs, by `Presentation.spans`. None when `cutsPresentation` is off.
    ///
    /// - Parameters:
    ///   - store: The thread's record, with the turn's entries recorded.
    ///   - turn: The turn whose replies are judged.
    /// - Returns: The cuts, in store order.
    func presentation(in store: ThreadRecord, turn: Int) -> [PresentationCut] {
        guard cutsPresentation else { return [] }
        let mine = store.entries.filter { $0.origin == .turn && $0.turn == turn }
        let outputs = mine.filter { $0.kind == .toolOutput }
        guard !outputs.isEmpty else { return [] }
        let texts = outputs.map { ThreadRecord.text(of: $0.value) }
        var found: [PresentationCut] = []
        for entry in mine where entry.kind == .response {
            guard case .response(let response) = entry.value else { continue }
            for (index, segment) in response.segments.enumerated() {
                guard case .text(let text) = segment else { continue }
                for span in Presentation.spans(in: text.content, outputs: texts) {
                    let output = outputs[span.output]
                    var tool = "tool"
                    if case .toolOutput(let value) = output.value { tool = value.toolName }
                    let cut = ThreadRecord.Cut(
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
        switch policy {
        case .condense, .target: true
        case .failFast: false
        }
    }

    /// Condensing before a prompt under `.condense(keepTurns:)`, when the tokens the conversation uses plus a
    /// rough cost for the prompt (four bytes a token) reach `budget` of `window`, and condensing would drop a turn;
    /// nil otherwise, and always under `.target`, which `TargetCondensing` handles.
    ///
    /// - Parameters:
    ///   - prompt: The prompt about to be sent.
    ///   - store: The thread's record.
    ///   - used: Tokens the active view occupies: the last request's reported usage, or the model's count.
    ///   - window: The model's context window.
    /// - Returns: The condensation to apply, or nil.
    func ahead(of prompt: String, in store: ThreadRecord, used: Int, window: Int) -> Condensation? {
        guard case .condense(let keepTurns) = policy, used > 0 else { return nil }
        let estimate = used + prompt.utf8.count / Self.bytesPerToken
        guard Double(estimate) >= Double(window) * budget else { return nil }
        let before = literal(store)
        let after = before.condensed(keepTurns: keepTurns)
        guard after.turnCount < before.turnCount else { return nil }
        return Condensation(before: before, after: after, estimate: estimate)
    }

    /// Condensing after the window overflowed under `.condense(keepTurns:)`, to retry the prompt once; nil under
    /// `.failFast` and `.target` (`Agent.retryToTarget`). It applies
    /// even when no turn would go, since it also sheds the failed attempt, as a rebuilt session always did.
    ///
    /// - Parameter store: The thread's record, as it was before the failed prompt.
    /// - Returns: The condensation to apply, or nil.
    func overflow(in store: ThreadRecord) -> Condensation? {
        guard case .condense(let keepTurns) = policy else { return nil }
        let before = literal(store)
        return Condensation(before: before, after: before.condensed(keepTurns: keepTurns), estimate: nil)
    }
}
