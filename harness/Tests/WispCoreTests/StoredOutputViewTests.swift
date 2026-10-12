import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The person's views of a tool's output (ADR 0050, "The person's views"): `/show` and `/last` show the whole stored
/// output when the model was given part of it, with a header saying so; otherwise what the tool returned and why;
/// the terminal pages a stored one only on a terminal; and `wisp chat --json` serves it a page at a time.
@Suite struct StoredOutputViewTests {
    /// A scratch directory, removed by the caller.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-stored-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `count` numbered lines, each ending in a newline.
    private static func lines(_ count: Int) -> String { (1...count).map { "line \($0)\n" }.joined() }

    /// A `tool.result` event of `session` for call `call`, with `output` as what the tool returned.
    private static func result(_ output: String, call: String = "c1", session: String = "s1") -> AuditEvent {
        AuditEvent(
            session: session, kind: .toolResult, turn: 1, call: call,
            details: ["tool": "run_command", "output": .string(output), "bytes": .int(output.utf8.count)])
    }

    /// What a tool returns when it held part of `call`'s output back and kept it.
    private static func heldBack(_ call: String) -> String {
        "line 1\n[… 98 lines held back …]\nline 100\nheld back: lines 2-99 (1 KiB); "
            + ChatOutput.keptPhrase + "\(call) (100 lines)"
    }

