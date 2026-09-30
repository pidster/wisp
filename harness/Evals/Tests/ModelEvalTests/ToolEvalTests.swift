import Foundation
import Testing

@testable import WispCore

/// How reliably the configured model performs delegated tasks through wisp's tools. Needs the
/// model, so it runs only with `WISP_MODEL_TESTS=1` (`scripts/check eval`); each test records a
/// `Measurement` that ships with the tool catalogue. Numbers are reported and recorded; only a
/// floor is asserted so a regression fails the run.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct ToolEvalTests {
    /// A scratch directory inside the writable set.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-tool-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Read a small file, then rewrite one numbered line: the pairing `edit_file` exists for. A pass
    /// is the file ending up exactly as intended, nothing else changed. Single runs varied between 5
    /// and 10 of 10 on 2026-09-21, so every case is attempted `attempts` times and all count.
    @Test func replacesExactlyWhatItReadWithEditFile() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(name: String, before: String, find: String, replacement: String)] = [
            ("a.swift", "let x = 1\nlet y = 2\n", "let x = 1", "let x = 42"),
            ("b.py", "def f():\n    return 1\n\ndef g():\n    return 2\n", "    return 1", "    return 10"),
            ("c.md", "# Title\n\nfirst paragraph\n\nsecond paragraph\n", "first paragraph", "opening paragraph"),
            (
                "d.toml", "[package]\nname = \"tools\"\nversion = \"0.1.0\"\n", "version = \"0.1.0\"",
                "version = \"0.2.0\""
            ),
            ("e.txt", "alpha\nbeta\ngamma\ndelta\n", "gamma", "GAMMA"),
            (
                "f.json", "{\n  \"name\": \"wisp\",\n  \"debug\": false\n}\n", "  \"debug\": false",
                "  \"debug\": true"
            ),
            ("g.sh", "#!/bin/sh\nset -eu\necho start\necho done\n", "echo start", "echo starting"),
            (
                "h.yml", "name: ci\non: push\njobs:\n  build:\n    runs-on: macos-15\n", "    runs-on: macos-15",
                "    runs-on: macos-26"
            ),
            ("i.rs", "fn main() {\n    let n = 3;\n    println!(\"{n}\");\n}\n", "    let n = 3;", "    let n = 4;"),
            ("j.css", "body {\n  color: black;\n  margin: 0;\n}\n", "  color: black;", "  color: navy;"),
        ]
        let model = try ModelSelection.default.resolve()
        let attempts = 3
        var passed = 0
        for (round, item) in (1...attempts).flatMap({ round in cases.map { (round, $0) } }) {
            let sink = MemoryAuditSink()
            let audit = AuditLog(session: "eval", sink: sink)
            let registry = ToolRegistry(runner: .init(writableRoot: dir.path), audit: audit)
            let tools = registry.select(["read_file", "edit_file"]).tools
            let file = dir.appending(path: item.name)
            try Data(item.before.utf8).write(to: file)
            let agent = Agent(
                instructions: Prompting.systemPrompt(memory: false), tools: tools, model: model, audit: audit)
            let prompt =
                "Use read_file to read \(file.path). Then use edit_file with mode replace on \(file.path), with line "
                + "set to the number read_file showed for `\(item.find)` and content `\(item.replacement)`. "
                + "Report the tool results verbatim."
            let expected = item.before.replacingOccurrences(of: item.find, with: item.replacement)
            do {
                _ = try await agent.respond(to: prompt)
            } catch {
                print("tool eval: edit_file \(item.name): error \(error)")
            }
            let after = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let ok = after == expected
            if ok { passed += 1 }
            let calls = sink.events.filter { $0.kind == .toolCall && $0.details["tool"] == "edit_file" }
                .map { $0.details["arguments"]?.stringValue ?? "" }
            print(
                "tool eval: edit_file \(item.name) #\(round): \(ok ? "pass" : "FAIL") "
                    + (ok ? "" : "file=\(after.replacingOccurrences(of: "\n", with: "⏎")) calls=\(calls)"))
        }
        try? Measurements.report(
            Measurement(
                task: "edit_file.replace", tool: "edit_file", model: model.selection.description, passed: passed,
                total: cases.count * attempts,
                notes: "read a small file with read_file, then rewrite one numbered line with edit_file, ten files "
                    + "attempted three times each; a pass is the file ending up exactly as intended"))
        #expect(passed * 2 >= cases.count * attempts, "edit_file replace passed \(passed)/\(cases.count * attempts)")
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
        let model = try ModelSelection.default.resolve()
        var passed = 0
        for item in cases {
            let agent = Agent(instructions: "You classify code.", tools: [], model: model)
            let reply = try await agent.respond(to: "Which language is this?\n\n\(item.code)", schema: schema)
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(reply.text.utf8))
            let ok = parsed?.objectValue?["language"]?.stringValue == item.expected
            if ok { passed += 1 }
            print("tool eval: schema \(item.expected): \(ok ? "pass" : "FAIL") \(reply.text)")
        }
        try? Measurements.report(
            Measurement(
                task: "respond.schema", model: model.selection.description, passed: passed, total: cases.count,
                notes: "classify a code snippet into an enum through a schema; a pass parses and names the language"))
        #expect(passed * 2 >= cases.count, "schema answers passed \(passed)/\(cases.count)")
    }
}
