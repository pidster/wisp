import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Distilling prose into facts as turns leave the active view (decision D1 of the layered-context proposal):
/// one call per condensation in a session of its own, audited, bounded, and never failing the turn.
@Suite struct FactDistillationTests {
    /// What the scripted model answers when asked to distil.
    static let answer = """
        {"facts":[{"subject":"entity","name":"release codename","value":"BLUE HERON","speaker":"person"},\
        {"subject":"tests","name":"ci","value":"failing","speaker":"person"},\
        {"subject":"tests","name":"ci","value":"green again","speaker":"person"},\
        {"subject":"nonsense","name":"x","value":"y","speaker":"model"},\
        {"subject":"file","name":"a.md","value":"a summary of the file","speaker":"model"},\
        {"subject":"task","name":"","value":"add a --dry-run flag to harbour sync","speaker":"person"}]}
        """

    /// An agent that condenses to the last turn once two turns pass a tiny window.
    static func agent(_ model: ScriptedModel, sink: MemoryAuditSink, capabilities: Bool = true) -> Agent {
        let agent = Agent(
            instructions: "You are wisp.", tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 60),
            contextPolicy: .condense(keepTurns: 1), audit: AuditLog(session: "s", sink: sink))
        agent.facts = FactSettings()
        return agent
    }

    /// A prompt long enough to pass the budget of a 60-token window.
    static let long = " This sentence makes the prompt long enough to pass the budget of the tiny window."

    @Test func aCondensationDistilsTheDroppedTurnsIntoFactsTheNextRequestCarries() async throws {
        let model = ScriptedModel(steps: [
            .say("Noted."), .say("Understood."), .say(Self.answer), .say("It is BLUE HERON."),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        _ = try await agent.respond(to: "The codename is BLUE HERON and the CI build is failing." + Self.long)
        _ = try await agent.respond(to: "By the way, CI is green again." + Self.long)
        let reply = try await agent.respond(to: "What is the codename?" + Self.long)
        #expect(reply.text == "It is BLUE HERON." && reply.condensed)
        // The distiller was asked in a session of its own, with the schema, the kinds, and the dropped turn.
        let requests = model.script.requests.withLock { $0 }
        #expect(requests.count == 4)
        let distilling = requests[2]
        #expect(distilling.schema != nil && distilling.generationOptions.maximumResponseTokens == 900)
        let asked = Array(distilling.transcript)
        guard case .instructions(let instructions) = asked.first else {
            Issue.record("the distiller has its own instructions")
            return
        }
        #expect(ContextArchive.text(instructions.segments).hasPrefix("You keep a record of a conversation"))
        let prompt = ConversationStore.text(of: try #require(asked.last))
        #expect(prompt.contains("- entity: A named thing") && prompt.contains("Turn 1, the person: The codename is"))
        #expect(!prompt.contains("- file:"), "kinds whose facts come from tools are not offered")
        #expect(prompt.contains("Turn 1, the assistant: Noted.") && !prompt.contains("Turn 2, the assistant"))
        // The kept turn's prompt is shown for hindsight, after the turns being distilled.
        let later = try #require(
            prompt.range(of: "Later turns, still in view (for the latest values):\nTurn 2, the person: By the way"))
        #expect(later.lowerBound > (prompt.range(of: "Turn 1, the person")?.lowerBound ?? prompt.endIndex))
        // The facts: an unknown subject dropped, the later CI value kept, the entity a proposal.
        let facts = agent.store.facts.current
        #expect(facts.map(\.identity.subject) == ["entity", "tests", "task"])
        #expect(facts.first { $0.identity.subject == "tests" }?.value == "green again")
        let entity = try #require(facts.first)
        #expect(entity.proposed && entity.source == .model && entity.method == .distilled)
        #expect(entity.detail == "the person said, turn 1" && entity.entries == [2, 3])
        #expect(agent.factView.groups.count == 3)
        // The question's request carries them, after the instructions and the kept turn, as a record.
        let question = Array(requests[3].transcript)
        #expect(FactFrame.isFrame(question[1]))
        let earlier = ConversationStore.text(of: question[1])
        #expect(earlier.contains("- entity release codename: BLUE HERON [model, distilled: the person said, turn 1]"))
        #expect(earlier.contains("- tests ci: green again"))
        let now = try #require(question.last { FactFrame.isFrame($0) })
        #expect(ConversationStore.text(of: now).contains("- task: add a --dry-run flag to harbour sync"))
        // The distilling call is not in the conversation, and it is audited with what it recorded.
        #expect(!agent.store.entries.contains { ConversationStore.text(of: $0.value).contains("You keep a record") })
        let event = try #require(sink.events.first { $0.kind == .distillation })
        #expect(event.details["turns"] == [1] && event.details["entries"] == 2 && event.details["failure"] == nil)
        #expect(event.details["facts"]?.arrayValue?.count == 3)
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .distillation)))
        let kinds = sink.events.map(\.kind)
        let condensed = try #require(kinds.firstIndex(of: .condensation))
        #expect(kinds.firstIndex(of: .distillation).map { $0 > condensed } == true)
        #expect(sink.events.filter { $0.kind == .factRecorded }.count == 3)
        for event in sink.events where event.kind == .factRecorded {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .factRecorded)))
        }
    }

    @Test func aFailedDistillationIsAuditedAndTheTurnGoesOn() async throws {
        let model = ScriptedModel(
            steps: [.say("a"), .say("b"), .say("c")], capabilities: [.toolCalling])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        for prompt in ["one", "two", "three"] { _ = try await agent.respond(to: prompt + Self.long) }
        #expect(model.script.requests.withLock { $0.count } == 3, "no distilling request was made")
        let event = try #require(sink.events.first { $0.kind == .distillation })
        #expect(event.details["failure"]?.stringValue?.isEmpty == false && event.details["facts"] == [])
        #expect(agent.store.facts.facts.isEmpty && agent.condensations == 1)
        // Switched off, nothing is asked or audited.
        let off = ScriptedModel(steps: [.say("a"), .say("b"), .say("c")])
        let quiet = MemoryAuditSink()
        let plain = Self.agent(off, sink: quiet)
        plain.facts?.distils = false
        for prompt in ["one", "two", "three"] { _ = try await plain.respond(to: prompt + Self.long) }
        #expect(!quiet.events.contains { $0.kind == .distillation } && off.script.requests.withLock { $0.count } == 3)
    }

    @Test func thePromptIsBoundedAndListsKnownIdentities() {
        let turns = (1...40).map {
            FactDistiller.Turn(
                number: $0, prompt: String(repeating: "p", count: 2000), reply: String(repeating: "r", count: 2000))
        }
        let existing = (1...60).map { FactIdentity.Key(subject: "file", name: "f\($0)") }
        let prompt = FactDistiller.prompt(turns: turns, kinds: .defaults, existing: existing, budgetBytes: 12_000)
        #expect(prompt.contains("- file f40") && !prompt.contains("- file f41"))
        #expect(prompt.utf8.count < 12_000 + 5_000, "\(prompt.utf8.count)")
        // Each text is cut to its share, never below 120 characters.
        let line = prompt.split(separator: "\n").first { $0.hasPrefix("Turn 1, the person: ") }
        #expect(line.map { $0.count <= 20 + 151 } == true)
    }

    @Test func turnsAreReadFromPromptsAndReplies() {
        let store = ConversationStore(
            carrying: Transcript(entries: [
                .instructions(.init(segments: [.text(.init(content: "i"))], toolDefinitions: [])),
                .prompt(.init(segments: [.text(.init(content: "q1"))])),
                .response(.init(assetIDs: [], segments: [.text(.init(content: "a1"))])),
                .response(.init(assetIDs: [], segments: [.text(.init(content: "a1b"))])),
                .prompt(.init(segments: [.text(.init(content: "q2"))])),
            ]))
        let turns = FactDistiller.turns(in: store.entries)
        #expect(turns == [.init(number: 1, prompt: "q1", reply: "a1\na1b"), .init(number: 2, prompt: "q2", reply: "")])
    }
}
