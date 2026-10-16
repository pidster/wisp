import Foundation
import Synchronization
import Testing
import WispMLX
import WispTestSupport

@testable import WispCore

/// The models an eval measures, and how each case and each suite's result on one of them is bounded and reported.
///
/// `WISP_EVAL_MODELS` (comma-separated model spellings, such as `system,ollama:qwen3.8:27b`) names the models;
/// without it a suite measures the configured model, `ModelSelection.default`, exactly as a release's eval does.
/// The suites that decide delegation loop over the models, so one run compares them; `scripts/check eval compare`
/// runs those suites once per model, so a local runtime holds one model at a time (docs/measurements.md).
///
/// Floors are the release's: they apply to the configured model only, and a compared model below a floor is
/// reported, not failed. A model that is missing, refuses (no tool calling, say), throws, or runs past
/// `caseLimit` scores that case as a failure and the run goes on to the next case and the next model.
///
/// A case that fails because Apple's model service refused it (`ModelServiceFault`) never reached the model, so it is
/// counted apart (`serviceFaults`): on a model that met one, a floor is not asserted, and the configured model's run
/// fails as not measured, naming the fault and the fix, rather than reporting a low score.
enum EvalModels {
    /// The model service faults each model met in this run.
    static let serviceFaults = ServiceFaults()

    /// Model service faults counted per model, for the whole run: the service is the Mac's, so one fault puts every
    /// suite measured on that model after it in doubt.
    final class ServiceFaults: Sendable {
        /// Each model's count and its latest fault, keyed by the model's spelling.
        private let faults = Mutex<[String: (count: Int, fault: ModelServiceFault)]>([:])

        /// Counts `error` against `selection` when it is a model service fault.
        ///
        /// - Parameters:
        ///   - error: What a case threw.
        ///   - selection: The model the case ran on.
        /// - Returns: Whether it was one.
        @discardableResult
        func record(_ error: any Error, on selection: ModelSelection) -> Bool {
            guard let fault = ModelServiceFault.recognise(error) else { return false }
            faults.withLock { $0[selection.description] = (($0[selection.description]?.count ?? 0) + 1, fault) }
            return true
        }

        /// How many faults `selection` met so far, and the latest.
        ///
        /// - Parameter selection: The model.
        /// - Returns: The count, 0 for none, and the fault.
        func met(on selection: ModelSelection) -> (count: Int, fault: ModelServiceFault?) {
            faults.withLock { $0[selection.description].map { ($0.count, $0.fault) } ?? (0, nil) }
        }
    }

    /// The environment variable naming the models.
    static let variable = "WISP_EVAL_MODELS"

    /// How long one case may take before it counts as a failure: well past any case's time on any model measured
    /// so far (a 27B model's draft of a 52 KB diff, about two minutes), so only a stuck case reaches it.
    static let caseLimit: Duration = .seconds(300)

    /// The models `text` names, in order, skipping spellings that do not parse; nil when it names none.
    ///
    /// - Parameter text: The variable's value, comma-separated.
    /// - Returns: The selections, or nil for an unset or empty list.
    static func parse(_ text: String?) -> [ModelSelection]? {
        let named = text?.split(separator: ",").compactMap {
            try? ModelSelection(parsing: $0.trimmingCharacters(in: .whitespaces))
        }
        return named?.isEmpty == false ? named : nil
    }

    /// The environment variable that runs the whole case sets of `edit_file`, `system_info`, and `draft_change`:
    /// `1` runs every case; anything else, or nothing, runs the release's fixed seeded subset of each.
    static let fullVariable = "WISP_EVAL_FULL"

    /// Whether this run measures the whole case sets (`WISP_EVAL_FULL=1`) rather than the release's subsets.
    static var full: Bool { ProcessInfo.processInfo.environment[fullVariable] == "1" }

    /// The cases a run measures: the whole set with `WISP_EVAL_FULL=1`, otherwise the release's subset, `release`
    /// cases chosen by `EvalSample` with its fixed seed and spread over the strata, so every release runs the same
    /// ones (docs/measurements.md, "The case sets").
    ///
    /// - Parameters:
    ///   - items: The whole set.
    ///   - release: The size of the release's subset; the whole set when nil.
    ///   - id: Each case's unique id.
    ///   - stratum: Each case's group, such as an edit's shape.
    /// - Returns: The cases, in the set's order.
    static func chosen<T>(_ items: [T], release: Int?, id: (T) -> String, stratum: (T) -> String) -> [T] {
        full ? items : EvalSample.subset(items, count: release ?? items.count, id: id, stratum: stratum)
    }

