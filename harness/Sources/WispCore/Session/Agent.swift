import Foundation
import FoundationModels

/// A tool-using agent over the on-device Apple Foundation Model.
///
/// `Agent` keeps the conversation in a `ConversationStore` and asks a `ContextComposer` for the transcript
/// each request carries. A `LanguageModelSession` over that transcript runs the tool-call loop: the model
/// requests a tool, the framework invokes the matching `Tool`, and the result is fed back until the model
/// replies; the turn's new entries then go into the store, linked to the audit events that recorded them.
/// When the context window overflows, `contextPolicy` decides whether the active view is condensed and
/// the prompt retried.
public final class Agent {
    /// The model every session is created on; kept so sessions can be rebuilt.
    public let model: ResolvedModel
    /// Tools bound to every session, in registration order.
    /// The tools the model may call.
    public let tools: [any Tool]
    /// Every entry of the conversation, active or dropped, with the audit events that recorded it.
    public private(set) var store: ConversationStore
    /// Builds each request's transcript from `store`.
    private var composer: ContextComposer
    /// The live session, over the last composed transcript. A request whose composition is what the session
    /// already holds continues it, keeping the runtime's processed prefix and the session's token totals;
    /// any other composition starts a new session. Replaced, never mutated.
    private var session: LanguageModelSession

    /// What happens when a prompt no longer fits the context window.
    public var contextPolicy: ContextPolicy { composer.policy }
    /// How many times the transcript has been condensed, to recover from overflow or ahead of it.
    public private(set) var condensations = 0
    /// The fraction of the context window a turn may start at before the transcript is condensed
    /// first. Runtimes such as Ollama truncate silently instead of failing, so the estimate is the
    /// only warning; the framework's models fail loudly and this merely saves the failed call.
    public var contextBudget: Double {
        get { composer.budget }
        set { composer.budget = newValue }
    }
    /// The window as the model stated it, or as the last overflow error reported it; nil until known.
    public private(set) var contextSize: Int?
    /// Output tokens a schema-shaped reply may take. A small model can loop inside a string the schema
    /// cannot bound; the cap turns a runaway into a prompt error instead of a full window (probed
    /// 2026-09-21: one chunk ran 8193 tokens and six minutes before this).
    public var maximumSchemaTokens = 1024
    /// Where turns, responses, condensations, and errors are recorded.
    public let audit: AuditLog?
    /// The conversation's turn counter, advanced once per prompt; the approval gate reads it.
    public let turns: TurnClock
    /// Where the transcript is saved before and after each condensation; nil saves nothing.
    public var archive: ContextArchive?
    /// Where each turn's time and outcome are recorded for `/stats`; nil records nothing.
    public var stats: CallStats?
    /// The conversation's tool events, so the store can link tool calls and outputs to them; set by
    /// `Conversation.openAgent`. Nil leaves tool entries without sources.
    public var toolEvents: ToolEventTrail?

