import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// What a long conversation keeps: the context eval of the layered-context proposal
/// (docs/proposals/2026-09-29-layered-context.md, "Evaluation"), run through dropping as the baseline, and
/// through output handling (cutting presentational text) on a scenario that shows a file, through D12's
/// output handling (each tool output a reference after its turn) on both, and through facts (phase 4a) on
/// both. The scenario, scoring, and runner are `ContextEval` in `WispTestSupport`, tested in the
/// gate; this suite only drives them on real models. Needs the model; runs only with `WISP_MODEL_TESTS=1`.
///
/// The on-device model's window is 8,192 tokens. Ollama's is sized from the Mac's memory when a model is
/// selected (ADR 0043) and can be many times the scenario, so granite runs three times: at a configured
/// `contextLength` of 8,192, the comparison with the on-device model; at 32,768, which holds the whole
/// scenario, so nothing is dropped; and at the window wisp sizes for it, which is what a user gets and
/// depends on the Mac's free memory at the time (8,192 under load on 2026-09-29). All three use the default
/// config apart from that, not the operator's, so a run does not depend on `~/.wisp/config.json`.
///
/// This is a baseline measurement: the only floor is that the run completed and scored every question.
/// Suites run in parallel with the other evals under `scripts/check eval`; its turns here run serially.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil), .serialized)
struct ContextEvalTests {
    /// The Ollama model the proposal names for the comparison.
    static let ollama = ModelSelection.ollama("granite4.1:8b")

    /// Resolves granite with `contextLength`, or nil (printing why) when Ollama or the model is missing.
    static func granite(contextLength: Int?) -> ResolvedModel? {
        do {
            return try ollama.resolve(config: Config(ollama: .init(contextLength: contextLength)).resolved)
        } catch {
            print("context eval: \(ollama) unavailable, skipped: \(error)")
            return nil
        }
    }

    /// Runs `scenario` (the baseline by default) on `model` through `strategy` (dropping by default), prints
    /// each turn and the summary, and reports the measurement.
    static func measure(
        _ model: ResolvedModel, variant: String? = nil, strategy: some ContextStrategy = DroppingStrategy(),
        scenario: ContextEval.Scenario = ContextEval.baseline()
    ) async throws {
        let run = await ContextEval.run(
            scenario, strategy: strategy, model: model, instructions: Prompting().rendered,
            tools: { audit in
                let gate = ApprovalGate(
                    classifier: RuleRiskClassifier.standard,
                    approver: DenyingApprover(reason: "not during the eval"), threshold: .level(.moderate),
                    audit: audit)
                return ToolRegistry(audit: audit, approval: gate).select(["read_file"]).tools
            },
            onTurn: { print("context eval: \(strategy.name) \(model.selection) \(variant ?? ""): \($0.line)") })
        for line in run.report { print("context eval: \(line)") }
        if let summary = run.summary {
            print("context eval: summary v\(summary.version) of \(summary.covered) turns: \(summary.text)")
        }
        for answer in run.answers {
            let shown = answer.reply.replacingOccurrences(of: "\n", with: "⏎").prefix(200)
            print("context eval: \(answer.question.id) \(answer.verdict.rawValue): \(shown)")
        }
        try? Measurements.report(run.measurement(variant: variant))
        #expect(run.turns.count == scenario.steps.count + scenario.questions.count)
        #expect(run.answers.count == scenario.questions.count)
    }

    @Test func baselineOnTheOnDeviceModel() async throws {
        try await Self.measure(try ModelSelection.system.resolve())
    }

