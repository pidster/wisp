import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// Whether the configured model's commit subjects, or each model's that `WISP_EVAL_MODELS` names (`EvalModels`),
/// name what a change is about, in three size bands. Needs the model (`scripts/check eval`). The shape rules (length,
/// capital, no trailing period) are applied in code, so the eval measures content, judged by an explicit rubric in
/// code rather than by a model: each diff of `drafts.json` (`EvalSets.Drafts`) has terms a right subject contains
/// (`must`, any one) and terms that would misdescribe the change (`mustNot`, none), each matched where it begins a word,
/// ignoring case. The terms name the gist of each change, not merely a file it touches: a looser set on 2026-09-24
/// passed "Cache installation instructions and config format in JSON" for a README change. Small diffs are written for
/// the eval; medium (4 to 16 KB) and large (24 to 56 KB) ones are real commits of this repository. Each diff is drafted
/// once; the release drafts a fixed subset of each band (`WISP_EVAL_FULL=1` drafts all), against floors set from the
/// configured model's history (docs/measurements.md).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct DraftEvalTests {
    /// Drafts a commit subject for `diff` on `model`, as `draft_change` would.
    ///
    /// - Parameters:
    ///   - diff: The diff.
    ///   - model: The model.
    /// - Returns: The subject.
    /// - Throws: A model or schema error.
    static func subject(_ diff: String, model: ResolvedModel) async throws -> String {
        let instructions = Prompting().rendered(toolsAvailable: false)
        let summarySchema = try OutputSchema(json: DiffSummary.schemaJSON)
        let draftSchema = try OutputSchema(json: ChangeDraft.schemaJSON)
        return try await ChangeDraft.draft(
            .commit, from: .init(text: diff), source: .path("fixture"),
            summarise: {
                try await Agent(instructions: instructions, tools: [], model: model).respond(
                    to: $0, schema: summarySchema
                )
                .text
            },
            write: {
                try await Agent(instructions: instructions, tools: [], model: model).respond(
                    to: $0, schema: draftSchema
                )
                .text
            }
        ).subject
    }

    /// Each band's suite name in the summary table, and the configured model's historical rate, which sets its floor.
    static let suites: [String: (suite: String, rate: EvalFloor.Rate)] = [
        "small": ("draft", EvalFloor.Historical.draftSmall),
        "medium": ("draft.medium", EvalFloor.Historical.draftMedium),
        "large": ("draft.large", EvalFloor.Historical.draftLarge),
    ]

    @Test func subjectsNameWhatTheChangeIsAboutAtEachSize() async throws {
        let set = try EvalSets.Drafts.load()
        // Every band's diffs, read once: a missing fixture fails the suite before any model runs.
        var bands: [(band: String, all: Int, cases: [(item: EvalSets.Drafts.Case, diff: String)])] = []
        for band in EvalSets.Drafts.bands {
            let all = set.cases(band)
            let chosen = EvalModels.chosen(all, release: set.release[band], id: \.id, stratum: { _ in "" })
            bands.append((band, all.count, try chosen.map { ($0, try $0.diff()) }))
        }
        for selection in EvalModels.selections {
            let suites = EvalSets.Drafts.bands.compactMap { Self.suites[$0]?.suite }
            guard let model = EvalModels.resolve(selection, for: suites) else { continue }
            for (band, all, cases) in bands {
                guard let (suite, rate) = Self.suites[band] else { continue }
                var passed = 0
                var times: [Double] = []
                for (item, diff) in cases {
                    let (drafted, milliseconds) = await EvalModels.attempt(
                        "draft eval: \(band) \(item.id)", on: selection, strict: true
                    ) { try await Self.subject(diff, model: model) }
                    times.append(milliseconds)
                    let verdict = drafted.map(item.judge)
                    if verdict == .pass { passed += 1 }
                    let why =
                        switch verdict {
                        case .pass: "pass"
                        case .missing: "FAIL (names none of \(item.must))"
                        case .forbidden(let term): "FAIL (says \(term))"
                        case nil: "FAIL (no subject)"
                        }
                    print(
                        "draft eval: on \(selection) \(band) \(item.id) (\(diff.utf8.count) B): \(why) "
                            + "\(drafted ?? "")")
                }
                let largest = cases.map(\.diff.utf8.count).max()
                EvalModels.result(suite, on: selection, passed: passed, total: cases.count, milliseconds: times)
                try? Measurements.report(
                    Measurement(
                        task: ChangeDraft.routingTask, model: selection.description, passed: passed,
                        total: cases.count,
                        notes: "commit subjects for \(band) diffs up to \((largest ?? 0) / 1024) KB, "
                            + "\(EvalModels.scope(cases.count, of: all)) once each"
                            + (band == "small" ? " (written for the eval)" : " (real commits of this repository)")
                            + "; a pass names the change's gist and says nothing it does not do (drafts.json's rubric)",
                        maxInputBytes: largest))
                EvalModels.expectFloor(suite, passed: passed, total: cases.count, rate: rate, on: selection)
            }
        }
    }
}
