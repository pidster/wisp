import Foundation
import FoundationModels

/// A tool-using agent over the on-device Apple Foundation Model.
///
/// `Agent` owns a `LanguageModelSession`, which keeps the transcript and
/// runs the tool-call loop: the model requests a tool, the framework invokes
/// the matching `Tool`, and the result is fed back until the model replies.
/// When the context window overflows, `contextPolicy` decides whether the
/// session is rebuilt from a condensed transcript and the prompt retried.
public final class Agent {
    /// The model every session is created on; kept so sessions can be rebuilt.
    public let model: ResolvedModel
    /// Tools bound to every session, in registration order.
    /// The tools the model may call.
    public let tools: [any Tool]
    /// The live session. Replaced, never mutated, when the conversation is condensed or reset.
    private var session: LanguageModelSession

    /// What happens when a prompt no longer fits the context window.
    public let contextPolicy: ContextPolicy
    /// How many times the transcript has been condensed, to recover from overflow or ahead of it.
    public private(set) var condensations = 0
    /// The fraction of the context window a turn may start at before the transcript is condensed
    /// first. Runtimes such as Ollama truncate silently instead of failing, so the estimate is the
    /// only warning; the framework's models fail loudly and this merely saves the failed call.
    public var contextBudget = 0.85
    /// The window as the model stated it, or as the last overflow error reported it; nil until known.
    public private(set) var contextSize: Int?
    /// Bytes of prompt per token assumed when estimating a new prompt's cost.
    static let bytesPerToken = 4
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
        self.contextPolicy = contextPolicy
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        session = self.model.session(tools: tools, instructions: instructions)
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
        self.contextPolicy = contextPolicy
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = model.contextSize
        session = model.session(tools: tools, instructions: instructions)
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
    public init(
        transcript: Transcript, tools: [any Tool], model: ResolvedModel, contextPolicy: ContextPolicy = .default,
        audit: AuditLog? = nil, turns: TurnClock? = nil
    ) {
        self.model = model
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = model.contextSize
        session = model.session(tools: tools, transcript: transcript)
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
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public init(
        transcript: Transcript, tools: [any Tool], model: ModelSelection = .default,
        contextPolicy: ContextPolicy = .default, audit: AuditLog? = nil, turns: TurnClock? = nil
    ) throws {
        self.model = try model.resolve()
        self.tools = tools
        self.contextPolicy = contextPolicy
        self.audit = audit
        self.turns = turns ?? audit?.turns ?? TurnClock()
        contextSize = self.model.contextSize
        session = self.model.session(tools: tools, transcript: transcript)
    }

    /// The conversation so far, suitable for saving and resuming.
    public var transcript: Transcript { session.transcript }

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
        if let counted = try await model.tokenCount(for: session.transcript) { return counted }
        return lastInputTokens > 0 ? lastInputTokens : nil
    }

    /// Condenses before a prompt when the transcript plus a rough cost for the new prompt would pass the
    /// budget of a known window, so a runtime that truncates silently never gets the chance. The
    /// transcript's size is the last request's reported usage, or, for a model that reports none (the
    /// on-device model), the model's own count of the transcript. Returns whether it did.
    nonisolated(nonsending) private func condenseAheadIfNeeded(for prompt: String) async -> Bool {
        guard case .condense(let keepTurns) = contextPolicy, let contextSize else { return false }
        let used = lastInputTokens > 0 ? lastInputTokens : ((try? await model.tokenCount(for: session.transcript)) ?? 0)
        guard used > 0 else { return false }
        let estimate = used + prompt.utf8.count / Self.bytesPerToken
        guard Double(estimate) >= Double(contextSize) * contextBudget else { return false }
        let before = session.transcript
        let condensed = before.condensed(keepTurns: keepTurns)
        guard condensed.turnCount < before.turnCount else { return false }
        session = model.session(tools: tools, transcript: condensed)
        condensations += 1
        audit?.record(
            .condensation,
            details: AuditEvent.Details.condensation(
                turnsBefore: before.turnCount, turnsAfter: condensed.turnCount, contextSize: contextSize,
                tokenCount: estimate, reason: "budget", saved: saveCondensation(before, condensed)))
        Diagnostics.agent.info("condensed ahead of the window: \(estimate) of \(contextSize) tokens")
        return true
    }

    /// Starts a fresh session with the same instructions and tools, discarding the conversation,
    /// and records it as a `session.start` with reason `new`.
    public func reset() {
        session = model.session(tools: tools, transcript: session.transcript.condensed(keepTurns: 0))
        audit?.record(
            .sessionStart, details: AuditEvent.Details.sessionRestart(tools: tools.map(\.name), model: model.selection))
    }

    /// Runs `operation`; on context overflow under a `.condense` policy, rebuilds the
    /// session from the pre-call transcript condensed to the policy's turn count and retries once.
    nonisolated(nonsending) private func withOverflowRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        let before = session.transcript
        do {
            return try await operation()
        } catch {
            guard let overflow = Self.overflow(in: error) else { throw error }
            contextSize = overflow.contextSize
            guard case .condense(let keepTurns) = contextPolicy else { throw error }
            let condensed = before.condensed(keepTurns: keepTurns)
            session = model.session(tools: tools, transcript: condensed)
            condensations += 1
            audit?.record(
                .condensation,
                details: AuditEvent.Details.condensation(
                    turnsBefore: before.turnCount, turnsAfter: condensed.turnCount, contextSize: overflow.contextSize,
                    tokenCount: overflow.tokenCount, reason: "overflow", saved: saveCondensation(before, condensed)))
            Diagnostics.agent.info("condensed \(before.turnCount) -> \(condensed.turnCount) turns")
            return try await operation()
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
        audit?.record(.prompt, details: AuditEvent.Details.prompt(text: prompt, schema: schema))
        let started = Date()
        let before = condensations
        _ = await condenseAheadIfNeeded(for: prompt)
        do {
            let text = try await withOverflowRecovery(operation)
            let reply = Reply(text: text, condensed: condensations > before)
            recordStats(started: started, failure: nil)
            audit?.record(
                .response,
                details: AuditEvent.Details.response(
                    text: text, condensed: reply.condensed, seconds: Date().timeIntervalSince(started)))
            return reply
        } catch {
            recordStats(started: started, failure: "\(error)")
            audit?.error(error, context: "turn")
            Diagnostics.agent.error("turn failed: \(error)")
            throw error
        }
    }
}
