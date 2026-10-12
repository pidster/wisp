import Foundation
import Testing

@testable import WispCore

/// `memory`'s condense and summarise over a stored output, driven without a model: a chunk that fails is counted
/// and the others answer, answers that do not fit are combined by a further question, the combined answer is
/// bounded, and a request that names a turn, or nothing stored, is refused.
@Suite struct MemoryCondenseTests {
    /// A store holding one long output of `lines` rows under `id`, and a tool over it with `condenser`.
    private func tool(
        lines: Int, id: String, condenser: OutputCondenser?, sink: MemoryAuditSink = MemoryAuditSink()
    ) -> (tool: MemoryTool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-condense-\(UUID().uuidString)")
        let store = OutputStore(directory: dir)
        let text = (1...lines).map { "row \($0): " + String(repeating: "q", count: 50) }.joined(separator: "\n") + "\n"
        store.keep(text, id: id, tool: "run_command")
        let source = MemorySource()
        source.publish(store: ThreadRecord(), facts: [], kinds: nil, turn: 1)
        let tool = MemoryTool(
            source: source, audit: AuditLog(session: "s", sink: sink), store: store, condenser: condenser)
        return (tool, dir)
    }

    /// A failed chunk is counted and named, the answers of the others are combined when together they do not fit,
    /// and the result stays within the budget.
    @Test func answersThatDoNotFitAreCombinedAndAFailedChunkIsCounted() async {
        let condenser = OutputCondenser()
        let sink = MemoryAuditSink()
        let (memory, dir) = tool(lines: 200, id: "aaaa1111", condenser: condenser, sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Unavailable: Error {}
        condenser.attach { prompt in
            if prompt.contains("Combine them into") { return "one combined answer" }
            if prompt.contains("part 2 of") { throw Unavailable() }
            return String(repeating: "x", count: 2500)
        }
        let answer = await memory.call(arguments: .init(request: "condense output aaaa1111: what is repeated"))
        #expect(answer.contains("(1 chunk failed):\none combined answer"), "\(answer)")
        #expect(answer.utf8.count <= 4096)
        let event = sink.events.last { $0.kind == .memory }
        #expect(event?.details["failure"] == "1 chunk failed" && event?.details["output"] == "aaaa1111")
        // When the combining question fails too, the answers are given as they are, cut to the room.
        condenser.attach { prompt in
            if prompt.contains("Combine them into") { throw Unavailable() }
            return String(repeating: "x", count: 2500)
        }
        let uncombined = await memory.call(arguments: .init(request: "condense output aaaa1111: what is repeated"))
        #expect(uncombined.contains("part 1: xxxx") && uncombined.utf8.count <= 4096)
    }

    /// Chunks whose answer is "nothing here" are left out, and when all say it the answer says nothing answers.
    @Test func whenNoChunkAnswersTheResultSaysSo() async {
        let condenser = OutputCondenser()
        let (memory, dir) = tool(lines: 20, id: "bbbb2222", condenser: condenser)
        defer { try? FileManager.default.removeItem(at: dir) }
        condenser.attach { _ in "Nothing here." }
        let answer = await memory.call(arguments: .init(request: "condense output bbbb2222: where is the error"))
        #expect(answer.hasSuffix(":\nnothing in the output answers it"), "\(answer)")
    }

    /// A stored output is summarised by its id, and the tool that made it is read from the store.
    @Test func aStoredOutputIsSummarisedByItsID() async {
        let (memory, dir) = tool(lines: 30, id: "cccc3333", condenser: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = await memory.call(arguments: .init(request: "summarise output cccc3333 overview"))
        #expect(summary.hasPrefix("overview (exact readers, no model): 30 lines, "), "\(summary)")
        let missing = await memory.call(arguments: .init(request: "summarise output dddd4444"))
        #expect(missing.hasPrefix("memory: no output dddd4444 in this conversation's store"))
        let turn = await memory.call(arguments: .init(request: "condense turn 1: why"))
        #expect(turn.hasPrefix("error: name a stored entry"))
    }
}
