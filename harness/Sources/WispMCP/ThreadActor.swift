import Foundation
import FoundationModels
import WispCore

/// What `WispServer.respond` needs from a thread, so tests can substitute one without a model.
public protocol RespondingThread: Sendable {
    /// Sends one user turn and returns the reply; with `schema`, the reply's text is JSON of that shape.
    func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply

    /// The model's context as `/inspect context <argument>` shows it (`ChatView.context(_:of:)`): the next
    /// request's for `next`, or the one composed at the start of a numbered turn; nil when the thread cannot
    /// show its context.
    func context(_ argument: String) async -> Result<ChatView, ChatView.Failure>?

    /// The thread's turns with what changed at each (`ContextView.turns(of:)`); nil when it cannot show them.
    func contextTurns() async -> [ContextView.Turn]?

    /// Sets the thread's task as the caller's assertion (decision D6).
    ///
    /// - Parameter task: The task.
    /// - Throws: `FactFailure` when the thread keeps no facts.
    func setTask(_ task: String) async throws

    /// Every fact the thread sees, in any state (`Agent.allFacts`); nil when it keeps none.
    func facts() async -> [Fact]?

    /// The running summary's versions, oldest first (`ThreadRecord.summaries`); nil when the thread keeps no
    /// facts.
    func summaries() async -> [RunningSummary]?

    /// Moves one of the thread's facts, or a session fact, to `target` as the caller's action
    /// (`Agent.setFactScope`).
    ///
    /// - Parameters:
    ///   - id: The fact (`c3`, `s1`).
    ///   - target: `thread` or `session`.
    /// - Returns: The fact as its new scope holds it.
    /// - Throws: `FactFailure`.
    func setFactScope(_ id: String, to target: FactTarget) async throws -> Fact

    /// Keeps the fact the person was asked about as a permanent fact, on the person's answer
    /// (`Agent.keepAsked`, ADR 0048).
    ///
    /// - Parameters:
    ///   - shown: The fact as the request named it.
    ///   - request: The request answered.
    /// - Returns: The fact as the shared store holds it.
    /// - Throws: `FactFailure`.
    func keepAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact

    /// Leaves the fact the person declined to keep in its thread (`Agent.dropAsked`, ADR 0048).
    ///
    /// - Parameters:
    ///   - shown: The fact as the request named it.
    ///   - request: The request answered.
    /// - Returns: The fact as it now stands.
    /// - Throws: `FactFailure`.
    func dropAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact
}

extension RespondingThread {
    /// None: a thread without a thread record cannot show its context.
    public func context(_ argument: String) async -> Result<ChatView, ChatView.Failure>? { nil }

    /// None, as for `context(_:)`.
    public func contextTurns() async -> [ContextView.Turn]? { nil }

    /// Refused: a thread without a thread record keeps no facts.
    public func setTask(_ task: String) async throws { throw FactFailure.off }

    /// None, as for `context(_:)`.
    public func facts() async -> [Fact]? { nil }

    /// None, as for `context(_:)`.
    public func summaries() async -> [RunningSummary]? { nil }

    /// Refused: a thread without a thread record keeps no facts.
    public func setFactScope(_ id: String, to target: FactTarget) async throws -> Fact { throw FactFailure.off }

    /// Refused: a thread without a thread record keeps no facts.
    public func keepAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact {
        throw FactFailure.off
    }

    /// Refused: a thread without a thread record keeps no facts.
    public func dropAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact {
        throw FactFailure.off
    }
}

/// One thread with the on-device model, addressable by id across MCP calls.
///
/// An actor so that calls on the same thread serialise (a session cannot answer
/// two prompts at once) while different threads run concurrently.
public actor ThreadActor: RespondingThread {
    /// The identifier clients pass as `thread_id`.
    public nonisolated let id: String
    /// The conversation; isolated to this actor because it is not `Sendable`.
    private let agent: Agent

    /// Wraps an agent opened from a `WispThread` the session set up for this thread.
    public init(id: String, agent: Agent) {
        self.id = id
        self.agent = agent
    }

    /// Sends one user turn on this thread's session, shaped by `schema` when given.
    public func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply {
        if let schema { return try await agent.respond(to: prompt, schema: schema) }
        return try await agent.respond(to: prompt)
    }

    /// The agent's context, composed from its store without a model call.
    public func context(_ argument: String) async -> Result<ChatView, ChatView.Failure>? {
        ChatView.context(argument, of: agent)
    }

    /// The agent's turns, from its store.
    public func contextTurns() async -> [ContextView.Turn]? { ContextView.turns(of: agent) }

    /// Sets the agent's task as the caller's.
    public func setTask(_ task: String) async throws { try agent.setTask(task, source: .caller) }

    /// Moves a fact as the caller's action.
    public func setFactScope(_ id: String, to target: FactTarget) async throws -> Fact {
        try agent.setFactScope(id, to: target, by: .caller)
    }

    /// Keeps the fact on the person's answer.
    public func keepAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact {
        try agent.keepAsked(shown, request: request)
    }

    /// Leaves the fact in its thread on the person's answer.
    public func dropAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact {
        try agent.dropAsked(shown, request: request)
    }

    /// The agent's running summary's versions, or nil when it keeps no facts.
    public func summaries() async -> [RunningSummary]? {
        agent.facts == nil ? nil : agent.store.summaries
    }

    /// The agent's facts, or nil when it keeps none; proposals moved elsewhere are marked superseded first.
    public func facts() async -> [Fact]? {
        guard agent.facts != nil else { return nil }
        agent.syncProposals()
        return agent.allFacts
    }
}
