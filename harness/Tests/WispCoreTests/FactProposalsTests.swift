import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The process's proposed permanent facts (decisions D2 and D3 of the layered-context proposal; ADR 0044,
/// amended 2026-09-30): conversations mirror their proposals into one registry, and chat lists and moves
/// another conversation's.
@Suite struct FactProposalsTests {
    /// An agent keeping facts in `settings`, recording to `sink` under `session`.
    private func agent(_ session: String, sink: MemoryAuditSink, settings: FactSettings) -> Agent {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])),
            audit: AuditLog(session: session, sink: sink))
        agent.facts = settings
        return agent
    }

    /// Has `agent`'s model propose `name` = `value` as a permanent entity, distilled from the person's words.
    @discardableResult
    private func propose(_ agent: Agent, _ name: String, _ value: String) throws -> Fact {
        let fact = try #require(
            agent.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .permanent, subject: "entity", name: name), source: .model,
                    value: value, temporalClass: .permanent, method: .distilled, detail: "the person said, turn 3",
                    turn: 4)))
        agent.refreshFacts()
        return fact
    }

    @Test func conversationsMirrorTheirProposalsAndAnyMoveOrNewerValueWithdrawsThem() throws {
        let settings = FactSettings()
        let agent = agent("git", sink: MemoryAuditSink(), settings: settings)
        let fact = try propose(agent, "release codename", "BLUE HERON")
        let proposal = try #require(settings.proposals.proposal("git/c1"))
        #expect(proposal.status == .awaiting && proposal.fact == fact)
        #expect(FactProposal.parse("git/c1")! == ("git", "c1") && FactProposal.parse("c1") == nil)
        #expect(FactProposal.parse("a/b/c") == nil && FactProposal.parse("/c1") == nil)
        // A newer value withdraws the older proposal; deleting one withdraws it too.
        _ = try propose(agent, "release codename", "GREY HERON")
        #expect(settings.proposals.proposal("git/c1")?.status == .withdrawn)
        _ = try agent.deleteFact("c2")
        #expect(settings.proposals.proposal("git/c2")?.status == .withdrawn && settings.proposals.awaiting.isEmpty)
        // Moving a proposal within its conversation withdraws it from the registry.
        try propose(agent, "team", "Platform")
        #expect(settings.proposals.awaiting.map(\.reference) == ["git/c3"])
        try agent.setFactScope("c3", to: .thread)
        #expect(settings.proposals.awaiting.isEmpty && agent.fact("c3")?.proposed == false)
        // Moved and withdrawn entries are trimmed past the history limit; awaiting ones are not.
        for number in 0..<(FactProposals.historyLimit + 5) {
            try propose(agent, "vendor \(number)", "V\(number)")
            _ = try agent.deleteFact(agent.store.facts.current.last?.id ?? "")
        }
        try propose(agent, "kept", "still waiting")
        #expect(settings.proposals.all.count <= FactProposals.historyLimit + 1)
        #expect(settings.proposals.awaiting.map(\.fact.value) == ["still waiting"])
    }

    @Test func chatListsAndMovesAnotherConversationsProposal() async throws {
        let sink = MemoryAuditSink()
        let settings = FactSettings()
        let thread = agent("git", sink: sink, settings: settings)
        try propose(thread, "release codename", "BLUE HERON")
        try propose(thread, "team", "Platform")
        try propose(thread, "office", "Leeds")
        let chat = agent("chat", sink: sink, settings: settings)
        #expect(chat.proposalsElsewhere.map(\.reference) == ["git/c1", "git/c2", "git/c3"])
        #expect(thread.proposalsElsewhere.isEmpty)
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-proposals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = ChatLoopTests.Capture(lines: [
            "/inspect facts", "/fact git/c1 permanent", "/fact git/c1 permanent", "/fact git/c9 permanent",
            "/fact git/c2 thread", "/fact git/c3 session", "quit",
        ])
        var loop = ChatLoop(
            agent: chat, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context,
            io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains("## Proposed in other conversations"))
        #expect(
            out.contains(
                "| git/c1 | entity | release codename | BLUE HERON | model, distilled: the person said, turn 3 | git |  |"
            ))
        #expect(out.contains("`/fact ID permanent` keeps one for every conversation"))
        let notes = capture.noted
        #expect(notes.contains("moved git/c1 to permanent as p1 (kept in ~/.wisp/facts.json for every conversation)"))
        #expect(notes.contains { $0.contains("error: no proposal git/c1 awaiting approval") })
        #expect(notes.contains { $0.contains("error: no proposal git/c9 awaiting approval") })
        #expect(notes.contains { $0.contains("error: git/c2 is another conversation's proposal") })
        #expect(notes.contains("moved git/c3 to session as s1"))
        let changed = sink.events.filter { $0.kind == .factScopeChanged }
        #expect(changed.map(\.session) == ["chat", "git", "chat", "git"])
        #expect(changed[0].details["fact"] == "git/c1" && changed[0].details["by"] == "person")
        #expect(changed[0].details["from"] == "thread" && changed[0].details["to"] == "permanent")
        // The thread marks its copies superseded when it next syncs, without a second audit.
        thread.refreshFacts()
        #expect(
            thread.store.facts.fact("c1")?.supersededBy == "p1" && thread.store.facts.fact("c3")?.supersededBy == "s1")
        #expect(sink.events.filter { $0.kind == .factSuperseded && $0.details["id"] == "c1" }.count == 1)
        // With nothing of its own and nothing elsewhere, the listing says so and has no second section.
        let empty = FactReport.markdown([], all: false, elsewhere: [])
        #expect(!empty.contains("Proposed in other conversations"))
        // A fresh conversation after /new is a conversation of its own, so the earlier one's proposal stays
        // listed and movable though the new store numbers its facts from c1 again.
        let earlier = try propose(chat, "vendor", "Initech")
        chat.reset()
        #expect(chat.threadID == "chat.1")
        let fresh = try propose(chat, "vendor", "Umbrella")
        #expect(fresh.id == "c1")
        #expect(chat.proposalsElsewhere.map(\.reference).contains("chat/\(earlier.id)"))
        #expect(settings.proposals.proposal("chat.1/\(fresh.id)")?.fact.value == "Umbrella")
        // The conversation's own proposal can be named by reference too.
        let own = try propose(thread, "vendor", "Acme")
        let admitted = try thread.setFactScope("git/\(own.id)", to: .permanent)
        #expect(admitted.identity.scope == .permanent)
    }
}