    /// Creates an agent on a model.
    ///
    /// - Parameters:
    ///   - instructions: System-level guidance the model follows for the whole session.
    ///   - tools: Tools the model may call; each must have a unique `name`.
    ///   - model: Which model; defaults to the on-device system model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        instructions: String, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil, turns: TurnClock? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        composer = ContextComposer(policy: contextPolicy)
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        session = self.model.session(tools: tools, instructions: instructions)
        store = ConversationStore(carrying: session.transcript)
    }

    /// Creates an agent on an already resolved model, such as a custom one; cannot fail.
    ///
    /// - Parameters:
    ///   - instructions: System-level guidance the model follows for the whole session.
    ///   - tools: Tools the model may call; each must have a unique `name`.
    ///   - model: The resolved model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    public init(
        instructions: String, tools: [any Tool], model: ResolvedModel, contextPolicy: ContextPolicy = .default,
        audit: AuditLog? = nil, turns: TurnClock? = nil
    ) {
        self.model = model
        self.tools = tools
        composer = ContextComposer(policy: contextPolicy)
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = model.contextSize
        session = model.session(tools: tools, instructions: instructions)
        store = ConversationStore(carrying: session.transcript)
    }

    /// Creates an agent that continues a saved conversation on an already resolved model; cannot fail.
    ///
    /// - Parameters:
    ///   - transcript: A transcript previously read from `Agent.transcript`.
    ///   - tools: Tools the model may call; they must match the names the transcript refers to.
    ///   - model: The resolved model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    ///   - links: The store links saved with the transcript (`TranscriptStore.Saved.links`); the store keeps
    ///     every entry's audit references and its dropped entries when they match, and carries the
    ///     transcript alone otherwise.
    public init(
        transcript: Transcript, tools: [any Tool], model: ResolvedModel, contextPolicy: ContextPolicy = .default,
        audit: AuditLog? = nil, turns: TurnClock? = nil,
        links: ConversationStore.Snapshot? = nil
    ) {
        self.model = model
        self.tools = tools
        composer = ContextComposer(policy: contextPolicy)
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = model.contextSize
        session = model.session(tools: tools, transcript: transcript)
        store = ConversationStore(carrying: session.transcript, restoring: links)
    }

    /// Creates an agent that continues a conversation's store on an already resolved model, as chat's
    /// `/model` does; cannot fail. The new model's first request carries what the store's active view
    /// holds, and the store keeps every entry and its audit references.
    ///
    /// - Parameters:
    ///   - store: The store of the agent being replaced (`Agent.store`).
    ///   - tools: Tools the model may call; they must match the names the store's entries refer to.
    ///   - model: The resolved model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    public init(
        store: ConversationStore, tools: [any Tool], model: ResolvedModel, contextPolicy: ContextPolicy = .default,
        audit: AuditLog? = nil, turns: TurnClock? = nil
    ) {
        self.model = model
        self.tools = tools
        composer = ContextComposer(policy: contextPolicy)
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = model.contextSize
        self.store = store
        session = model.session(tools: tools, transcript: composer.compose(store))
    }

    /// Creates an agent that continues a saved conversation.
    ///
    /// - Parameters:
    ///   - transcript: A transcript previously read from `Agent.transcript`.
    ///   - tools: Tools the model may call; they must match the names the transcript refers to.
    ///   - model: Which model; defaults to the on-device system model.
    ///   - contextPolicy: Overflow handling; defaults to condensing to the last four turns.
    ///   - audit: Where to record turns; nil records nothing.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a fresh one.
    ///   - links: The store links saved with the transcript, as for the resolved-model initialiser.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        transcript: Transcript, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil, turns: TurnClock? = nil,
        links: ConversationStore.Snapshot? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        composer = ContextComposer(policy: contextPolicy)
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = self.model.contextSize
        session = self.model.session(tools: tools, transcript: transcript)
        store = ConversationStore(carrying: session.transcript, restoring: links)
    }

    /// The transcript the next request carries: the store's active view, composed. Suitable for saving and
    /// resuming, and what `/inspect context` saves.
    public var transcript: Transcript { composer.compose(store) }

    /// Tokens the last request occupied, as the runtime reported them (`UsageReporting`); 0 for a
    /// model that does not report or before the first request. `LanguageModelSession.usage` cannot
    /// serve: it accumulates across requests.
    public var lastInputTokens: Int { model.reportedInputTokens() ?? 0 }

    /// The session's running token totals, in and out, as the framework counts them across requests;
    /// zero for a model that does not report. `ChatLoop` takes the difference across a turn.
    public var tokensUsed: TurnTokens {
        let usage = session.usage
        return TurnTokens(input: usage.input.totalTokenCount, output: usage.output.totalTokenCount)
    }

    /// Tokens the current transcript occupies: counted by the model when it can, else the runtime's
    /// report for the last request, else nil.
    ///
    /// - Throws: Framework errors if counting fails.
    nonisolated(nonsending) public func contextTokens() async throws -> Int? {
        if let counted = try await model.tokenCount(for: transcript) { return counted }
        return lastInputTokens > 0 ? lastInputTokens : nil
    }

    /// Condenses before a prompt when the transcript plus a rough cost for the new prompt would pass the
    /// budget of a known window, so a runtime that truncates silently never gets the chance. The
    /// transcript's size is the last request's reported usage, or, for a model that reports none (the
    /// on-device model), the model's own count of the transcript. Returns whether it did.
    nonisolated(nonsending) private func condenseAheadIfNeeded(for prompt: String) async -> Bool {
        guard composer.condensesAhead, let contextSize else { return false }
        let used = lastInputTokens > 0 ? lastInputTokens : ((try? await model.tokenCount(for: transcript)) ?? 0)
        guard let condensation = composer.ahead(of: prompt, in: store, used: used, window: contextSize) else {
            return false
        }
        let estimate = condensation.estimate ?? 0
        apply(condensation, contextSize: contextSize, tokenCount: estimate, reason: "budget")
        Diagnostics.agent.info("condensed ahead of the window: \(estimate) of \(contextSize) tokens")
        return true
    }

    /// Starts a fresh session with the same instructions and tools, discarding the conversation and its
    /// store, and records it as a `session.start` with reason `new`.
    public func reset() {
        store = ConversationStore(carrying: transcript.condensed(keepTurns: 0))
        materialise(fresh: true)
        audit?.record(
            .sessionStart, details: AuditEvent.Details.sessionRestart(tools: tools.map(\.name), model: model.selection))
    }

    /// Runs `operation`; on context overflow under a `.condense` policy, condenses the store's active view
    /// as it was before the call to the policy's turn count, and retries once on a fresh session.
    nonisolated(nonsending) private func withOverflowRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard let overflow = Self.overflow(in: error) else { throw error }
            contextSize = overflow.contextSize
            guard let condensation = composer.overflow(in: store) else { throw error }
            apply(
                condensation, contextSize: overflow.contextSize, tokenCount: overflow.tokenCount, reason: "overflow",
                fresh: true)
            Diagnostics.agent.info(
                "condensed \(condensation.before.turnCount) -> \(condensation.after.turnCount) turns")
            return try await operation()
        }
    }

    /// Applies a condensation: counts it, saves the transcript before and after, records the
    /// `context.condensation` event, marks the dropped entries in the store with it, and moves the session
    /// onto the condensed view.
    ///
    /// - Parameters:
    ///   - condensation: What the composer decided.
    ///   - contextSize: The window, for the event.
    ///   - tokenCount: The estimate or the overflowing request's size, for the event.
    ///   - reason: `budget` or `overflow`.
    ///   - fresh: Whether to start a new session even when the view is what the session holds.
    private func apply(
        _ condensation: ContextComposer.Condensation, contextSize: Int, tokenCount: Int, reason: String,
        fresh: Bool = false
    ) {
        condensations += 1
        let event = audit?.record(
            .condensation,
            details: AuditEvent.Details.condensation(
                turnsBefore: condensation.before.turnCount, turnsAfter: condensation.after.turnCount,
                contextSize: contextSize, tokenCount: tokenCount, reason: reason,
                saved: saveCondensation(condensation.before, condensation.after)))
        store.retain(condensation.after, droppedBy: event)
        materialise(fresh: fresh)
    }

    /// Puts the session over the composer's transcript: continues it when that is what it holds, entry
    /// for entry, and starts a new one from the composition otherwise or when `fresh`.
    private func materialise(fresh: Bool = false) {
        let composed = transcript
        guard fresh || composed.map(\.id) != session.transcript.map(\.id) else { return }
        session = model.session(tools: tools, transcript: composed)
    }

    /// Stores the entries the session added this turn, whether it succeeded or failed, linked to the audit
    /// events that recorded them.
    ///
    /// - Parameters:
    ///   - prompt: The turn's `prompt` event.
    ///   - response: The turn's `response` event; nil when the turn failed.
    private func remember(prompt: AuditReference?, response: AuditReference?) {
        let added = Array(session.transcript).filter { !store.contains($0) }
        let turn = turns.current
        let sources = ConversationStore.sources(
            for: added, prompt: prompt, response: response, toolEvents: toolEvents?.take(turn: turn) ?? [])
        for (entry, references) in zip(added, sources) {
            store.record(entry, origin: .turn, turn: turn, sources: references)
        }
    }

    /// Saves the transcript before and after a condensation to `archive`, returning both paths for the
    /// audit record; nil when there is no archive or saving failed, which never stops the turn.
    private func saveCondensation(_ before: Transcript, _ after: Transcript) -> (before: String, after: String)? {
        guard let archive else { return nil }
        let label = "turn\(turns.current)-condensed\(condensations)"
        do {
            let saved = try archive.save(before, label: label + "-before")
            let kept = try archive.save(after, label: label + "-after")
            return (saved.path, kept.path)
        } catch {
            Diagnostics.agent.error("could not save the condensed context: \(error)")
            return nil
        }
    }

    /// The window and the size of the request when `error` is a context overflow: the framework's
    /// `contextSizeExceeded`, or, as the on-device model on macOS 27 reports it, an `inferenceFailed`
    /// whose message reads "Provided 8,913 tokens, but the maximum allowed is 8,192". Nil otherwise.
    static func overflow(in error: any Error) -> (contextSize: Int, tokenCount: Int)? {
        if case LanguageModelError.contextSizeExceeded(let details) = error {
            return (details.contextSize, details.tokenCount)
        }
        let text = String(describing: error)
        guard
            let match = text.firstMatch(
                of: #/Provided ([\d,]+) tokens, but the maximum allowed is ([\d,]+)/#),
            let provided = Int(match.1.filter(\.isNumber)), let allowed = Int(match.2.filter(\.isNumber))
        else { return nil }
        return (allowed, provided)
    }

    /// What one turn produced.
    public struct Reply: Sendable, Equatable {
        /// The final assistant text.
        public var text: String
        /// Whether older turns were dropped to fit the context window during this turn.
        public var condensed: Bool

        /// Creates a reply.
        public init(text: String, condensed: Bool) {
            self.text = text
            self.condensed = condensed
        }
    }

    /// Sends one user turn and returns the reply.
    nonisolated(nonsending) public func respond(to prompt: String) async throws -> Reply {
        try await turn(prompt) { try await session.respond(to: prompt).content }
    }

    /// Sends one user turn and returns the reply as JSON shaped by `schema`, through the framework's
    /// guided generation. The model must declare that capability; the check happens before the turn.
    ///
    /// - Parameters:
    ///   - prompt: The task.
    ///   - schema: The shape the reply must take.
    /// - Returns: The reply, whose `text` is the JSON.
    /// - Throws: `ModelSelection.Failure.unsupportedCapability`, or framework errors.
    nonisolated(nonsending) public func respond(to prompt: String, schema: OutputSchema) async throws -> Reply {
        try model.checkGuidedGeneration()
        return try await turn(prompt, schema: schema.source) {
            try await session.respond(
                to: prompt, schema: schema.schema, options: .init(maximumResponseTokens: maximumSchemaTokens)
            ).content.jsonString
        }
    }

    /// Sends one user turn, calling `onDelta` with each new fragment of the assistant text as it
    /// streams, and returns the reply.
    ///
    /// Snapshots are cumulative. If a retry after mid-stream overflow starts a new answer that does
    /// not continue the text already shown, a newline separates the two so the caller's output stays
    /// readable rather than splicing an unrelated suffix onto it.
    @discardableResult
    nonisolated(nonsending) public func stream(_ prompt: String, onDelta: (String) -> Void) async throws -> Reply {
        // `emitted` lives outside the retried closure so a retry after mid-stream overflow continues
        // from what the caller has already seen instead of repeating it.
        var emitted = ""
        return try await turn(prompt) {
            for try await snapshot in session.streamResponse(to: prompt) {
                let full = snapshot.content
                guard full != emitted else { continue }
                if full.hasPrefix(emitted) {
                    onDelta(String(full.dropFirst(emitted.count)))
                } else {
                    onDelta("\n" + full)
                }
                emitted = full
            }
            return emitted
        }
    }

    /// Records one turn in `stats`, with the runtime's reported prompt tokens when there are any.
    private func recordStats(started: Date, failure: String?) {
        stats?.record(
            CallStats.Call(
                kind: .turn, model: model.selection.description, started: started,
                seconds: Date().timeIntervalSince(started), failure: failure, inputTokens: model.reportedInputTokens()))
    }

    /// Records the prompt, runs `operation` with overflow recovery, and records the response or error.
    nonisolated(nonsending) private func turn(
        _ prompt: String, schema: JSONValue? = nil, _ operation: () async throws -> String
    ) async throws -> Reply {
        turns.advance()
        let prompted = audit?.record(.prompt, details: AuditEvent.Details.prompt(text: prompt, schema: schema))
        let started = Date()
        let before = condensations
        if !(await condenseAheadIfNeeded(for: prompt)) { materialise() }
        do {
            let text = try await withOverflowRecovery(operation)
            let reply = Reply(text: text, condensed: condensations > before)
            recordStats(started: started, failure: nil)
            let responded = audit?.record(
                .response,
                details: AuditEvent.Details.response(
                    text: text, condensed: reply.condensed, seconds: Date().timeIntervalSince(started)))
            remember(prompt: prompted, response: responded)
            return reply
        } catch {
            recordStats(started: started, failure: "\(error)")
            audit?.error(error, context: "turn")
            Diagnostics.agent.error("turn failed: \(error)")
            remember(prompt: prompted, response: nil)
            throw error
        }
    }
}
