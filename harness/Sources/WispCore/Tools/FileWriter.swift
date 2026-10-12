import Foundation

/// Writes text to a file inside the writable set, the same directories the sandbox lets commands
/// write under, so `edit_file` can change no more than `run_command` could.
///
/// Three edits: write the whole file (created if absent), append, or replace: one exact occurrence of
/// a piece of text, or one numbered line as `read_file` numbered it. Replacement demands exactly one
/// match, or a line that still holds what the model expects, so it cannot change more than it showed
/// it meant to. Two refinements forgive a small model's commonest slips without guessing (ADR 0024, refined
/// 2026-10-06): a rewritten line that lost its indentation keeps the old line's, and a stale number with a
/// `find` that is on exactly one other line edits that line. Each says so in the result, which also shows
/// the line as it now reads. Every write is atomic: a temporary file beside the target, renamed over it.
/// Nothing here creates directories or follows the model outside the set.
///
/// A replacement works on the file's bytes through `TextLines`, which numbers lines as `read_file` does: a line ends
/// at `\n`, `\r\n`, or a lone `\r`. Every line keeps its own ending, so a CRLF file stays CRLF and a mixed file
/// stays mixed; a line break a replacement adds takes the file's dominant ending; a file without a final line break
/// keeps having none; and every byte outside the edit is written back as it was. A guard (`checked`) refuses any
/// edit whose result changes a line it does not name.
public struct FileWriter: Sendable {
    /// What to do to the file.
    public enum Edit: Equatable, Sendable {
        /// Replace the whole file with `content`, creating it if absent.
        case write(String)
        /// Add `content` to the end, creating the file if absent.
        case append(String)
        /// Replace the one occurrence of `find` with `replacement`; a line break in either stands for any line ending,
        /// and the replacement's take the file's dominant one.
        case replace(find: String, replacement: String)
        /// Replace the whole 1-based `line` with `content`; when `expecting` is given the line must
        /// contain it, or else `expecting` must be on exactly one line of the file, which is edited instead,
        /// so a stale number changes nothing it should not. A `content` without indentation for a line
        /// with some keeps the line's indentation unless only whitespace differs (`FileWriter.indented`).
        case replaceLine(Int, content: String, expecting: String?)

        /// The spelling the model uses and the audit records.
        public var mode: String {
            switch self {
            case .write: "write"
            case .append: "append"
            case .replace, .replaceLine: "replace"
            }
        }
    }

    /// What an edit did.
    public struct Result: Equatable, Sendable {
        /// A line edit whose number did not hold `find`, moved to the one line that does.
        public struct Moved: Equatable, Sendable {
            /// The line number the model gave.
            public var line: Int
            /// The text that line did not contain.
            public var find: String
        }

        /// The path as given.
        public var path: String
        /// The edit's mode.
        public var mode: String
        /// Whether the file did not exist before.
        public var created: Bool
        /// Size before the edit; 0 when created.
        public var bytesBefore: Int
        /// Size after the edit.
        public var bytesAfter: Int
        /// For a replacement, the 1-based line where it started.
        public var line: Int?
        /// For a line edit moved to the one line holding `find`: the number the model gave, and `find`.
        public var movedFrom: Moved?
        /// For a line edit that kept the old line's indentation, that indentation.
        public var keptIndentation: String?
        /// For a replacement, the first `shownLines` edited lines as they now read.
        public var nowReads: [String] = []
        /// For a replacement, how many lines it edited; more than `nowReads` holds when it spans many.
        public var editedLines = 0

        /// How many edited lines a result shows.
        static let shownLines = 3
        /// How many characters of each shown line a result keeps.
        static let shownCharacters = 200

        /// Model-facing rendering: what happened, in one line, and for a replacement the edited lines as
        /// they now read, so a model that got it wrong can see it.
        public var rendered: String {
            switch mode {
            case "replace":
                let place =
                    if let movedFrom {
                        "line \(movedFrom.line) did not contain \(Self.quoted(movedFrom.find)); replaced line "
                            + "\(line ?? 0) of \(path), the one line that does"
                    } else {
                        "replaced at line \(line ?? 0) of \(path)"
                    }
                let kept = keptIndentation.map { ", keeping the line's indentation (\(Self.describe($0)))" } ?? ""
                return "\(place)\(kept); now \(bytesAfter) bytes\(shown)"
            case "append": return "appended to \(path); now \(bytesAfter) bytes"
            default: return "\(created ? "created" : "wrote") \(path); now \(bytesAfter) bytes"
            }
        }

