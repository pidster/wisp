import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Context checkpoint 2 without a model (docs/proposals/2026-10-06-context-checkpoint-2.md): the sustained scenario
/// and its fixtures, an estimate that it condenses at the default budget where `recalling` does not, the plan read
/// from the environment and its cells, the model switch carrying the store, and the table's row. `harness/Evals`'s
/// `ContextCheckpointTests` runs the same cells on real models.
@Suite struct ContextCheckpointPlanTests {
    /// Runs `scenario` through references and condensing to `target` on a scripted model with the on-device window,
    /// replying two sentences to each step and one line to each question, and counting three bytes a token plus 260
    /// for the tool definitions the count of the transcript leaves out. Calibrated on 2026-10-06 against ADR 0045's
    /// checkpoint, where `recalling` reached 6,239 and 6,511 tokens on real models without condensing: this estimate
    /// gives it 5,718.
    static func estimate(_ scenario: ContextEval.Scenario, target: ContextTarget = .default) async -> ContextEval.Run {
        var steps: [ScriptedModel.Step] = []
        let reply = String(repeating: "The file describes how the command plans and applies its changes. ", count: 4)
        for step in scenario.steps {
            if let file = step.file {
                let path = scenario.fixtures.appending(path: file).path
                steps.append(.call(name: "read_file", arguments: #"{"path":"\#(path)"}"#))
            }
            steps.append(.say(reply))
        }
        steps += scenario.questions.map { _ in .say("A short answer of about one line, as a model gives it.") }
        let resolved = ResolvedModel(
            selection: .system, custom: ScriptedModel(steps: steps, reportsUsage: false), contextSize: 8192,
            countTokens: { ContextComposer.bytes(of: $0) / 3 + 260 })
        return await ContextEval.run(
            scenario, strategy: ReferencingStrategy(policy: .target(target)), model: resolved,
            instructions: Prompting().rendered(toolsAvailable: true, memory: true),
            tools: { ToolRegistry(audit: $0).select(["read_file"]).tools })
    }

    @Test func theSustainedScenarioContinuesNotingBackOnTheTask() throws {
        let noting = ContextEval.noting()
        let scenario = ContextEval.sustained()
        #expect(scenario.name == "sustained" && scenario.summary.hasPrefix(noting.summary))
        #expect(Array(scenario.steps.prefix(noting.steps.count)) == noting.steps)
        #expect(Array(scenario.questions.prefix(noting.questions.count)) == noting.questions)
        #expect(scenario.steps.count == 29 && scenario.questions.count == 10)
        let added = scenario.steps.dropFirst(noting.steps.count)
        #expect(added.filter { $0.kind == .talk }.count == 3 && added.filter { $0.file != nil }.count == 10)
        #expect(added.filter { $0.kind == .plant }.count == 1)
        // Only the first turn and the return to the task state the task, so `restated` changes it there and only there.
        let restating = scenario.steps.indices.filter { AssessmentRules.restatesTask(scenario.steps[$0].prompt) }
        #expect(restating == [0, noting.steps.count], "\(restating)")
        #expect(ContextCheckpoint.switchTurns == [noting.steps.count + 1, scenario.steps.count + 1])
        // The late fact was said in a prompt; the reporter is in the issue alone.
        let said = ContextEval.normalised(scenario.steps.map(\.prompt).joined(separator: " "))
        let channel = try #require(scenario.questions.first { $0.id == "channel" })
        #expect(channel.score(said) == .correct)
        let reporter = try #require(scenario.questions.first { $0.id == "reporter" })
        #expect(reporter.probe == .detail && reporter.score(said) == .wrong)
    }

    @Test func theNewFixturesAreOnePageEachAndHoldOnlyTheirOwnAnswer() throws {
        let scenario = ContextEval.sustained()
        let original = Set(ContextEval.noting().files)
        for file in Set(scenario.files).subtracting(original) {
            let path = scenario.fixtures.appending(path: file).path
            #expect(try !FileReader().read(path: path).hasMore, "\(file) needs more than one read_file page")
            let text = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!text.contains(scenario.files[0]), "\(file) names the first file read")
            for question in scenario.questions where question.probe != .changedFact {
                let held = question.score(text) == .correct
                #expect(
                    held == (question.id == "reporter" && file == "harbour-issue-212.md"), "\(file): \(question.id)")
            }
        }
    }

