import Foundation
import Testing

@testable import WispCore

@Suite struct FileReaderTests {
    private func temporaryFile(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-fr-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    @Test func readsWholeSmallFile() throws {
        let path = try temporaryFile("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader().read(path: path)
        #expect(window == .init(firstLine: 1, lines: ["a", "b", "c"], hasMore: false, truncatedByBytes: false))
        #expect(window.rendered == "1\ta\n2\tb\n3\tc\n[end of file]")
    }

    @Test func pagesByOffsetAndLimit() throws {
        let path = try temporaryFile((1...10).map(String.init).joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try FileReader().read(path: path, offset: 1, limit: 4)
        #expect(first.lines == ["1", "2", "3", "4"])
        #expect(first.nextOffset == 5)
        let last = try FileReader().read(path: path, offset: 9, limit: 4)
        #expect(last.lines == ["9", "10"])
        #expect(last.nextOffset == nil)
        let beyond = try FileReader().read(path: path, offset: 50)
        #expect(beyond.lines.isEmpty)
        #expect(beyond.rendered.contains("(no lines in range)"))
    }

    @Test func exactLimitAtEndOfFileIsNotMore() throws {
        let path = try temporaryFile("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader().read(path: path, limit: 3)
        #expect(window.lines == ["a", "b", "c"])
        #expect(!window.hasMore)
        let unterminated = try temporaryFile("a\nb\nc")
        defer { try? FileManager.default.removeItem(atPath: unterminated) }
        #expect(!(try FileReader().read(path: unterminated, limit: 3)).hasMore)
        #expect(try FileReader().read(path: path, limit: 2).hasMore)
    }

    @Test func overLongLinesAreCutOnScalarBoundaries() {
        let data = Data("ab€cd".utf8)  // € is three bytes at offsets 2-4
        #expect(FileReader.utf8Prefix(data, maxBytes: 3) == "ab")
        #expect(FileReader.utf8Prefix(data, maxBytes: 4) == "ab")
        #expect(FileReader.utf8Prefix(data, maxBytes: 5) == "ab€")
        #expect(FileReader.utf8Prefix(data, maxBytes: 99) == "ab€cd")
    }

    @Test func honoursByteBudget() throws {
        let path = try temporaryFile("aaaa\nbbbb\ncccc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader(maxBytes: 9).read(path: path)
        #expect(window.lines == ["aaaa", "bbbb"])
        #expect(window.truncatedByBytes)
        #expect(window.nextOffset == 3)
    }

    @Test func streamsAcrossChunkBoundariesAndHandlesCRLF() throws {
        let path = try temporaryFile("one\r\ntwo\r\nthree")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader(chunkSize: 4).read(path: path)
        #expect(window.lines == ["one", "two", "three"])
        #expect(!window.hasMore)
    }

    @Test func stopsReadingOnceWindowIsFull() throws {
        let path = try temporaryFile(String(repeating: "x\n", count: 100_000))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader(chunkSize: 1024).read(path: path, offset: 10, limit: 2)
        #expect(window == .init(firstLine: 10, lines: ["x", "x"], hasMore: true, truncatedByBytes: false))
    }

    @Test func rejectsBadInputs() throws {
        let directory = FileManager.default.temporaryDirectory.path
        #expect(throws: FileReader.Failure.isDirectory(directory)) { try FileReader().read(path: directory) }
        #expect(throws: FileReader.Failure.notFound("/nonexistent/x")) { try FileReader().read(path: "/nonexistent/x") }
        let binary = try temporaryFile("ab\u{0}cd")
        defer { try? FileManager.default.removeItem(atPath: binary) }
        #expect(throws: FileReader.Failure.binary(binary)) { try FileReader().read(path: binary) }
        #expect(throws: FileReader.Failure.invalidRange) { try FileReader().read(path: binary, offset: 0) }
    }

    @Test func aWildcardThatMatchesNoFileIsADirectiveNotANotFound() throws {
        let failure = FileReader.Failure.pattern("test*.wisp")
        #expect(
            failure.description
                == "read_file takes one path, not a pattern: test*.wisp; list matches with run_command, e.g. ls test*.wisp"
        )
        for path in ["/nonexistent/test*.wisp", "/nonexistent/a?.txt", "/nonexistent/[ab].txt"] {
            #expect(throws: FileReader.Failure.pattern(path)) { try FileReader().read(path: path) }
        }
        // A file really named with a wildcard character is read.
        let directory = FileManager.default.temporaryDirectory.appending(path: "wisp-star-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let named = directory.appending(path: "a*b.txt")
        try Data("hi\n".utf8).write(to: named)
        #expect(try FileReader().read(path: named.path).lines == ["hi"])
        #expect(ToolOutput.error(failure).hasPrefix("error: read_file takes one path"))
    }

    @Test func lineScannerSplitsAcrossFeeds() {
        var scanner = LineScanner()
        #expect(scanner.feed(Data("ab".utf8)).isEmpty)
        #expect(scanner.feed(Data("c\nd\ne".utf8)) == [Data("abc".utf8), Data("d".utf8)])
        #expect(scanner.finish() == Data("e".utf8))
        #expect(scanner.finish() == nil)
    }
}
