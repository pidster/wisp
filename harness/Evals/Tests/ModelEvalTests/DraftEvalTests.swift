import Foundation
import Testing

@testable import WispCore

/// Whether the configured model's commit subjects name what a change is about. Needs the model
/// (`scripts/check eval`). The shape rules (length, capital, no trailing period) are applied in code, so
/// the eval measures content: a pass is a subject containing one of the words a reviewer would expect.
/// The words name the gist of each change, not merely a file it touches: a looser set on 2026-09-24
/// passed "Cache installation instructions and config format in JSON" for a README change.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct DraftEvalTests {
    struct Fixture {
        let name: String
        let diff: String
        /// Any one of these, case-insensitively, in the subject.
        let words: [String]
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "retry",
            diff: """
                diff --git a/Sources/Upload.swift b/Sources/Upload.swift
                --- a/Sources/Upload.swift
                +++ b/Sources/Upload.swift
                @@ -10,6 +10,14 @@ struct Uploader {
                     func send(_ data: Data) async throws {
                -        try await client.post(data)
                +        var attempt = 0
                +        while true {
                +            do { return try await client.post(data) } catch where attempt < 2 {
                +                attempt += 1
                +                try await Task.sleep(for: .seconds(attempt))
                +            }
                +        }
                     }
                """, words: ["retry", "retries", "retrying"]),
        Fixture(
            name: "timeout default",
            diff: """
                diff --git a/Sources/Config.swift b/Sources/Config.swift
                --- a/Sources/Config.swift
                +++ b/Sources/Config.swift
                @@ -3,3 +3,3 @@ struct Config {
                -    var timeoutSeconds = 30
                +    var timeoutSeconds = 120
                """, words: ["timeout", "time out"]),
        Fixture(
            name: "new flag",
            diff: """
                diff --git a/Sources/CLI.swift b/Sources/CLI.swift
                --- a/Sources/CLI.swift
                +++ b/Sources/CLI.swift
                @@ -8,4 +8,7 @@ struct List: ParsableCommand {
                     @Flag var all = false
                +    /// Print JSON instead of text.
                +    @Flag(name: .long, help: "Print JSON.") var json = false
                     func run() throws {
                -        print(items.map(\\.name).joined(separator: "\\n"))
                +        print(json ? encode(items) : items.map(\\.name).joined(separator: "\\n"))
                """, words: ["json"]),
        Fixture(
            name: "bug fix",
            diff: """
                diff --git a/Sources/Paging.swift b/Sources/Paging.swift
                --- a/Sources/Paging.swift
                +++ b/Sources/Paging.swift
                @@ -20,3 +20,3 @@ func page(_ items: [Item], number: Int, size: Int) -> [Item] {
                -    let start = number * size + 1
                +    let start = number * size
                     return Array(items[start..<min(start + size, items.count)])
                """, words: ["off-by-one", "off by one", "start index", "page start", "first item"]),
        Fixture(
            name: "docs only",
            diff: """
                diff --git a/README.md b/README.md
                --- a/README.md
                +++ b/README.md
                @@ -12,2 +12,6 @@ ## Install
                 brew install tool
                +
                +## Configuration
                +
                +Settings live in `~/.tool/config.json`; `tool config` prints the effective values.
                """, words: ["readme", "document", "docs"]),
    ]

    /// Real commits from this repository's history, in two size bands, with words their subjects had.
    static let bands: [(name: String, fixtures: [(file: String, words: [String])])] = [
        (
            "medium",
            [("f7b9cd9", ["process name", "require"]), ("d6bdf31", ["cache", "verdict"])]
        ),
        (
            "large",
            [("19d3748", ["unified log", "unified-log", "exit status", "failing command"]), ("b816acd", ["watch"])]
        ),
    ]

    /// The diff of a fixture commit, read beside this file.
    static func diff(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).diff")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The models to measure: `WISP_EVAL_MODELS` (comma-separated spellings), else the configured default.
    static var models: [ModelSelection] {
        let named = ProcessInfo.processInfo.environment["WISP_EVAL_MODELS"]?.split(separator: ",").compactMap {
            try? ModelSelection(parsing: $0.trimmingCharacters(in: .whitespaces))
        }
        return (named?.isEmpty == false ? named : nil) ?? [.default]
    }

    /// Drafts a commit subject for `diff` on `model`, as `draft_change` would.
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

    @Test func subjectsNameWhatTheChangeIsAboutAtEachSize() async throws {
        let config = try Session.loadConfig(home: Home.resolve())
        for selection in Self.models {
            let model = try selection.resolve(config: config, home: Home.resolve())
            // Small diffs, twice each; the floor applies here.
            var passed = 0
            for (round, fixture) in (1...2).flatMap({ round in Self.fixtures.map { (round, $0) } }) {
                let subject = try await Self.subject(fixture.diff, model: model)
                let ok = fixture.words.contains { subject.lowercased().contains($0) }
                if ok { passed += 1 }
                print("draft eval: \(selection) small #\(round) \(fixture.name): \(ok ? "pass" : "FAIL") \(subject)")
            }
            let total = Self.fixtures.count * 2
            try? Measurements.report(
                Measurement(
                    task: ChangeDraft.routingTask, model: selection.description, passed: passed, total: total,
                    notes: "commit subjects for five small diffs (a retry loop, a default changed, a new flag, an "
                        + "off-by-one fix, a docs addition), twice each; a pass is a subject naming what the change is about",
                    maxInputBytes: Self.fixtures.map(\.diff.utf8.count).max()))
            #expect(passed * 2 >= total, "\(selection): small draft subjects passed \(passed)/\(total)")
            // Real commits in larger bands, once each: evidence for routing, not a floor.
            for band in Self.bands {
                var bandPassed = 0
                var largest = 0
                for fixture in band.fixtures {
                    let diff = try Self.diff(fixture.file)
                    largest = max(largest, diff.utf8.count)
                    let subject = try await Self.subject(diff, model: model)
                    let ok = fixture.words.contains { subject.lowercased().contains($0) }
                    if ok { bandPassed += 1 }
                    print(
                        "draft eval: \(selection) \(band.name) \(fixture.file) (\(diff.utf8.count) B): \(ok ? "pass" : "FAIL") \(subject)"
                    )
                }
                try? Measurements.report(
                    Measurement(
                        task: ChangeDraft.routingTask, model: selection.description, passed: bandPassed,
                        total: band.fixtures.count,
                        notes: "commit subjects for \(band.fixtures.count) real commits of this repository up to "
                            + "\(largest / 1024) KB of diff; a pass is a subject naming what the commit did",
                        maxInputBytes: largest))
            }
        }
    }
}
