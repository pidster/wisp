import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// What the person can do to facts (decisions D3 and D6 of the layered-context proposal): state one, which
/// outranks a tool and the model; delete one; approve a proposed permanent fact into the shared store; and
/// see and set the task. Also the audit of each, conflicts raised and resolved, the shared store on disk,
/// and a saved conversation keeping its facts.
@Suite struct FactControlsTests {
    /// A scratch directory, removed by the caller.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An agent keeping facts, with its permanent facts in `home` when given.
    private func agent(sink: MemoryAuditSink, home: Home? = nil, steps: [ScriptedModel.Step] = []) -> Agent {
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)),
            audit: AuditLog(session: "s", sink: sink))
        agent.facts = FactSettings(permanent: home.map(SharedFacts.permanent(home:)) ?? SharedFacts(scope: .permanent))
        return agent
    }

    @Test func thePersonStatesDeletesAndResolvesConflicts() throws {
        let sink = MemoryAuditSink()
        let agent = agent(sink: sink)
        let tool = try #require(
            agent.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .thread, subject: "tests", name: "swift test"), source: .tool,
                    value: "failed (exit status 1)", temporalClass: .dynamic, method: .extracted, detail: "run_command")
            ))
        agent.refreshFacts()
        // The person disagrees: their word wins and the conflict is raised, once.
        let pinned = try agent.stateFact(subject: "tests", name: "swift test", value: "flaky; ignore it")
        #expect(pinned.source == .person && pinned.id == "c2")
        agent.refreshFacts()
        let group = try #require(agent.factView.groups.first)
        #expect(group.winner.id == "c2" && group.disagreeing.map(\.id) == [tool.id])
        #expect(sink.events.filter { $0.kind == .factConflict }.count == 1)
        let raised = try #require(sink.events.first { $0.kind == .factConflict })
        #expect(raised.details["winner"] == "c2" && raised.details["others"] == ["c1"])
        // Deleting the tool's fact resolves it; the store keeps it as deleted history.
        let deleted = try agent.deleteFact(tool.id)
        #expect(deleted.state == .deleted && agent.store.facts.fact(tool.id)?.state == .deleted)
        #expect(sink.events.contains { $0.kind == .factResolved && $0.details["subject"] == "tests" })
        #expect(sink.events.first { $0.kind == .factDeleted }?.details["by"] == "person")
        #expect(throws: FactFailure.noSuchFact("c1")) { try agent.deleteFact("c1") }
        #expect(throws: FactFailure.noSuchFact("x9")) { try agent.deleteFact("x9") }
        #expect(throws: FactFailure.unknownSubject("mood", known: SubjectKinds.defaults.kinds.map(\.name))) {
            try agent.stateFact(subject: "mood", name: "", value: "fine")
        }
        #expect(throws: FactFailure.emptyValue) { try agent.stateFact(subject: "task", name: "", value: " ") }
        for event in sink.events where event.kind.rawValue.hasPrefix("fact.") {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind)), "\(event.kind)")
        }
    }

    @Test func onlyThePersonAdmitsAPermanentFactAndTheSharedStoreIsUserOnly() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        let sink = MemoryAuditSink()
        let agent = agent(sink: sink, home: home)
        // The model's permanent fact is held by the conversation as a proposal.
        let proposal = try #require(
            agent.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .permanent, subject: "entity", name: "codename"), source: .model,
                    value: "BLUE HERON", temporalClass: .permanent, method: .distilled)))
        #expect(proposal.identity.scope == .thread && proposal.proposed && proposal.id == "c1")
        #expect(!FileManager.default.fileExists(atPath: home.factsFile.path))
        let admitted = try agent.setFactScope(proposal.id, to: .permanent)
        #expect(admitted.id == "p1" && admitted.identity.scope == .permanent && admitted.approved != nil)
        #expect(admitted.source == .model && FactComposition.provenance(admitted).hasSuffix("approved by the person"))
        #expect(
            agent.store.facts.fact("c1")?.state == .superseded && agent.store.facts.fact("c1")?.supersededBy == "p1")
        let changed = try #require(sink.events.first { $0.kind == .factScopeChanged })
        #expect(
            changed.details["now"] == "p1" && changed.details["from"] == "thread"
                && changed.details["to"] == "permanent")
        #expect(changed.details["by"] == "person" && changed.details["proposed"] == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.factsFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // The person's own statement of a permanent kind goes straight to the shared store.
        let stated = try agent.stateFact(subject: "preference", name: "Maria's reviews", value: "early returns")
        #expect(stated.id == "p2" && stated.source == .person)
        // A later conversation, in a later process, sees both.
        let later = self.agent(sink: MemoryAuditSink(), home: home)
        #expect(later.factView.groups.map(\.winner.value) == ["BLUE HERON", "early returns"])
        #expect(throws: FactFailure.noSuchFact("c9")) { try later.setFactScope("c9", to: .permanent) }
        _ = try later.deleteFact("p2")
        #expect(self.agent(sink: MemoryAuditSink(), home: home).factView.groups.count == 1)
    }

    @Test func ephemeralFactsAreTheSessionsAndDynamicOnesTheConversations() throws {
        let shared = SharedFacts.session()
        let one = agent(sink: MemoryAuditSink())
        let two = agent(sink: MemoryAuditSink())
        one.facts?.session = shared
        two.facts?.session = shared
        one.record(
            FactBook.Assertion(
                identity: FactIdentity(scope: .session, subject: "service", name: "port 8080"), source: .tool,
                value: "node, listening", temporalClass: .ephemeral, method: .extracted, detail: "system_info"))
        try one.setTask("one's task")
        #expect(two.factView.groups.map(\.winner.value) == ["node, listening"])
        #expect(one.factView.groups.count == 2 && two.fact("s1")?.value == "node, listening")
        // The session's facts go next to the request, and the person can delete them from any conversation.
        two.refreshFacts()
        #expect(
            two.composer.facts.now?.contains("- service port 8080: node, listening — from tool system_info") == true)
        _ = try two.deleteFact("s1")
        #expect(shared.current.isEmpty)
        // A new conversation in the same agent starts without the old one's facts.
        one.reset()
        #expect(one.taskHistory.isEmpty)
    }

    @Test func theTaskIsAFactWithHistory() throws {
        let agent = agent(sink: MemoryAuditSink())
        #expect(FactReport.task(agent.taskHistory) == "no task yet; /task TEXT sets one")
        try agent.setTask("add a --dry-run flag")
        try agent.setTask("write the docs", source: .caller)
        let history = agent.taskHistory
        #expect(history.map(\.state) == [.current, .current], "the person's and the caller's stand side by side")
        try agent.setTask("write the docs and tests")
        #expect(agent.taskHistory.map(\.state) == [.superseded, .current, .current])
        let text = FactReport.task(agent.taskHistory)
        #expect(text.hasPrefix("task: write the docs and tests\n  the person,") && text.contains("earlier:"))
        #expect(text.contains("c1 superseded: add a --dry-run flag (the person,"))
        _ = try agent.deleteFact("c3")
        _ = try agent.deleteFact("c2")
        #expect(FactReport.task(agent.taskHistory).hasPrefix("no task now"))
    }

    @Test func aSavedConversationKeepsItsFacts() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = agent(sink: MemoryAuditSink(), steps: [.say("ok")])
        _ = try await agent.respond(to: "hello")
        try agent.setTask("the task")
        let store = TranscriptStore(directory: dir)
        try store.save(agent.store, as: "kept")
        let saved = try store.loadThread("kept")
        #expect(saved.links.facts?.current.map(\.value) == ["the task"])
        let resumed = Agent(
            transcript: saved.transcript, tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()),
            links: saved.links)
        resumed.facts = FactSettings()
        #expect(resumed.taskHistory.map(\.value) == ["the task"])
        #expect(resumed.transcript.contains(where: FactFrame.isFrame), "the task is composed again")
        // A store without facts is saved without a facts field, and restores empty.
        var bare = agent.store.snapshot
        bare.facts = nil
        #expect(bare.restored(over: agent.store.active)?.facts.facts.isEmpty == true)
    }

    @Test func theReportShowsSourcesClassesConflictsAndHistory() throws {
        let agent = agent(sink: MemoryAuditSink())
        #expect(FactReport.markdown(agent.allFacts, all: false).contains("No facts yet."))
        agent.record(
            FactBook.Assertion(
                identity: FactIdentity(scope: .permanent, subject: "entity", name: "codename"), source: .model,
                value: "BLUE | HERON", temporalClass: .permanent, method: .distilled, detail: "the person said, turn 1")
        )
        agent.record(
            FactBook.Assertion(
                identity: FactIdentity(scope: .thread, subject: "tests", name: "ci"), source: .tool,
                value: "failing", temporalClass: .dynamic, method: .extracted, detail: "run_command"))
        try agent.stateFact(subject: "tests", name: "ci", value: "green")
        try agent.stateFact(subject: "tests", name: "ci", value: "green again")
        let current = FactReport.markdown(agent.allFacts, all: false)
        #expect(
            current.contains("| c1 | entity | codename | BLUE \\| HERON | model, distilled: the person said, turn 1 |"))
        #expect(current.contains("permanent (proposed) | /fact c1 permanent to keep it |"))
        #expect(current.contains("| c4 | tests | ci | green again | the person | dynamic | wins; disagreeing: c2 |"))
        #expect(
            current.contains(
                "| c2 | tests | ci | failing | tool run_command | dynamic | disagrees with c4, which wins |"))
        #expect(!current.contains("| c3 |") && current.contains("2 subjects in force, 1 in conflict."))
        let all = FactReport.markdown(agent.allFacts, all: true)
        #expect(all.contains("| c3 | tests | ci | green | the person | dynamic | superseded by c4 |"))
        let json = FactReport.json(try #require(agent.fact("c2")), view: agent.factView)
        #expect(json.objectValue?["conflict"]?.objectValue?["winner"] == "c4")
        #expect(agent.factHistory("c2").map(\.id) == ["c2", "c3", "c4"] && agent.factHistory("zz").isEmpty)
    }
}