        /// `; line N now: "…"`, or `; lines N-M now: "…", "…"`, for the edited lines; empty when none.
        private var shown: String {
            guard let line, !nowReads.isEmpty else { return "" }
            let quoted = nowReads.prefix(Self.shownLines).map(Self.quoted).joined(separator: ", ")
            let count = max(editedLines, nowReads.count)
            let more = count > nowReads.count ? " (and \(count - nowReads.count) more)" : ""
            let label = count == 1 ? "line \(line)" : "lines \(line)-\(line + count - 1)"
            return "; \(label) now: \(quoted)\(more)"
        }

        /// `text` in double quotes with backslashes, quotes, tabs, carriage returns, and line feeds escaped, so its
        /// whitespace is visible, cut at `shownCharacters`. Escaped scalar by scalar: as a `Character`, `"\r\n"` is
        /// one grapheme that matches neither `"\r"` nor `"\n"`.
        static func quoted(_ text: String) -> String {
            let cut = text.count > shownCharacters ? String(text.prefix(shownCharacters)) + "…" : text
            var escaped = ""
            for scalar in cut.unicodeScalars {
                switch scalar {
                case "\\": escaped += "\\\\"
                case "\"": escaped += "\\\""
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                case "\n": escaped += "\\n"
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return "\"\(escaped)\""
        }

        /// Indentation in words: `4 spaces`, `1 tab`, `1 tab and 2 spaces`.
        static func describe(_ indentation: String) -> String {
            let tabs = indentation.count(where: { $0 == "\t" })
            let spaces = indentation.count - tabs
            let parts = [(tabs, "tab"), (spaces, "space")].filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            return parts.joined(separator: " and ")
        }
    }

    /// Why an edit was not made.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The path is outside every writable directory.
        case outsideWritableSet(path: String, roots: [String])
        /// The path is under wisp's own home, which nothing the model does may change.
        case protected(String)
        /// The parent directory does not exist.
        case noParent(String)
        /// The path is a directory.
        case isDirectory(String)
        /// The file contains NUL bytes.
        case binary(String)
        /// The file is larger than the writer will load for a replacement.
        case tooLarge(path: String, bytes: Int, limit: Int)
        /// The text to replace was not found.
        case notFound(find: String)
        /// The text to replace occurs more than once.
        case ambiguous(find: String, count: Int)
        /// The line number is past the end of the file.
        case noSuchLine(Int, lines: Int)
        /// The numbered line does not contain the text the model expected there.
        case lineMismatch(Int, expected: String, actual: String)
        /// A line edit was given more than one line of content.
        case notOneLine(Int)
        /// The edit would change lines it does not name; a guard, which no edit is built to reach.
        case changesUnnamedLines(line: Int, reason: String)
        /// The approval gate refused the edit.
        case notApproved(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .outsideWritableSet(let path, let roots):
                "cannot write \(path): outside the writable directories (\(roots.joined(separator: ", ")))"
            case .protected(let path): "cannot write \(path): it is in wisp's own home, which edits never change"
            case .noParent(let path): "cannot write \(path): its directory does not exist"
            case .isDirectory(let path): "path is a directory: \(path)"
            case .binary(let path): "file appears to be binary: \(path)"
            case .tooLarge(let path, let bytes, let limit):
                "file too large to edit in place: \(path) is \(bytes) bytes, limit \(limit)"
            case .notFound(let find): "text to replace not found: \(Self.excerpt(find))"
            case .ambiguous(let find, let count):
                "text to replace occurs \(count) times, include more surrounding text: \(Self.excerpt(find))"
            case .noSuchLine(let line, let lines): "no line \(line): the file has \(lines) lines"
            case .lineMismatch(let line, let expected, let actual):
                "line \(line) does not contain \(Self.excerpt(expected)); it is: \(Self.excerpt(actual))"
            case .notOneLine(let line): "content for line \(line) must be one line; nothing changed"
            case .changesUnnamedLines(let line, let reason):
                "edit at line \(line) refused: \(reason), more than the edit names; nothing changed"
            case .notApproved(let reason): "edit not approved: \(reason)"
            }
        }

