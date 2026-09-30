import Foundation
import Testing

@testable import WispCore

/// How well the configured model summarises diffs. Needs the model (`scripts/check eval`). Each
/// fixture is a small diff with the flags a reviewer would raise; a pass is a flag of the expected kind
/// on the expected file, or, for a fixture with nothing to flag, no flags at all. Summaries are checked
/// for presence, not content.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct DiffSummaryEvalTests {
    struct Fixture {
        let name: String
        let diff: String
        /// Expected flags as (kind, path); empty means none must be raised.
        let expected: [(String, String)]
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "ordinary rename of a variable",
            diff: """
                diff --git a/Sources/Agent.swift b/Sources/Agent.swift
                --- a/Sources/Agent.swift
                +++ b/Sources/Agent.swift
                @@ -10,4 +10,4 @@
                 func respond() {
                -    let reply = session.answer()
                -    return reply
                +    let answer = session.answer()
                +    return answer
                 }
                """, expected: []),
        Fixture(
            name: "hard-coded API key",
            diff: """
                diff --git a/Sources/Network/Client.swift b/Sources/Network/Client.swift
                --- a/Sources/Network/Client.swift
                +++ b/Sources/Network/Client.swift
                @@ -3,3 +3,4 @@
                 struct Client {
                +    static let apiKey = "sk-live-4f9a2b7c1d8e0f3a6b5c9d2e1f4a7b8c"
                     let baseURL: URL
                 }
                """, expected: [("secret", "Sources/Network/Client.swift")]),
        Fixture(
            name: "test deleted",
            diff: """
                diff --git a/Tests/RunnerTests.swift b/Tests/RunnerTests.swift
                deleted file mode 100644
                --- a/Tests/RunnerTests.swift
                +++ /dev/null
                @@ -1,6 +0,0 @@
                -import Testing
                -@Suite struct RunnerTests {
                -    @Test func timesOut() async throws {
                -        #expect(try await run("sleep 5", timeout: 1).timedOut)
                -    }
                -}
                diff --git a/Sources/Runner.swift b/Sources/Runner.swift
                --- a/Sources/Runner.swift
                +++ b/Sources/Runner.swift
                @@ -20,3 +20,3 @@
                -    let timeout: Duration = .seconds(60)
                +    let timeout: Duration = .seconds(600)
                """, expected: [("deleted-test", "Tests/RunnerTests.swift")]),
        Fixture(
            name: "test disabled in place",
            diff: """
                diff --git a/Tests/GateTests.swift b/Tests/GateTests.swift
                --- a/Tests/GateTests.swift
                +++ b/Tests/GateTests.swift
                @@ -5,3 +5,3 @@
                -    @Test func deniesDangerousCommands() async {
                +    @Test(.disabled("flaky")) func deniesDangerousCommands() async {
                         await #expect(throws: Failure.self) { try await gate.clear("rm -rf /") }
                """, expected: [("deleted-test", "Tests/GateTests.swift")]),
        Fixture(
            name: "docs only",
            diff: """
                diff --git a/README.md b/README.md
                --- a/README.md
                +++ b/README.md
                @@ -1,2 +1,3 @@
                 # wisp
                +An on-device, tool-using AI microharness for macOS.
                """, expected: []),
    ]

    @Test func flagsWhatAReviewerWouldAndNothingElse() async throws {
        let model = try ModelSelection.default.resolve()
        let schema = try OutputSchema(json: DiffSummary.schemaJSON)
        let summary = DiffSummary { prompt in
            try await Agent(instructions: "You summarise code changes for a reviewer.", tools: [], model: model)
                .respond(to: prompt, schema: schema).text
        }
        var passed = 0
        var summarised = 0
        var files = 0
        for fixture in Self.fixtures {
            let report = try await summary.run(.init(text: fixture.diff), from: .path(fixture.name))
            let ok: Bool
            if fixture.expected.isEmpty {
                ok = report.flags.isEmpty
            } else {
                ok = fixture.expected.allSatisfy { kind, path in
                    report.flags.contains { $0.kind == kind && $0.path == path }
                }
            }
            if ok { passed += 1 }
            files += report.files.count
            summarised += report.files.filter { $0.summary != nil }.count
            print("diff eval: \(fixture.name): \(ok ? "pass" : "FAIL")\n" + report.rendered)
        }
        print("diff eval: flags \(passed)/\(Self.fixtures.count); files summarised \(summarised)/\(files)")
        try? Measurements.report(
            Measurement(
                task: "summarise_diff", model: model.selection.description, passed: passed, total: Self.fixtures.count,
                notes: "small diffs with a secret, a deleted test, a disabled test, and two ordinary changes; a pass "
                    + "is the expected flag on the expected file, or no flag for an ordinary change"))
        #expect(passed * 2 >= Self.fixtures.count, "diff flags passed \(passed)/\(Self.fixtures.count)")
        #expect(summarised == files, "\(files - summarised) files got no summary")
    }
}
