import Foundation
import Testing

@testable import WispCore

/// How well the configured model triages real build and test output. Needs the model, so it runs
/// only with `WISP_MODEL_TESTS=1` (`scripts/check eval`); reports recall per fixture and asserts a
/// floor so a regression fails the run. Fixtures are captured output, abridged; the expected
/// locations are what a reader would list.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct TriageEvalTests {
    struct Fixture {
        let name: String
        let output: String
        /// For each expected failure, the substrings that would identify it (any one, in some finding's
        /// location or message): a test name or the file:line of its assertion both count.
        let expected: [[String]]
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "swift build",
            output: """
                Building for debugging...
                [1/12] Write sources
                [5/12] Compiling WispCore Agent.swift
                /Users/me/src/harness/Sources/WispCore/Session/Agent.swift:42:13: error: cannot find 'fooBar' in scope
                        let x = fooBar()
                                ^~~~~~
                /Users/me/src/harness/Sources/WispCore/Session/Agent.swift:58:9: warning: variable 'unused' was never used; consider replacing with '_' or removing it
                        let unused = 1
                            ^
                /Users/me/src/harness/Sources/WispCore/Tools/ReadFileTool.swift:17:1: error: missing return in instance method expected to return 'String'
                }
                ^
                error: fatalError
                """,
            expected: [["Agent.swift:42"], ["ReadFileTool.swift:17"]]),
        Fixture(
            name: "swift test",
            output: """
                Test Suite 'All tests' started at 2026-09-20 10:00:00.000.
                ◇ Test run started.
                ◇ Suite CommandRunnerTests started.
                ✔ Test capturesOutput() passed after 0.012 seconds.
                ✘ Test respectsTimeout() recorded an issue at CommandRunnerTests.swift:88:9: Expectation failed: (outcome.timedOut → false) == true
                ✘ Test respectsTimeout() failed after 1.203 seconds with 1 issue.
                ✔ Test rendersOutcome() passed after 0.001 seconds.
                ◇ Suite ApprovalGateTests started.
                ✘ Test deniesWhenTheApproverDeclines() recorded an issue at ApprovalGateTests.swift:41:5: Caught error: refused("no")
                ✘ Test deniesWhenTheApproverDeclines() failed after 0.003 seconds with 1 issue.
                ✘ Test run with 40 tests in 6 suites failed after 2.100 seconds with 2 issues.
                """,
            expected: [
                ["respectsTimeout", "CommandRunnerTests.swift:88"],
                ["deniesWhenTheApproverDeclines", "ApprovalGateTests.swift:41"],
            ]),
        Fixture(
            name: "cargo test",
            output: """
                   Compiling tools v0.1.0 (/Users/me/src/tools)
                error[E0425]: cannot find value `undefined_name` in this scope
                  --> src/main.rs:14:20
                   |
                14 |     let total = undefined_name + 1;
                   |                 ^^^^^^^^^^^^^^ not found in this scope

                error[E0308]: mismatched types
                  --> src/lib.rs:7:5
                   |
                 7 |     "seven"
                   |     ^^^^^^^ expected `i32`, found `&str`

                error: could not compile `tools` (bin "tools") due to 2 previous errors
                """,
            expected: [["src/main.rs:14"], ["src/lib.rs:7"]]),
        Fixture(
            name: "pytest",
            output: """
                ============================= test session starts ==============================
                collected 3 items

                tests/test_math.py .F.                                                   [100%]

                =================================== FAILURES ===================================
                _________________________________ test_divide __________________________________

                    def test_divide():
                >       assert divide(1, 0) == 0
                E       ZeroDivisionError: division by zero

                tests/test_math.py:12: ZeroDivisionError
                =========================== short test summary info ============================
                FAILED tests/test_math.py::test_divide - ZeroDivisionError: division by zero
                ========================= 1 failed, 2 passed in 0.04s ==========================
                """,
            expected: [["test_divide", "test_math.py:12"]]),
    ]

    @Test func findsTheFailuresInEachFixture() async throws {
        let model = try ModelSelection.default.resolve()
        let schema = try OutputSchema(json: Triage.schemaJSON)
        let triage = Triage(options: .init(chunkBytes: 4096)) { prompt in
            try await Agent(instructions: "You triage build and test output.", tools: [], model: model)
                .respond(to: prompt, schema: schema).text
        }
        var hits = 0
        var wanted = 0
        var exact = 0
        var chunks = 0
        for fixture in Self.fixtures {
            let report = try await triage.run(.init(text: fixture.output), from: .path(fixture.name))
            let haystack = report.findings.map { "\($0.location ?? "") \($0.message)" }
            let found = fixture.expected.filter { needles in
                haystack.contains { hay in needles.contains { hay.contains($0) } }
            }
            hits += found.count
            wanted += fixture.expected.count
            let spurious = report.findings.count - found.count
            exact += report.exactChunks
            chunks += report.chunks
            print(
                "triage eval: \(fixture.name): \(found.count)/\(fixture.expected.count) expected found, "
                    + "\(spurious) other findings\n" + report.rendered)
        }
        print("triage eval: recall \(hits)/\(wanted); \(exact) of \(chunks) chunks read exactly, without the model")
        #expect(hits * 4 >= wanted * 3, "recall \(hits)/\(wanted) is below three quarters")
        try? Measurements.report(
            Measurement(
                task: "triage", model: ModelSelection.default.description, passed: hits, total: wanted,
                notes: "expected failures found across abridged swift build, swift test, cargo test, and pytest "
                    + "output, by test name or file:line"))
    }
}
