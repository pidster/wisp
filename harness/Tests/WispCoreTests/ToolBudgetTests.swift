import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The tool-output budget and the output store (ADR 0050): the budget from the window, its floor and ceiling,
/// the agent keeping it current, a result fitted to it with its head and tail, the store keeping the whole,
/// `read_file` and recall paging by it, and a repeated call noticed.
@Suite struct ToolBudgetTests {
    @Test func theBudgetIsAnEighthOfTheWindowWithinTheFloorAndCeiling() {
        #expect(ToolBudget.bytes(forWindow: nil) == 4096)
        #expect(ToolBudget.bytes(forWindow: 8192) == 4096)
        #expect(ToolBudget.bytes(forWindow: 4096) == 4096)
        #expect(ToolBudget.bytes(forWindow: 53248) == 26624)
        #expect(ToolBudget.bytes(forWindow: 32768) == 16384)
        #expect(ToolBudget.bytes(forWindow: 131_072) == 65536)
        #expect(ToolBudget.bytes(forWindow: 1_048_576) == 65536)
        let budget = ToolBudget()
        #expect(budget.bytes == 4096 && budget.window == nil && !budget.memory)
        budget.window = 53248
        #expect(budget.bytes == 26624)
        budget.memory = true
        #expect(budget.memory)
    }

