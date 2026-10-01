import Foundation
import FoundationModels

/// The stored view of one thread: every entry it has had, once, in the order it happened, each under
/// a stable id ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "Three
/// views of one conversation").
///
/// The audit log stays the one verbatim record (decision D8). An entry here refers to the audit events that
/// recorded its content (`sources`) and adds what composing a request needs on top: its kind, where it came
/// from, and whether it is still in the active view or was dropped, and by which condensation. The entry's
/// framework value is kept as well, as an in-memory cache of the conversation's own entries, so composing a
/// request never reads the audit files. `TranscriptStore` saves the active view as the transcript and the
/// whole store, dropped entries included, as a `Snapshot` beside it; a resumed conversation rebuilds its
/// store from the two, or from the transcript alone when there is no usable snapshot.
///
/// Phase 2 of the proposal populates entries and their state; phase 3 adds a reply's cuts, the stretches
/// of presentational text a composer leaves out (`Cut`, `Entry.presented`); phase 3b adds when each entry
/// was recorded and the turn from which a condensation dropped it or a tool output was sent as a reference
/// (`Entry.droppedAt`, `Entry.referencedAt`), so the context of any turn can be composed again
/// (`ContextComposer.compose(_:atTurn:)`). Phase 4a adds the conversation's facts and phase 4b the running
/// summary's versions, both citing entries by `Entry.ID`; `recall` will read their content back from the
/// audit log through `sources`.
public struct ThreadRecord: Sendable {
    /// What an entry is, as the framework's transcript names it.
    public enum Kind: String, Codable, Sendable, Equatable {
        /// The instructions the session was created with, tool definitions included.
        case instructions
        /// A prompt, which starts a turn.
        case prompt
        /// The tool calls the model asked for.
        case toolCalls
        /// One tool call's output.
        case toolOutput
        /// The model's text.
        case response
        /// The model's reasoning, for a model that reports it.
        case reasoning
        /// An entry of a kind this build does not know.
        case other
        /// A block of facts a composer adds to a request (`FactFrame`); never stored, only composed.
        case facts

        /// The kind of `entry`.
        init(_ entry: Transcript.Entry) {
            switch entry {
            case .instructions: self = .instructions
            case .prompt: self = .prompt
            case .toolCalls: self = .toolCalls
            case .toolOutput: self = .toolOutput
            case .response: self = .response
            case .reasoning: self = .reasoning
            @unknown default: self = .other
            }
        }
    }

    /// Where an entry came from.
    public enum Origin: String, Codable, Sendable, Equatable {
        /// A turn of this conversation produced it, and `sources` names the audit events that recorded it.
        case turn
        /// It came with the conversation's start: the instructions a session was created with, or a saved
        /// transcript handed to an agent without store data. Its content was recorded elsewhere or not at all, so
        /// it has no sources.
        case carried
        /// A turn of an earlier conversation produced it, and a saved store brought it back
        /// (`Snapshot`). `turn` and `sources` refer to the session that recorded it, which
        /// `session.start`'s `carriedFrom` names on resume.
        case resumed
    }

    /// Whether an entry is composed into requests.
    public enum State: Sendable, Equatable {
        /// In the active view: every request carries it.
        case active
        /// Left out of every later request by a condensation, named by its `context.condensation` event
        /// when the conversation is audited. The entry itself stays in the store.
        case dropped(by: AuditReference?)
    }

