import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The process's proposed permanent facts and the fact-approval effect (decisions D2 and D3 of the
/// layered-context proposal; ADR 0044, amended 2026-09-30): conversations mirror their proposals into one
/// registry, the host asks about each once, one question at a time, a decline is remembered by subject, name,
/// and value, silence leaves the proposal waiting, and chat lists and approves another conversation's.
@Suite struct FactProposalsTests {
    /// Answers every question with the next of `answers`, and keeps the questions.
    final class ScriptedFactApprover: FactApprover {
        let answers: Mutex<[FactApprovalDecision]>
        let asked = Mutex<[FactApprovalRequest]>([])
        let canAsk: Bool

        init(_ answers: [FactApprovalDecision], canAsk: Bool = true) {
            self.answers = Mutex(answers)
            self.canAsk = canAsk
        }

        func decide(_ request: FactApprovalRequest) async -> FactApprovalDecision {
            asked.withLock { $0.append(request) }
            return answers.withLock { $0.isEmpty ? .declined : $0.removeFirst() }
        }

        var questions: [FactApprovalRequest] { asked.withLock { $0 } }
    }

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

    @Test func conversationsMirrorTheirProposalsAndTheQuestionSaysWhereOneCameFrom() throws {
        let settings = FactSettings()
        let agent = agent("git", sink: MemoryAuditSink(), settings: settings)
        let fact = try propose(agent, "release codename", "BLUE HERON")
        let proposal = try #require(settings.proposals.proposal("git/c1"))
        #expect(proposal.status == .awaiting && !proposal.asked && proposal.fact == fact)
        #expect(FactProposal.parse("git/c1")! == ("git", "c1") && FactProposal.parse("c1") == nil)
        #expect(FactProposal.parse("a/b/c") == nil && FactProposal.parse("/c1") == nil)
        let request = FactApprovalRequest(proposal: proposal, position: 2, count: 3)
        #expect(
            request.question
                == "Keep as a permanent fact? release codename: BLUE HERON (proposed by the model, from the person's "
                + "words in turn 3)")
        #expect(request.title == "wisp: keep as a permanent fact? (2 of 3)")
        #expect(FactApprovalRequest(proposal: proposal).title == "wisp: keep as a permanent fact?")
        var other = proposal
        other.fact.detail = "the model concluded, turns 2-4"
        #expect(
            FactApprovalRequest(proposal: other).provenance == "proposed by the model, its own conclusion in turns 2-4")
        other.fact.detail = nil
        #expect(FactApprovalRequest(proposal: other).provenance == "proposed by the model in turn 4")
        other.fact.source = .tool
        other.fact.detail = "read_file"
        #expect(FactApprovalRequest(proposal: other).provenance == "proposed by tool read_file in turn 4")
        other.fact.source = .person
        #expect(FactApprovalRequest(proposal: other).provenance == "proposed by the person")
        other.fact.identity.name = ""
        #expect(FactApprovalRequest(proposal: other).statement == "entity: BLUE HERON")
        // A newer value withdraws the older proposal; deleting one withdraws it too.
        _ = try propose(agent, "release codename", "GREY HERON")
        #expect(settings.proposals.proposal("git/c1")?.status == .withdrawn)
        _ = try agent.deleteFact("c2")
        #expect(settings.proposals.proposal("git/c2")?.status == .withdrawn && settings.proposals.awaiting.isEmpty)
    }

    @Test func eachProposalIsAskedOnceAndEveryAnswerIsCarriedOutAndAudited() async throws {
        let sink = MemoryAuditSink()
        let settings = FactSettings()
        let agent = agent("t1", sink: sink, settings: settings)
        try propose(agent, "codename", "BLUE HERON")
        try propose(agent, "team", "Platform")
        try propose(agent, "office", "Leeds")
        try propose(agent, "vendor", "Acme")
        let approver = ScriptedFactApprover([.approved, .declined, .unanswered(.seconds(1)), .failed("broken pipe")])
        let claimed = settings.proposals.claim(permanent: settings.permanent)
        #expect(claimed.map(\.reference) == ["t1/c1", "t1/c2", "t1/c3", "t1/c4"])
        // Claimed once: a second caller finds nothing to ask.
        #expect(settings.proposals.claim(permanent: settings.permanent).isEmpty)
        await settings.proposals.ask(claimed, via: approver, permanent: settings.permanent)
        #expect(approver.questions.map(\.position) == [1, 2, 3, 4] && approver.questions.allSatisfy { $0.count == 4 })
        // Accept admitted the first as approved by the person; its conversation marks its copy superseded.
        let kept = try #require(settings.permanent.current.first)
        #expect(kept.value == "BLUE HERON" && kept.approved != nil && kept.rank == FactSource.person.rank)
        agent.refreshFacts()
        #expect(
            agent.store.facts.fact("c1")?.state == .superseded && agent.store.facts.fact("c1")?.supersededBy == "p1")
        // Decline left the second with the conversation, as its proposal, and remembers it.
        #expect(agent.store.facts.fact("c2")?.state == .current && agent.store.facts.fact("c2")?.proposed == true)
        #expect(settings.proposals.proposal("t1/c2")?.status == .declined)
        // Silence and a failed dialog leave theirs waiting, asked.
        #expect(settings.proposals.awaiting.map(\.reference) == ["t1/c3", "t1/c4"])
        #expect(settings.proposals.awaiting.allSatisfy { $0.asked })
        let decided = sink.events.filter { $0.kind == .factApprovalDecided }
        #expect(decided.map { $0.details["decision"] } == ["approved", "declined", "timed-out", "failed"])
        #expect(decided[0].details["admitted"] == "p1" && decided[3].details["reason"] == "broken pipe")
        #expect(sink.events.filter { $0.kind == .factApprovalAsked }.count == 4)
        #expect(sink.events.first { $0.kind == .factApproved }?.details["via"] == "elicitation")
        for event in sink.events where event.kind.rawValue.hasPrefix("fact.") {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind)), "\(event.kind)")
        }
        // The same subject, name, and value from another conversation is not asked about again; nor is a value
        // the shared store already holds. A different value is.
        let other = self.agent("t2", sink: sink, settings: settings)
        try propose(other, "team", "platform ")
        try propose(other, "codename", "blue heron")
        try propose(other, "vendor", "Globex")
        #expect(settings.proposals.claim(permanent: settings.permanent).map(\.reference) == ["t2/c3"])
        // A claimed proposal decided meanwhile is skipped.
        let late = try propose(other, "office", "York")
        let claimedLate = settings.proposals.claim(permanent: settings.permanent)
        _ = try other.approveFact(late.id)
        let quiet = ScriptedFactApprover([.approved])
        await settings.proposals.ask(claimedLate, via: quiet, permanent: settings.permanent)
        #expect(quiet.questions.isEmpty)
    }

    @Test func chatListsAndApprovesAnotherConversationsProposal() async throws {
        let sink = MemoryAuditSink()
        let settings = FactSettings()
        let thread = agent("git", sink: sink, settings: settings)
        try propose(thread, "release codename", "BLUE HERON")
        try propose(thread, "team", "Platform")
        let chat = agent("chat", sink: sink, settings: settings)
        #expect(chat.proposalsElsewhere.map(\.reference) == ["git/c1", "git/c2"])
        #expect(thread.proposalsElsewhere.isEmpty)
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-proposals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = ChatLoopTests.Capture(lines: [
            "/inspect facts", "/fact approve git/c1", "/fact approve git/c1", "/fact approve git/c9", "quit",
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
        #expect(out.contains("`/fact approve ID` keeps one for every conversation."))
        let notes = capture.noted
        #expect(notes.contains("approved git/c1: kept as p1 in ~/.wisp/facts.json for every conversation"))
        #expect(notes.contains { $0.contains("error: no proposal git/c1 awaiting approval") })
        #expect(notes.contains { $0.contains("error: no proposal git/c9 awaiting approval") })
        #expect(sink.events.first { $0.kind == .factApproved }?.session == "git")
        #expect(sink.events.first { $0.kind == .factApproved }?.details["via"] == "chat")
        // The thread marks its copy superseded when it next syncs, without a second audit.
        thread.refreshFacts()
        #expect(thread.store.facts.fact("c1")?.supersededBy == "p1")
        #expect(sink.events.filter { $0.kind == .factSuperseded && $0.details["id"] == "c1" }.count == 1)
        // A declined proposal can still be approved, which forgets the decline.
        settings.proposals.decline("git/c2")
        let team = try #require(thread.store.facts.fact("c2"))
        #expect(settings.proposals.isDeclined(team))
        #expect(chat.proposalsElsewhere.isEmpty)
        _ = try chat.approveFact("git/c2")
        #expect(!settings.proposals.isDeclined(team))
        // With nothing of its own and nothing elsewhere, the listing says so and has no second section.
        let empty = FactReport.markdown([], all: false, elsewhere: [])
        #expect(!empty.contains("Proposed in other conversations"))
        // A fresh conversation after /new is a conversation of its own, so the earlier one's proposal stays
        // listed and approvable though the new store numbers its facts from c1 again.
        let earlier = try propose(chat, "vendor", "Initech")
        chat.reset()
        #expect(chat.conversationID == "chat.1")
        let fresh = try propose(chat, "vendor", "Umbrella")
        #expect(fresh.id == "c1")
        #expect(chat.proposalsElsewhere.map(\.reference) == ["chat/\(earlier.id)"])
        #expect(settings.proposals.proposal("chat.1/\(fresh.id)")?.fact.value == "Umbrella")
        // The conversation's own proposal can be named by reference too.
        let own = try propose(thread, "vendor", "Acme")
        let admitted = try thread.approveFact("git/\(own.id)")
        #expect(admitted.identity.scope == .permanent)
    }
}
