import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The running summary (phase 4b of the layered-context proposal, decision D1): written by the conversation's
/// model when enough dropped turns have accumulated, in a call of its own or in the facts' call, each version
/// the one before plus the new turns, carried at the end of the earlier block, audited, and never failing
/// the turn.
@Suite struct RunningSummaryTests {
    /// An agent that keeps facts and condenses to the last turn once a prompt passes a 60-token window.
    static func agent(_ model: ScriptedModel, sink: MemoryAuditSink, together: Bool = false) -> Agent {
        let agent = Agent(
            instructions: "You are wisp.", tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 60),
            contextPolicy: .condense(keepTurns: 1), audit: AuditLog(session: "s", sink: sink))
        agent.facts = FactSettings(summaryWithFacts: together)
        return agent
    }

    /// A suffix that makes a prompt pass the budget of the 60-token window, so the turn condenses first.
    static let long = " This sentence makes the prompt long enough to pass the budget of the tiny window."

    /// The distiller's answer with one fact.
    static let facts = #"{"facts":[{"subject":"entity","name":"codename","value":"BLUE HERON","speaker":"person"}]}"#

    @Test func aCondensationThatDropsABatchWritesTheSummaryInACallOfItsOwnAfterTheFacts() async throws {
        let model = ScriptedModel(steps: [
            .say("a"), .say("b"), .say("c"), .say("d"), .say(Self.facts),
            .say("The person counted one, two, and three; the assistant answered a, b, and c."), .say("e"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        for prompt in ["one", "two", "three", "four"] { _ = try await agent.respond(to: prompt) }
        let reply = try await agent.respond(to: "five" + Self.long)
        #expect(reply.text == "e" && reply.condensed)
        let requests = model.script.requests.withLock { $0 }
        try #require(requests.count == 7)
        // The facts' call first, then the summary's: plain text, greedy, bounded, in a session of its own.
        #expect(requests[4].schema != nil)
        let summarising = requests[5]
        #expect(summarising.schema == nil)
        #expect(summarising.generationOptions.maximumResponseTokens == 512 / 4 * 2)
        let asked = Array(summarising.transcript)
        guard case .instructions(let instructions) = asked.first else {
            Issue.record("the summary has its own instructions")
            return
        }
        #expect(ContextArchive.text(instructions.segments).hasPrefix("You keep a running summary"))
        let prompt = ThreadRecord.text(of: try #require(asked.last))
        #expect(prompt.hasPrefix("There is no summary yet.\n\nThe turns to add, in order:\nTurn 1, the person: one"))
        #expect(prompt.contains("Turn 3, the assistant: c") && !prompt.contains("Turn 4"))
        #expect(prompt.hasSuffix("Write the updated summary in at most 73 words."))
        // The store keeps the version with what it covers.
        let summary = try #require(agent.store.summary)
        #expect(summary.version == 1 && summary.covered == 3 && summary.turns == [1, 2, 3] && summary.turn == 5)
        #expect(summary.entries == [2, 3, 4, 5, 6, 7] && summary.through == 7 && summary.model == "system")
        #expect(summary.audit.count == 6)
        // The next request carries it at the end of the earlier block, after the facts, before the kept turn.
        let question = Array(requests[6].transcript)
        #expect(FactFrame.isFrame(question[1]))
        let earlier = ThreadRecord.text(of: question[1]).split(separator: "\n").map(String.init)
        #expect(earlier.first == FactFrame.earlierHeader)
        #expect(earlier[1].hasPrefix("- entity codename: BLUE HERON"))
        #expect(
            Array(earlier.suffix(2)) == [
                FactFrame.summaryHeader(covering: 3),
                "The person counted one, two, and three; the assistant answered a, b, and c.",
            ])
        #expect(ThreadRecord.text(of: question[2]) == "four")
        // Audited after the distillation, with the fields documented for it.
        let event = try #require(sink.events.first { $0.kind == .summary })
        #expect(event.details["version"] == 1 && event.details["covered"] == 3 && event.details["combined"] == false)
        #expect(
            event.details["turns"] == [1, 2, 3] && event.details["entries"] == 6 && event.details["failure"] == nil)
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .summary)))
        let kinds = sink.events.map(\.kind)
        #expect((kinds.firstIndex(of: .distillation) ?? kinds.endIndex) < (kinds.firstIndex(of: .summary) ?? 0))
        // The turn list says so.
        #expect(ContextView.turns(of: agent).last?.changes == "condensed 6, summarised 1")
    }

    @Test func droppedTurnsWaitForABatchAndEachVersionAddsToTheOneBefore() async throws {
        let empty = #"{"facts":[]}"#
        let model = ScriptedModel(steps: [
            .say("a"), .say("b"),
            .say(empty), .say("c"),
            .say(empty), .say("d"),
            .say(empty), .say("First, turns one to three."), .say("e"),
            .say(empty), .say("f"),
            .say(empty), .say("g"),
            .say(empty), .say("First, turns one to three. Then four to six."), .say("h"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        _ = try await agent.respond(to: "one")
        _ = try await agent.respond(to: "two")
        for prompt in ["three", "four"] {
            _ = try await agent.respond(to: prompt + Self.long)
            #expect(agent.store.summary == nil, "one or two dropped turns wait")
        }
        _ = try await agent.respond(to: "five" + Self.long)
        let first = try #require(agent.store.summary)
        #expect(first.version == 1 && first.turns == [1, 2, 3] && first.text == "First, turns one to three.")
        for prompt in ["six", "seven", "eight"] { _ = try await agent.respond(to: prompt + Self.long) }
        let second = try #require(agent.store.summary)
        #expect(second.version == 2 && second.covered == 6 && second.turns == [4, 5, 6])
        #expect(agent.store.summaries.count == 2 && agent.store.summaries.first == first)
        // The second call was shown the first version before the new turns.
        let prompts = model.script.requests.withLock { $0 }.filter { $0.schema == nil }.map {
            ThreadRecord.text(of: Array($0.transcript).last ?? .prompt(.init(segments: [])))
        }
        let update = try #require(prompts.first { $0.hasPrefix("The summary so far") })
        #expect(update.hasPrefix("The summary so far, of 3 earlier turns:\nFirst, turns one to three.\n\n"))
        #expect(update.contains("Turn 4, the person: four") && !update.contains("Turn 3, the person"))
        #expect(sink.events.filter { $0.kind == .summary }.count == 2)
        #expect(sink.events.filter { $0.kind == .distillation }.count == 6)
    }

    @Test func anEmptyOrFailedSummaryLeavesTheOneBeforeAndTheTurnGoesOn() async throws {
        let model = ScriptedModel(steps: [
            .say("a"), .say("b"), .say("c"), .say("d"), .say(#"{"facts":[]}"#), .say(""), .say("e"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        for prompt in ["one", "two", "three", "four"] { _ = try await agent.respond(to: prompt) }
        #expect(try await agent.respond(to: "five" + Self.long).text == "e")
        #expect(agent.store.summary == nil && agent.store.unsummarised.count == 6, "the batch waits for the next")
        let event = try #require(sink.events.first { $0.kind == .summary })
        #expect(event.details["failure"] == "the model wrote no summary" && event.details["version"] == nil)
        // In the facts' call, on a model that cannot answer in a schema: both audited as failed, nothing kept.
        let plain = ScriptedModel(
            steps: [.say("a"), .say("b"), .say("c"), .say("d"), .say("e")], capabilities: [.toolCalling])
        let quiet = MemoryAuditSink()
        let together = Self.agent(plain, sink: quiet, together: true)
        for prompt in ["one", "two", "three", "four"] { _ = try await together.respond(to: prompt) }
        #expect(try await together.respond(to: "five" + Self.long).text == "e")
        #expect(together.store.summary == nil && plain.script.requests.withLock { $0.count } == 5)
        let failed = quiet.events.filter { $0.kind == .summary || $0.kind == .distillation }
        #expect(failed.count == 2 && failed.allSatisfy { $0.details["failure"] != nil })
    }

    @Test func togetherTheFactsAndTheSummaryComeFromOneCall() async throws {
        let answer =
            #"{"facts":[{"subject":"entity","name":"codename","value":"BLUE HERON","speaker":"person"}],"#
            + #""summary":"The person gave the codename, then counted."}"#
        let model = ScriptedModel(steps: [.say("a"), .say("b"), .say("c"), .say("d"), .say(answer), .say("e")])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink, together: true)
        for prompt in ["The codename is BLUE HERON.", "two", "three", "four"] {
            _ = try await agent.respond(to: prompt)
        }
        _ = try await agent.respond(to: "five" + Self.long)
        let requests = model.script.requests.withLock { $0 }
        try #require(requests.count == 6)
        let call = requests[4]
        #expect(call.schema != nil)
        #expect(call.generationOptions.maximumResponseTokens == FactDistiller.maximumResponseTokens + 256)
        guard case .instructions(let instructions) = Array(call.transcript).first else {
            Issue.record("the call has its own instructions")
            return
        }
        #expect(ContextArchive.text(instructions.segments).contains("Then write the running summary"))
        let prompt = ThreadRecord.text(of: try #require(Array(call.transcript).last))
        #expect(prompt.contains("There is no summary yet.\n\nThe turns:\nTurn 1, the person: The codename is"))
        #expect(prompt.hasSuffix("Give the facts, then the updated summary of the turns above in at most 73 words."))
        #expect(agent.store.summary?.text == "The person gave the codename, then counted.")
        #expect(agent.store.facts.current.map(\.value) == ["BLUE HERON"])
        let summary = try #require(sink.events.first { $0.kind == .summary })
        let distillation = try #require(sink.events.first { $0.kind == .distillation })
        #expect(summary.details["combined"] == true && distillation.details["facts"]?.arrayValue?.count == 1)
    }

    @Test func switchedOffNothingIsWrittenOrCarried() async throws {
        let model = ScriptedModel(steps: [.say("a"), .say("b"), .say("c"), .say("d"), .say(#"{"facts":[]}"#)])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        agent.summarises = false
        for prompt in ["one", "two", "three", "four"] { _ = try await agent.respond(to: prompt) }
        _ = try await agent.respond(to: "five" + Self.long)
        #expect(model.script.requests.withLock { $0.count } == 6 && agent.store.summary == nil)
        #expect(!sink.events.contains { $0.kind == .summary })
        // A summary already in the store is not carried while the switch is off.
        agent.store.summarise(SummaryWriterTests.version(1, "Earlier work."))
        agent.summarises = false
        #expect(!agent.transcript.contains { ThreadRecord.text(of: $0).contains("Earlier work.") })
        agent.summarises = true
        #expect(agent.transcript.contains { ThreadRecord.text(of: $0).contains("Earlier work.") })
        // An agent that keeps no facts writes none.
        let bare = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: []), contextSize: 60),
            contextPolicy: .condense(keepTurns: 1))
        #expect(bare.summaryBatch(leaving: agent.store.entries) == nil)
    }
}
