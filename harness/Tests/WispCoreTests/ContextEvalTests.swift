import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The context eval's scenario, scoring, and runner, without a model: `ModelEvalTests` drives the same
/// code on real models, so what it measures is settled here.
@Suite struct ContextEvalScenarioTests {
    @Test func normalisesCaseSeparatorsAndThousands() {
        #expect(ContextEval.normalised("BLUE-HERON.") == "blue heron")
        #expect(ContextEval.normalised("  Ticket #4,127 ") == "ticket 4127")
        #expect(ContextEval.normalised("`--dry-run`") == "dry run")
        #expect(ContextEval.normalised("a, b") == "a b")
        #expect(ContextEval.normalised("") == "")
    }

    @Test func scoresPhrasesLeniently() {
        let codename = ContextEval.Check.mentions(["blue heron"])
        #expect(ContextEval.score("The codename is Blue Heron.", codename) == .correct)
        #expect(ContextEval.score("It's BLUE-HERON", codename) == .correct)
        #expect(ContextEval.score("I don't know the codename.", codename) == .wrong)
        #expect(ContextEval.score("It is 4,127.", .mentions(["4127"])) == .correct)
    }

    @Test func scoresTheCurrentValueOfAChangedFact() {
        let ci = ContextEval.Check.currentValue(current: ["green", "pass"], stale: ["fail"])
        #expect(ContextEval.score("The CI build is green.", ci) == .correct)
        #expect(ContextEval.score("It is passing now.", ci) == .correct)
        // Naming both, as a history, counts as current: the rule is lenient by design.
        #expect(ContextEval.score("It was failing, but it passes now.", ci) == .correct)
        #expect(ContextEval.score("The build is failing.", ci) == .stale)
        #expect(ContextEval.score("I have no information about it.", ci) == .wrong)
    }

    @Test func percentileTakesTheNearestRank() {
        #expect(ContextEval.percentile([], 0.5) == nil)
        #expect(ContextEval.percentile([3, 1, 2], 0.5) == 2)
        #expect(ContextEval.percentile([1, 2, 3, 4], 0.5) == 2)
        #expect(ContextEval.percentile(Array(1...20).map(Double.init), 0.95) == 19)
        #expect(ContextEval.percentile([5], 0) == 5)
    }

    @Test func theBaselineScenarioPlantsBeforeItAsks() {
        let scenario = ContextEval.baseline()
        #expect(scenario.steps.first?.kind == .plant)
        #expect(scenario.steps.filter { $0.kind == .change }.count == 1)
        #expect(scenario.files.count == 13)
        #expect(Set(scenario.files).count == scenario.files.count)
        // Every question's answer was said in a turn before the questions: the changed fact's current
        // value, the task, and each fact.
        let said = ContextEval.normalised(scenario.steps.map(\.prompt).joined(separator: " "))
        for question in scenario.questions {
            switch question.check {
            case .mentions(let phrases):
                if question.probe != .order {
                    #expect(phrases.contains { said.contains(ContextEval.normalised($0)) }, "\(question.id)")
                }
            case .currentValue(let current, let stale):
                #expect(current.contains { said.contains(ContextEval.normalised($0)) }, "\(question.id)")
                #expect(stale.contains { said.contains(ContextEval.normalised($0)) }, "\(question.id)")
            }
        }
        // The order question names the first file read.
        let first = scenario.questions.first { $0.probe == .order }
        #expect(first?.score(scenario.files[0]) == .correct)
        #expect(first?.score(scenario.files[1]) == .wrong)
    }

    @Test func theFixturesAreOnePageEachHoldNoAnswerAndOverflowTheWindow() throws {
        let scenario = ContextEval.baseline()
        var bytes = 0
        for file in scenario.files {
            let path = scenario.fixtures.appending(path: file).path
            let page = try FileReader().read(path: path)
            #expect(!page.hasMore, "\(file) needs more than one read_file page")
            let text = try String(contentsOfFile: path, encoding: .utf8)
            bytes += text.utf8.count
            // An answer found in a fixture could be read back rather than remembered.
            let normalised = ContextEval.normalised(text)
            for question in scenario.questions {
                let phrases: [String]
                switch question.check {
                case .mentions(let listed): phrases = listed
                case .currentValue(let current, let stale): phrases = current + stale
                }
                for phrase in phrases where question.probe != .changedFact {
                    #expect(!normalised.contains(ContextEval.normalised(phrase)), "\(file) holds \(phrase)")
                }
            }
            for other in scenario.files where other != file {
                #expect(!text.contains(other), "\(file) names \(other)")
            }
        }
        // At four bytes a token, the reads alone pass the on-device window more than once.
        #expect(bytes / 4 > 8192, "\(bytes) bytes of fixtures")
    }