        /// The first line of `text`, up to any line ending, shortened.
        private static func excerpt(_ text: String) -> String {
            let first = String(Substring(text.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }))
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
    }

    /// Canonical directories writes may land under; nil means anywhere (the sandbox is off).
    public let roots: [String]?
    /// Canonical directories never written, inside the roots or not, sandbox or not: wisp's own home.
    public let protected: [String]
    /// Largest file loaded for a replacement.
    public let maxBytes: Int

    /// Creates a writer confined to `roots`.
    ///
    /// - Parameters:
    ///   - roots: Canonical directories, as `CommandPolicy.writableRoots` gives them; nil confines nothing.
    ///   - protected: Directories never written, canonicalised here; by default wisp's home (`Home.resolve()`).
    ///   - maxBytes: Largest file a replacement will load (default 1 MiB).
    public init(roots: [String]?, protected: [String]? = nil, maxBytes: Int = 1 << 20) {
        self.roots = roots
        self.protected = (protected ?? [Home.resolve().root.path]).map(CommandPolicy.canonical)
        self.maxBytes = maxBytes
    }

    /// A writer confined exactly as `options` confines commands: the same roots the Seatbelt profile
    /// is built from, or nothing when the sandbox is off, and never wisp's home (`Options.protectedPaths`).
    public init(options: CommandRunner.Options) {
        guard options.policy.sandbox.enabled else {
            self.init(roots: nil, protected: options.protectedPaths)
            return
        }
        self.init(
            roots: options.policy.writableRoots(
                writableRoot: options.writableRoot, temporaryDirectory: FileManager.default.temporaryDirectory.path,
                userCacheDirectory: CommandRunner.userCacheDirectory,
                home: FileManager.default.homeDirectoryForCurrentUser.path),
            protected: options.protectedPaths)
    }

    /// Whether `path` (canonicalised) lies under one of the roots and under none of the protected directories.
    public func permits(_ path: String) -> Bool {
        let canonical = CommandPolicy.canonical(path)
        guard !protected.contains(where: { CommandPolicy.contains($0, canonical) }) else { return false }
        guard let roots else { return true }
        return roots.contains { CommandPolicy.contains($0, canonical) }
    }

