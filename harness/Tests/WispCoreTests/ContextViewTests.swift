import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The model's context, viewable at any time at no model cost (decision D12 of the layered-context
/// proposal): chat's `/inspect context next` for the next request, `/inspect context N` for the context
/// composed at the start of a turn, and `/inspect context turns` for what changed at each; `wisp chat --json` sends them as `view` lines.
@Suite struct ContextViewTests {
    /// A scratch directory with a 30-line file.
    private func scratch() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-context-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "notes.txt")
        try Data(((1...30).map { "line \($0)" }.joined(separator: "\n") + "\n").utf8).write(to: file)
        return (dir, file)
    }

    @Test func chatShowsTheContextOfTheNextRequestAndOfEachTurn() async throws {
        let (dir, file) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = AuditLog(session: "view", sink: MemoryAuditSink())
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("Thirty lines."), .say("ok"),
        ])
        let agent = Agent(
            instructions: "x", tools: ToolRegistry(audit: audit).select(["read_file"]).tools,
            model: ResolvedModel(selection: .system, custom: model), audit: audit)
        let capture = ChatLoopTests.Capture(lines: [
            "read \(file.path)", "/inspect context turns", "/inspect context 1", "/inspect context 9",
            "/inspect context x", "next", "/inspect context next",
            "/quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context,
            io: capture.io)
        try await loop.run()
        let noted = capture.noted
        // `turns` lists the turn; `1` shows it with the output whole as the turn's own.
        #expect(capture.output.contains("| 1 | ") && capture.output.contains(" | read /"))
        #expect(capture.output.contains("# The context composed at the start of turn 1"))
        #expect(capture.output.contains("tool output: read_file · this turn's"))
        #expect(noted.contains("no turn 9: this conversation's turns run from 1 to 1"))
        #expect(noted.contains("usage: /inspect context [next|turns|N]"))
        // After the second turn, the next request carries the first output as a reference.
        let entry = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        #expect(capture.output.contains("# The context the next request carries"))
        #expect(capture.output.contains("tool output: read_file (sent as a reference)"))
        #expect(capture.output.contains("[output of entry \(entry.id) not repeated: read_file"))
    }

    @Test func aViewGoesToTheFrontEndsPanelWhenItHasOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("hi")])))
        let capture = ChatLoopTests.Capture(lines: ["hello", "/inspect context 1", "/inspect context turns", "/quit"])
        let views = ViewSink()
        var io = capture.io
        io.view = { view in views.views.withLock { $0.append(view) } }
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context, io: io)
        try await loop.run()
        let seen = views.views.withLock { $0 }
        #expect(seen.map(\.kind) == [.context, .turns] && seen.first?.turn == 1 && seen.first?.turns == 1)
        #expect(!capture.output.contains("# The context"))
        let line = ChatProtocol.view(ChatView(kind: .context, turn: 2, turns: 3, text: "# x"))
        #expect(line == ["kind": "context", "turn": .int(2), "turns": .int(3), "text": "# x"])
    }

    @Test func theTurnListSaysWhatChangedAndTheViewMarksEachEntry() throws {
        // Turn 2 dropped entries and referenced an output; turn 3 followed a reply with a cut.
        var store = ConversationStore()
        let text = { (content: String) in Transcript.Segment.text(.init(content: content)) }
        store.record(
            .prompt(.init(segments: [text("first\nprompt | with a pipe")])), origin: .turn, turn: 1, sources: [])
        store.record(
            .toolOutput(.init(id: "o", toolName: "notify", segments: [text(String(repeating: "x", count: 900))])),
            origin: .turn, turn: 1, sources: [])
        store.record(.response(.init(assetIDs: [], segments: [text("r")])), origin: .turn, turn: 1, sources: [])
        store.cut(3, [ConversationStore.Cut(segment: 0, start: 0, end: 1, output: 2, tool: "notify")])
        store.record(.prompt(.init(segments: [text("second")])), origin: .turn, turn: 2, sources: [])
        store.reference(2, from: 2)
        let composer = ContextComposer()
        let turn2 = composer.composition(store, atTurn: 2)
        #expect(turn2.map(\.own) == [false, false, false, true])
        #expect(turn2[1].referenced && turn2[2].cut && !turn2[0].referenced && !turn2[0].cut)
        let markdown = ContextView.markdown(turn2, title: "Turn 2")
        #expect(markdown.hasPrefix("# Turn 2\n\n4 entries from 2 turns, about "))
        #expect(markdown.contains("## 2 · turn 1 · tool output: notify (sent as a reference)"))
        #expect(markdown.contains("## 3 · turn 1 · reply (presentational text cut)"))
        #expect(markdown.contains("## 4 · turn 2 · prompt · this turn's\n\nsecond"))
        let row = ContextView.Turn(
            number: 2, time: nil, prompt: "a | b", tokens: 10, condensed: 0, cut: 1, referenced: 2)
        #expect(row.changes == "cut 1, referenced 2")
        #expect(
            ContextView.Turn(number: 1, time: nil, prompt: "", tokens: 0, condensed: 3, cut: 0, referenced: 0).changes
                == "condensed 3")
        #expect(
            ContextView.Turn(number: 1, time: nil, prompt: "", tokens: 0, condensed: 0, cut: 0, referenced: 0).changes
                == "none")
        let table = ContextView.table([row]) { "wisp://t/\($0)" }
        #expect(table.contains("| 2 | - | 10 | cut 1, referenced 2 | a \\| b | wisp://t/2 |"))
        #expect(!ContextView.table([row]).contains("wisp://"))
        #expect(ContextView.estimatedTokens([.prompt(.init(segments: [text("12345678")]))]) == 2)
    }
}

/// Collects the views a loop shows.
private final class ViewSink: Sendable {
    /// The views, in order.
    let views = Mutex<[ChatView]>([])
}