    /// One entry of the conversation.
    public struct Entry: Sendable, Identifiable {
        /// Position in the store, from 1; stable for the conversation's life.
        public let id: Int
        /// What it is.
        public let kind: Kind
        /// Where it came from.
        public let origin: Origin
        /// The conversation's turn that produced it (the audit's turn number); nil when carried.
        public let turn: Int?
        /// The audit events that hold its content verbatim: a prompt's `prompt` event, a reply's `response`
        /// event, each tool call's `tool.call` event, a tool output's `tool.result` event. Empty when nothing
        /// recorded it: carried entries, text the model wrote before a tool call, and tool activity in an
        /// agent not opened through a `WispThread` (which has no `ToolEventTrail`).
        public let sources: [AuditReference]
        /// Whether requests carry it.
        public internal(set) var state: State
        /// The framework's entry: the in-memory cache composing reads.
        public let value: Transcript.Entry
        /// Stretches of a reply that reproduced a tool output of its turn, which a composer that cuts
        /// presentational text leaves out of later requests (`Presentation`). The entry itself stays whole.
        public internal(set) var cuts: [Cut] = []
        /// When it was recorded: a prompt when it was sent, a tool output when its `tool.result` event was
        /// written, anything else when its turn was stored; nil when unknown (carried).
        public internal(set) var time: Date? = nil
        /// The turn during which a condensation dropped it, in this session's turns: requests of that turn
        /// and later leave it out. 0 when it was dropped before this session began (a resumed store); nil
        /// while active, or when it is not known.
        public internal(set) var droppedAt: Int? = nil
        /// For a tool output, the turn from whose first request it has been sent as a reference rather than
        /// in full (`ContextComposer.referencesOutput`), in this session's turns; 0 when that began before
        /// this session; nil while it is still sent whole.
        public internal(set) var referencedAt: Int? = nil

        /// The entry as a composer that cuts presentational text sends it: a reply with each cut replaced by
        /// its marker, under the same id; any other entry, or a reply without cuts, as it is.
        public var presented: Transcript.Entry {
            guard !cuts.isEmpty, case .response(var response) = value else { return value }
            for (index, segment) in response.segments.enumerated() {
                guard case .text(var text) = segment else { continue }
                let mine = cuts.filter { $0.segment == index }
                guard !mine.isEmpty else { continue }
                text.content = Presentation.replacing(
                    text.content, mine.map { (range: $0.start..<$0.end, with: $0.marker) })
                response.segments[index] = .text(text)
            }
            return .response(response)
        }
    }

    /// A stretch of a reply cut from the active context because it reproduced a tool output of the same
    /// turn: which text segment, where in it, and which output.
    public struct Cut: Codable, Sendable, Equatable {
        /// The index of the reply's text segment.
        public var segment: Int
        /// The UTF-8 offset in that segment's text where the cut starts.
        public var start: Int
        /// The UTF-8 offset where it ends.
        public var end: Int
        /// The store id of the tool output it reproduced.
        public var output: Int
        /// That output's tool.
        public var tool: String

        /// What the model reads in its place.
        public var marker: String { "(showed the person the \(tool) output, entry \(output))" }
    }

    /// Every entry, in the order it happened.
    public private(set) var entries: [Entry] = []
    /// The turn clock's value when this store began: its own turns are the ones after it. 0 for a store
    /// opened with its conversation; a `/new` starts a store at the turn it was typed.
    public internal(set) var firstTurn = 0
    /// The framework ids of the stored entries, so an entry the session already carried is not stored twice.
    private var known: Set<Transcript.Entry.ID> = []
    /// The conversation's facts (decision D2): its dynamic facts, and the permanent facts proposed in it and
    /// not yet approved. Saved with the store.
    public internal(set) var facts = FactBook(scope: .thread)
    /// The facts each turn's requests carried, by turn, so the context of an earlier turn can be shown as it
    /// was sent; this session's turns only, and not saved.
    var frames: [Int: FactFrame] = [:]
    /// The tools each turn's requests registered, by turn, when an assessment selected them (phase 4d, D4), so the
    /// context of an earlier turn shows the definitions it carried; this session's turns only, and not saved. A turn
    /// with no entry registered every tool.
    var toolSets: [Int: [String]] = [:]
    /// The running summary's versions, oldest first (phase 4b, decision D1): the last is current, each earlier
    /// one superseded by the next. Saved with the store; at most `RunningSummary.historyLimit` are kept.
    public internal(set) var summaries: [RunningSummary] = []

    /// The current running summary, or nil before the first is written.
    public var summary: RunningSummary? { summaries.last }

    /// Makes `summary` the current running summary, superseding the one before it, and keeps the history within
    /// `RunningSummary.historyLimit`.
    ///
    /// - Parameter summary: The new version.
    mutating func summarise(_ summary: RunningSummary) {
        summaries.append(summary)
        if summaries.count > RunningSummary.historyLimit {
            summaries.removeFirst(summaries.count - RunningSummary.historyLimit)
        }
    }