    @Test func itCondensesAtTheDefaultBudgetWhereRecallingDoesNot() async {
        let recalling = await Self.estimate(ContextEval.recalling())
        #expect(recalling.condensations == 0, "\(recalling.report)")
        let sustained = await Self.estimate(ContextEval.sustained())
        let first = sustained.firstCondensation ?? 0
        #expect(sustained.condensations >= 1 && first > ContextEval.noting().steps.count, "\(sustained.report)")
        #expect(sustained.floors == 0 && sustained.turns.flatMap(\.condensations).allSatisfy { $0 == "budget" })
        // The grid moves it: a higher target condenses at least as often as a lower one.
        let low = await Self.estimate(ContextEval.sustained(), target: ContextTarget(share: 0.4, headroomTurns: 8))
        let high = await Self.estimate(ContextEval.sustained(), target: ContextTarget(share: 0.6, headroomTurns: 8))
        #expect(high.condensations >= low.condensations && high.fills.min() ?? 0 > low.fills.max() ?? 0)
    }

    @Test func theCheckpointIsReadFromTheEnvironment() throws {
        #expect(try ContextCheckpoint.parse([:]) == nil)
        #expect(try ContextCheckpoint.parse(["WISP_CHECKPOINT": " "]) == nil)
        let all = try #require(try ContextCheckpoint.parse(["WISP_CHECKPOINT": "all"]))
        #expect(all.parts == ContextCheckpoint.Part.allCases && all.targets == [0.4, 0.5, 0.6])
        #expect(all.headrooms == [0, 1, 8] && all.window == 8192 && all.runs == 1)
        #expect(
            all.switchPlans == [
                [.init(model: .system), .init(model: .ollama("granite4.1:8b")), .init(model: .system)],
                [.init(model: .ollama("granite4.1:8b"), window: 32768), .init(model: .system)],
            ])
        let some = try #require(
            try ContextCheckpoint.parse([
                "WISP_CHECKPOINT": "memory, grid", "WISP_CHECKPOINT_TARGETS": "0.5", "WISP_CHECKPOINT_HEADROOMS": "8,2",
                "WISP_CHECKPOINT_WINDOW": "16384", "WISP_CHECKPOINT_RUNS": "3",
                "WISP_CHECKPOINT_SWITCHES": "ollama:gemma4:12b@65536>ollama:granite4.1:8b",
            ]))
        #expect(some.parts == [.grid, .memory] && some.targets == [0.5] && some.headrooms == [8, 2])
        #expect(some.window == 16384 && some.runs == 3)
        #expect(some.switchPlans.map { $0.map(\.spelling) } == [["ollama:gemma4:12b@65536", "ollama:granite4.1:8b"]])
        for (variable, value) in [
            ("WISP_CHECKPOINT", "grid,sometimes"), ("WISP_CHECKPOINT_TARGETS", "1.5"),
            ("WISP_CHECKPOINT_HEADROOMS", "-1"), ("WISP_CHECKPOINT_WINDOW", "100"), ("WISP_CHECKPOINT_RUNS", "0"),
            ("WISP_CHECKPOINT_SWITCHES", "system"), ("WISP_CHECKPOINT_SWITCHES", "system>gpt"),
        ] {
            var environment = ["WISP_CHECKPOINT": "grid"]
            environment[variable] = value
            #expect(throws: ContextCheckpoint.Failure.self, "\(variable)=\(value)") {
                try ContextCheckpoint.parse(environment)
            }
        }
    }

    @Test func theCellsAnswerEachQuestion() {
        let checkpoint = ContextCheckpoint()
        let grid = checkpoint.cells(.grid)
        #expect(grid.count == 9 && grid.first?.label == "t40-h0" && grid.last?.label == "t60-h8")
        #expect(grid.allSatisfy { $0.scenario.name == "sustained" && $0.strategy.name == "memory-target" })
        let half = checkpoint.cells(.half)
        #expect(half.map(\.label) == ["half-stack", "half-no-memory", "half-fixed", "half-dropping"])
        #expect(half.map(\.strategy.name) == ["memory-target", "summary-target", "memory", "dropping"])
        #expect(half.allSatisfy { $0.scenario.name == "recalling" })
        // The memory part's cell with memory is the grid's default cell, so a run of both does it once.
        let memory = checkpoint.cells(.memory)
        #expect(memory.map(\.label) == ["t50-h8", "memory-off"] && grid.contains { $0.label == "t50-h8" })
        #expect(memory.map(\.strategy.hasMemory) == [true, false])
        let assessment = checkpoint.cells(.assessment)
        #expect(assessment.map(\.label) == ["assess-off", "assess-any", "assess-restated"])
        #expect(
            assessment.map(\.strategy.name) == ["memory-target", "assessing-target", "assessing-restated-target"])
        #expect(assessment.allSatisfy(\.allTools) && checkpoint.cells(.switches).isEmpty)
        let model = ResolvedModel(selection: .system, custom: ScriptedModel(steps: []), contextSize: 8192)
        let cell = ContextCheckpoint.switchCell(
            [.init(model: .system), .init(model: .ollama("granite4.1:8b"))], models: [model, model])
        #expect(cell.label == "switch system>ollama:granite4.1:8b" && cell.strategy.name == "memory-target-switched")
        #expect(cell.strategy.summary.hasSuffix("; the model switched before turn 16 (system)"))
    }

    @Test func aSwitchContinuesTheStoreAndSettingsOnTheNextModel() async throws {
        let fixtures = ContextEval.fixturesDirectory
        let path = fixtures.appending(path: "harbour.toml").path
        let scenario = ContextEval.Scenario(
            name: "tiny", fixtures: fixtures,
            steps: [
                ContextEval.Step(kind: .plant, prompt: "The codename for this release is BLUE HERON."),
                ContextEval.Step(kind: .read, prompt: "Use read_file to read \(path).", file: "harbour.toml"),
            ],
            questions: [
                ContextEval.Question(
                    id: "codename", probe: .fact, prompt: "What is the codename?", check: .mentions(["blue heron"]))
            ])
        let first = ScriptedModel(steps: [.say("Noted.")])
        let second = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(path)"}"#), .say("Read."), .say("BLUE HERON."),
        ])
        let next = ResolvedModel(selection: .ollama("granite4.1:8b"), custom: second, contextSize: 32768)
        let strategy = SwitchingStrategy(
            base: MemoryStrategy(policy: .default), switches: [ModelSwitch(turn: 2, model: next)])
        #expect(strategy.linksToolEvents && strategy.hasMemory)
        let run = await ContextEval.run(
            scenario, strategy: strategy,
            model: ResolvedModel(selection: .system, custom: first, contextSize: 8192), instructions: "x",
            tools: { ToolRegistry(audit: $0).select(["read_file"]).tools })
        #expect(run.answers.map(\.verdict) == [.correct] && run.turns.allSatisfy { !$0.failed })
        #expect(first.script.requests.withLock { $0.count } == 1)
        // The second model's first request carries the first model's turn, from the store.
        let carried = second.script.requests.withLock { $0.first.map { Array($0.transcript) } } ?? []
        #expect(carried.contains { ThreadRecord.text(of: $0).contains("BLUE HERON") })
        #expect(run.switches.count == 1 && run.switches[0].hasPrefix("turn 2: system (window 8192) to "))
        #expect(run.switches[0].contains("ollama:granite4.1:8b (window 32768), carrying "))
        #expect(run.report.last?.hasPrefix("switched at turn 2: ") == true)
        #expect(run.measurement().notes.contains("switched at turn 2: "))
        // Tool events reach the agent the switch made: the read's facts were extracted on the second model.
        #expect(run.turns[1].tools == ["read_file"] && run.turns[1].facts > 0)
    }

    @Test func aContinuingAgentKeepsEverySetting() throws {
        let audit = AuditLog(session: "switch", sink: MemoryAuditSink())
        let source = MemorySource()
        let old = Agent(
            instructions: "x", tools: ToolRegistry(audit: audit, memory: source).select(["memory"]).tools,
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])), contextPolicy: .fixed,
            audit: audit)
        old.contextBudget = 0.5
        old.cutsPresentation = false
        old.factsShare = 0.2
        old.summaryBatchTurns = 5
        old.facts = FactSettings()
        old.memory = source
        old.toolEvents = ToolEventTrail()
        old.assessment = AssessmentSettings(tools: .all, taskChanges: .restated)
        _ = try old.stateFact(subject: "entity", name: "release codename", value: "BLUE HERON")
        let agent = SwitchingThread.continuing(
            old, on: ResolvedModel(selection: .ollama("granite4.1:8b"), custom: ScriptedModel(steps: [])))
        #expect(agent.model.selection == .ollama("granite4.1:8b") && agent.contextPolicy == .fixed)
        #expect(agent.contextBudget == 0.5 && !agent.cutsPresentation && agent.referencesOutput)
        #expect(agent.factsShare == 0.2 && agent.summaryBatchTurns == 5 && agent.facts != nil)
        #expect(agent.memory === source && agent.toolEvents === old.toolEvents && agent.assessment == old.assessment)
        #expect(agent.store.facts == old.store.facts)
        #expect(agent.factView.groups.map(\.winner.value) == old.factView.groups.map(\.winner.value))
        #expect(agent.factView.groups.contains { $0.winner.value == "BLUE HERON" })
        #expect(agent.tools.map(\.name) == ["memory"] && agent.turns === old.turns)
    }

    @Test func theScriptsTableNamesTheRowsFieldsInOrder() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../scripts/check").standardizedFileURL
        let text = try String(contentsOf: script, encoding: .utf8)
        let start = try #require(text.range(of: "CHECKPOINT_HEADER=\"$(printf '%s\\t' "))
        let end = try #require(text.range(of: " | sed", range: start.upperBound..<text.endIndex))
        let words = text[start.upperBound..<end.lowerBound].replacingOccurrences(of: "\\\n", with: " ")
        let fields = words.matches(of: #/'([^']*)'|([^\s']+)/#).map { String($0.output.1 ?? $0.output.2 ?? "") }
        #expect(fields == ContextCheckpoint.rowHeader.split(separator: "\t").map(String.init), "\(fields)")
    }

    @Test func aRowCarriesTheRunsFiguresAndItsHeaderNamesThem() {
        var condensed = ContextEval.Turn(
            number: 2, label: "read", reply: "r", failed: false, seconds: 2, tokens: 300,
            condensations: ["budget", "budget:floor"], tools: ["read_file"], distillations: [3.5])
        condensed.fills = [120, 140]
        condensed.targets = [150, 150]
        condensed.assessments = ["model run_command (1.0 s) task", "rules run_command (0.0 s)"]
        condensed.taskChanges = 1
        let run = ContextEval.Run(
            strategy: "memory-target", model: "system", window: 8192,
            turns: [
                .init(
                    number: 1, label: "plant", reply: "r", failed: false, seconds: 1, tokens: 100, condensations: [],
                    tools: []),
                condensed,
            ],
            answers: [
                .init(question: ContextEval.baseline().questions[0], reply: "Blue Heron", verdict: .correct),
                .init(question: ContextEval.baseline().questions[5], reply: "no idea", verdict: .wrong),
            ], load: (2, 3))
        #expect(run.floors == 1 && run.taskChanges == 1 && run.assessmentCalls == 1)
        let cell = ContextCheckpoint.Cell(
            part: .grid, label: "t50-h8", scenario: ContextEval.sustained(), strategy: MemoryStrategy())
        let row = ContextCheckpoint.row(run, model: .system, cell: cell, number: 1)
        let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == ContextCheckpoint.rowHeader.split(separator: "\t").count + 1)
        #expect(
            Array(fields.prefix(10)) == [
                "checkpoint row", "system", "grid", "t50-h8", "1", "1", "2", "1/1", "0/0", "wrong",
            ])
        #expect(fields[11] == "2" && fields[12] == "1" && fields[13] == "-" && fields[14] == "120")
        #expect(fields.contains("codename=correct task=wrong") && fields.last == "2-3")
    }
}