    @Test func theAgentKeepsTheBudgetAtItsWindowAsItBecomesKnown() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        let session = try Session.begin(.init(entryPoint: .respond), home: home, dependencies: .testing())
        let thread = try session.thread(id: "b", approver: DenyingApprover(reason: "no"), tools: .named(["read_file"]))
        #expect(thread.budget.window == nil && thread.budget.bytes == 4096)
        // A scripted model states no window: the floor, until an overflow reports one.
        let model = ScriptedModel(steps: [.say("one")], overflowOnce: true)
        model.script.overflowSize.withLock { $0 = (contextSize: 65536, tokenCount: 70000) }
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        #expect(agent.toolBudget === thread.budget)
        _ = try await agent.respond(to: "hi")
        #expect(agent.contextSize == 65536 && thread.budget.bytes == 32768)
        // A conversation given memory marks its budget so, one without does not.
        let withMemory = try session.thread(id: "m", approver: DenyingApprover(reason: "no"), tools: .named(["memory"]))
        #expect(withMemory.budget.memory && !thread.budget.memory)
        // The store lives under the home by the thread's audit session, and the agent's runner shares it.
        #expect(thread.outputs?.directory == home.outputs.appending(path: "b", directoryHint: .isDirectory))
    }

    @Test func aFitShowsTheHeadAndTailAndAccountsForEveryLineBetween() {
        let lines = (1...100).map { "line \($0) of the output" }
        let whole = lines.joined(separator: "\n") + "\n"
        let fits = ToolOutput.fit(head: whole, tail: whole, within: 10_000)
        #expect(fits.shown == whole && fits.held == nil)
        let fit = ToolOutput.fit(head: whole, tail: whole, within: 400)
        let held = try! #require(fit.held)
        let shown = fit.shown.split(separator: "\n").map(String.init)
        #expect(shown.first == "line 1 of the output" && shown.last == "line 100 of the output")
        let marker = try! #require(shown.firstIndex { $0.hasPrefix("[… ") })
        // The lines before the marker are 1...held.firstLine-1, after it held.lastLine+1...100.
        #expect(shown[marker - 1] == "line \(held.firstLine - 1) of the output")
        #expect(shown[marker + 1] == "line \(held.lastLine + 1) of the output")
        #expect(held.lines == 100 - (shown.count - 1) && held.bytes > 0)
        #expect(shown[marker] == "[… \(held.lines) lines (\(ToolOutput.size(held.bytes))) held back …]")
        #expect(fit.shown.utf8.count <= 400 + 80)
        // In pieces: the head's last and the tail's first line may be fragments and are not shown.
        let pieces = ToolOutput.fit(
            head: "alpha\nbeta\ngam", tail: "ta\nomega\n", total: (lines: 9, bytes: 60), within: 400, lineOffset: 2)
        #expect(pieces.shown == "alpha\nbeta\n[… 6 lines (43 bytes) held back …]\nomega")
        #expect(pieces.held == .init(firstLine: 5, lastLine: 10, bytes: 43))
        // One over-long line is cut on a character boundary and marked.
        let long = String(repeating: "é", count: 3000)
        let cut = ToolOutput.fit(head: long, tail: long, within: 300)
        #expect(cut.shown.hasSuffix("…") || cut.held != nil)
        #expect(cut.shown.utf8.count <= 400)
        #expect(ToolOutput.size(640) == "640 bytes" && ToolOutput.size(180 * 1024) == "180 KiB")
        #expect(ToolOutput.size(3 << 20) == "3.0 MiB")
    }

    @Test func aFittedResultIsKeptWholeInTheStoreUnderTheCallsID() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let store = OutputStore(directory: dir, audit: AuditLog(session: "s", sink: sink))
        let budget = ToolBudget(window: 8192, memory: true)
        let text = (1...600).map { "row \($0): some words that make the line longer" }.joined(separator: "\n")
        let fitted = ToolCallContext.$call.withValue("0123abcd") {
            ToolOutput.fitted(text, tool: "inspect", budget: budget, store: store)
        }
        #expect(fitted.utf8.count <= 4096, "\(fitted.utf8.count)")
        #expect(fitted.hasPrefix("row 1: ") && fitted.contains("held back …]"))
        #expect(fitted.contains("the whole output is kept as output 0123abcd (600 lines)"))
        #expect(fitted.contains("memory \"recall output 0123abcd from line "))
        #expect(!fitted.contains("do not run the command again"))
        let kept = try #require(store.kept("0123abcd"))
        #expect(kept.lines == 600 && kept.bytes == text.utf8.count && !kept.cut && kept.tool == "inspect")
        #expect(kept.sha256.count == 64 && store.text("0123abcd") == text && store.lines("0123abcd")?.count == 600)
        #expect(store.bytes >= text.utf8.count)
        let event = try #require(sink.events.first { $0.kind == .outputKept })
        #expect(
            event.call == "0123abcd" && event.details["tool"] == "inspect"
                && event.details["sha256"] == .string(kept.sha256))
        #expect(event.summary.contains("output.kept"))
        // Within the budget nothing is kept; without memory the note names no recall; a bad id is refused.
        #expect(ToolOutput.fitted("short", tool: "inspect", budget: budget, store: store) == "short")
        budget.memory = false
        let plain = ToolOutput.fitted(text, tool: "inspect", budget: budget, store: store)
        #expect(plain.contains("is kept as output ") && !plain.contains("memory"))
        #expect(store.kept("../x") == nil && store.data("nope") == nil)
        // The store composes parts, streaming a file in, and removes it when asked.
        let part = dir.appending(path: "part.txt")
        try Data("middle\n".utf8).write(to: part)
        let composed = try #require(
            store.compose([.text("top\n"), .file(part, remove: true), .text("end")], id: "feedface", tool: "t"))
        #expect(composed.lines == 3 && store.text("feedface") == "top\nmiddle\nend")
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func readFilePagesByTheBudgetAndRefusesWhatIsNotARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "f.txt")
        try Data((1...2000).map { "line \($0) with a little text" }.joined(separator: "\n").utf8).write(to: file)
        var reader = FileReader()
        let budget = ToolBudget(window: 32768)
        reader.budget = budget
        #expect(reader.pageBytes == 16384)
        let page = try reader.read(path: file.path, limit: 10_000)
        #expect(page.truncatedByBytes && page.lines.count > 400 && page.lines.count < 700)
        // A FIFO is refused before it is opened, so the read cannot block waiting for a writer.
        let fifo = dir.appending(path: "pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: FileReader.Failure.notRegular(fifo.path, kind: "fifo")) { try reader.read(path: fifo.path) }
        #expect(throws: FileReader.Failure.notRegular("/dev/null", kind: "character device")) {
            try reader.read(path: "/dev/null")
        }
        #expect(
            FileReader.Failure.notRegular("/p", kind: "fifo").description.hasPrefix("not a regular file: /p is a fifo"))
        // A file with no newline at all is read by bytes: one page of it, not the whole file in memory.
        let endless = dir.appending(path: "endless.txt")
        try Data(repeating: 0x61, count: 3 << 20).write(to: endless)
        let window = try FileReader(maxBytes: 1000).read(path: endless.path)
        #expect(window.lines == [String(repeating: "a", count: 1000)] && !window.hasMore)
        var scanner = LineScanner(keep: 16)
        #expect(scanner.feed(Data(repeating: 0x62, count: 10_000)).isEmpty && scanner.pendingBytes == 16)
        #expect(scanner.feed(Data("\ncd".utf8)) == [Data(repeating: 0x62, count: 16)] && scanner.hasPending)
        #expect(scanner.finish() == Data("cd".utf8))
    }

    @Test func writeAndAppendDoNotLoadTheExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "big.txt")
        // Larger than the writer's replacement limit, which append and write never consult.
        try Data(repeating: 0x7A, count: 3 << 20).write(to: file)
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)], maxBytes: 1 << 20)
        let appended = try writer.apply(.append("tail\n"), to: file.path)
        #expect(appended.bytesBefore == 3 << 20 && appended.bytesAfter == (3 << 20) + 5 && !appended.created)
        let handle = try FileHandle(forReadingFrom: file)
        try handle.seek(toOffset: UInt64(3 << 20))
        #expect(try handle.readToEnd() == Data("tail\n".utf8))
        try handle.close()
        let written = try writer.apply(.write("fresh\n"), to: file.path)
        #expect(written.bytesBefore == (3 << 20) + 5 && written.bytesAfter == 6)
        #expect(try String(contentsOf: file, encoding: .utf8) == "fresh\n")
        #expect(throws: FileWriter.Failure.self) {
            try writer.apply(.replace(find: "x", replacement: "y"), to: file.path)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["big.txt"])
    }

    @Test func aRepeatedCallIsNoticedWithinATurnAndNotAcrossTurns() async throws {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let ledger = CallLedger()
        let tool = AuditedTool(CurrentDateTool(), audit: audit, ledger: ledger)
        audit.beginTurn()
        let first = try await tool.call(arguments: .init(timeZone: "UTC"))
        #expect(!first.hasPrefix("[repeated call"))
        let second = try await tool.call(arguments: .init(timeZone: "UTC"))
        #expect(second.hasPrefix(AuditedTool<CurrentDateTool>.repeatedLine(tool: "current_date", repeats: 2) + "\n"))
        #expect(second.contains("as 1 earlier call this turn"))
        let other = try await tool.call(arguments: .init(timeZone: "Asia/Tokyo"))
        #expect(!other.hasPrefix("[repeated call"))
        let third = try await tool.call(arguments: .init(timeZone: "UTC"))
        #expect(third.contains("as 2 earlier calls this turn"))
        audit.beginTurn()
        #expect(!(try await tool.call(arguments: .init(timeZone: "UTC"))).hasPrefix("[repeated call"))
        let results = sink.events.filter { $0.kind == .toolResult }
        #expect(results.map { $0.details["repeat"] } == [nil, .int(2), nil, .int(3), nil])
        #expect(results.allSatisfy { Set($0.details.keys).isSubset(of: AuditEvent.fields(for: .toolResult)) })
    }

    @Test func inspectListsATurnsCallsOneLineEachAndFiltersAuditByTurn() async throws {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-calls-\(UUID().uuidString)"))
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = try FileAuditSink(url: home.auditFile)
        let log = AuditLog(session: "s", sink: sink)
        log.beginTurn()
        log.record(.toolCall, call: "c1", details: ["tool": "run_command", "arguments": #"{"command":"swift build"}"#])
        log.record(.commandOutcome, details: ["command": "swift build", "exitStatus": 1, "timedOut": false])
        log.record(.toolResult, call: "c1", details: ["tool": "run_command", "output": "exit status: 1", "bytes": 14])
        log.record(.toolCall, call: "c2", details: ["tool": "read_file", "arguments": #"{"path":"/a"}"#])
        log.record(.toolResult, call: "c2", details: ["tool": "read_file", "output": "1\tx", "bytes": 3])
        log.record(.toolCall, call: "c3", details: ["tool": "inspect", "arguments": #"{"what":"audit"}"#])
        log.record(.toolResult, call: "c3", details: ["tool": "inspect", "output": "error: nope", "bytes": 11])
        log.beginTurn()
        log.record(.toolCall, call: "c4", details: ["tool": "notify", "arguments": "{}"])
        log.record(.error, call: "c4", details: ["message": "boom"])
        let views = Introspection(
            home: home, config: Config().resolved, store: ApprovalStore(url: nil),
            status: { ["session": "s", "turn": 2] })
        let tool = InspectTool(introspection: views)
        let calls = await tool.call(arguments: .init(what: "calls", last: nil, kind: nil, session: nil, turn: 1))
        #expect(
            calls == """
                turn 1: 3 tool calls
                1. run_command {"command":"swift build"} → exit status 1
                2. read_file {"path":"/a"} → ok, 3 bytes
                3. inspect {"what":"audit"} → error: nope
                """, "\(calls)")
        let current = await tool.call(arguments: .init(what: "calls", last: nil, kind: nil, session: nil, turn: nil))
        #expect(current == "turn 2: 1 tool call\n1. notify {} → threw: boom")
        #expect(
            await tool.call(arguments: .init(what: "calls", last: nil, kind: nil, session: nil, turn: 9))
                == "no tool calls in turn 9")
        let turn = await tool.call(arguments: .init(what: "audit", last: nil, kind: nil, session: nil, turn: 2))
        #expect(turn.split(separator: "\n").count == 2 && turn.contains("notify") && !turn.contains("swift build"))
        #expect(tool.limits.contains("calls lists a turn's tool calls"))
    }
}
