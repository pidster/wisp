import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The checkpoint this process runs, read once from the environment, and the cells it has run.
enum CheckpointState {
    /// The checkpoint the environment describes; nil when it describes none or does not parse (printed).
    static let plan: ContextCheckpoint? = {
        do {
            return try ContextCheckpoint.parse(ProcessInfo.processInfo.environment)
        } catch {
            print("context checkpoint: \(error)")
            return nil
        }
    }()

    /// Whether the suite runs at all: model tests on, and a checkpoint named.
    static var enabled: Bool { ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil && plan != nil }

    /// Whether the plan includes `part`.
    static func includes(_ part: ContextCheckpoint.Part) -> Bool { plan?.parts.contains(part) == true }

    /// The cells already run in this process, as `model cell`, so a cell two parts share runs once.
    static let done = Done()

    /// A set behind a lock, for `done`.
    final class Done: Sendable {
        /// The keys.
        let keys = Mutex<Set<String>>([])

        /// Inserts `key`; false when it was there.
        func insert(_ key: String) -> Bool { keys.withLock { $0.insert(key).inserted } }
    }
}

/// Context checkpoint 2 (docs/proposals/2026-10-06-context-checkpoint-2.md) on real models: the target and headroom
/// grid on the sustained scenario at the default budget, the 50% variants under the guard, `memory` on and off, the
/// assessment off, as built, and changing the task only when restated, and model switches mid-conversation. The
/// cells, the scenario, and the row are `ContextCheckpoint` in `WispTestSupport`, tested in the gate; this suite only
/// runs them. Runs only with `WISP_MODEL_TESTS=1` and `WISP_CHECKPOINT` naming its parts, so neither the release's
/// eval nor `eval context` nor `eval compare` runs it: `scripts/check eval checkpoint` does, one test (a part) at a
/// time, printing a `checkpoint row` for each run, which the script gathers into a table.
///
/// Every part but the switches runs on each model `WISP_EVAL_MODELS` names (the on-device model without it), model
/// by model, at `WISP_CHECKPOINT_WINDOW` (8,192 by default, the on-device model's own, which the setting does not
/// change). A cell that the memory part shares with the grid (the default target and headroom) runs once.
@Suite(.enabled(if: CheckpointState.enabled), .serialized)
struct ContextCheckpointTests {
    /// The checkpoint.
    static var plan: ContextCheckpoint? { CheckpointState.plan }

    /// Whether the plan includes `part`.
    static func includes(_ part: ContextCheckpoint.Part) -> Bool { CheckpointState.includes(part) }

    /// Runs one cell `plan.runs` times on `model`, printing each turn, each run's report and row, and recording the
    /// measurement when `WISP_EVAL_RECORD` is set (variant `checkpoint.<cell>`).
    static func run(
        _ cell: ContextCheckpoint.Cell, on model: ResolvedModel, opening selection: ModelSelection
    )
        async
        throws
    {
        guard let plan, CheckpointState.done.insert("\(selection) \(cell.label)") else { return }
        for number in 1...plan.runs {
            print(
                "context checkpoint: \(cell.part.rawValue) \(cell.label) on \(selection), run \(number) of \(plan.runs)"
            )
            let run = try await ContextEvalTests.measure(
                model,
                variant: "checkpoint.\(cell.label.replacingOccurrences(of: " ", with: "-"))"
                    + (plan.runs > 1 ? ".run\(number)" : ""),
                strategy: cell.strategy, scenario: cell.scenario, allTools: cell.allTools)
            print(ContextCheckpoint.row(run, model: selection, cell: cell, number: number))
        }
    }

    /// Runs every cell of `part` on each model, model by model, so a local runtime holds one model at a time.
    static func runPart(_ part: ContextCheckpoint.Part) async throws {
        guard let plan else { return }
        let config = EvalModels.contextConfig(window: plan.window)
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: [], config: config) else {
                print("context checkpoint: \(selection) unavailable; \(part.rawValue) skipped on it")
                continue
            }
            for cell in plan.cells(part) {
                try await run(cell, on: model, opening: selection)
            }
        }
    }

    @Test(.enabled(if: includes(.grid)), .timeLimit(.minutes(1440)))
    func grid() async throws { try await Self.runPart(.grid) }

    @Test(.enabled(if: includes(.half)), .timeLimit(.minutes(1440)))
    func half() async throws { try await Self.runPart(.half) }

    @Test(.enabled(if: includes(.memory)), .timeLimit(.minutes(1440)))
    func memory() async throws { try await Self.runPart(.memory) }

    @Test(.enabled(if: includes(.assessment)), .timeLimit(.minutes(1440)))
    func assessment() async throws { try await Self.runPart(.assessment) }

    /// Each switch plan once per run: the legs resolved at their own windows (the checkpoint's when not given), the
    /// conversation opening on the first and moving at the return to the task and, for a third leg, at the first
    /// question. A plan with a leg that does not resolve is skipped, with the reason.
    @Test(.enabled(if: includes(.switches)), .timeLimit(.minutes(1440)))
    func switches() async throws {
        guard let plan = Self.plan else { return }
        for legs in plan.switchPlans {
            let models = legs.compactMap { leg in
                EvalModels.resolve(
                    leg.model, for: [], config: EvalModels.contextConfig(window: leg.window ?? plan.window))
            }
            guard models.count == legs.count, let first = legs.first else {
                print("context checkpoint: a model of \(legs.map(\.spelling).joined(separator: ">")) is unavailable")
                continue
            }
            try await Self.run(ContextCheckpoint.switchCell(legs, models: models), on: models[0], opening: first.model)
        }
    }
}
