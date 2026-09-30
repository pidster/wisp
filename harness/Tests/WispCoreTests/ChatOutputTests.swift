import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// wisp shows tool output; the model does not retype it (decision D12 of the layered-context proposal): the
/// terminal chat prints each output under its note, folded past `shownOutputLines`; `/show` prints one in
/// full; and `wisp chat --json` carries it on the `tool.result` event.
@Suite struct ChatOutputTests {
    /// A `tool.result` event with `output`.
    static func result(_ output: String, tool: String = "read_file") -> AuditEvent {
        AuditEvent(
            session: "s", kind: .toolResult, turn: 1, call: "c1",
            details: ["tool": .string(tool), "output": .string(output), "bytes": .int(output.utf8.count)])
    }

    /// `count` numbered lines.
    static func lines(_ count: Int) -> String { (1...count).map { "line \($0)" }.joined(separator: "\n") }

    @Test func outputIsShownUnderItsNoteAndFoldedPastTheSetting() throws {
        let short = try #require(ChatEvents.shownOutput(Self.result("one\ntwo\n"), lines: 20, style: .plain))
        #expect(short == "    one\n    two")
        let event = Self.result(Self.lines(30))
        let long = try #require(ChatEvents.shownOutput(event, lines: 20, style: .plain))
        let shown = long.split(separator: "\n")
        #expect(shown.count == 21 && shown[0] == "    line 1" && shown[19] == "    line 20")
        let id = try #require(event.id)
        #expect(shown[20] == "    … 10 more lines, \(Self.lines(30).utf8.count) bytes in all: /show \(id.prefix(8))")
        // 0 shows the note alone; other events and empty output show nothing.
        #expect(ChatEvents.shownOutput(event, lines: 0, style: .plain) == nil)
        #expect(ChatEvents.shownOutput(Self.result(""), lines: 20, style: .plain) == nil)
        let call = AuditEvent(session: "s", kind: .toolCall, details: ["output": "x"])
        #expect(ChatEvents.shownOutput(call, lines: 20, style: .plain) == nil)
        // Styled, every line is in the quiet tone.
        let styled = try #require(ChatEvents.shownOutput(Self.result("a"), lines: 5, style: Style(enabled: true)))
        #expect(styled == Style(enabled: true).muted("    a"))
    }

    @Test func aFoldKeepsWithinTheByteBoundAndCutsAVeryLongLine() {
        let wide = String(repeating: "x", count: 900)
        let fold = ChatEvents.folded([wide, wide, wide, "tail"].joined(separator: "\n"), lines: 20)
        #expect(fold.shown.count == 2 && fold.hidden == 2)
        let huge = ChatEvents.folded(String(repeating: "y", count: 5000), lines: 20)
        #expect(huge.shown.count == 1 && huge.shown[0].count == ChatEvents.shownOutputBytes / 2 + 1 && huge.hidden == 0)
    }

    @Test func theJSONEventCarriesTheOutputAndTheFoldSize() throws {
        let event = Self.result(Self.lines(30) + "\n")
        let fields = ChatProtocol.event(event, shownLines: 12)
        let output = try #require(fields["output"]?.objectValue)
        #expect(output["id"] == .string(event.id ?? "") && output["text"] == .string(Self.lines(30) + "\n"))
        #expect(output["lines"] == .int(30) && output["bytes"] == .int(Self.lines(30).utf8.count + 1))
        #expect(output["shownLines"] == .int(12) && output["truncated"] == .bool(false))
        // Only a tool result has it; a large output is cut to a page and says so.
        #expect(ChatProtocol.event(AuditEvent(session: "s", kind: .toolCall))["output"] == nil)
        let big = String(repeating: "z", count: Paging.pageBytes + 10)
        let cut = try #require(ChatProtocol.event(Self.result(big))["output"]?.objectValue)
        #expect(cut["truncated"] == .bool(true) && cut["text"]?.stringValue?.utf8.count == Paging.pageBytes)
    }

    @Test func pagesSplitAtLinesAndCutAnOverlongOne() throws {
        let text = ["aaaa", "bbbb", "cccc"].joined(separator: "\n")
        #expect(Paging.page(text, number: 1, size: 9)?.text == "aaaa\nbbbb")
        #expect(
            Paging.page(text, number: 2, size: 9)?.text == "cccc" && Paging.page(text, number: 2, size: 9)?.count == 2)
        #expect(Paging.page(text, number: 3, size: 9) == nil && Paging.page(text, number: 0, size: 9) == nil)
        #expect(Paging.page("abcdefghij", number: 2, size: 4)?.text == "efgh")
        #expect(Paging.page("", number: 1)?.text == "")
    }

    /// A scratch directory with a 30-line file.
    private func scratch() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "notes.txt")
        try Data((Self.lines(30) + "\n").utf8).write(to: file)
        return (dir, file)
    }

    @Test func chatShowsTheOutputFoldsItAndShowsItAgain() async throws {
        let (dir, file) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
        let tap = ChatEvents.Tap()
        let thread = try WispThread.setUp(
            session: session, audit: session.audit,
            host: session.host(approver: DenyingApprover(reason: "not in tests")),
            prompting: session.prompting, toolNames: ["read_file"], model: .system, observer: tap)
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("Thirty lines."), .say("ok"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        let capture = ChatLoopTests.Capture(lines: ["read \(file.path)", "/show", "/show 99", "/quit"])
        var context = ChatLoopTests.context
        context.shownOutputLines = 5
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: capture.io)
        try await loop.run()
        let noted = capture.noted
        // The note, then the first five lines and the fold line, on the notes channel.
        let shown = try #require(noted.first { $0.hasPrefix("    1\tline 1") })
        #expect(shown.split(separator: "\n").count == 6 && shown.contains("… 26 more lines"))
        let entry = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        let id = try #require(entry.sources.first?.event)
        #expect(shown.hasSuffix("/show \(id.prefix(8))"))
        // /show with no id prints the last output whole, to stdout; an unknown id says so.
        #expect(capture.output.contains("30\tline 30\n[end of file]"))
        #expect(noted.contains("no tool output 99"))
    }

    @Test func showFindsAnOutputByEntryOrEventID() {
        var store = ThreadRecord()
        store.record(
            .toolOutput(.init(id: "o1", toolName: "read_file", segments: [.text(.init(content: "first"))])),
            origin: .turn, turn: 1, sources: [AuditReference(session: "s", turn: 1, event: "abcdef0123456789")])
        store.record(
            .toolOutput(.init(id: "o2", toolName: "read_file", segments: [.text(.init(content: "second"))])),
            origin: .turn, turn: 1, sources: [AuditReference(session: "s", turn: 1, event: "abcd999999999999")])
        #expect(ChatEvents.output("1", in: store, last: nil) == "first")
        #expect(ChatEvents.output("abcdef01", in: store, last: nil) == "first")
        #expect(ChatEvents.output("abcd", in: store, last: nil) == nil)  // two match
        #expect(ChatEvents.output("abc", in: store, last: nil) == nil)  // too short
        #expect(ChatEvents.output("7", in: store, last: nil) == nil)
        #expect(ChatEvents.output(nil, in: store, last: nil) == "second")
        #expect(ChatEvents.output(nil, in: store, last: "live") == "live")
        #expect(ChatEvents.output(nil, in: ThreadRecord(), last: nil) == nil)
    }
}