    /// How many of a set's cases ran, for a measurement's notes.
    ///
    /// - Parameters:
    ///   - run: The cases run.
    ///   - total: The cases in the set.
    /// - Returns: Such as "all 86" or "36 of 86 (the release's fixed subset)".
    static func scope(_ run: Int, of total: Int) -> String {
        run >= total ? "all \(total)" : "\(run) of \(total) (the release's fixed subset)"
    }

    /// Asserts the release's floor for `total` cases at the configured model's historical `rate` (`EvalFloor`): the
    /// least score a run at that rate falls below by chance at most one time in a hundred. On another model the floor
    /// is printed and nothing is asserted; a floor of 0 asserts nothing.
    ///
    /// - Parameters:
    ///   - suite: The suite's short name.
    ///   - passed: Cases passed.
    ///   - total: Cases run.
    ///   - rate: The configured model's historical pass rate on the suite.
    ///   - selection: The model measured.
    static func expectFloor(
        _ suite: String, passed: Int, total: Int, rate: EvalFloor.Rate, on selection: ModelSelection
    ) {
        let (faults, fault) = serviceFaults.met(on: selection)
        if let fault {
            let text =
                "\(suite) on \(selection) not measured: \(faults) case\(faults == 1 ? "" : "s") in this run never "
                + "reached the model: \(fault)"
            print("floor eval: \(text)")
            if floorsApply(to: selection) { Issue.record("\(text)") }
            return
        }
        let floor = EvalFloor.minimum(cases: total, rate: rate.value)
        print(
            "floor eval: \(suite) on \(selection): \(floorLine(passed: passed, total: total, rate: rate, floor: floor))"
                + (floorsApply(to: selection) ? "" : "; not asserted"))
        if floorsApply(to: selection) {
            #expect(passed >= floor, "\(suite) on \(selection) passed \(passed)/\(total), below its floor of \(floor)")
        }
    }

    /// A floor's result in words: this run's count and rate, what the suite's history makes of a run this size, where
    /// that history comes from, and the floor, such as `12/24 (50%) this run; about 17/24 (72%) expected, the rate
    /// over 258 earlier cases (185 passed); floor 12`. The history pools every recorded run, whole sets and the release's
    /// subsets alike, so its count of cases is not this run's.
    ///
    /// - Parameters:
    ///   - passed: Cases passed.
    ///   - total: Cases run.
    ///   - rate: The suite's historical pass rate.
    ///   - floor: The fewest passes the run needs.
    /// - Returns: The line, without its `floor eval: <suite> on <model>:` prefix.
    static func floorLine(passed: Int, total: Int, rate: EvalFloor.Rate, floor: Int) -> String {
        let percent = { (part: Double) in "\(Int((part * 100).rounded()))%" }
        let observed = total > 0 ? Double(passed) / Double(total) : 0
        let expected = Int((rate.value * Double(total)).rounded())
        return
            "\(passed)/\(total) (\(percent(observed))) this run; about \(expected)/\(total) (\(percent(rate.value))) "
            + "expected, the rate over \(rate.total) earlier cases (\(rate.passed) passed); floor \(floor)"
    }

    /// The models `WISP_EVAL_MODELS` names, or nil when it is unset.
    static var named: [ModelSelection]? { parse(ProcessInfo.processInfo.environment[variable]) }

    /// The models to measure: the named ones, else the configured default.
    static var selections: [ModelSelection] { named ?? [.default] }

    /// Whether the release's floors apply to `selection`: only the configured model's.
    ///
    /// - Parameter selection: The model measured.
    /// - Returns: True for the configured default.
    static func floorsApply(to selection: ModelSelection) -> Bool { selection == .default }

    /// The operator's configuration, so a local model resolves as a user's would (its runtime's address and
    /// timeout); the defaults when the file is missing or unreadable. Read, never written.
    static var config: Config.Resolved {
        (try? Session.loadConfig(home: Home.resolve())) ?? Config().resolved
    }

    /// Resolves `selection` for `suite`, or reports the suite failed on it and returns nil. On the configured
    /// model the failure is also an issue, so the release's eval fails as it did when it resolved the model with
    /// `try`.
    ///
    /// - Parameters:
    ///   - selection: The model.
    ///   - suites: The suites the model would have run, each reported as failed.
    ///   - config: The configuration to resolve with.
    /// - Returns: The resolved model, or nil.
    static func resolve(
        _ selection: ModelSelection, for suites: [String], config: Config.Resolved = EvalModels.config
    ) -> ResolvedModel? {
        registerBackends()
        do {
            return try selection.resolve(config: config, home: Home.resolve())
        } catch {
            for suite in suites {
                result(suite, on: selection, passed: 0, total: 0, milliseconds: [], note: "unavailable: \(error)")
            }
            if floorsApply(to: selection) { Issue.record("\(selection) unavailable: \(error)") }
            return nil
        }
    }

