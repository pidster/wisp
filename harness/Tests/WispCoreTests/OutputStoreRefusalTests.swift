import Foundation
import Testing

@testable import WispCore

/// What the output store refuses and what it leaves behind when it cannot keep an output: a directory that cannot
/// be made, a file that cannot be opened, an empty output, an unsafe id. Each ends in nothing kept and nothing left.
@Suite struct OutputStoreRefusalTests {
    /// A fresh scratch directory.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-outstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store whose directory sits under a regular file cannot make it, so nothing is kept and nothing is read back.
    @Test func aDirectoryThatCannotBeMadeKeepsNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "blocker")
        try Data("a file".utf8).write(to: blocker)
        let store = OutputStore(directory: blocker.appending(path: "output", directoryHint: .isDirectory))
        #expect(store.keep("some output\n", id: "call1", tool: "run_command") == nil)
        #expect(store.kept("call1") == nil && store.text("call1") == nil && store.bytes == 0)
        #expect(store.spill("call1.out") == nil)
    }

    /// A file that cannot be opened (its name is taken by a directory) keeps nothing, however much is written.
    @Test func aFileThatCannotBeOpenedKeepsNothingAndLeavesNoRecord() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OutputStore(directory: root.appending(path: "output", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: store.url("taken"), withIntermediateDirectories: true)
        let writer = store.writer(id: "taken", tool: "read_file")
        writer.append(Data("lost\n".utf8))
        #expect(writer.finish() == nil)
        #expect(store.kept("taken") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url("taken.json").path))
    }

    /// An output with nothing in it is not kept, and its empty file is removed.
    @Test func anEmptyOutputIsNotKeptAndItsFileIsRemoved() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OutputStore(directory: root.appending(path: "output", directoryHint: .isDirectory))
        #expect(store.keep("", id: "empty", tool: "run_command") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url("empty").path))
        #expect(store.writer(id: "../escape", tool: "run_command").finish() == nil)
        #expect(store.kept("../escape") == nil && store.data("../escape") == nil)
    }
}