    /// The dropped entries the running summary does not cover yet: prompts, tool calls, and replies after its
    /// `through`, in order. Condensing drops whole turns, so these are whole turns too.
    var unsummarised: [Entry] {
        let through = summary?.through ?? 0
        return entries.filter { entry in
            guard entry.id > through, entry.state != .active else { return false }
            return [.prompt, .toolCalls, .response].contains(entry.kind)
        }
    }

    /// An empty store.
    public init() {}

    /// A store of exactly `entries`, whose framework ids it takes as known.
    init(entries: [Entry]) {
        self.entries = entries
        known = Set(entries.map(\.value.id))
    }

    /// A store whose entries all come with the conversation's start, active.
    ///
    /// - Parameter transcript: The instructions a session was created with, or a saved conversation.
    public init(carrying transcript: Transcript) {
        for entry in transcript { record(entry, origin: .carried, turn: nil, sources: []) }
    }

    /// A store that continues a saved conversation: rebuilt from `snapshot` when it matches `transcript`
    /// (see `Snapshot.restored(over:)`), else carrying `transcript` alone with no links, which is what a
    /// save without store data does. A snapshot that does not match is logged, not raised.
    ///
    /// - Parameters:
    ///   - transcript: The conversation's active view, as the session holds it.
    ///   - snapshot: The links saved beside it, if any.
    public init(carrying transcript: Transcript, restoring snapshot: Snapshot?) {
        if let snapshot {
            if let restored = snapshot.restored(over: transcript) {
                self = restored
                return
            }
            Diagnostics.agent.info("the saved store does not match the transcript; resuming without links")
        }
        self.init(carrying: transcript)
    }

    /// The active entries, in order: the transcript a literal composition sends.
    public var active: Transcript {
        Transcript(entries: entries.filter { $0.state == .active }.map(\.value))
    }

    /// Whether the store holds `entry`, by its framework id.
    func contains(_ entry: Transcript.Entry) -> Bool { known.contains(entry.id) }

    /// Appends `entry`, active, unless the store already holds it.
    ///
    /// - Parameters:
    ///   - entry: The framework's entry.
    ///   - origin: Where it came from.
    ///   - turn: The turn that produced it, when a turn did.
    ///   - sources: The audit events that recorded it.
    ///   - time: When it was recorded, when known.
    mutating func record(
        _ entry: Transcript.Entry, origin: Origin, turn: Int?, sources: [AuditReference], time: Date? = nil
    ) {
        guard known.insert(entry.id).inserted else { return }
        entries.append(
            Entry(
                id: entries.count + 1, kind: Kind(entry), origin: origin, turn: turn, sources: sources, state: .active,
                value: entry, time: time))
    }

    /// Makes `view` the active view: every active entry it does not carry is dropped by `condensation`. The
    /// view must be drawn from the active entries, as a condensed composition is.
    ///
    /// - Parameters:
    ///   - view: The entries to keep active.
    ///   - condensation: The `context.condensation` event that dropped the rest, when audited.
    ///   - turn: The turn during which it happened, when known.
    mutating func retain(_ view: Transcript, droppedBy condensation: AuditReference?, at turn: Int? = nil) {
        let kept = Set(view.map(\.id))
        for index in entries.indices where entries[index].state == .active && !kept.contains(entries[index].value.id) {
            entries[index].state = .dropped(by: condensation)
            entries[index].droppedAt = turn
        }
    }

    /// Attributes the entries with store ids `ids`, dropped during a condensation to a target before its event
    /// was recorded, to that event.
    ///
    /// - Parameters:
    ///   - ids: The dropped entries' store ids.
    ///   - condensation: The `context.condensation` event.
    mutating func attribute(_ ids: [Int], to condensation: AuditReference?) {
        for id in ids where id >= 1 && id <= entries.count && entries[id - 1].id == id {
            entries[id - 1].state = .dropped(by: condensation)
        }
    }

