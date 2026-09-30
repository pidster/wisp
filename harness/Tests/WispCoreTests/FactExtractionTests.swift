import Foundation
import Testing

@testable import WispCore

/// Facts taken from tool output without a model (decision D1 of the layered-context proposal): each rule's
/// shape, what it refuses, and the bound per turn.
@Suite struct FactExtractionTests {
    /// A call as the extraction reads it.
    static func call(_ tool: String, _ arguments: [String: JSONValue], _ output: String) -> FactExtraction.Call {
        FactExtraction.Call(
            tool: tool, arguments: arguments, output: output,
            result: AuditReference(session: "s", turn: 1, event: "r-\(tool)"), time: Date(timeIntervalSince1970: 0))
    }

    /// The facts `calls` give, as `subject name = value`.
    static func facts(_ calls: [FactExtraction.Call]) -> [String] {
        FactExtraction.assertions(from: calls, kinds: .defaults, turn: 3, entries: ["r-read_file": 9]).map {
            "\($0.identity.subject) \($0.identity.name) = \($0.value)"
        }
    }

    @Test func aTestCommandsExitStatusIsAFactAndSupersedesAsItChanges() {
        let failing = Self.call(
            "run_command", ["command": "swift test 2>&1 | tail -3", "workingDirectory": "/work/repo/"],
            "exit status: 1\nstdout:\nerror: 2 tests failed")
        #expect(Self.facts([failing]) == ["workdir  = /work/repo", "tests swift test = failed (exit status 1)"])
        // The same command passing supersedes the failure in a book: CI failing, then green.
        var book = FactBook(scope: .conversation)
        let first = FactExtraction.assertions(from: [failing], kinds: .defaults, turn: 3)
        for assertion in first { book.record(assertion) }
        var passing = failing
        passing.output = "exit status: 0\nstdout:\nall tests passed"
        for assertion in FactExtraction.assertions(from: [passing], kinds: .defaults, turn: 5) {
            book.record(assertion)
        }
        let tests = book.facts.filter { $0.identity.subject == "tests" }
        #expect(tests.map(\.state) == [.superseded, .current])
        #expect(tests.last?.value == "passed (exit status 0)" && tests.last?.turn == 5 && tests.last?.version == 2)
        #expect(tests.first?.supersededBy == tests.last?.id)
        // A command that is not a test gives no tests fact; one refused by policy gives nothing.
        #expect(Self.facts([Self.call("run_command", ["command": "ls"], "exit status: 0\nstdout:\na")]).isEmpty)
        #expect(Self.facts([Self.call("run_command", ["command": "swift test"], "error: denied by policy")]).isEmpty)
    }