    /// Writes `data` to a temporary file beside `url`, gives it the existing file's mode, and renames
    /// it over the target, so a reader never sees a partial file and a failure leaves the original.
    ///
    /// - Throws: A file-system error; the temporary file is removed on failure.
    static func writeAtomically(_ data: Data, to url: URL, replacing exists: Bool) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).wisp-\(ShortID.make())")
        do {
            try data.write(to: temporary)
            if exists, let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Appends `data` to the file at `url` atomically without loading it: the existing bytes are copied to a
    /// temporary file beside it in 64 KiB chunks, `data` is written after them, and the temporary file is renamed
    /// over the target with the original's mode.
    ///
    /// - Parameters:
    ///   - data: The bytes to add.
    ///   - url: The file.
    ///   - exists: Whether it exists.
    /// - Returns: The size after.
    /// - Throws: A file-system error; the temporary file is removed on failure.
    static func appendAtomically(_ data: Data, to url: URL, replacing exists: Bool) throws -> Int {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).wisp-\(ShortID.make())")
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw POSIXError(.EACCES)
            }
            let writer = try FileHandle(forWritingTo: temporary)
            defer { try? writer.close() }
            var total = 0
            if exists {
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                while let chunk = try reader.read(upToCount: 1 << 16), !chunk.isEmpty {
                    try writer.write(contentsOf: chunk)
                    total += chunk.count
                }
            }
            try writer.write(contentsOf: data)
            total += data.count
            try writer.close()
            if exists, let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return total
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Applies `edit` to the file at `path`.
    ///
    /// - Parameters:
    ///   - edit: What to do.
    ///   - path: The file; created by `write` and `append` when absent, its directory must exist.
    /// - Returns: What happened.
    /// - Throws: `Failure`, or a file-system error from the write.
    public func apply(_ edit: Edit, to path: String) throws -> Result {
        guard permits(path) else {
            let canonical = CommandPolicy.canonical(path)
            if protected.contains(where: { CommandPolicy.contains($0, canonical) }) { throw Failure.protected(path) }
            throw Failure.outsideWritableSet(path: path, roots: roots ?? [])
        }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw Failure.isDirectory(path) }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Failure.noParent(path) }
        let size = exists ? Int((try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) : 0
        var result = Result(path: path, mode: edit.mode, created: !exists, bytesBefore: size, bytesAfter: 0, line: nil)
        // A write replaces the file and an append copies it in chunks: neither loads what is there (the 2026-10-09
        // review); only a replacement reads the file, and only up to `maxBytes`.
        switch edit {
        case .write(let content):
            let data = Data(content.utf8)
            try Self.writeAtomically(data, to: url, replacing: exists)
            result.bytesAfter = data.count
            return result
        case .append(let content):
            result.bytesAfter = try Self.appendAtomically(Data(content.utf8), to: url, replacing: exists)
            return result
        default:
            break
        }
        let before = exists ? try Data(contentsOf: url) : Data()
        let file = try editableBytes(before, path: path)
        let lines = TextLines(file)
        let after: [UInt8]
        switch edit {
        case .write, .append:
            after = file
        case .replace(let find, let replacement):
            // Matched on bytes with every line ending made one line feed, so a line break in `find` matches any
            // ending and a match never splits a carriage return from its line feed; the replacement's line breaks
            // take the file's dominant ending.
            let (flat, origins) = TextLines.normalised(file)
            let needle = TextLines.normalised(Array(find.utf8)).bytes
            let found = TextLines.occurrences(of: needle, in: flat)
            guard let match = found.first else { throw Failure.notFound(find: find) }
            guard found.count == 1 else { throw Failure.ambiguous(find: find, count: found.count) }
            let inserted = TextLines.converting(Array(replacement.utf8), to: lines.dominantEnding)
            let range = origins[match.lowerBound]..<origins[match.upperBound]
            let written = Array(file[..<range.lowerBound]) + inserted + Array(file[range.upperBound...])
            let first = flat[..<match.lowerBound].count(where: { $0 == TextLines.lineFeed })
            let added = TextLines.endings(in: inserted)
            let now = try Self.checked(
                written, against: lines, at: first, replacing: needle.count(where: { $0 == TextLines.lineFeed }),
                with: added)
            // The lines the replacement now covers: one, plus one for each line break it holds, a final one
            // ending the replacement's last line rather than starting another.
            let edited = max(
                1,
                inserted.last == TextLines.lineFeed || inserted.last == TextLines.carriageReturn
                    ? added : added + 1)
            result.line = first + 1
            result.editedLines = edited
            result.nowReads = (first..<min(now.segments.count, first + min(edited, Result.shownLines))).map(now.text)
            after = written
        case .replaceLine(let number, let content, let expecting):
            let count = lines.count
            guard number >= 1, number <= count else { throw Failure.noSuchLine(number, lines: count) }
            var target = number
            if let expecting, !lines.text(number - 1).contains(expecting) {
                // A stale number: the one line that holds `expecting` exactly is the line meant; none or
                // several is not knowable, so nothing changes.
                let holding = (0..<count).filter { lines.text($0).contains(expecting) }
                guard holding.count == 1, let only = holding.first else {
                    throw Failure.lineMismatch(number, expected: expecting, actual: lines.text(number - 1))
                }
                target = only + 1
                result.movedFrom = .init(line: number, find: expecting)
            }
            // A line has no line break of its own: one trailing ending is dropped, any other is refused, so a
            // model that pastes the page marker or a neighbour cannot corrupt the file. The line keeps its ending.
            let single = TextLines(Array(content.utf8)).segments
            guard single.count == 1 || (single.count == 2 && single[1].text.isEmpty) else {
                throw Failure.notOneLine(number)
            }
            let written = Self.indented(
                String(decoding: single[0].text, as: UTF8.self), replacing: lines.text(target - 1))
            var changed = lines
            changed.segments[target - 1].text = Array(written.line.utf8)
            after = try Self.checked(changed.bytes, against: lines, at: target - 1, replacing: 0, with: 0).bytes
            result.line = target
            result.keptIndentation = written.kept
            result.editedLines = 1
            result.nowReads = [written.line]
        }
        let data = Data(after)
        try Self.writeAtomically(data, to: url, replacing: exists)
        result.bytesAfter = data.count
        return result
    }

    /// The edited file, once it is known to change no line the edit does not name: segments `first` to
    /// `first + replacing` of `before` (0-based; `replacing` is how many line endings the edit removes) become
    /// segments `first` to `first + with` of `written`, and every segment before and after them is as it was, its
    /// ending included, as is the ending of the last one touched. A line edit names one line and no ending, so it can
    /// never change the line count; a `find` replacement changes it by exactly the line breaks it removes and adds.
    /// Every edit is built to keep this; the check is the structural guarantee that a mistake in that construction
    /// refuses rather than writes (2026-10-12: a CRLF file read as one line, and a one-line edit replaced all of it).
    ///
    /// - Parameters:
    ///   - written: The bytes the edit would write.
    ///   - before: The file as it is.
    ///   - first: The first segment the edit touches, from 0.
    ///   - replacing: The line endings the edit removes.
    ///   - with: The line endings the edit adds.
    /// - Returns: The edited file's lines.
    /// - Throws: `Failure.changesUnnamedLines` when the edit would change more than that.
    static func checked(
        _ written: [UInt8], against before: TextLines, at first: Int, replacing: Int, with: Int
    ) throws -> TextLines {
        let after = TextLines(written)
        let old = before.segments
        let new = after.segments
        let line = first + 1
        let expected = old.count - 1 - replacing + with
        guard new.count - 1 == expected, first + replacing < old.count, first + with < new.count else {
            throw Failure.changesUnnamedLines(
                line: line, reason: "the file would have \(new.count - 1) line breaks, not \(expected)")
        }
        if let other = (0..<first).first(where: { old[$0] != new[$0] }) {
            throw Failure.changesUnnamedLines(line: line, reason: "line \(other + 1) would change too")
        }
        let oldTail = first + replacing + 1
        let newTail = first + with + 1
        if let offset = (0..<(old.count - oldTail)).first(where: { old[oldTail + $0] != new[newTail + $0] }) {
            throw Failure.changesUnnamedLines(line: line, reason: "line \(newTail + offset + 1) would change too")
        }
        guard old[first + replacing].ending == new[first + with].ending else {
            throw Failure.changesUnnamedLines(
                line: line, reason: "line \(first + with + 1) would end differently")
        }
        return after
    }

    /// The file's bytes for a replacement, once they are known to be few enough and not binary.
    ///
    /// - Parameters:
    ///   - data: The file's bytes.
    ///   - path: The file, for the errors.
    /// - Returns: The bytes.
    /// - Throws: `Failure.tooLarge` or `Failure.binary`.
    private func editableBytes(_ data: Data, path: String) throws -> [UInt8] {
        guard data.count <= maxBytes else { throw Failure.tooLarge(path: path, bytes: data.count, limit: maxBytes) }
        guard !data.contains(0) else { throw Failure.binary(path) }
        return Array(data)
    }

    /// The line to write for `content` in place of `old`, and the indentation kept, if any.
    ///
    /// Small models rewrite an indented line without its indentation (asked for `    return 10`, they send
    /// `return 10`). When `content` has no leading spaces or tabs, `old` has some, and the two differ by
    /// more than whitespace at their ends, the line keeps `old`'s indentation. Everything else is written
    /// exactly: an empty line, any content with indentation of its own, and a whitespace-only change
    /// (`    x` to `x` is a deliberate dedent). The one blind spot, a text change and a dedent to column
    /// zero in one edit, keeps the indentation, and the result says so, so the model can redo it.
    ///
    /// - Parameters:
    ///   - content: The new line, as the model gave it.
    ///   - old: The line it replaces.
    /// - Returns: The line to write, and the indentation it kept from `old` (nil when written exactly).
    static func indented(_ content: String, replacing old: String) -> (line: String, kept: String?) {
        let indentation = String(old.prefix(while: isIndentation))
        guard let first = content.first, !isIndentation(first), !indentation.isEmpty,
            trimmed(content) != trimmed(old)
        else { return (content, nil) }
        return (indentation + content, indentation)
    }

    /// Whether `character` indents a line: a space or a tab.
    private static func isIndentation(_ character: Character) -> Bool { character == " " || character == "\t" }

    /// `text` without the spaces and tabs at either end.
    private static func trimmed(_ text: String) -> Substring {
        let start = text.drop(while: isIndentation)
        return start.prefix(start.count - start.reversed().prefix(while: isIndentation).count)
    }
}
