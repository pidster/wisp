import Foundation
import Testing

@testable import WispCore

/// Recall's refusals: a stored output asked for where there is no store, or no such output, or by an id that would
/// leave the store; a task asked for where only other facts exist; and a filter of `.none` changing nothing.
@Suite struct RecallEdgeTests {
    /// A conversation with no output store says so rather than pretending the output was lost.
    @Test func anOutputAskedForWithoutAStoreSaysThereIsNone() {
        let found = Recall.material(
            .output("3f9a2c1b"), in: .init(store: ThreadRecord(), facts: []), read: { _ in nil })
        #expect(!found.found && found.lines.isEmpty)
        #expect(found.header == "memory: this conversation has no output store, so output 3f9a2c1b was not kept")
    }

    /// An id the store does not hold, or one that is no safe name, is not found, and the note shows what an id looks like.
    @Test func anOutputTheStoreDoesNotHoldIsNotFound() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-recall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OutputStore(directory: dir)
        store.keep("one\ntwo\n", id: "aaaa1111", tool: "run_command")
        let material = MemorySource.Material(store: ThreadRecord(), facts: [])
        for id in ["bbbb2222", "../aaaa1111"] {
            let found = Recall.material(.output(id), in: material, read: { _ in nil }, outputs: store)
            #expect(!found.found && found.header.hasPrefix("memory: no output \(id) in this conversation's store"))
            #expect(found.header.contains("output 3f9a2c1b"))
        }
        let held = Recall.material(.output("aaaa1111"), in: material, read: { _ in nil }, outputs: store)
        #expect(held.found && held.lines == ["one", "two"])
    }

    /// A task asked for when the conversation holds facts but no task and no prompt has nothing earlier to give.
    @Test func aTaskAskedForWithOnlyOtherFactsFindsNothingEarlier() {
        let other = RecallTests.fact("f1", subject: "cwd", value: "/tmp")
        let found = Recall.material(.task, in: .init(store: ThreadRecord(), facts: [other]), read: { _ in nil })
        #expect(!found.found && found.lines.isEmpty && found.header == Recall.nothingEarlier)
    }

    /// The `none` filter keeps every line as it is and adds no note.
    @Test func theNoneFilterChangesNothing() {
        let applied = Recall.Filter.none.apply(to: ["a", "b"])
        #expect(applied.lines == ["a", "b"] && applied.note == nil)
    }
}