    @Test func gitNamesTheBranchOnlyWhenUnambiguous() {
        #expect(FactExtraction.branch(in: "exit status: 0\nstdout:\nOn branch main\nnothing to commit") == "main")
        #expect(
            FactExtraction.branch(in: "exit status: 0\nstdout:\n## feature/x...origin/feature/x [ahead 1]")
                == "feature/x")
        #expect(FactExtraction.branch(in: "exit status: 0\nstderr:\nSwitched to a new branch 'fix-1'") == "fix-1")
        #expect(FactExtraction.branch(in: "exit status: 0\nstdout:\nmain") == "main")
        #expect(FactExtraction.branch(in: "exit status: 0\nstdout:\nHEAD") == nil)
        #expect(FactExtraction.branch(in: "exit status: 0\nstdout:\nOn branch a\nSwitched to branch 'b'") == nil)
        #expect(FactExtraction.branch(in: "exit status: 0\nstdout:\n M a.swift\n M b.swift") == nil)
        let status = Self.call(
            "run_command", ["command": "git status"], "exit status: 0\nstdout:\nOn branch main\nnothing to commit")
        #expect(Self.facts([status]) == ["branch  = main"])
        let failed = Self.call("run_command", ["command": "git checkout x"], "exit status: 1\nstderr:\nx")
        #expect(Self.facts([failed]).isEmpty)
    }

    @Test func filesReadAndWrittenAreFactsByPath() {
        let page = (1...3).map { "\($0)\tline" }.joined(separator: "\n") + "\n[end of file]"
        let read = Self.call("read_file", ["path": "/elsewhere/a.md"], page)
        let assertions = FactExtraction.assertions(
            from: [read], kinds: .defaults, turn: 3, entries: ["r-read_file": 9])
        #expect(assertions.first?.entries == [9] && assertions.first?.audit.first?.event == "r-read_file")
        #expect(assertions.first?.detail == "read_file" && assertions.first?.source == .tool)
        #expect(Self.facts([read]) == ["file /elsewhere/a.md = read lines 1-3, to the end, \(page.utf8.count) bytes"])
        let more = Self.call("read_file", ["path": "/elsewhere/a.md"], "5\tx\n6\ty\n[more: call again with offset 7]")
        #expect(Self.facts([more]).first?.contains("= read lines 5-6, more after, ") == true)
        #expect(Self.facts([Self.call("read_file", ["path": "/x"], "error: no such file")]).isEmpty)
        #expect(Self.facts([Self.call("read_file", ["path": "/x"], "(no lines in range)\n[end of file]")]).isEmpty)
        let edit = Self.call(
            "edit_file", ["path": "/elsewhere/a.md", "mode": "append"], "appended 12 bytes to /elsewhere/a.md")
        #expect(Self.facts([edit]) == ["file /elsewhere/a.md = appended 12 bytes to /elsewhere/a.md"])
        let refused = Self.call("edit_file", ["path": "/elsewhere/a.md"], "error: denied")
        #expect(Self.facts([refused]) == ["file /elsewhere/a.md = edit failed: error: denied"])
    }

    @Test func systemInfoGivesEphemeralFacts() throws {
        let ports = """
            2 sockets listening on TCP
            COMMAND  PID  PROTO  ADDRESS        STATE
            node     311  TCP    *:8080         LISTEN
            ollama   42   TCP    127.0.0.1:11434 LISTEN
            (your processes only; other users' are visible only to root)
            """
        let assertions = FactExtraction.assertions(
            from: [Self.call("system_info", ["topic": "ports"], ports)], kinds: .defaults, turn: 1)
        #expect(assertions.map(\.identity.name) == ["port 8080", "port 11434"])
        #expect(assertions.first?.value == "node (pid 311), listening")
        #expect(assertions.allSatisfy { $0.identity.scope == .session && $0.temporalClass == .ephemeral })
        #expect(
            Self.facts([Self.call("system_info", ["topic": "memory"], "12 GB used of 16 GB\nmore")]) == [
                "machine memory = 12 GB used of 16 GB"
            ])
        #expect(Self.facts([Self.call("current_date", [:], "2026-09-30")]).isEmpty)
    }

    @Test func callsArePairedFromAuditEventsAndBoundedPerTurn() {
        var events: [AuditEvent] = []
        for index in 0..<20 {
            events.append(
                AuditEvent(
                    session: "s", kind: .toolCall, turn: 1, call: "k\(index)",
                    details: ["tool": "read_file", "arguments": .string(#"{"path":"/f\#(index)"}"#)]))
            events.append(
                AuditEvent(
                    session: "s", kind: .toolResult, turn: 1, call: "k\(index)",
                    details: ["output": "1\tx\n[end of file]"]))
        }
        events.append(
            AuditEvent(session: "s", kind: .toolCall, turn: 1, call: "orphan", details: ["tool": "read_file"]))
        let calls = FactExtraction.calls(from: events)
        #expect(calls.count == 20 && calls.first?.string("path") == "/f0")
        #expect(FactExtraction.assertions(from: calls, kinds: .defaults, turn: 1).count == FactExtraction.perTurn)
    }
}
