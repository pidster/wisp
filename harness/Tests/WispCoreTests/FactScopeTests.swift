import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Moving a fact to a scope by name (decided 2026-09-30, ADR 0044 amended): the person, or an MCP caller,
/// changes where a fact lives; scope and temporal class move together, the old copy stays as history, and
/// every move is audited as `fact.scope.changed`. Also the listing of what a turn recorded.
@Suite struct FactScopeTests {
    /// An agent keeping facts in `settings`, recording to `sink`.
    private func agent(
        sink: MemoryAuditSink = MemoryAuditSink(), settings: FactSettings = FactSettings(), session: String = "chat"
    ) -> Agent {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])),
            audit: AuditLog(session: session, sink: sink))
        agent.facts = settings
        return agent
    }

    /// Has the model propose `name` = `value` as a permanent entity.
    @discardableResult
    private func propose(_ agent: Agent, _ name: String, _ value: String) throws -> Fact {
        let fact = try #require(
            agent.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .permanent, subject: "entity", name: name), source: .model,
                    value: value, temporalClass: .permanent, method: .distilled, turn: 1)))
        agent.refreshFacts()
        return fact
    }

    /// Has a tool record a session fact.
    @discardableResult
    private func serve(_ agent: Agent, _ port: String) throws -> Fact {
        try #require(
            agent.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .session, subject: "service", name: port), source: .tool,
                    value: "listening", temporalClass: .ephemeral, method: .extracted, detail: "system_info")))
    }

    @Test func aFactMovesInEveryDirectionWithScopeAndClassTogether() throws {
        let sink = MemoryAuditSink()
        let agent = agent(sink: sink)
        try agent.stateFact(subject: "tests", name: "ci", value: "green")
        // thread -> session
        let shared = try agent.setFactScope("c1", to: .session)
        #expect(shared.id == "s1" && shared.identity.scope == .session && shared.temporalClass == .ephemeral)
        #expect(
            agent.store.facts.fact("c1")?.state == .superseded && agent.store.facts.fact("c1")?.supersededBy == "s1")
        // session -> thread
        let owned = try agent.setFactScope("s1", to: .thread)
        #expect(owned.id == "c2" && owned.identity.scope == .conversation && owned.temporalClass == .dynamic)
        #expect(agent.facts?.session.current.isEmpty == true)
        // thread -> permanent: the shared store holds it as the person's, and it ranks with the person.
        let kept = try agent.setFactScope("c2", to: .permanent)
        #expect(kept.id == "p1" && kept.identity.scope == .permanent && kept.temporalClass == .permanent)
        #expect(kept.approved != nil && kept.rank == FactSource.person.rank && kept.value == "green")
        #expect(
            agent.facts?.permanent.current.map(\.id) == ["p1"] && agent.store.facts.fact("c2")?.supersededBy == "p1")
        // permanent -> session, and back to permanent from the session
        let out = try agent.setFactScope("p1", to: .session)
        #expect(out.id == "s2" && out.temporalClass == .ephemeral && agent.facts?.permanent.current.isEmpty == true)
        #expect(agent.facts?.permanent.facts.first?.state == .superseded)
        let again = try agent.setFactScope("s2", to: .permanent)
        #expect(again.id == "p2" && agent.facts?.permanent.current.map(\.id) == ["p2"])
        // permanent -> thread: out of the shared store into the conversation doing the move.
        let home = try agent.setFactScope("p2", to: .thread)
        #expect(home.id == "c3" && home.identity.scope == .conversation && home.temporalClass == .dynamic)
        #expect(agent.facts?.permanent.current.isEmpty == true && agent.fact("c3")?.state == .current)
        // The audit says what moved, from where to where, and by whom.
        let changes = sink.events.filter { $0.kind == .factScopeChanged }
        #expect(
            changes.map { "\($0.details["from"]?.stringValue ?? "")>\($0.details["to"]?.stringValue ?? "")" } == [
                "thread>session", "session>thread", "thread>permanent", "permanent>session", "session>permanent",
                "permanent>thread",
            ])
        #expect(changes.allSatisfy { $0.details["by"] == "person" })
        #expect(changes[0].details["fact"] == "c1" && changes[0].details["now"] == "s1")
        #expect(changes[0].details["subject"] == "tests" && changes[0].details["value"] == "green")
        #expect(changes[0].details["proposed"] == false)
        #expect(sink.events.filter { $0.kind == .factSuperseded }.count == 6)
        for event in sink.events where event.kind.rawValue.hasPrefix("fact.") {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind)), "\(event.kind)")
        }
        // A caller's move is recorded as the caller's.
        try agent.setFactScope("c3", to: .session, by: .caller)
        #expect(sink.events.last { $0.kind == .factScopeChanged }?.details["by"] == "caller")
    }

    @Test func aProposedPermanentFactBecomesTheThreadsOwnInPlaceOrMovesToTheSession() throws {
        let sink = MemoryAuditSink()
        let settings = FactSettings()
        let agent = agent(sink: sink, settings: settings)
        let first = try propose(agent, "codename", "BLUE HERON")
        let second = try propose(agent, "team", "Platform")
        #expect(first.proposed && second.proposed && settings.proposals.awaiting.count == 2)
        let kept = try agent.setFactScope(first.id, to: .thread)
        #expect(kept.id == first.id && !kept.proposed && kept.temporalClass == .dynamic && kept.state == .current)
        #expect(sink.events.last { $0.kind == .factScopeChanged }?.details["proposed"] == true)
        #expect(!sink.events.contains { $0.kind == .factSuperseded })
        #expect(settings.proposals.awaiting.map(\.reference) == ["chat/c2"])
        let shared = try agent.setFactScope(second.id, to: .session)
        #expect(shared.id == "s1" && !shared.proposed && settings.proposals.awaiting.isEmpty)
        #expect(agent.store.facts.fact("c2")?.supersededBy == "s1")
        // Already where it is, once it is no longer a proposal.
        #expect(throws: FactFailure.alreadyThere("c1", .thread)) { try agent.setFactScope("c1", to: .thread) }
        #expect(throws: FactFailure.alreadyThere("s1", .session)) { try agent.setFactScope("s1", to: .session) }
        #expect(throws: FactFailure.noSuchFact("c9")) { try agent.setFactScope("c9", to: .thread) }
        #expect(throws: FactFailure.noSuchFact("c2")) { try agent.setFactScope("c2", to: .thread) }
        #expect(throws: FactFailure.noSuchFact("x1")) { try agent.setFactScope("x1", to: .thread) }
        #expect(throws: FactFailure.noSuchProposal("other/c1")) { try agent.setFactScope("other/c1", to: .permanent) }
        // A fact of an agent that keeps none is refused.
        let bare = try Agent(instructions: "x", tools: [], model: .system)
        #expect(throws: FactFailure.off) { try bare.setFactScope("c1", to: .thread) }
        // Its own reference names a fact of this conversation.
        try propose(agent, "office", "Leeds")
        #expect(try agent.setFactScope("chat/c3", to: .thread).id == "c3")
    }

    @Test func aMoveToPermanentIsSavedAndAnotherConversationSeesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        let settings = FactSettings(permanent: SharedFacts.permanent(home: home))
        let agent = agent(settings: settings)
        let proposal = try propose(agent, "codename", "BLUE HERON")
        try agent.setFactScope(proposal.id, to: .permanent)
        let later = self.agent(settings: FactSettings(permanent: SharedFacts.permanent(home: home)))
        #expect(later.factView.groups.map(\.winner.value) == ["BLUE HERON"])
        // Out of the shared store again, which is saved too.
        try agent.setFactScope("p1", to: .session)
        let empty = self.agent(settings: FactSettings(permanent: SharedFacts.permanent(home: home)))
        #expect(empty.factView.groups.isEmpty)
        // A store that cannot be written refuses the move and leaves the fact where it was.
        let blocked = dir.appending(path: "blocked")
        try Data("x".utf8).write(to: blocked)
        let broken = self.agent(
            settings: FactSettings(
                permanent: SharedFacts(scope: .permanent, url: blocked.appending(path: "facts.json"))))
        let stuck = try propose(broken, "team", "Platform")
        #expect(throws: FactFailure.self) { try broken.setFactScope(stuck.id, to: .permanent) }
        #expect(broken.fact(stuck.id)?.state == .current)
    }

    @Test func aTurnListsTheFactsItRecordedOrChangedThatAreStillInForce() async throws {
        let model = ScriptedModel(steps: [
            .say("Noted."), .say("Understood."), .say(FactDistillationTests.answer), .say("It is BLUE HERON."),
        ])
        let agent = FactDistillationTests.agent(model, sink: MemoryAuditSink())
        let long = FactDistillationTests.long
        let one = try await agent.respond(to: "The codename is BLUE HERON and the CI build is failing." + long)
        let two = try await agent.respond(to: "By the way, CI is green again." + long)
        #expect(one.facts.isEmpty && two.facts.isEmpty)
        let reply = try await agent.respond(to: "What is the codename?" + long)
        // The distiller's facts: the proposal, the newest version of the test status, and the task; the first
        // version of the status was superseded within the turn and is not listed.
        #expect(reply.facts.map(\.value).contains("BLUE HERON") && reply.facts.map(\.value).contains("green again"))
        #expect(!reply.facts.map(\.value).contains("failing"))
        #expect(reply.facts.allSatisfy { $0.state == .current })
        #expect(reply.facts.first { $0.value == "BLUE HERON" }?.proposed == true)
        // A turn that records nothing lists nothing.
        let next = try await FactDistillationTests.agent(
            ScriptedModel(steps: [.say("ok")]), sink: MemoryAuditSink()
        ).respond(to: "hello")
        #expect(next.facts.isEmpty)
    }

    @Test func theNoteAfterATurnIsOneBoundedLineAndAbsentWhenThereAreNoFacts() throws {
        #expect(FactReport.newFacts([]) == nil)
        func fact(_ id: String, _ name: String, _ value: String, _ source: FactSource = .model) -> Fact {
            Fact(
                id: id, identity: FactIdentity(scope: .conversation, subject: "entity", name: name), source: source,
                version: 1, value: value, temporalClass: .permanent, method: .distilled, entries: [], audit: [],
                recorded: Date(), state: .current)
        }
        #expect(
            FactReport.newFacts([fact("c7", "release codename", "BLUE HERON")])
                == "1 new fact: c7 release codename = BLUE HERON (model) \u{2014} /fact <id> permanent|thread|session")
        let many = (1...5).map { fact("c\($0)", "n\($0)", "v\($0)", $0 == 2 ? .tool : .model) }
        let note = try #require(FactReport.newFacts(many))
        #expect(
            note == "5 new facts: c1 n1 = v1 (model), c2 n2 = v2 (tool), c3 n3 = v3 (model), and 2 more"
                + " \u{2014} /fact <id> permanent|thread|session")
        let long = try #require(FactReport.newFacts([fact("c1", "", String(repeating: "x", count: 200) + "\nmore")]))
        #expect(
            long.contains("c1 entity = " + String(repeating: "x", count: 60) + "\u{2026} (model)")
                && !long.contains("\n"))
        let json = try #require(
            FactReport.newFactsJSON([fact("c7", "codename", "BLUE HERON")]).arrayValue?.first?.objectValue)
        #expect(
            json["id"] == "c7" && json["scope"] == "thread" && json["proposed"] == true && json["source"] == "model")
        #expect(json["subject"] == "entity" && json["name"] == "codename" && json["value"] == "BLUE HERON")
    }

    @Test func chatNotesTheNewFactsAfterTheReplyAndTheProtocolCarriesThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-scope-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ScriptedModel(steps: [
            .say("Noted."), .say("Understood."), .say(FactDistillationTests.answer), .say("It is BLUE HERON."),
        ])
        let agent = FactDistillationTests.agent(model, sink: MemoryAuditSink())
        let long = FactDistillationTests.long
        let capture = ChatLoopTests.Capture(lines: [
            "The codename is BLUE HERON and the CI build is failing." + long, "By the way, CI is green again." + long,
            "What is the codename?" + long, "/fact c3 permanent", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context,
            io: capture.io)
        try await loop.run()
        let facts = capture.noted.filter { $0.contains(" new fact") }
        #expect(facts.count == 1, "\(capture.noted)")
        let line = try #require(facts.first)
        // The chat's own observations (c1, c2) came before the turns; the distiller's three are the turn's.
        #expect(line.hasPrefix("3 new facts: c3 release codename = BLUE HERON (model), c4 ci = green again (model)"))
        #expect(line.hasSuffix("/fact <id> permanent|thread|session") && !line.contains("more"))
        // The turn's end carries the same facts for a front end, only when there are some.
        let ends = capture.turns.withLock { $0 }.compactMap { mark -> [String: JSONValue]? in
            guard case .end = mark else { return nil }
            return ChatProtocol.turn(mark)
        }
        #expect(ends.count == 3 && ends[0]["facts"] == nil && ends[1]["facts"] == nil)
        let carried = try #require(ends[2]["facts"]?.arrayValue)
        #expect(carried.count == 3 && carried.contains { $0.objectValue?["value"] == "BLUE HERON" })
        #expect(carried.first?.objectValue?["scope"] == "thread")
        // The command the note names works on the id it printed.
        #expect(capture.noted.contains { $0.hasPrefix("moved c3 to permanent as p1") })
    }
}
