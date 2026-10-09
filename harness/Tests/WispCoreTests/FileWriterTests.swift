import Foundation
import Testing

@testable import WispCore

@Suite struct FileWriterTests {
    /// A scratch directory under the temporary directory, which is inside the default writable set.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writesAppendsAndReplacesOnce() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let file = dir.appending(path: "a.txt").path
        let created = try writer.apply(.write("one\ntwo\n"), to: file)
        #expect(created == .init(path: file, mode: "write", created: true, bytesBefore: 0, bytesAfter: 8, line: nil))
        #expect(created.rendered == "created \(file); now 8 bytes")
        let appended = try writer.apply(.append("three\n"), to: file)
        #expect(appended.created == false && appended.bytesBefore == 8 && appended.bytesAfter == 14)
        #expect(appended.rendered == "appended to \(file); now 14 bytes")
        let replaced = try writer.apply(.replace(find: "two", replacement: "2"), to: file)
        #expect(replaced.line == 2 && replaced.bytesAfter == 12)
        #expect(replaced.rendered == "replaced at line 2 of \(file); now 12 bytes; line 2 now: \"2\"")
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\n2\nthree\n")
        let overwritten = try writer.apply(.write("x"), to: file)
        #expect(overwritten.rendered == "wrote \(file); now 1 bytes")
        // Writes are atomic: the mode survives the rename and no temporary file is left behind.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file)
        _ = try writer.apply(.append("y"), to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.txt"])
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "xy")
        #expect(throws: FileWriter.Failure.notFound(find: "zzz")) {
            try writer.apply(.replace(find: "zzz", replacement: ""), to: file)
        }
        try Data("ab ab".utf8).write(to: URL(fileURLWithPath: file))
        #expect(throws: FileWriter.Failure.ambiguous(find: "ab", count: 2)) {
            try writer.apply(.replace(find: "ab", replacement: "c"), to: file)
        }
        #expect(throws: FileWriter.Failure.notFound(find: "")) {
            try writer.apply(.replace(find: "", replacement: "c"), to: file)
        }
    }

    @Test func replacesANumberedLineAndChecksWhatIsThere() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let file = dir.appending(path: "n.txt").path
        try Data("one\ntwo\nthree\n".utf8).write(to: URL(fileURLWithPath: file))
        let result = try writer.apply(.replaceLine(2, content: "TWO", expecting: "two"), to: file)
        #expect(result.line == 2 && result.mode == "replace" && result.bytesAfter == 14)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\nTWO\nthree\n")
        // Without a check the number alone decides; the trailing newline survives; the last line counts.
        _ = try writer.apply(.replaceLine(3, content: "3", expecting: nil), to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\nTWO\n3\n")
        #expect(throws: FileWriter.Failure.noSuchLine(4, lines: 3)) {
            try writer.apply(.replaceLine(4, content: "x", expecting: nil), to: file)
        }
        #expect(throws: FileWriter.Failure.noSuchLine(0, lines: 3)) {
            try writer.apply(.replaceLine(0, content: "x", expecting: nil), to: file)
        }
        #expect(throws: FileWriter.Failure.lineMismatch(1, expected: "uno", actual: "one")) {
            try writer.apply(.replaceLine(1, content: "x", expecting: "uno"), to: file)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\nTWO\n3\n")
        // A file without a trailing newline keeps that shape.
        try Data("a\nb".utf8).write(to: URL(fileURLWithPath: file))
        _ = try writer.apply(.replaceLine(2, content: "B", expecting: "b"), to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "a\nB")
        // One trailing newline is dropped; a second line inside the content is refused.
        _ = try writer.apply(.replaceLine(1, content: "A\n", expecting: nil), to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "A\nB")
        #expect(throws: FileWriter.Failure.notOneLine(1)) {
            try writer.apply(.replaceLine(1, content: "A\nB\n", expecting: nil), to: file)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "A\nB")
        #expect(FileWriter.Failure.notOneLine(2).description == "content for line 2 must be one line; nothing changed")
        #expect(FileWriter.Failure.noSuchLine(9, lines: 2).description == "no line 9: the file has 2 lines")
        #expect(FileWriter.Failure.lineMismatch(1, expected: "x", actual: "y").description.contains("it is: y"))
        try Data([0x61, 0x00]).write(to: URL(fileURLWithPath: file))
        #expect(throws: FileWriter.Failure.binary(file)) {
            try writer.apply(.replaceLine(1, content: "x", expecting: nil), to: file)
        }
    }

    @Test func refusesOutsideTheWritableSetAndUnusablePaths() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inside = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        // Outside the working directory and the temporary directory: the home. Unique, and removed even when a
        // regression wrote it, so the assertion below fails once rather than on every later run.
        let outside = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "wisp-must-not-exist-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: outside) }
        #expect(
            throws: FileWriter.Failure.outsideWritableSet(path: outside, roots: [CommandPolicy.canonical(dir.path)])
        ) {
            try inside.apply(.write("x"), to: outside)
        }
        #expect(!FileManager.default.fileExists(atPath: outside))
        // A sibling whose name merely starts with the root is outside it.
        #expect(!inside.permits(dir.path + "-sibling/x"))
        // The check follows symlinks: /tmp is /private/tmp.
        #expect(FileWriter(roots: ["/private/tmp"]).permits("/tmp/x"))
        #expect(throws: FileWriter.Failure.isDirectory(dir.path)) { try inside.apply(.write("x"), to: dir.path) }
        // A rename that cannot happen leaves no temporary file and the original untouched.
        let locked = dir.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appending(path: "t.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { try inside.apply(.write("new"), to: target.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == ["t.txt"])
        let orphan = dir.appending(path: "missing/x.txt").path
        #expect(throws: FileWriter.Failure.noParent(orphan)) { try inside.apply(.write("x"), to: orphan) }
        let binary = dir.appending(path: "b.bin").path
        try Data([0x61, 0x00, 0x62]).write(to: URL(fileURLWithPath: binary))
        #expect(throws: FileWriter.Failure.binary(binary)) {
            try inside.apply(.replace(find: "a", replacement: "b"), to: binary)
        }
        let small = FileWriter(roots: nil, maxBytes: 2)
        let big = dir.appending(path: "big.txt").path
        try Data("abc".utf8).write(to: URL(fileURLWithPath: big))
        #expect(throws: FileWriter.Failure.tooLarge(path: big, bytes: 3, limit: 2)) {
            try small.apply(.replace(find: "a", replacement: "b"), to: big)
        }
        // Unconfined when the sandbox is off; confined to the runner's roots otherwise.
        #expect(FileWriter(options: .init(policy: .unrestricted)).roots == nil)
        let confined = FileWriter(options: .init(writableRoot: dir.path))
        #expect(confined.roots?.first == CommandPolicy.canonical(dir.path))
        #expect(confined.roots?.contains("/private/tmp") == true)
        #expect(confined.permits(dir.appending(path: "new.txt").path))
        #expect(!confined.permits(outside))
        for failure: FileWriter.Failure in [
            .outsideWritableSet(path: "/p", roots: ["/r"]), .noParent("/p"), .isDirectory("/p"), .binary("/p"),
            .tooLarge(path: "/p", bytes: 2, limit: 1), .notFound(find: String(repeating: "x", count: 70) + "\nmore"),
            .ambiguous(find: "y", count: 3), .notApproved("no"),
        ] {
            #expect(!failure.description.isEmpty)
        }
        #expect(FileWriter.Failure.notFound(find: String(repeating: "x", count: 70)).description.hasSuffix("…"))
    }

    /// Writes `text` to a fresh file in `dir` and returns its path.
    private func file(_ text: String, named name: String, in dir: URL) throws -> String {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func keepsALinesIndentationWhenTheNewLineLostIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let path = try file("def f():\n    return 1\n", named: "b.py", in: dir)
        let result = try writer.apply(.replaceLine(2, content: "return 10", expecting: nil), to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "def f():\n    return 10\n")
        #expect(result.keptIndentation == "    " && result.movedFrom == nil && result.nowReads == ["    return 10"])
        #expect(
            result.rendered
                == "replaced at line 2 of \(path), keeping the line's indentation (4 spaces); now 23 bytes; "
                + "line 2 now: \"    return 10\"")
        // Tabs are kept as tabs, and named.
        let tabbed = try file("func f() {\n\treturn 1\n}\n", named: "t.go", in: dir)
        let tab = try writer.apply(.replaceLine(2, content: "return 2", expecting: "return 1"), to: tabbed)
        #expect(try String(contentsOfFile: tabbed, encoding: .utf8) == "func f() {\n\treturn 2\n}\n")
        #expect(
            tab.rendered.contains("keeping the line's indentation (1 tab)") && tab.rendered.hasSuffix("\"\\treturn 2\"")
        )
        #expect(FileWriter.Result.describe("\t\t  ") == "2 tabs and 2 spaces")
        #expect(FileWriter.Result.describe(" ") == "1 space")
        // The blind spot: a text change and a dedent to column zero in one edit keeps the indentation, and
        // the result says so, so the model can see it and write the line again some other way.
        let blind = try file("    return 1\n", named: "blind.py", in: dir)
        let kept = try writer.apply(.replaceLine(1, content: "print(1)", expecting: nil), to: blind)
        #expect(try String(contentsOfFile: blind, encoding: .utf8) == "    print(1)\n")
        #expect(kept.rendered.contains("keeping the line's indentation (4 spaces)"))
    }

    @Test func writesDeliberateWhitespaceEditsExactly() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        // (file, line, content, file afterwards): indent, dedent, dedent with trailing spaces stripped, tabs to
        // spaces, trailing spaces stripped, indentation of the content's own, an emptied line, an unindented
        // line rewritten.
        let cases: [(String, Int, String, String)] = [
            ("def f():\nreturn 1\n", 2, "    return 1", "def f():\n    return 1\n"),
            ("x = 1\n    y = 2\n", 2, "y = 2", "x = 1\ny = 2\n"),
            ("x = 1\n    y = 2  \n", 2, "y = 2", "x = 1\ny = 2\n"),
            ("{\n\treturn 1\n}\n", 2, "    return 1", "{\n    return 1\n}\n"),
            ("first line   \nsecond\n", 1, "first line", "first line\nsecond\n"),
            ("if x:\n    a = 1\n", 2, "  a = 2", "if x:\n  a = 2\n"),
            ("if x:\n    a = 1\n", 2, "", "if x:\n\n"),
            ("a = 1\nb = 2\n", 1, "a = 3", "a = 3\nb = 2\n"),
        ]
        for (index, (before, line, content, expected)) in cases.enumerated() {
            let path = try file(before, named: "w\(index).txt", in: dir)
            let result = try writer.apply(.replaceLine(line, content: content, expecting: nil), to: path)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == expected, "case \(index)")
            #expect(result.keptIndentation == nil && !result.rendered.contains("keeping"), "case \(index)")
        }
        #expect(FileWriter.indented("x", replacing: "\t x \t") == ("x", nil))
        #expect(FileWriter.indented("y", replacing: "  ") == ("  y", "  "))
    }

    @Test func movesAStaleLineToTheOneLineHoldingFind() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let original = "def f():\n    return 1\n\ndef g():\n    return 2\n"
        let path = try file(original, named: "b.py", in: dir)
        // None and several change nothing, with the error as before.
        #expect(throws: FileWriter.Failure.lineMismatch(1, expected: "nope", actual: "def f():")) {
            try writer.apply(.replaceLine(1, content: "x", expecting: "nope"), to: path)
        }
        #expect(throws: FileWriter.Failure.lineMismatch(3, expected: "return", actual: "")) {
            try writer.apply(.replaceLine(3, content: "x", expecting: "return"), to: path)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        // Exactly one line holds it: that line is edited, and the result says so.
        let moved = try writer.apply(.replaceLine(1, content: "return 10", expecting: "return 1"), to: path)
        #expect(
            try String(contentsOfFile: path, encoding: .utf8) == "def f():\n    return 10\n\ndef g():\n    return 2\n")
        #expect(moved.line == 2 && moved.movedFrom == .init(line: 1, find: "return 1"))
        #expect(
            moved.rendered
                == "line 1 did not contain \"return 1\"; replaced line 2 of \(path), the one line that does, "
                + "keeping the line's indentation (4 spaces); now \(moved.bytesAfter) bytes; line 2 now: \"    return 10\""
        )
        // Twice on one line is still one line; a number past the end is still an error.
        let twice = try file("a a\nb\n", named: "twice.txt", in: dir)
        let once = try writer.apply(.replaceLine(2, content: "c", expecting: "a"), to: twice)
        #expect(try String(contentsOfFile: twice, encoding: .utf8) == "c\nb\n" && once.line == 1)
        #expect(throws: FileWriter.Failure.noSuchLine(9, lines: 2)) {
            try writer.apply(.replaceLine(9, content: "x", expecting: "b"), to: twice)
        }
        // The line given holds it: no move.
        let held = try writer.apply(.replaceLine(2, content: "B", expecting: "b"), to: twice)
        #expect(
            held.movedFrom == nil && held.rendered == "replaced at line 2 of \(twice); now 4 bytes; line 2 now: \"B\"")
    }

    @Test func showsTheEditedLinesBounded() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        // Quotes, backslashes, tabs, and carriage returns are escaped, so whitespace is visible.
        #expect(FileWriter.Result.quoted("a\t\"b\"\\\r") == #""a\t\"b\"\\\r""#)
        // A long line is cut at 200 characters.
        let long = String(repeating: "x", count: 250)
        let path = try file("short\n", named: "long.txt", in: dir)
        let result = try writer.apply(.replaceLine(1, content: long, expecting: nil), to: path)
        #expect(result.rendered.hasSuffix("line 1 now: \"" + String(repeating: "x", count: 200) + "…\""))
        // A replacement by find shows the lines it now covers, at most three.
        let many = try file("a\nb\nc\n", named: "many.txt", in: dir)
        let two = try writer.apply(.replace(find: "b", replacement: "B1\nB2"), to: many)
        #expect(two.rendered.hasSuffix("; lines 2-3 now: \"B1\", \"B2\""), "\(two.rendered)")
        let five = try writer.apply(.replace(find: "B1\nB2\n", replacement: "1\n2\n3\n4\n5\n"), to: many)
        #expect(five.rendered.hasSuffix("; lines 2-6 now: \"1\", \"2\", \"3\" (and 2 more)"), "\(five.rendered)")
        let joined = try writer.apply(.replace(find: "5\nc", replacement: "5c"), to: many)
        #expect(joined.rendered.hasSuffix("; line 6 now: \"5c\""), "\(joined.rendered)")
        // Writes and appends show nothing more.
        #expect(try writer.apply(.append("z"), to: many).rendered == "appended to \(many); now 14 bytes")
    }
}
