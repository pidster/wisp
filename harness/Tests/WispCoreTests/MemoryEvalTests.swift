import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The context eval's memory additions without a model: the `recalling` scenario's detail question, the `noting`
/// scenario's fact stated in passing, `MemoryStrategy` counting memory calls and the questions' other tool calls,
/// and the count of answers that echo a fact's source.
@Suite struct MemoryEvalTests {
    @Test func theRecallingScenarioAsksForADetailOnlyTheFirstFileHolds() throws {
        let scenario = ContextEval.recalling()
        #expect(scenario.steps == ContextEval.showing().steps)
        let detail = try #require(scenario.questions.last)
        #expect(detail.id == "detail" && detail.probe == .detail && scenario.questions.count == 7)
        let first = try String(contentsOf: scenario.fixtures.appending(path: scenario.files[0]), encoding: .utf8)
        #expect(detail.score(first) == .correct)
        // No other file, and nothing said in a prompt, holds it.
        for file in scenario.files.dropFirst() {
            let text = try String(contentsOf: scenario.fixtures.appending(path: file), encoding: .utf8)
            #expect(detail.score(text) == .wrong, "\(file)")
        }
        #expect(detail.score(scenario.steps.map(\.prompt).joined(separator: " ")) == .wrong)
    }

    @Test func theNotingScenarioStatesAReleaseDateInPassingAndAsksForItLast() throws {
        let scenario = ContextEval.noting()
        #expect(scenario.questions.dropLast() == ContextEval.recalling().questions)
        let question = try #require(scenario.questions.last)
        #expect(question.id == "release-date" && question.probe == .noted)
        let stated = scenario.steps.filter { $0.prompt.contains("14 November") }
        #expect(stated.count == 1 && stated.first?.kind == .digression)
        #expect(stated.first?.file == "postmortem-08-migration-lock.md")
        #expect(question.score("The release date is 14 November.") == .correct)
        #expect(question.score("It is November 14th.") == .correct)
        // No fixture holds it.
        for file in scenario.files {
            let text = try String(contentsOf: scenario.fixtures.appending(path: file), encoding: .utf8)
            #expect(question.score(text) == .wrong, "\(file)")
        }
    }

    @Test func anAnswerThatRepeatsAFactsSourceIsCounted() {
        #expect(ContextEval.echoesSource("The codename is BLUE HERON [the person]."))
        #expect(ContextEval.echoesSource("CI is green [tool run_command, turn 11]"))
        #expect(ContextEval.echoesSource("BLUE HERON — from the person"))
        #expect(ContextEval.echoesSource("BLUE HERON - from model, noted, turn 1"))
        #expect(ContextEval.echoesSource("BLUE HERON (source: the person)"))
        #expect(!ContextEval.echoesSource("The codename is BLUE HERON, as you told me."))
        #expect(!ContextEval.echoesSource("Read [a.md] from the start."))
    }

    @Test func theMemoryStrategyRecallsAnEarlierReadAndCountsIt() async throws {
        let fixtures = ContextEval.fixturesDirectory
        let path = fixtures.appending(path: "harbour-sync-overview.md").path
        let scenario = ContextEval.Scenario(
            name: "tiny", fixtures: fixtures,
            steps: [
                ContextEval.Step(
                    kind: .read, prompt: "Use read_file to read \(path).", file: "harbour-sync-overview.md"),
                ContextEval.Step(kind: .plant, prompt: "The ticket is 4127."),
            ],
            questions: [ContextEval.recalling().questions[6]])
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(path)"}"#), .say("Read."), .say("Noted."),
            // Entry 4: after the instructions, the first prompt, and the tool call.
            .call(name: "memory", arguments: #"{"request":"recall entry 4"}"#),
            .say("From the file: {tool} [the person]"),
        ])
        let run = await ContextEval.run(
            scenario, strategy: MemoryStrategy(), model: ResolvedModel(selection: .system, custom: model),
            instructions: Prompting().rendered(toolsAvailable: true, memory: MemoryStrategy().hasMemory),
            tools: { ToolRegistry(audit: $0).select(["read_file"]).tools })
        #expect(run.strategy == "memory" && run.answers.map(\.verdict) == [.correct])
        #expect(run.memoryCalls == ["recall entry 4 -> entry found"] && run.questionCalls.isEmpty)
        #expect(run.turns[2].tools == ["memory"])
        #expect(run.turns[2].line.contains("memory [recall entry 4 -> entry found]"))
        #expect(
            run.report[1].contains("1 memory call (recall entry 4 -> entry found), 0 other tool calls in the questions")
        )
        #expect(run.echoes == 1 && run.report[0].hasSuffix("1 of 1 answers echo a fact's source"))
        let measurement = run.measurement(variant: "scripted")
        #expect(measurement.task == "context.memory.scripted" && measurement.notes.contains("detail correct"))
        #expect(measurement.notes.contains("1 memory call (") && measurement.notes.contains("1 answer echoing"))
        // References name memory.
        let requests = model.script.requests.withLock { $0 }
        let referenced = requests[3].transcript.compactMap {
            if case .toolOutput = $0 { ThreadRecord.text(of: $0) } else { nil }
        }
        #expect(referenced.first?.contains("; to see it: memory \"recall entry 4\"]") == true)
        #expect(MemoryStrategy().summary.contains("memory") && !SummaryStrategy().hasMemory)
    }
}
