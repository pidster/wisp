import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// `Agent` over the scripted model: every path that used to need Apple's model.
@Suite struct AgentTests {
    private func agent(
        steps: [ScriptedModel.Step] = [.say("hello there")], overflowOnce: Bool = false, partial: String = "",
        sink: MemoryAuditSink = MemoryAuditSink()
    ) -> Agent {
        Agent(
            instructions: "be brief", tools: [CurrentDateTool()],
            model: ResolvedModel(
                selection: .system,
                custom: ScriptedModel(steps: steps, overflowOnce: overflowOnce, partialBeforeOverflow: partial)),
            audit: AuditLog(session: "a", sink: sink))
    }

    @Test func tokenTotalsSurviveTheSessionBeingReplacedMidTurn() async throws {
        // Each scripted request reports 40 input tokens and one output token per word. A condensation ahead
        // of the window, an overflow retry, and a reset each start a session whose own count is zero; the
        // agent's total carries the old one, so a turn's difference is that turn's tokens and never falls.
        let scripted = ScriptedModel(steps: [.say("one"), .say("two"), .say("three"), .say("four")])
        let windowed = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: scripted, contextSize: 50),
            contextPolicy: .condense(keepTurns: 0))
        #expect(windowed.tokensUsed == TurnTokens(input: 0, output: 0))
        _ = try await windowed.respond(to: "first")
        #expect(windowed.tokensUsed == TurnTokens(input: 40, output: 1))
        // The second prompt is condensed ahead, which replaces the session before the request.
        let condensed = try await windowed.respond(to: "second prompt that is long enough to count")
        #expect(condensed.condensed)
        #expect(windowed.tokensUsed == TurnTokens(input: 80, output: 2))
        // An overflow on the next request: the retry runs on a fresh session.
        scripted.script.overflowOnce.withLock { $0 = true }
        let before = windowed.tokensUsed
        _ = try await windowed.respond(to: "third")
        let after = windowed.tokensUsed
        #expect(TurnTokens.between(before, after) == TurnTokens(input: 40, output: 1))
        // Starting over keeps the total.
        windowed.reset()
        #expect(windowed.tokensUsed == after)
        _ = try await windowed.respond(to: "fourth")
        #expect(TurnTokens.between(after, windowed.tokensUsed) == TurnTokens(input: 40, output: 1))
    }

    @Test func respondReturnsTextAndAdvancesTheClock() async throws {
        let sink = MemoryAuditSink()
        let agent = agent(steps: [.say("one"), .say("two")], sink: sink)
        #expect(try await agent.respond(to: "a") == .init(text: "one", condensed: false))
        #expect(try await agent.respond(to: "b") == .init(text: "two", condensed: false))
        #expect(agent.turns.current == 2)
        #expect(sink.events.map(\.turn) == [1, 1, 2, 2])
        #expect(agent.transcript.turnCount == 2)
        #expect(try await agent.contextTokens() == 40)  // the scripted runtime's report
    }

    @Test func streamRecoversFromOverflowAndReportsCondensed() async throws {
        // The first request streams "Hel" then overflows. The framework discards what the failed
        // request streamed, so the caller sees only the retry's text, and the reply says it condensed.
        let agent = agent(steps: [.say("Hello again")], overflowOnce: true, partial: "Hel")
        var seen: [String] = []
        let reply = try await agent.stream("hi") { seen.append($0) }
        #expect(reply.text == "Hello again" && reply.condensed)
        // The scripted overflow reports a 10-token window, which even the floor cannot fit under its target, so
        // the reply carries the note for the person; the retry, the one exact check, still answers.
        #expect(reply.contextNote?.hasPrefix("The context could not be condensed to its target") == true)
        #expect(seen.joined() == "Hello again")
        #expect(agent.condensations == 1)
    }

    @Test func streamSeparatesASnapshotThatDoesNotContinueTheShownText() async throws {
        // Three fragments, the middle one a cumulative snapshot that is not a prefix of the last.
        let agent = agent(steps: [.say("Hello wide world")])
        var seen: [String] = []
        let reply = try await agent.stream("hi") { seen.append($0) }
        #expect(reply.text == "Hello wide world")
        #expect(seen.joined() == "Hello wide world")
    }

    @Test func overflowWithoutACondensePolicyIsRethrown() async {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(overflowOnce: true)),
            contextPolicy: .failFast)
        await #expect(throws: LanguageModelError.self) { try await agent.respond(to: "hi") }
    }

    @Test func errorsAreAuditedAndRethrown() async {
        let sink = MemoryAuditSink()
        // Asking for a tool the session does not have is a framework error.
        let agent = agent(steps: [.call(name: "nope", arguments: "{}")], sink: sink)
        await #expect(throws: (any Error).self) { try await agent.respond(to: "hi") }
        #expect(sink.events.map(\.kind) == [.prompt, .error])
        #expect(sink.events.last?.details["context"] == "turn")
    }

    @Test func resetStartsOverAndRecordsIt() async throws {
        let sink = MemoryAuditSink()
        let agent = agent(steps: [.say("one"), .say("two")], sink: sink)
        _ = try await agent.respond(to: "a")
        agent.reset()
        #expect(agent.transcript.turnCount == 0)
        let restart = sink.events.last
        #expect(restart?.kind == .sessionStart)
        #expect(restart?.details["reason"] == "new")
        #expect(restart?.details["tools"] == .array(["current_date"]))
        #expect(restart?.details["model"] == "system")
        _ = try await agent.respond(to: "b")
        #expect(agent.transcript.turnCount == 1)
    }

    @Test func aModelThatReportsNoUsageIsCondensedAheadFromItsOwnCount() async throws {
        // The on-device model reports no usage but can count its transcript; on 2026-09-29 it reached 91% of
        // its 8,192-token window without condensing, then overflowed.
        let sink = MemoryAuditSink()
        let counting = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(
                selection: .system, custom: ScriptedModel(steps: [.say("one"), .say("two")], reportsUsage: false),
                contextSize: 50, countTokens: { transcript in transcript.turnCount * 45 }),
            contextPolicy: .condense(keepTurns: 0), audit: AuditLog(session: "a", sink: sink))
        #expect(try await counting.respond(to: "first").text == "one")
        #expect(counting.lastInputTokens == 0)
        let reply = try await counting.respond(to: "second")
        #expect(reply.condensed && counting.condensations == 1)
        #expect(sink.events.first { $0.kind == .condensation }?.details["reason"] == "budget")
    }

    @Test func anOverflowIsRecognisedFromTheOnDeviceModelsMessageToo() {
        struct Inference: Error, CustomStringConvertible {
            var description: String {
                "Provided 8,913 tokens, but the maximum allowed is 8,192.: The operation couldn’t be completed. "
                    + "(TokenGenerationInference.DecoderModelError error 3.)::inferenceFailed"
            }
        }
        let parsed = Agent.overflow(in: Inference())
        #expect(parsed?.contextSize == 8192 && parsed?.tokenCount == 8913)
        let framework = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 10, tokenCount: 11, debugDescription: "x", metadata: [:]))
        #expect(Agent.overflow(in: framework)?.contextSize == 10)
        #expect(Agent.overflow(in: CancellationError()) == nil)
    }

    @Test func condensationsSaveTheContextBeforeAndAfterAndChatSavesItOnRequest() async throws {
        let sink = MemoryAuditSink()
        let directory = FileManager.default.temporaryDirectory.appending(path: "wisp-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = Agent(
            instructions: "Be brief.", tools: [],
            model: ResolvedModel(
                selection: .system, custom: ScriptedModel(steps: [.say("one"), .say("two")]), contextSize: 50),
            contextPolicy: .condense(keepTurns: 0), audit: AuditLog(session: "s", sink: sink))
        agent.archive = ContextArchive(directory: directory, session: "s")
        _ = try await agent.respond(to: "remember BLUE HERON")
        _ = try await agent.respond(to: "second prompt that is long enough to count")
        let event = try #require(sink.events.first { $0.kind == .condensation })
        let before = try String(
            contentsOfFile: try #require(event.details["savedBefore"]?.stringValue), encoding: .utf8)
        let after = try String(contentsOfFile: try #require(event.details["savedAfter"]?.stringValue), encoding: .utf8)
        #expect(before.hasPrefix("# Context: 1 turn\n") && before.contains("remember BLUE HERON"), "\(before)")
        #expect(before.contains("## Instructions\n\nBe brief.") && before.contains("## Response\n\none"))
        #expect(after.hasPrefix("# Context: 0 turns") && !after.contains("BLUE HERON"), "\(after)")
        let json = event.details["savedBefore"]?.stringValue?.replacingOccurrences(of: ".md", with: ".json") ?? ""
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(filePath: json)))
        #expect(decoded.turnCount == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: json)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(AuditEvent.fields(for: .condensation).isSuperset(of: Set(event.details.keys)))
    }

    @Test func condensesAheadOfAKnownWindowFromReportedUsage() async throws {
        // The scripted model reports 40 input tokens per request. On a 50-token window at the default
        // 85% budget the second prompt (40 + a little) passes it, so the transcript is condensed first;
        // keeping zero turns makes the shrink visible.
        let sink = MemoryAuditSink()
        let windowed = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(
                selection: .system, custom: ScriptedModel(steps: [.say("one"), .say("two"), .say("three")]),
                contextSize: 50),
            contextPolicy: .condense(keepTurns: 0), audit: AuditLog(session: "a", sink: sink))
        #expect(windowed.contextSize == 50)
        #expect(windowed.lastInputTokens == 0)
        #expect(try await windowed.contextTokens() == nil)
        #expect(try await windowed.respond(to: "first").text == "one")
        #expect(windowed.lastInputTokens == 40)
        #expect(try await windowed.contextTokens() == 40)
        #expect(windowed.condensations == 0)
        let reply = try await windowed.respond(to: "second prompt that is long enough to count")
        #expect(reply.text == "two" && reply.condensed)
        #expect(windowed.condensations == 1)
        let event = sink.events.first { $0.kind == .condensation }
        #expect(event?.details["reason"] == "budget")
        #expect(event?.details["contextSize"] == 50)
        #expect(event?.details["turnsBefore"] == 1 && event?.details["turnsAfter"] == 0)
        // The third prompt finds one turn again and drops it again; only the third turn remains.
        _ = try await windowed.respond(to: "third prompt, also long enough to pass the budget")
        #expect(windowed.condensations == 2)
        #expect(windowed.transcript.turnCount == 1)
        // Condensing that cannot shrink the transcript is skipped: one turn kept from one turn.
        let keeping = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(
                selection: .system, custom: ScriptedModel(steps: [.say("a"), .say("b")]), contextSize: 50),
            contextPolicy: .condense(keepTurns: 1))
        _ = try await keeping.respond(to: "p")
        _ = try await keeping.respond(to: "q")
        #expect(keeping.condensations == 0 && keeping.transcript.turnCount == 2)
        // A generous budget, an unknown window, or a fail-fast policy never condenses ahead.
        let relaxed = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(
                selection: .system, custom: ScriptedModel(steps: [.say("a"), .say("b")]), contextSize: 50))
        relaxed.contextBudget = 2
        _ = try await relaxed.respond(to: "p")
        _ = try await relaxed.respond(to: "q")
        #expect(relaxed.condensations == 0)
        let unknown = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("a"), .say("b")])))
        #expect(unknown.contextSize == nil)
        _ = try await unknown.respond(to: "p")
        _ = try await unknown.respond(to: "q")
        #expect(unknown.condensations == 0)
        // An overflow teaches the window and is audited with its own reason.
        let overflowing = agent(steps: [.say("after")], overflowOnce: true, sink: sink)
        _ = try await overflowing.respond(to: "p")
        #expect(overflowing.contextSize == 10)
        #expect(sink.events.last { $0.kind == .condensation }?.details["reason"] == "overflow")
    }

    @Test func resumesATranscriptOnAResolvedModel() async throws {
        let first = agent(steps: [.say("one")])
        _ = try await first.respond(to: "a")
        let resumed = Agent(
            transcript: first.transcript, tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("two")])))
        #expect(resumed.transcript.turnCount == 1)
        #expect(try await resumed.respond(to: "b").text == "two")
        #expect(resumed.transcript.turnCount == 2)
    }
}
