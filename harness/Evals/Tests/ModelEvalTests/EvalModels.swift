import Foundation
import Testing

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
enum EvalModels {
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
        let shown = note.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        print(
            "eval result\t\(selection)\t\(suite)\t\(passed)\t\(total)\t"
                + (median.map { String(format: "%.0f", $0) } ?? "") + "\t\(shown)")
    }
}