    /// Registers the MLX backend, as wisp's `main` does, when a named model is an `mlx:` one; otherwise no backend
    /// is registered and the eval resolves models exactly as before. Without the `MLX` trait the backend is there
    /// and refuses each model, so its cells say why (`scripts/check eval` builds with the trait when one is named).
    static func registerBackends() {
        guard named?.contains(where: { $0.backend == MLXBackend().scheme }) == true else { return }
        ModelBackends.register(MLXBackend())
    }

    /// The configuration the context comparison resolves with: the defaults, with the window held at `window` for
    /// both local runtimes, and the operator's MLX models and their declared capabilities, which an `mlx:` model
    /// needs to be offered tools.
    ///
    /// - Parameter window: The context window, in tokens.
    /// - Returns: The configuration.
    static func contextConfig(window: Int) -> Config.Resolved {
        var resolved = Config(ollama: .init(contextLength: window)).resolved
        let operatorConfig = config
        resolved.mlxModelsDirectory = operatorConfig.mlxModelsDirectory
        resolved.mlxModels = operatorConfig.mlxModels
        resolved.mlxVerified = operatorConfig.mlxVerified
        resolved.mlxExecutor = operatorConfig.mlxExecutor
        resolved.mlxContextLength = window
        return resolved
    }

    /// Runs one case on `selection` within `caseLimit`, timing it. A thrown error or the limit reached is printed
    /// under `label` and returns nil; with `strict`, on the configured model it is also an issue, for suites whose
    /// release eval failed on an error before.
    ///
    /// - Parameters:
    ///   - label: The suite's prefix and the case, for the printed line.
    ///   - selection: The model the case runs on.
    ///   - strict: Whether an error fails the run on the configured model.
    ///   - operation: The case; it builds its own sessions, since a session cannot cross into it.
    /// - Returns: The case's value, or nil, and its time in milliseconds.
    static func attempt<T: Sendable>(
        _ label: String, on selection: ModelSelection, strict: Bool = false,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> (value: T?, milliseconds: Double) {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let value = try await Timeout.run(caseLimit, operation)
            return (value, milliseconds(started.duration(to: clock.now)))
        } catch {
            serviceFaults.record(error, on: selection)
            print("\(label) on \(selection): error \(error)")
            if strict, floorsApply(to: selection) { Issue.record("\(label) on \(selection): \(error)") }
            return (nil, milliseconds(started.duration(to: clock.now)))
        }
    }

    /// A duration in milliseconds.
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The median of `values`, nearest rank; nil for none.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }

    /// Prints the suite's result on one model as the line `scripts/check eval` gathers into its summary table:
    /// `eval result`, the model, the suite, passed, total, the median milliseconds per case, and a note, separated
    /// by tabs.
    ///
    /// - Parameters:
    ///   - suite: The suite's short name, a column of the table.
    ///   - selection: The model, a row of the table.
    ///   - passed: Cases passed.
    ///   - total: Cases run; 0 when the model could not run the suite.
    ///   - milliseconds: Each case's time.
    ///   - note: Why the suite did not run, or what else the cell should say.
    static func result(
        _ suite: String, on selection: ModelSelection, passed: Int, total: Int, milliseconds: [Double],
        note: String = ""
    ) {
        result(suite, on: selection, passed: passed, total: total, median: median(milliseconds), note: note)
    }

    /// `result` with the median already taken, for a suite that measures its own times.
    ///
    /// - Parameters:
    ///   - suite: The suite's short name.
    ///   - selection: The model.
    ///   - passed: Cases passed.
    ///   - total: Cases run.
    ///   - median: The median milliseconds per case, when known.
    ///   - note: A note for the cell.
    static func result(
        _ suite: String, on selection: ModelSelection, passed: Int, total: Int, median: Double?, note: String = ""
    ) {
        let faults = serviceFaults.met(on: selection).count
        let note =
            faults == 0
            ? note : [note, "\(faults) model service faults"].filter { !$0.isEmpty }.joined(separator: "; ")
        let shown = note.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        print(
            "eval result\t\(selection)\t\(suite)\t\(passed)\t\(total)\t"
                + (median.map { String(format: "%.0f", $0) } ?? "") + "\t\(shown)")
    }
}
