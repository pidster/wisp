import Foundation
import Testing

@testable import WispCore

@Suite struct ToolWrapperTests {
    @Test func runCommandRendersOutcomeAndHonoursWorkingDirectory() async throws {
        let tool = RunCommandTool(runner: CommandRunner(options: .init(policy: .unrestricted)))
        let plain = await tool.call(
            arguments: .init(command: "printf hi; printf err >&2; exit 2", workingDirectory: nil))
        #expect(plain == "exit status: 2\nstdout:\nhi\nstderr:\nerr")
        let elsewhere = await tool.call(arguments: .init(command: "pwd", workingDirectory: "/private/tmp"))
        #expect(elsewhere == "exit status: 0\nstdout:\n/private/tmp\n")
        let missing = await tool.call(arguments: .init(command: "true", workingDirectory: "/nonexistent/dir"))
        #expect(missing == "error: working directory does not exist: /nonexistent/dir")
        let denied = RunCommandTool(runner: CommandRunner(options: .init(policy: CommandPolicy(deny: ["nope"]))))
        #expect(
            await denied.call(arguments: .init(command: "echo nope", workingDirectory: nil)).hasPrefix(
                "error: command denied by policy"))
    }

    @Test func readFileDefaultsAndErrorsRenderForTheModel() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-wrap-\(UUID().uuidString).txt")
        try Data((1...150).map(String.init).joined(separator: "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tool = ReadFileTool()
        let page = await tool.call(arguments: .init(path: url.path, offset: nil, limit: nil))
        #expect(page.hasPrefix("1\t1\n"))
        #expect(page.contains("100\t100\n[more: call again with offset 101]"))
        let tail = await tool.call(arguments: .init(path: url.path, offset: 149, limit: 5))
        #expect(tail == "149\t149\n150\t150\n[end of file]")
        #expect(
            await tool.call(arguments: .init(path: "/nonexistent/x", offset: nil, limit: nil))
                == "error: file not found: /nonexistent/x")
    }

    @Test func editFileClearsTheGateAppliesAndAuditsOrExplains() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let file = dir.appending(path: "f.txt").path
        let open = EditFileTool(writer: writer, audit: audit)
        #expect(
            await open.call(arguments: .init(path: file, mode: "write", content: "hello\n", find: nil, line: nil))
                == "created \(file); now 6 bytes")
        #expect(
            await open.call(arguments: .init(path: file, mode: " Replace ", content: "bye", find: "hello", line: nil))
                == "replaced at line 1 of \(file); now 4 bytes; line 1 now: \"bye\"")
        let write = sink.events.first { $0.kind == .fileWrite }
        #expect(write?.details["mode"] == "write" && write?.details["created"] == true)
        #expect(write?.details["bytesAfter"] == 6 && write?.details["path"] == .string(file))
        #expect(write?.summary.hasSuffix("file.write session=s: write \(file) 0->6 bytes") == true)
        #expect(
            await open.call(arguments: .init(path: file, mode: "replace", content: "x", find: nil, line: nil))
                == "error: replace needs line (from read_file) or find (the exact text to replace)")
        #expect(
            await open.call(arguments: .init(path: file, mode: "replace", content: "BYE", find: "bye", line: 1))
                == "replaced at line 1 of \(file); now 4 bytes; line 1 now: \"BYE\"")
        #expect(
            await open.call(arguments: .init(path: file, mode: "replace", content: "x", find: "bye", line: 1))
                == "error: line 1 does not contain bye; it is: BYE")
        // An empty find beside line checks nothing (granite4.1:8b sends "" for an argument it does not need).
        #expect(
            await open.call(arguments: .init(path: file, mode: "replace", content: "BYE", find: "", line: 1))
                == "replaced at line 1 of \(file); now 4 bytes; line 1 now: \"BYE\"")
        #expect(
            await open.call(arguments: .init(path: file, mode: "delete", content: "x", find: nil, line: nil))
                == "error: mode must be write, append, or replace")
        #expect(
            await open.call(arguments: .init(path: file, mode: "replace", content: "x", find: "nope", line: nil))
                == "error: text to replace not found: nope")
        // With a gate: every edit is at least moderate, so a denying approver refuses it and nothing changes.
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "not now"),
            threshold: .level(.moderate), audit: audit)
        let gated = EditFileTool(writer: writer, approval: gate, audit: audit)
        let refused = await gated.call(arguments: .init(path: file, mode: "append", content: "!", find: nil, line: nil))
        #expect(refused.hasPrefix("error: edit not approved: "), "\(refused)")
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "BYE\n")
        let decided = sink.events.last { $0.kind == .approvalDecided }
        #expect(decided?.details["command"] == .string("edit_file append \(file)"))
        #expect(decided?.details["pattern"] == "edit_file *")
        // A credential path is dangerous by the rules, whatever the mode.
        let verdict = await RuleRiskClassifier.standard.classify(
            command: "edit_file write /Users/me/.ssh/authorized_keys", workingDirectory: "/")
        #expect(verdict.level == .dangerous)
        #expect(
            await RuleRiskClassifier.standard.classify(command: "edit_file write /tmp/x", workingDirectory: "/").level
                == .moderate)
        #expect(gated.limits.contains("Writes only under") && gated.limits.contains("exactly one match"))
        #expect(EditFileTool(writer: FileWriter(roots: nil)).limits.hasPrefix("No write confinement"))
        #expect(ToolRegistry().all.map(\.name).contains("edit_file"))
    }
}
