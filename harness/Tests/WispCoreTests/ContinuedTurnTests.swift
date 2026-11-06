import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// A request sent again on a fresh session after the turn has made tool calls (ADR 0086): after an overflow, under
/// either condensing policy, and after the model called a tool the request had not registered, the turn is rebuilt
/// from its audit events and continued with wisp's note, so no call runs again; when even the turn's own entries
/// cannot fit, the turn ends without sending them.
@Suite struct ContinuedTurnTests {
    /// An agent with `current_date` (and, with `assessing`, every tool the registry's assessment tests offer) on a
    /// model scripted with `steps`, recording to `sink` and keeping the tool event trail a thread gives it.
    static func agent(
        _ steps: [ScriptedModel.Step], sink: MemoryAuditSink, policy: ContextPolicy, window: Int = 100_000,
        assessing: Bool = false
    ) -> (Agent, ScriptedModel) {
        let events = ToolEventTrail()
        let audit = AuditLog(session: "c", sink: sink).alsoRecording(to: events)
        let model = ScriptedModel(steps: steps)
        model.script.overflowSize.withLock { $0 = (contextSize: window, tokenCount: window + 1) }
        let tools =
            assessing
            ? ToolRegistry(audit: audit).select(AssessmentTests.names).tools
            : [AuditedTool(CurrentDateTool(), audit: audit)]
        let agent = Agent(
            instructions: "x", tools: tools, model: ResolvedModel(selection: .system, custom: model),
            contextPolicy: policy, audit: audit)
        agent.toolEvents = events
        if assessing { agent.assessment = AssessmentSettings(infersTask: false) }
        return (agent, model)
    }

    /// A call to `current_date`.
    static let date = ScriptedModel.Step.call(name: "current_date", arguments: #"{"timeZone": "UTC"}"#)

    /// Whether `entry` is a tool output.
    static func isOutput(_ entry: Transcript.Entry) -> Bool { if case .toolOutput = entry { true } else { false } }

    @Test(arguments: [ContextPolicy.condense(keepTurns: 1), .target(.default)])
    func anOverflowAfterACallContinuesTheTurnWithoutRunningItAgain(policy: ContextPolicy) async throws {
        let sink = MemoryAuditSink()
        let (agent, model) = Self.agent([Self.date, .overflow, .say("It is {tool}")], sink: sink, policy: policy)
        let reply = try await agent.respond(to: "what is the date?")
        #expect(reply.text.hasPrefix("It is ") && reply.text.count > "It is ".count, "\(reply.text)")
        #expect(sink.events.count(where: { $0.kind == .toolCall }) == 1)
        #expect(sink.events.count(where: { $0.kind == .toolResult }) == 1)
        let condensations = sink.events.filter { $0.kind == .condensation }
        #expect(condensations.map { $0.details["reason"] } == ["overflow"])
        #expect(condensations.first?.details["continued"] == .int(1))
        // The retried request carries the call's output from the record and wisp's note, not the prompt again.
        let last = try #require(model.script.requests.withLock { $0.last })
        #expect(last.transcript.contains(where: Self.isOutput))
        #expect(last.transcript.contains(where: Agent.isWispNote))
        // The store keeps the person's prompt once, the call's output once, and the note as wisp's notice.
        #expect(agent.store.entries.count(where: { $0.kind == .prompt }) == 1)
        #expect(agent.store.entries.count(where: { $0.kind == .toolOutput }) == 1)
        #expect(agent.store.entries.count(where: { $0.kind == .notice }) == 1)
    }

    @Test func anOverflowBeforeAnyCallStillSendsThePromptAgain() async throws {
        let sink = MemoryAuditSink()
        let (agent, model) = Self.agent([.overflow, .say("hello")], sink: sink, policy: .condense(keepTurns: 1))
        #expect(try await agent.respond(to: "hi").text == "hello")
        let last = try #require(model.script.requests.withLock { $0.last })
        #expect(!last.transcript.contains(where: Agent.isWispNote))
        #expect(sink.events.first { $0.kind == .condensation }?.details["continued"] == nil)
    }

    @Test func anUnregisteredToolAfterACallContinuesTheTurnWithEveryTool() async throws {
        let sink = MemoryAuditSink()
        let (agent, model) = Self.agent(
            [Self.date, .call(name: "system_info", arguments: "{}"), .say("It is {tool}")], sink: sink,
            policy: .default, assessing: true)
        let reply = try await agent.respond(to: "What is the date today?")
        #expect(reply.text.hasPrefix("It is "), "\(reply.text)")
        #expect(sink.events.count(where: { $0.kind == .toolCall }) == 1)
        let retry = try #require(sink.events.last { $0.kind == .assessment })
        #expect(retry.details["method"] == "retry" && retry.details["continued"] == .int(1))
        let requests = model.script.requests.withLock { $0 }
        let last = try #require(requests.last)
        #expect(last.enabledToolDefinitions.map(\.name) == AssessmentTests.names)
        #expect(last.transcript.contains(where: Self.isOutput) && last.transcript.contains(where: Agent.isWispNote))
        #expect(agent.store.entries.count(where: { $0.kind == .prompt }) == 1)
    }

    @Test func aTurnWhoseCallsCannotFitEndsWithoutSendingThemAgain() async throws {
        // The window is smaller than the turn's own call and note: nothing is sent again, and the turn fails.
        let sink = MemoryAuditSink()
        let (agent, model) = Self.agent(
            [Self.date, .overflow, .say("never")], sink: sink, policy: .condense(keepTurns: 1), window: 10)
        await #expect(throws: ContextFailure.self) { try await agent.respond(to: "what is the date?") }
        #expect(model.script.requests.withLock { $0.count } == 2)
        #expect(sink.events.count(where: { $0.kind == .toolCall }) == 1)
        // What ran is kept for the next turn: the prompt once, and the call's output from the record.
        #expect(agent.store.entries.count(where: { $0.kind == .toolOutput }) == 1)
        #expect(agent.store.entries.count(where: { $0.kind == .prompt }) == 1)
    }

    @Test(arguments: [ContextPolicy.condense(keepTurns: 1), .target(.default)])
    func aContinuedTurnThatOverflowsAgainEndsAsDoesNotFit(policy: ContextPolicy) async throws {
        let sink = MemoryAuditSink()
        let (agent, model) = Self.agent(
            [Self.date, .overflow, .overflow, .say("never")], sink: sink, policy: policy)
        await #expect(throws: ContextFailure.self) { try await agent.respond(to: "what is the date?") }
        #expect(model.script.requests.withLock { $0.count } == 3)
        #expect(sink.events.count(where: { $0.kind == .toolCall }) == 1)
        #expect(agent.store.entries.count(where: { $0.kind == .toolOutput }) == 1)
    }

    @Test func aRebuildDropsTheCallsAContinuedSessionAlreadyHolds() {
        let call = Transcript.Entry.toolCalls(
            .init([.init(id: "c1", toolName: "t", arguments: GeneratedContent(properties: [:]))]))
        let output = Transcript.Entry.toolOutput(.init(id: "c1", toolName: "t", segments: [.text(.init(content: "o"))]))
        let prompt = Transcript.Entry.prompt(.init(segments: [.text(.init(content: "p"))]))
        let rebuilt = [prompt, call, output]
        let merged = Agent.continuing([call, output], with: rebuilt)
        #expect(merged.count == 3)
        #expect(Agent.calls(in: rebuilt) == 1)
        #expect(Agent.isWispNote(.prompt(.init(segments: [.text(.init(content: Agent.continuationNote))]))))
        #expect(!Agent.isWispNote(prompt))
    }
}