    /// Marks the tool output with store id `id` as sent by reference from `turn` on; an unknown id, or an
    /// entry already marked, changes nothing.
    ///
    /// - Parameters:
    ///   - id: The output's store id.
    ///   - turn: The turn whose first request carries the reference.
    mutating func reference(_ id: Int, from turn: Int) {
        guard id >= 1, id <= entries.count, entries[id - 1].id == id, entries[id - 1].referencedAt == nil else {
            return
        }
        entries[id - 1].referencedAt = turn
    }

    /// The tool call each tool output answers, by the output's framework id: the call's tool name and its
    /// arguments as JSON, from the `toolCalls` entries.
    var calls: [String: (tool: String, arguments: String)] {
        var found: [String: (tool: String, arguments: String)] = [:]
        for entry in entries {
            guard case .toolCalls(let calls) = entry.value else { continue }
            for call in calls { found[call.id] = (call.toolName, call.arguments.jsonString) }
        }
        return found
    }

    /// Marks the stretches of the entry with store id `id` that composing leaves out; an unknown id
    /// changes nothing.
    ///
    /// - Parameters:
    ///   - id: The reply's store id.
    ///   - cuts: Its cuts, replacing any it had.
    mutating func cut(_ id: Int, _ cuts: [Cut]) {
        guard id >= 1, id <= entries.count, entries[id - 1].id == id else { return }
        entries[id - 1].cuts = cuts
    }

    /// The text of an entry's text segments, joined; empty for an entry without text.
    static func text(of entry: Transcript.Entry) -> String {
        let segments: [Transcript.Segment]
        switch entry {
        case .toolOutput(let output): segments = output.segments
        case .response(let response): segments = response.segments
        case .prompt(let prompt): segments = prompt.segments
        default: segments = []
        }
        return segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
    }

    /// The audit events that recorded each of a turn's new entries, in the same order.
    ///
    /// Prompts refer to the turn's `prompt` event and the last response to its `response` event. Each tool
    /// call is matched to a `tool.call` event of the same tool, with the same arguments where one has them,
    /// latest first, so a call repeated after an overflow retry links to the retry's event; a tool output
    /// refers to the `tool.result` of the event its call matched.
    ///
    /// - Parameters:
    ///   - entries: The turn's new entries, in order.
    ///   - prompt: The turn's `prompt` event.
    ///   - response: The turn's `response` event; nil when the turn failed.
    ///   - toolEvents: The turn's `tool.call` and `tool.result` events, in the order they were written.
    /// - Returns: One list of references per entry.
    static func sources(
        for entries: [Transcript.Entry], prompt: AuditReference?, response: AuditReference?, toolEvents: [AuditEvent]
    ) -> [[AuditReference]] {
        var calls = toolEvents.filter { $0.kind == .toolCall }
        var results: [String: AuditEvent] = [:]
        for event in toolEvents where event.kind == .toolResult {
            if let call = event.call { results[call] = event }
        }
        var auditCall: [Transcript.ToolCall.ID: String] = [:]
        var sources = [[AuditReference]](repeating: [], count: entries.count)
        let lastResponse = entries.lastIndex { Kind($0) == .response }
        for (index, entry) in entries.enumerated().reversed() {
            switch entry {
            case .prompt:
                sources[index] = prompt.map { [$0] } ?? []
            case .response:
                if index == lastResponse, let response { sources[index] = [response] }
            case .toolCalls(let toolCalls):
                var matched: [AuditReference] = []
                for call in toolCalls.reversed() {
                    let arguments = call.arguments.jsonString
                    let found =
                        calls.lastIndex {
                            $0.details["tool"]?.stringValue == call.toolName
                                && $0.details["arguments"]?.stringValue == arguments
                        } ?? calls.lastIndex { $0.details["tool"]?.stringValue == call.toolName }
                    guard let found else { continue }
                    let event = calls.remove(at: found)
                    if let id = event.call { auditCall[call.id] = id }
                    matched.append(AuditReference(event))
                }
                sources[index] = matched.reversed()
            default:
                break
            }
        }
        for (index, entry) in entries.enumerated() {
            if case .toolOutput(let output) = entry, let call = auditCall[output.id], let result = results[call] {
                sources[index] = [AuditReference(result)]
            }
        }
        return sources
    }
}