    @Test func baselineOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(model, variant: "window-8192")
    }

    /// A window that holds the whole scenario (about 18,000 tokens), so nothing is dropped: what the model
    /// recalls when every turn is still there, the ceiling dropping is measured against.
    @Test func baselineOnGraniteWithNothingDropped() async throws {
        guard let model = Self.granite(contextLength: 32768) else { return }
        try await Self.measure(model, variant: "window-32768")
    }

    @Test func baselineOnGraniteAtItsSizedWindow() async throws {
        guard let model = Self.granite(contextLength: nil) else { return }
        print("context eval: \(Self.ollama) sized window \(model.contextSize ?? 0): \(model.contextNote ?? "")")
        try await Self.measure(model, variant: "window-sized")
    }

    // Output handling (phase 3): the showing scenario, where one reply retypes a file, through dropping and
    // through cutting, on the on-device model and on granite at the same window. `--filter
    // ContextEvalTests/showing` runs these four alone.

    @Test func showingOnTheOnDeviceModelDropping() async throws {
        try await Self.measure(try ModelSelection.system.resolve(), variant: "showing", scenario: ContextEval.showing())
    }

    @Test func showingOnTheOnDeviceModelCutting() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing", strategy: CuttingStrategy(),
            scenario: ContextEval.showing())
    }

    @Test func showingOnGraniteAtTheOnDeviceWindowDropping() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(model, variant: "showing.window-8192", scenario: ContextEval.showing())
    }

    @Test func showingOnGraniteAtTheOnDeviceWindowCutting() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192", strategy: CuttingStrategy(), scenario: ContextEval.showing())
    }

    // Output handling as D12 settled it (phase 3b): exact-copy cutting and each tool output a reference after
    // its turn, on the baseline and the showing scenarios, on the on-device model and on granite at the same
    // window. `--filter ContextEvalTests/referencing` runs these four alone.

    @Test func referencingBaselineOnTheOnDeviceModel() async throws {
        try await Self.measure(try ModelSelection.system.resolve(), strategy: ReferencingStrategy())
    }

    @Test func referencingShowingOnTheOnDeviceModel() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing", strategy: ReferencingStrategy(),
            scenario: ContextEval.showing())
    }

    @Test func referencingBaselineOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(model, variant: "window-8192", strategy: ReferencingStrategy())
    }

    @Test func referencingShowingOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192", strategy: ReferencingStrategy(), scenario: ContextEval.showing())
    }

    // Facts (phase 4a): references with facts extracted from tool output, the dropped turns' prose distilled
    // into facts at each condensation, and the facts composed on the prompt side, on the baseline and the
    // showing scenarios, on the on-device model and on granite at the same window. `--filter
    // ContextEvalTests/facts` runs these four alone. The target is the on-device showing run, where references
    // alone condensed once, at the first question, and lost every early fact.

    @Test func factsBaselineOnTheOnDeviceModel() async throws {
        try await Self.measure(try ModelSelection.system.resolve(), strategy: FactsStrategy())
    }

    @Test func factsShowingOnTheOnDeviceModel() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing", strategy: FactsStrategy(),
            scenario: ContextEval.showing())
    }

    @Test func factsBaselineOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(model, variant: "window-8192", strategy: FactsStrategy())
    }

    @Test func factsShowingOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192", strategy: FactsStrategy(), scenario: ContextEval.showing())
    }

    // The same, condensing at half the window rather than 85%, so every run drops turns and distils whatever
    // size the model's reads come to; referencing at the same budget is the comparison. `--filter
    // ContextEvalTests/budget50` runs these four alone.

    @Test func budget50ReferencingShowingOnTheOnDeviceModel() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing.budget-50",
            strategy: ReferencingStrategy(budget: 0.5),
            scenario: ContextEval.showing())
    }

    @Test func budget50FactsShowingOnTheOnDeviceModel() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing.budget-50", strategy: FactsStrategy(budget: 0.5),
            scenario: ContextEval.showing())
    }

    @Test func budget50ReferencingShowingOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192.budget-50", strategy: ReferencingStrategy(budget: 0.5),
            scenario: ContextEval.showing())
    }

    @Test func budget50FactsShowingOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192.budget-50", strategy: FactsStrategy(budget: 0.5),
            scenario: ContextEval.showing())
    }

    // The running summary (phase 4b) on facts, at half the window, where condensing drops turns: written in the
    // facts' call (the default, `summary`), and in a call of its own (`summary-separate`). `--filter
    // ContextEvalTests/summary` runs these four alone.

    @Test func summarySeparateShowingOnTheOnDeviceModel() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing.budget-50",
            strategy: SummaryStrategy(together: false, budget: 0.5), scenario: ContextEval.showing())
    }

    @Test func summaryShowingOnTheOnDeviceModel() async throws {
        try await Self.measure(
            try ModelSelection.system.resolve(), variant: "showing.budget-50",
            strategy: SummaryStrategy(together: true, budget: 0.5), scenario: ContextEval.showing())
    }

    @Test func summarySeparateShowingOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192.budget-50", strategy: SummaryStrategy(together: false, budget: 0.5),
            scenario: ContextEval.showing())
    }

    @Test func summaryShowingOnGraniteAtTheOnDeviceWindow() async throws {
        guard let model = Self.granite(contextLength: 8192) else { return }
        try await Self.measure(
            model, variant: "showing.window-8192.budget-50", strategy: SummaryStrategy(together: true, budget: 0.5),
            scenario: ContextEval.showing())
    }
}