    @Test func runsAScenarioThroughTodaysAgentAndScoresEveryQuestion() async throws {
        let scenario = ContextEval.baseline()
        var steps: [ScriptedModel.Step] = []
        for step in scenario.steps {
            if let file = step.file {
                let path = scenario.fixtures.appending(path: file).path
                steps.append(.call(name: "read_file", arguments: #"{"path":"\#(path)"}"#))
            }
            steps.append(.say("Noted."))
        }
        steps += [
            .say("It is Blue Heron."), .say("I don't know."), .say("Early returns."), .say("It was failing."),
            .say("harbour-sync-overview.md"), .say("Adding a --dry-run flag; I'll start with the planner."),
        ]
        // The scripted model reports 40 input tokens per request; a 60-token window puts every prompt past
        // the 85% budget, so the agent condenses whenever it holds more than four turns.
        let model = ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps), contextSize: 60)
        var seen: [Int] = []
        let run = await ContextEval.run(
            scenario, strategy: DroppingStrategy(), model: model, instructions: "Be brief.",
            tools: { ToolRegistry(audit: $0).select(["read_file"]).tools }, onTurn: { seen.append($0.number) })
        let total = scenario.steps.count + scenario.questions.count
        #expect(run.turns.count == total)
        #expect(seen == Array(1...total))
        #expect(run.strategy == "dropping" && run.model == "system" && run.window == 60)
        #expect(run.turns[1].tools == ["read_file"] && run.turns[0].tools.isEmpty)
        #expect(run.turns.allSatisfy { !$0.failed && $0.tokens == 40 })
        #expect(run.turns.prefix(5).allSatisfy { $0.condensations.isEmpty })
        #expect(run.turns[5].condensations == ["budget"])
        // Every later step's long prompt passes the budget; the shortest questions may not.
        #expect(run.turns[5..<scenario.steps.count].allSatisfy { $0.condensations == ["budget"] })
        #expect(run.condensations >= scenario.steps.count - 5)
        #expect(run.answers.map(\.verdict) == [.correct, .wrong, .correct, .stale, .correct, .correct])
        #expect(run.correct([.fact, .changedFact]) == (2, 4))
        #expect(run.report.count == 2 && run.report[0].contains("facts 2/4"), "\(run.report)")
        let measurement = run.measurement(variant: "scripted")
        #expect(measurement.task == "context.dropping.scripted")
        #expect(measurement.passed == 4 && measurement.total == 6)
        #expect(
            measurement.notes.contains("ci stale") && measurement.notes.contains("\(run.condensations) condensations"))
        #expect(measurement.p50Milliseconds != nil)
        #expect(run.turns[0].line.hasPrefix("turn 1 plant: ") && run.turns[5].line.contains("condensed budget"))
    }

    @Test func recordsAThrownTurnAsItsReplyAndCarriesOn() async throws {
        let scenario = ContextEval.Scenario(
            name: "tiny", fixtures: ContextEval.fixturesDirectory,
            steps: [ContextEval.Step(kind: .plant, prompt: "The codename is BLUE HERON.")],
            questions: [
                ContextEval.Question(
                    id: "codename", probe: .fact, prompt: "Codename?", check: .mentions(["blue heron"]))
            ])
        let run = await ContextEval.run(
            scenario, strategy: FailingStrategy(),
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])), instructions: "x",
            tools: { _ in [] })
        #expect(run.turns.count == 2 && run.turns.allSatisfy { $0.failed })
        #expect(run.turns[0].reply.hasPrefix("error: "))
        #expect(run.answers.map(\.verdict) == [.wrong])
        #expect(run.turns[0].tokens == nil)
    }
}

/// A strategy whose conversation fails every turn and cannot read its tokens, as a runtime error would.
struct FailingStrategy: ContextStrategy {
    /// `failing`.
    let name = "failing"
    /// What it does.
    let summary = "every turn throws"

    /// A conversation that always throws.
    final class Conversation: ContextConversation {
        /// The failure every turn throws.
        struct Failure: Error {}

        /// Throws.
        nonisolated(nonsending) func send(_ prompt: String) async throws -> String { throw Failure() }

        /// Nothing to read.
        nonisolated(nonsending) func occupiedTokens() async -> Int? { nil }
    }

    /// Opens the failing conversation.
    func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextConversation
    { Conversation() }
}
