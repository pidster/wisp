import Foundation
import Testing

@testable import WispCore

/// How well the configured model's pass finds personal data the rules cannot recognise. Needs the model
/// (`scripts/check eval`). Each fixture lists values that must be gone from the thorough redaction and
/// text that must survive it; a pass is both. The rules run first, as they do for callers, so the model
/// only sees what they left.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct RedactionEvalTests {
    struct Fixture {
        let name: String
        let text: String
        /// Values the redaction must replace.
        let gone: [String]
        /// Text the redaction must leave alone.
        let kept: [String]
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "support ticket",
            text: """
                Ticket 5521: Customer Margaret Oyelaran (account 88-2041-7736) reports the export fails with a \
                timeout. Replacement unit to ship to 42 Wren Lane, Bristol.
                """,
            gone: ["Margaret Oyelaran", "88-2041-7736", "42 Wren Lane"], kept: ["the export fails"]),
        Fixture(
            name: "service log",
            text: """
                2026-09-21T10:02:11Z worker[412] INFO connected to db-prod-7.internal.acme.net as svc_billing
                2026-09-21T10:02:12Z worker[412] INFO login ok for user tomasz.kowalczyk from the web client
                2026-09-21T10:02:15Z worker[412] WARN retrying job 7 after 3 s
                """,
            gone: ["db-prod-7.internal.acme.net", "tomasz.kowalczyk"], kept: ["worker[412]", "retrying job 7"]),
        Fixture(
            name: "build output",
            text: """
                [5/12] Compiling WispCore Agent.swift
                Sources/WispCore/Session/Agent.swift:42:13: error: cannot find 'fooBar' in scope
                Build complete with 1 error in 3.2 s
                """,
            gone: [], kept: ["Compiling WispCore Agent.swift", "Agent.swift:42:13", "fooBar"]),
        Fixture(
            name: "stack trace",
            text: """
                Thread 3 Crashed:: Dispatch queue: com.apple.root.default-qos
                0   wisp   0x0000000102a4c3f8 ApprovalGate.clear(readingFile:workingDirectory:) + 412
                1   wisp   0x0000000102a4b0e0 Triage.capture(_:runner:gate:maxOutputBytes:) + 96
                """,
            gone: [], kept: ["ApprovalGate.clear(readingFile:workingDirectory:)", "Triage.capture"]),
        Fixture(
            name: "meeting note",
            text: """
                Call with Priya Raghunathan and Owen Pritchard about the migration. Priya will send the \
                revised plan by Friday; Owen owns the rollback script.
                """,
            gone: ["Priya Raghunathan", "Owen Pritchard"], kept: ["the migration", "rollback script"]),
    ]

    @Test func findsWhatRulesMissAndLeavesOrdinaryTextAlone() async throws {
        let model = try ModelSelection.default.resolve()
        let schema = try OutputSchema(json: ModelSweep.schemaJSON)
        // The instructions a caller's pass runs under: wisp's own prompt with no tools, as `redact` and
        // `wisp redact --thorough` open it.
        let instructions = Prompting().rendered(toolsAvailable: false)
        let redaction = Redaction(options: .init(thorough: true)) { prompt in
            try await Agent(instructions: instructions, tools: [], model: model).respond(to: prompt, schema: schema)
                .text
        }
        var passed = 0
        var found = 0
        var expected = 0
        for fixture in Self.fixtures {
            let report = try await redaction.run(fixture.text, from: .path(fixture.name))
            let missed = fixture.gone.filter { report.text.contains($0) }
            let damaged = fixture.kept.filter { !report.text.contains($0) }
            let ok = missed.isEmpty && damaged.isEmpty
            if ok { passed += 1 }
            expected += fixture.gone.count
            found += fixture.gone.count - missed.count
            print(
                "redaction eval: \(fixture.name): \(ok ? "pass" : "FAIL") missed \(missed) damaged \(damaged)\n"
                    + report.text)
        }
        print("redaction eval: fixtures \(passed)/\(Self.fixtures.count); values found \(found)/\(expected)")
        try? Measurements.report(
            Measurement(
                task: "redact.thorough", model: model.selection.description, passed: passed,
                total: Self.fixtures.count,
                notes: "thorough redaction (rules, then the model) of a ticket, a log, and a note holding names, an "
                    + "account number, a user id, an address, and a private hostname, plus build output and a stack "
                    + "trace that must come through intact; a pass is every value replaced and every kept phrase unchanged"
            ))
        #expect(passed * 2 >= Self.fixtures.count, "redaction passed \(passed)/\(Self.fixtures.count)")
    }
}