    @Test func bytePagesJoinToTheBytesAndEndAtLines() throws {
        let text = Self.lines(500)
        let data = Data(text.utf8)
        let first = try #require(Paging.bytePage(number: 1, size: 256, total: data.count) { data.subdata(in: $0) })
        var joined = Data()
        for number in 1...first.count {
            let page = try #require(
                Paging.bytePage(number: number, size: 256, total: data.count) { data.subdata(in: $0) })
            if number < first.count { #expect(page.data.last == 0x0A, "page \(number) ends at a line") }
            #expect(page.data.count <= 512)
            joined.append(page.data)
        }
        #expect(joined == data)
        #expect(Paging.bytePage(number: first.count + 1, size: 256, total: data.count) { data.subdata(in: $0) } == nil)
        #expect(Paging.bytePage(number: 0, size: 256, total: data.count) { data.subdata(in: $0) } == nil)
        // Nothing is one empty page; a line longer than a page is cut at a character boundary, never inside one.
        #expect(Paging.bytePage(number: 1, size: 8, total: 0) { _ in Data() }?.count == 1)
        let wide = Data(String(repeating: "é", count: 40).utf8)
        var pieces = Data()
        let count = try #require(Paging.bytePage(number: 1, size: 7, total: wide.count) { wide.subdata(in: $0) }).count
        for number in 1...count {
            let page = try #require(
                Paging.bytePage(number: number, size: 7, total: wide.count) { wide.subdata(in: $0) })
            #expect(String(data: page.data, encoding: .utf8) != nil, "page \(number) is whole characters")
            pieces.append(page.data)
        }
        #expect(pieces == wide)
    }

    @Test func theStorePagesAFileWithoutLoadingIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OutputStore(directory: dir)
        let text = Self.lines(2000)
        try #require(store.keep(text, id: "c1", tool: "run_command") != nil)
        let first = try #require(store.page("c1", number: 1, size: 1024))
        let all = (1...first.count).compactMap { store.page("c1", number: $0, size: 1024)?.text }.joined()
        #expect(all == text && first.count > 1)
        #expect(
            store.page("c1", number: first.count + 1, size: 1024) == nil && store.page("c9", number: 1, size: 1) == nil)
    }

    @Test func aHeldBackOutputIsShownWholeFromTheStoreWithAHeader() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        let store = OutputStore(directory: home.outputs.appending(path: "s1", directoryHint: .isDirectory))
        let whole = Self.lines(100)
        try #require(store.keep(whole, id: "c1", tool: "run_command") != nil)
        let output = ChatOutput.resolve(
            returned: Self.heldBack("c1"), event: Self.result(Self.heldBack("c1")), outputs: home.outputs)
        #expect(output.isStored && output.text == whole && output.sourceName == "stored")
        #expect(output.header.hasPrefix("output c1 from run_command: the whole of it, 100 lines"))
        #expect(!output.header.contains("cut"))
        #expect(output.source?.session == "s1")
        // The store's cut at its ceiling is said.
        let small = OutputStore(directory: store.directory, ceiling: 64)
        try #require(small.keep(whole, id: "c2", tool: "run_command") != nil)
        let cut = ChatOutput.resolve(
            returned: Self.heldBack("c2"), event: Self.result(Self.heldBack("c2"), call: "c2"), outputs: home.outputs)
        #expect(cut.text.utf8.count == 64)
        #expect(cut.header.contains("the store cut it at 64 bytes of \(ToolOutput.size(whole.utf8.count)): the rest"))
        // A typed command's output is found by its `stored` detail, the event having no call.
        let typed = AuditEvent(
            session: "s1", kind: .commandTyped, details: ["output": "head", "stored": "c1"])
        #expect(ChatOutput.resolve(returned: "head", event: typed, outputs: home.outputs).text == whole)
    }

    @Test func withNothingStoredTheViewSaysWhyAndShowsWhatTheToolReturned() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        // Nothing held back: the whole, as the tool returned it.
        let small = ChatOutput.resolve(returned: "a\nb\n", event: Self.result("a\nb\n"), outputs: home.outputs)
        #expect(small.whole == .returned && small.text == "a\nb\n")
        #expect(small.header == "the whole output: nothing was held back (2 lines, 4 bytes)")
        // Held back and kept, then swept: what the tool returned, and why.
        let swept = ChatOutput.resolve(
            returned: Self.heldBack("c7"), event: Self.result(Self.heldBack("c7"), call: "c7"), outputs: home.outputs)
        #expect(swept.whole == .gone("c7") && swept.text == Self.heldBack("c7"))
        #expect(
            swept.header.contains("output c7 is no longer in the output store") && swept.header.contains("outputDays"))
        #expect(swept.page(1)?.text == Self.heldBack("c7"))
        // Held back with no store (the audit off).
        let unkept = "head\nheld back: lines 2-9 (1 KiB); " + ChatOutput.notKeptPhrase
        let none = ChatOutput.resolve(returned: unkept, event: Self.result(unkept), outputs: nil)
        #expect(none.whole == .notKept && none.header.contains("audit.enabled was false") && none.text == unkept)
        // The phrase quoted on a line that is not the note is not taken for one.
        let quoted = "docs say: " + ChatOutput.keptPhrase + "abcd1234\n"
        #expect(ChatOutput.heldID(in: quoted) == nil && ChatOutput.heldID(in: Self.heldBack("c7")) == "c7")
    }

    @Test func thePagerIsUsedOnlyOnATerminalAndHonoursPAGER() {
        #expect(TerminalPager.command(environment: ["PAGER": "more"], isTerminal: false) == nil)
        #expect(TerminalPager.command(environment: [:], isTerminal: true) == "less -R")
        #expect(TerminalPager.command(environment: ["PAGER": "  "], isTerminal: true) == "less -R")
        #expect(TerminalPager.command(environment: ["PAGER": "most -s"], isTerminal: true) == "most -s")
        #expect(TerminalPager.Outcome.failed(127).shown == false && TerminalPager.Outcome.failed(1).shown)
    }

    @Test func thePagerGetsTheTextAndAPagerQuitEarlyIsNoHarm() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "paged.txt")
        #expect(TerminalPager.run("one\ntwo", command: "cat > '\(file.path)'") == .paged)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwo\n")
        // A pager that reads nothing and quits: the write ends on EPIPE, without SIGPIPE killing the test.
        #expect(TerminalPager.run(String(repeating: "x\n", count: 1 << 20), command: "exit 0").shown)
        #expect(TerminalPager.run("x", command: "no-such-pager-\(UUID().uuidString)") == .failed(127))
    }

    @Test func showAndLastPrintTheStoredWholeThenSayWhenItIsSwept() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(
            .init(entryPoint: .chat, autoApprove: true), home: home, dependencies: .testing(sink: sink))
        let tap = ChatEvents.Tap()
        let thread = try WispThread.setUp(
            session: session, audit: session.audit, host: session.host(approver: AutoApprover()),
            prompting: session.prompting, toolNames: ["run_command"], model: .system, observer: tap)
        let model = ScriptedModel(steps: [
            .call(name: "run_command", arguments: #"{"command":"seq 1 3000"}"#), .say("Three thousand."),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        var context = ChatLoopTests.context
        context.outputs = home.outputs
        let capture = ChatLoopTests.Capture(lines: ["count", "/last", "/quit"])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: capture.io)
        try await loop.run()
        let whole = (1...3000).map { "\($0)\n" }.joined()
        // The model was given the head and tail; /last prints every line, after a header saying so.
        let returned = try #require(tap.lastToolOutput)
        #expect(returned.contains("held back: ") && !returned.contains("\n1500\n"))
        #expect(capture.output.contains(whole))
        #expect(capture.noted.contains { $0.contains("from run_command: the whole of it, 3,0") }, "\(capture.noted)")
        // /show by the entry's number, and by its event id's start, does the same.
        let entry = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        let event = try #require(entry.sources.first?.event)
        let shown = ChatLoopTests.Capture(lines: ["/show \(entry.id)", "/show \(event.prefix(8))", "/quit"])
        var third = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: shown.io)
        try await third.run()
        #expect(shown.output.components(separatedBy: "\n1500\n").count == 3, "both print the whole")
        #expect(shown.noted.filter { $0.contains("the whole of it") }.count == 2)
        // Swept: the store's directory gone, /show says so and shows what the tool returned.
        try FileManager.default.removeItem(at: home.outputs)
        let again = ChatLoopTests.Capture(lines: ["/show \(entry.id)", "/last", "/quit"])
        var second = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: again.io)
        try await second.run()
        #expect(again.noted.filter { $0.contains("is no longer in the output store") }.count == 2)
        #expect(again.output.contains(returned) && !again.output.contains("\n1500\n"))
    }

    @Test func aFaceThatShowsTheOutputItselfGetsItWithCtrlCLeftToThePager() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tap = ChatEvents.Tap()
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])))
        tap.write(Self.result("small output"))
        let interrupt = ChatInterrupt()
        let presses = Mutex<[ChatInterrupt.Press]>([])
        let shown = Mutex<[String]>([])
        var context = ChatLoopTests.context
        context.interrupt = interrupt
        let capture = ChatLoopTests.Capture(lines: ["/last", "/quit"])
        var io = capture.io
        io.showOutput = { output in
            presses.withLock { $0.append(interrupt.press()) }
            shown.withLock { $0.append(output.text) }
            return true
        }
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context, io: io)
        try await loop.run()
        #expect(shown.withLock { $0 } == ["small output"] && presses.withLock { $0 } == [.paging])
        #expect(interrupt.press() == .idle && !capture.output.contains("small output"))
        // A face that declines (the pager for an output not stored) leaves the loop to print it.
        let printed = ChatLoopTests.Capture(lines: ["/last", "/quit"])
        var declining = printed.io
        declining.showOutput = { _ in false }
        var plain = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: declining)
        try await plain.run()
        #expect(printed.output.contains("small output\n") && printed.noted.contains { $0.contains("nothing was held") })
    }

    @Test func theProtocolServesAnOutputAPageAtATime() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        let store = OutputStore(directory: home.outputs.appending(path: "s1", directoryHint: .isDirectory))
        let whole = Self.lines(30_000)
        try #require(store.keep(whole, id: "c1", tool: "run_command") != nil)
        let event = Self.result(Self.heldBack("c1"))
        let id = try #require(event.id)
        // The request line parses and reaches the router's handler off the loop.
        let line = #"{"type":"output","id":"\#(id)","session":"s1","page":2}"#
        #expect(ChatProtocol.Inbound(line: line) == .output(id: id, session: "s1", page: 2))
        #expect(ChatProtocol.Inbound(line: #"{"type":"output","id":"e1"}"#) == .output(id: "e1", session: nil, page: 1))
        let router = LineRouter()
        let asked = Mutex<[String]>([])
        router.onOutput { id, session, page in asked.withLock { $0.append("\(id) \(session ?? "-") \(page)") } }
        router.receive(line)
        #expect(asked.withLock { $0 } == ["\(id) s1 2"])
        // Each page comes from the store, bounded, and the pages joined are the whole output.
        let audit = AuditLog(session: "s1", sink: MemoryAuditSink())
        let found = try #require(
            ChatOutput.find(id: id, session: "s1", audit: audit, last: event, outputs: home.outputs))
        let first = ChatProtocol.outputView(found, id: id, session: "s1", page: 1)
        let pages = try #require(first["pages"]?.intValue)
        #expect(pages > 1 && first["kind"] == "output" && first["source"] == "stored" && first["lines"] == .int(30_000))
        #expect(first["header"]?.stringValue?.contains("the whole of it") == true && first["cut"] == .bool(false))
        var joined = ""
        for page in 1...pages {
            let view = ChatProtocol.outputView(found, id: id, session: "s1", page: page)
            let text = try #require(view["text"]?.stringValue)
            #expect(text.utf8.count <= 2 * ChatOutput.pageBytes && view["page"] == .int(page))
            joined += text
        }
        #expect(joined == whole)
        let past = ChatProtocol.outputView(found, id: id, session: "s1", page: pages + 1)
        #expect(past["pages"] == .int(pages) && past["text"] == nil)
        // An id the conversation does not hold: no pages, and a header saying so.
        #expect(ChatOutput.find(id: "nope", session: "s1", audit: audit, last: event, outputs: home.outputs) == nil)
        let missing = ChatProtocol.outputView(nil, id: "nope", session: "s1", page: 1)
        #expect(missing["pages"] == .int(0) && missing["source"] == "missing")
        // The encoded line is one JSON object of type view.
        let encoded = ChatProtocol.encode("view", first)
        #expect(encoded.hasPrefix("{") && encoded.contains(#""type":"view""#) && !encoded.contains("\n"))
    }
}
