import FoundationModels

/// The stored view of one conversation: every entry it has had, once, in the order it happened, each under
/// a stable id ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "Three
/// views of one conversation").
///
/// The audit log stays the one verbatim record (decision D8). An entry here refers to the audit events that
/// recorded its content (`sources`) and adds what composing a request needs on top: its kind, where it came
/// from, and whether it is still in the active view or was dropped, and by which condensation. The entry's
/// framework value is kept as well, as an in-memory cache of the conversation's own entries, so composing a
/// request never reads the audit files. Nothing here is written to disk: `TranscriptStore` saves the active
/// view as before, and a resumed conversation rebuilds its store from that transcript.
///
/// Phase 2 of the proposal populates entries and their state only. Facts and summaries (phase 4) will cite
/// entries by `Entry.ID`, and `recall` will read their content back from the audit log through `sources`.
public struct ConversationStore: Sendable {
    /// What an entry is, as the framework's transcript names it.
    public enum Kind: String, Sendable, Equatable {
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
    public enum Origin: String, Sendable, Equatable {
        /// A turn of this conversation produced it, and `sources` names the audit events that recorded it.
        case turn
        /// It came with the conversation's start: the instructions a session was created with, or a saved
        /// transcript being resumed. Its content was recorded elsewhere or not at all, so it has no sources.
        case carried
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
        /// agent not opened through a `Conversation` (which has no `ToolEventTrail`).
        public let sources: [AuditReference]
        /// Whether requests carry it.
        public internal(set) var state: State
        /// The framework's entry: the in-memory cache composing reads.
        public let value: Transcript.Entry
    }

    /// Every entry, in the order it happened.
    public private(set) var entries: [Entry] = []
    /// The framework ids of the stored entries, so an entry the session already carried is not stored twice.
    private var known: Set<Transcript.Entry.ID> = []

    /// An empty store.
    public init() {}

    /// A store whose entries all come with the conversation's start, active.
    ///
    /// - Parameter transcript: The instructions a session was created with, or a saved conversation.
    public init(carrying transcript: Transcript) {
        for entry in transcript { record(entry, origin: .carried, turn: nil, sources: []) }
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
    mutating func record(_ entry: Transcript.Entry, origin: Origin, turn: Int?, sources: [AuditReference]) {
        guard known.insert(entry.id).inserted else { return }
        entries.append(
            Entry(
                id: entries.count + 1, kind: Kind(entry), origin: origin, turn: turn, sources: sources, state: .active,
                value: entry))
    }

    /// Makes `view` the active view: every active entry it does not carry is dropped by `condensation`. The
    /// view must be drawn from the active entries, as a condensed composition is.
    ///
    /// - Parameters:
    ///   - view: The entries to keep active.
    ///   - condensation: The `context.condensation` event that dropped the rest, when audited.
    mutating func retain(_ view: Transcript, droppedBy condensation: AuditReference?) {
        let kept = Set(view.map(\.id))
        for index in entries.indices where entries[index].state == .active && !kept.contains(entries[index].value.id) {
            entries[index].state = .dropped(by: condensation)
        }
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
