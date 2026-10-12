import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// How reliably the configured model, or each model `WISP_EVAL_MODELS` names (`EvalModels`), performs delegated
/// tasks through wisp's tools. Needs the model, so it runs only with `WISP_MODEL_TESTS=1` (`scripts/check eval`);
/// each test records a `Measurement` that ships with the tool catalogue. Numbers are reported and recorded; only a
/// floor is asserted, on the configured model, so a regression fails the run.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct ToolEvalTests {
    /// A scratch directory inside the writable set.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-tool-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Read a file, then rewrite what the prompt names: the pairing `edit_file` exists for. The cases are
    /// `edit_file.json`'s `replace` set (`EvalSets.EditFile`): files in many languages and of three sizes, a line
    /// named by its text, neighbouring lines in two calls, a line emptied or a fragment cut, an empty line filled,
    /// near-duplicate lines, non-ASCII text, CRLF files edited by line number and by `find`, and a stale line number
    /// reconciled by `find`. A pass is the file ending up exactly as intended. Single runs of the first ten files, three attempts each,
    /// varied from 16 to 25 of 30 (2026-10-04 to 2026-10-12); since 0.23.0 each case runs once, and the release runs a
    /// fixed subset (`WISP_EVAL_FULL=1` runs all), with a floor set from that history (docs/measurements.md).
    @Test func replacesExactlyWhatItReadWithEditFile() async throws {
        try await editFile(
            task: "replace", suite: "edit_file", measurement: "edit_file.replace",
            rate: EvalFloor.Historical.editFileReplace,
            notes: "read a file with read_file, then rewrite what the prompt names with edit_file (a numbered line, "
                + "two neighbouring lines, a line emptied or filled, a fragment by find, a stale number with find) "
                + "across languages, file sizes, near-duplicate lines, non-ASCII text, and CRLF files")
    }

    /// Whitespace-only rewrites of one numbered line: indent, dedent, tabs to spaces and back, trailing spaces or a
    /// tab stripped. The cases where keeping a line's indentation must not apply (ADR 0024, refined 2026-10-06),
    /// measured apart from `edit_file.replace`; the `whitespace` set of `edit_file.json`.
    @Test func rewritesWhitespaceExactlyWithEditFile() async throws {
        try await editFile(
            task: "whitespace", suite: "edit_file.whitespace", measurement: "edit_file.whitespace",
            rate: EvalFloor.Historical.editFileWhitespace,
            notes: "read a file with read_file, then change only one numbered line's whitespace with edit_file "
                + "(indent, dedent, tabs to spaces and back, trailing spaces or a tab)")
    }

    /// One `edit_file` task on every model: the cases this run measures, each once.
    ///
    /// - Parameters:
    ///   - task: The set's task, `replace` or `whitespace`.
    ///   - suite: The column of the summary table.
    ///   - measurement: The measurement's task.
    ///   - rate: The configured model's historical pass rate, which sets the floor.
    ///   - notes: What the cases are, for the measurement's notes.
    /// - Throws: A fixture or file error.
    private func editFile(
        task: String, suite: String, measurement: String, rate: EvalFloor.Rate, notes: String
    ) async throws {
        let set = try EvalSets.EditFile.load()
        let all = set.cases(task)
        let cases = EvalModels.chosen(all, release: set.release[task], id: \.id, stratum: \.shape)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: [suite]) else { continue }
            let passed = try await editFile(cases, in: dir, on: model, suite: suite)
            let total = cases.count
            try? Measurements.report(
                Measurement(
                    task: measurement, tool: "edit_file", model: selection.description, passed: passed, total: total,
                    notes: notes + ", \(EvalModels.scope(total, of: all.count)) cases once each; a pass is the file "
                        + "ending up exactly as intended"))
            EvalModels.expectFloor(suite, passed: passed, total: total, rate: rate, on: selection)
        }
    }

    /// The edit_file cases on one model, each once.
    ///
    /// - Parameters:
    ///   - cases: The cases.
    ///   - dir: The scratch directory the files are written in.
    ///   - model: The model measured.
    ///   - suite: The column of the summary table.
    /// - Returns: The cases passed.
    /// - Throws: A file error writing a case's file.
    private func editFile(
        _ cases: [EvalSets.EditFile.Case], in dir: URL, on model: ResolvedModel, suite: String
    ) async throws -> Int {
        let selection = model.selection
        var passed = 0
        var times: [Double] = []
        for item in cases {
            let file = dir.appending(path: item.file)
            try Data(item.before.utf8).write(to: file)
            let prompt = item.prompt(path: file.path)
            let root = dir.path
            let (calls, milliseconds) = await EvalModels.attempt("tool eval: edit_file \(item.id)", on: selection) {
                let sink = MemoryAuditSink()
                let audit = AuditLog(session: "eval", sink: sink)
                let registry = ToolRegistry(runner: .init(writableRoot: root), audit: audit)
                let tools = registry.select(["read_file", "edit_file"]).tools
                let agent = Agent(
                    instructions: Prompting.systemPrompt(memory: false), tools: tools, model: model, audit: audit)
                _ = try await agent.respond(to: prompt)
                return sink.events.filter { $0.kind == .toolCall && $0.details["tool"] == "edit_file" }
                    .map { $0.details["arguments"]?.stringValue ?? "" }
            }
            times.append(milliseconds)
            let after = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let ok = after == item.after
            if ok { passed += 1 }
            print(
                "tool eval: \(suite) on \(selection) \(item.id) (\(item.shape)): \(ok ? "pass" : "FAIL") "
                    + (ok ? "" : "file=\(after.debugDescription) calls=\(calls ?? [])"))
        }
        EvalModels.result(suite, on: selection, passed: passed, total: cases.count, milliseconds: times)
        return passed
    }

    /// A classification with a schema: the reply must parse and carry the expected enum value.
    @Test func answersInTheShapeOfASchema() async throws {
        let schema = try OutputSchema(json: [
            "type": "object",
            "properties": [
                "language": ["type": "string", "enum": ["swift", "rust", "python", "shell", "other"]],
                "confidence": ["type": "number"],
            ],
            "required": ["language", "confidence"],
        ])
        let cases: [(code: String, expected: String)] = [
            ("let x = try await foo(); guard let y else { return }", "swift"),
            ("fn main() { println!(\"hi\"); }", "rust"),
            ("def f(x):\n    return [i for i in range(x)]", "python"),
            ("for f in *.txt; do wc -l \"$f\"; done", "shell"),
            ("SELECT id FROM users WHERE age > 30;", "other"),
            ("struct Point { var x: Double; var y: Double }", "swift"),
        ]
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: ["schema"]) else { continue }
            var passed = 0
            var times: [Double] = []
            for item in cases {
                let (reply, milliseconds) = await EvalModels.attempt(
                    "tool eval: schema \(item.expected)", on: selection, strict: true
                ) {
                    try await Agent(instructions: "You classify code.", tools: [], model: model)
                        .respond(to: "Which language is this?\n\n\(item.code)", schema: schema).text
                }
                times.append(milliseconds)
                let parsed = reply.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                let ok = parsed?.objectValue?["language"]?.stringValue == item.expected
                if ok { passed += 1 }
                print("tool eval: schema on \(selection) \(item.expected): \(ok ? "pass" : "FAIL") \(reply ?? "")")
            }
            EvalModels.result("schema", on: selection, passed: passed, total: cases.count, milliseconds: times)
            try? Measurements.report(
                Measurement(
                    task: "respond.schema", model: selection.description, passed: passed, total: cases.count,
                    notes: "classify a code snippet into an enum through a schema; a pass parses and names the language"
                ))
            if EvalModels.floorsApply(to: selection) {
                #expect(passed * 2 >= cases.count, "schema answers passed \(passed)/\(cases.count)")
            }
        }
    }
}
