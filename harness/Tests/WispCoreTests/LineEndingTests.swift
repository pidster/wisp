import Foundation
import Testing

@testable import WispCore

/// Line endings through `read_file` and `edit_file`: CRLF, classic Mac (CR alone), mixed, and no final line break.
/// Lines are split on bytes (`TextLines`), never on `Character`, which reads `"\r\n"` as one grapheme: before
/// 2026-10-12 a CRLF file was one line to `FileWriter`, so an edit of its line 1 replaced the whole file.
@Suite struct LineEndingTests {
    /// The files every test runs over: (name, bytes). Each has three lines, `one`, `  two`, `three`.
    static let files: [(String, String)] = [
        ("lf", "one\n  two\nthree\n"),
        ("crlf", "one\r\n  two\r\nthree\r\n"),
        ("cr", "one\r  two\rthree\r"),
        ("mixed", "one\r\n  two\nthree\r"),
        ("crlf-no-final", "one\r\n  two\r\nthree"),
        ("cr-no-final", "one\r  two\rthree"),
    ]

    /// A scratch directory under the temporary directory, which is inside the default writable set.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-endings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `text` to `name` in `dir` and returns its path.
    private func file(_ text: String, named name: String, in dir: URL) throws -> String {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    /// The file's bytes as text, for comparing exactly (a `String` compares `"\r\n"` and `"\n"` as different).
    private func contents(_ path: String) throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path))) }

    @Test func textLinesSplitEveryEndingAndGiveTheBytesBack() {
        let crlf = TextLines(Array("a\r\nb\r\n".utf8))
        #expect(
            crlf.count == 2 && crlf.segments.map(\.ending) == [.carriageReturnLineFeed, .carriageReturnLineFeed, .none])
        #expect(TextLines(Array("a\rb".utf8)).count == 2)
        #expect(TextLines(Array("a\r\n\r\n".utf8)).count == 2)
        #expect(
            TextLines(Array("\r\r\n\n".utf8)).segments.map(\.ending) == [
                .carriageReturn, .carriageReturnLineFeed, .lineFeed, .none,
            ])
        #expect(TextLines([]).count == 0 && TextLines(Array("x".utf8)).count == 1)
        for (name, text) in Self.files {
            let lines = TextLines(Array(text.utf8))
            #expect(lines.count == 3, "\(name)")
            #expect(lines.bytes == Array(text.utf8), "\(name)")
            #expect((0..<3).map(lines.text) == ["one", "  two", "three"], "\(name)")
        }
        // The dominant ending, ties to the line feed; none at all is the line feed.
        #expect(TextLines(Array("a\r\nb\r\nc\n".utf8)).dominantEnding == .carriageReturnLineFeed)
        #expect(TextLines(Array("a\r\nb\n".utf8)).dominantEnding == .lineFeed)
        #expect(TextLines(Array("a\rb\r".utf8)).dominantEnding == .carriageReturn)
        #expect(TextLines(Array("a".utf8)).dominantEnding == .lineFeed)
        // Normalised, a CRLF is one line feed whose origin is the carriage return.
        let flat = TextLines.normalised(Array("a\r\nb\rc".utf8))
        #expect(flat.bytes == Array("a\nb\nc".utf8) && flat.origins == [0, 1, 3, 4, 5, 6])
        #expect(
            TextLines.converting(Array("x\ny\r\nz\r".utf8), to: .carriageReturnLineFeed)
                == Array("x\r\ny\r\nz\r\n".utf8))
        #expect(TextLines.occurrences(of: Array("ab".utf8), in: Array("abab a".utf8)) == [0..<2, 2..<4])
        #expect(TextLines.occurrences(of: [], in: Array("a".utf8)).isEmpty)
        // Tool output splits at line feeds only, on scalars, so CRLF output has lines and joins back exactly.
        #expect("a\r\nb\r\n".split(separator: "\n", omittingEmptySubsequences: false).count == 1)
        #expect(TextLines.splitAtLineFeeds("a\r\nb\r\n") == ["a\r", "b\r", ""])
        #expect(ToolOutput.lines("a\r\nb\r\n") == ["a\r", "b\r"])
    }

    @Test func readFileNumbersLinesAsEditFileDoes() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in Self.files {
            let path = try file(text, named: name, in: dir)
            let window = try FileReader().read(path: path)
            #expect(window.lines == ["one", "  two", "three"] && !window.hasMore, "\(name): \(window.lines)")
            let lines = TextLines(Array(text.utf8))
            #expect(window.lines == (0..<lines.count).map(lines.text), "\(name)")
            // Read in chunks of every size, so a CRLF split across two chunks is one ending, not an empty line.
            for size in 1...4 {
                let chunked = try FileReader(chunkSize: size).read(path: path)
                #expect(chunked.lines == window.lines && !chunked.hasMore, "\(name), chunks of \(size)")
                let first = try FileReader(chunkSize: size).read(path: path, limit: 2)
                #expect(first.lines == ["one", "  two"] && first.hasMore, "\(name), chunks of \(size)")
                let last = try FileReader(chunkSize: size).read(path: path, offset: 3, limit: 1)
                #expect(last.lines == ["three"] && !last.hasMore, "\(name), chunks of \(size)")
            }
        }
        // The window that fills on a line whose CRLF is split from its line feed, with nothing after, is the end.
        let path = try file("ab\r\n", named: "split", in: dir)
        #expect(try FileReader(chunkSize: 3).read(path: path, limit: 1).hasMore == false)
    }

    @Test func aLineEditChangesThatLineAloneInEveryFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        for (name, text) in Self.files {
            for line in 1...3 {
                let path = try file(text, named: "\(name)-\(line)", in: dir)
                let result = try writer.apply(.replaceLine(line, content: "  new", expecting: nil), to: path)
                var expected = TextLines(Array(text.utf8))
                expected.segments[line - 1].text = Array("  new".utf8)
                // Byte for byte: every other line, and every ending, as it was.
                #expect(try contents(path) == expected.bytes, "\(name), line \(line)")
                #expect(result.line == line && result.nowReads == ["  new"], "\(name), line \(line)")
                #expect(result.rendered.hasSuffix("line \(line) now: \"  new\""), "\(name): \(result.rendered)")
            }
            let path = try file(text, named: "\(name)-past", in: dir)
            #expect(throws: FileWriter.Failure.noSuchLine(4, lines: 3)) {
                try writer.apply(.replaceLine(4, content: "x", expecting: nil), to: path)
            }
        }
        // The bug: line 1 of a CRLF file was the whole file, and editing it replaced everything.
        let crlf = try file("[app]\r\nversion=1.2.0\r\nchannel=stable\r\n", named: "app.ini", in: dir)
        _ = try writer.apply(.replaceLine(1, content: "[service]", expecting: "[app]"), to: crlf)
        #expect(try contents(crlf) == Array("[service]\r\nversion=1.2.0\r\nchannel=stable\r\n".utf8))
        _ = try writer.apply(.replaceLine(2, content: "version=1.3.0", expecting: "1.2.0"), to: crlf)
        #expect(try contents(crlf) == Array("[service]\r\nversion=1.3.0\r\nchannel=stable\r\n".utf8))
        // A trailing ending of any kind is dropped from the content; a line break inside it is refused.
        _ = try writer.apply(.replaceLine(3, content: "channel=beta\r\n", expecting: nil), to: crlf)
        #expect(try contents(crlf) == Array("[service]\r\nversion=1.3.0\r\nchannel=beta\r\n".utf8))
        for content in ["a\rb", "a\r\nb", "a\nb\n"] {
            #expect(throws: FileWriter.Failure.notOneLine(1)) {
                try writer.apply(.replaceLine(1, content: content, expecting: nil), to: crlf)
            }
        }
        #expect(try contents(crlf) == Array("[service]\r\nversion=1.3.0\r\nchannel=beta\r\n".utf8))
    }

    @Test func aLineEditKeepsIndentationAndReconcilesAStaleNumberInACRLFFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let path = try file("def f():\r\n    return 1\r\n\r\ndef g():\r\n    return 2\r\n", named: "b.py", in: dir)
        let moved = try writer.apply(.replaceLine(1, content: "return 10", expecting: "return 1"), to: path)
        #expect(try contents(path) == Array("def f():\r\n    return 10\r\n\r\ndef g():\r\n    return 2\r\n".utf8))
        #expect(
            moved.line == 2 && moved.movedFrom == .init(line: 1, find: "return 1") && moved.keptIndentation == "    ")
        #expect(moved.rendered.hasSuffix("line 2 now: \"    return 10\""), "\(moved.rendered)")
        #expect(throws: FileWriter.Failure.lineMismatch(3, expected: "return", actual: "")) {
            try writer.apply(.replaceLine(3, content: "x", expecting: "return"), to: path)
        }
        // A classic Mac file too.
        let mac = try file("if x:\r\ta = 1\rend\r", named: "m.txt", in: dir)
        let kept = try writer.apply(.replaceLine(3, content: "a = 2", expecting: "a = 1"), to: mac)
        #expect(try contents(mac) == Array("if x:\r\ta = 2\rend\r".utf8) && kept.keptIndentation == "\t")
    }

    @Test func aFindReplacementMatchesAnyEndingAndWritesTheFilesOwn() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let original = "a\r\nb\r\nc\r\nd\r\n"
        // Within a line.
        let within = try file(original, named: "within", in: dir)
        let one = try writer.apply(.replace(find: "c", replacement: "C"), to: within)
        #expect(try contents(within) == Array("a\r\nb\r\nC\r\nd\r\n".utf8))
        #expect(one.line == 3 && one.rendered.hasSuffix("; line 3 now: \"C\""), "\(one.rendered)")
        // A range of lines, found with line feeds, replaced with line feeds: written with the file's CRLF.
        let range = try file(original, named: "range", in: dir)
        let two = try writer.apply(.replace(find: "b\nc", replacement: "B\nC"), to: range)
        #expect(try contents(range) == Array("a\r\nB\r\nC\r\nd\r\n".utf8))
        #expect(two.line == 2 && two.rendered.hasSuffix("; lines 2-3 now: \"B\", \"C\""), "\(two.rendered)")
        // An insertion and a deletion.
        let insert = try file(original, named: "insert", in: dir)
        _ = try writer.apply(.replace(find: "b\n", replacement: "b\nb2\n"), to: insert)
        #expect(try contents(insert) == Array("a\r\nb\r\nb2\r\nc\r\nd\r\n".utf8))
        let delete = try file(original, named: "delete", in: dir)
        let gone = try writer.apply(.replace(find: "c\r\n", replacement: ""), to: delete)
        #expect(try contents(delete) == Array("a\r\nb\r\nd\r\n".utf8))
        #expect(gone.line == 3 && gone.rendered.hasSuffix("; line 3 now: \"d\""), "\(gone.rendered)")
        // The last line of a file with no final line break, and the whole last ending.
        let last = try file("a\r\nb", named: "last", in: dir)
        _ = try writer.apply(.replace(find: "b", replacement: "B"), to: last)
        #expect(try contents(last) == Array("a\r\nB".utf8))
        _ = try writer.apply(.replace(find: "a\nB", replacement: "a"), to: last)
        #expect(try contents(last) == Array("a".utf8))
        // A mixed file: the replacement's line breaks take the dominant ending; the others keep theirs.
        let mixed = try file("a\r\nb\r\nc\nd\r", named: "mixed", in: dir)
        _ = try writer.apply(.replace(find: "c", replacement: "c1\nc2"), to: mixed)
        #expect(try contents(mixed) == Array("a\r\nb\r\nc1\r\nc2\nd\r".utf8))
        // A classic Mac file.
        let mac = try file("a\rb\rc\r", named: "mac", in: dir)
        _ = try writer.apply(.replace(find: "b\n", replacement: "b\nb2\n"), to: mac)
        #expect(try contents(mac) == Array("a\rb\rb2\rc\r".utf8))
        // A find of a bare carriage return never splits it from its line feed; a match is still exactly one.
        #expect(throws: FileWriter.Failure.ambiguous(find: "\r", count: 4)) {
            try writer.apply(.replace(find: "\r", replacement: ""), to: within)
        }
    }

    @Test func bytesOutsideTheEditAreWrittenBackExactly() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        // Invalid UTF-8 on another line, and a decomposed accent, survive an edit untouched.
        let bytes: [UInt8] = Array("x\r\n".utf8) + [0xFF, 0xFE, 0x0D, 0x0A] + Array("cafe\u{301}\r\nend".utf8)
        let url = dir.appending(path: "raw")
        try Data(bytes).write(to: url)
        _ = try writer.apply(.replaceLine(1, content: "y", expecting: "x"), to: url.path)
        #expect(try contents(url.path) == Array("y\r\n".utf8) + Array(bytes.dropFirst(3)))
        _ = try writer.apply(.replace(find: "end", replacement: "END"), to: url.path)
        #expect(
            try contents(url.path) == Array("y\r\n".utf8) + Array(bytes.dropFirst(3).dropLast(3)) + Array("END".utf8))
    }

    @Test func theGuardRefusesAnEditThatChangesLinesItDoesNotName() throws {
        let before = TextLines(Array("a\r\nb\r\nc\r\n".utf8))
        // What the bug wrote for an edit of line 1: the whole file replaced by one line.
        #expect(
            throws: FileWriter.Failure.changesUnnamedLines(
                line: 1, reason: "the file would have 0 line breaks, not 3")
        ) {
            try FileWriter.checked(Array("x".utf8), against: before, at: 0, replacing: 0, with: 0)
        }
        // Another line changed, an ending changed, a line lost and one gained at the end.
        #expect(throws: FileWriter.Failure.changesUnnamedLines(line: 2, reason: "line 3 would change too")) {
            try FileWriter.checked(Array("a\r\nB\r\nC\r\n".utf8), against: before, at: 1, replacing: 0, with: 0)
        }
        #expect(throws: FileWriter.Failure.changesUnnamedLines(line: 1, reason: "line 1 would end differently")) {
            try FileWriter.checked(Array("A\nb\r\nc\r\n".utf8), against: before, at: 0, replacing: 0, with: 0)
        }
        #expect(throws: FileWriter.Failure.changesUnnamedLines(line: 2, reason: "line 1 would change too")) {
            try FileWriter.checked(Array("A\r\nB\r\nc\r\n".utf8), against: before, at: 1, replacing: 0, with: 0)
        }
        // What an edit names passes: one line rewritten, and two lines made one.
        #expect(
            try FileWriter.checked(Array("a\r\nB\r\nc\r\n".utf8), against: before, at: 1, replacing: 0, with: 0).count
                == 3)
        #expect(
            try FileWriter.checked(Array("a\r\nbc\r\n".utf8), against: before, at: 1, replacing: 1, with: 0).count == 2)
        #expect(
            FileWriter.Failure.changesUnnamedLines(line: 1, reason: "line 2 would change too").description
                == "edit at line 1 refused: line 2 would change too, more than the edit names; nothing changed")
    }

    @Test func theResultShowsLineEndingsEscaped() {
        #expect(FileWriter.Result.quoted("a\r\nb") == #""a\r\nb""#)
        #expect(FileWriter.Failure.notFound(find: "first\r\nsecond").description == "text to replace not found: first")
    }
}
