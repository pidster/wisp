import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// A response with neither a reply nor a tool call, which the framework ends the turn on, keeping nothing of it: wisp
/// rebuilds the turn from its record and asks once more with its note, so nothing runs again, and gives its own line
/// when that is empty too.
@Suite struct EmptyReplyTests {
    /// An agent with `current_date`, on a model scripted with `steps`, recording to `sink`, and with the tool event
    /// trail a thread gives it unless `trail` is false.
    static func agent(
        _ steps: [ScriptedModel.Step], sink: MemoryAuditSink, trail: Bool = true
    ) -> (Agent, ScriptedModel) {
        let events = ToolEventTrail()
        let audit =
            trail ? AuditLog(session: "s", sink: sink).alsoRecording(to: events) : AuditLog(session: "s", sink: sink)
        let model = ScriptedModel(steps: steps)
        let agent = Agent(
            instructions: "x", tools: [AuditedTool(CurrentDateTool(), audit: audit)],
            model: ResolvedModel(selection: .system, custom: model), audit: audit)
        if trail { agent.toolEvents = events }
        return (agent, model)
    }

    static let date = ScriptedModel.Step.call(name: "current_date", arguments: #"{"timeZone": "UTC"}"#)

    @Test func anEmptyResponseIsAskedOnceAndTheTurnGoesOnWithoutRunningAgain() async throws {
        let sink = MemoryAuditSink()
        let (agent, model) = Self.agent([Self.date, .silent, .say("It is {tool}")], sink: sink)
        let reply = try await agent.respond(to: "what is the date?")
        #expect(reply.text.hasPrefix("It is "))
        #expect(sink.events.count(where: { $0.kind == .toolCall }) == 1)
        #expect(sink.events.filter { $0.kind == .turnEmpty }.map { $0.details["outcome"] } == ["replied"])
        // The last request carries the rebuilt turn, its call's output from the record, then the note; the store keeps the
        // note as wisp's notice and the person's prompt once.
        let last = try #require(model.script.requests.withLock { $0.last })
        #expect(last.transcript.contains(where: Agent.isEmptyReplyNote))
        #expect(last.transcript.contains { if case .toolOutput = $0 { true } else { false } })
        #expect(agent.store.entries.count(where: { $0.kind == .toolOutput }) == 1)
        let notices = agent.store.entries.filter { $0.kind == .notice }
        #expect(notices.count == 1 && agent.store.entries.count(where: { $0.kind == .prompt }) == 1)
    }

    @Test func emptyAgainEndsTheTurnWithWispsLine() async throws {
        let sink = MemoryAuditSink()
        let (agent, _) = Self.agent([Self.date, .silent, .silent], sink: sink)
        let reply = try await agent.respond(to: "what is the date?")
        #expect(reply.text == Agent.emptyReplyLine)
        #expect(sink.events.filter { $0.kind == .turnEmpty }.map { $0.details["outcome"] } == ["empty again"])
        #expect(sink.events.count(where: { $0.kind == .toolCall }) == 1)
    }

    @Test func anEmptyFirstResponseIsAskedTooAndWithoutATrailSaidSo() async throws {
        let sink = MemoryAuditSink()
        let (agent, _) = Self.agent([.silent, .say("Hello")], sink: sink)
        #expect(try await agent.respond(to: "hi").text == "Hello")
        #expect(sink.events.first { $0.kind == .turnEmpty }?.details["outcome"] == "replied")
        let bare = MemoryAuditSink()
        let (untracked, _) = Self.agent([.silent, .say("Hello")], sink: bare, trail: false)
        #expect(try await untracked.respond(to: "hi").text == Agent.emptyReplyLine)
        #expect(bare.events.first { $0.kind == .turnEmpty }?.details["outcome"] == "nothing to rebuild")
    }

    @Test func onlyTheFrameworksEmptyEndIsRecovered() {
        struct Other: Error, CustomStringConvertible { var description: String { "other" } }
        #expect(!Agent.endedEmpty(Other()))
        #expect(!Agent.isEmptyReplyNote(.prompt(Transcript.Prompt(segments: [.text(.init(content: "hi"))]))))
        #expect(
            Agent.isEmptyReplyNote(.prompt(Transcript.Prompt(segments: [.text(.init(content: Agent.emptyReplyNote))]))))
    }
}
