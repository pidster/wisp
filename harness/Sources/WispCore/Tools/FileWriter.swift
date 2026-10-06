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
public struct FileWriter: Sendable {
    /// What to do to the file.
    public enum Edit: Equatable, Sendable {
        /// Replace the whole file with `content`, creating it if absent.
        case write(String)
        /// Add `content` to the end, creating the file if absent.
        case append(String)
        /// Replace the one occurrence of `find` with `replacement`.
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

        /// `text` in double quotes with backslashes, quotes, tabs, and carriage returns escaped, so its
        /// whitespace is visible, cut at `shownCharacters`.
        static func quoted(_ text: String) -> String {
            let cut = text.count > shownCharacters ? String(text.prefix(shownCharacters)) + "…" : text
            var escaped = ""
            for character in cut {
                switch character {
                case "\\": escaped += "\\\\"
                case "\"": escaped += "\\\""
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default: escaped.append(character)
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
        /// The approval gate refused the edit.
        case notApproved(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .outsideWritableSet(let path, let roots):
                "cannot write \(path): outside the writable directories (\(roots.joined(separator: ", ")))"
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
            case .notApproved(let reason): "edit not approved: \(reason)"
            }
        }

        /// The first line of `text`, shortened.
        private static func excerpt(_ text: String) -> String {
            let first = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
    }

    /// Canonical directories writes may land under; nil means anywhere (the sandbox is off).
    public let roots: [String]?
    /// Largest file loaded for a replacement.
    public let maxBytes: Int

    /// Creates a writer confined to `roots`.
    ///
    /// - Parameters:
    ///   - roots: Canonical directories, as `CommandPolicy.writableRoots` gives them; nil confines nothing.
    ///   - maxBytes: Largest file a replacement will load (default 1 MiB).
    public init(roots: [String]?, maxBytes: Int = 1 << 20) {
        self.roots = roots
        self.maxBytes = maxBytes
    }

    /// A writer confined exactly as `options` confines commands: the same roots the Seatbelt profile
    /// is built from, or nothing when the sandbox is off.
    public init(options: CommandRunner.Options) {
        guard options.policy.sandbox.enabled else {
            self.init(roots: nil)
            return
        }
        self.init(
            roots: options.policy.writableRoots(
                writableRoot: options.writableRoot, temporaryDirectory: FileManager.default.temporaryDirectory.path,
                userCacheDirectory: CommandRunner.userCacheDirectory,
                home: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    /// Whether `path` (canonicalised) lies under one of the roots.
    public func permits(_ path: String) -> Bool {
        guard let roots else { return true }
        let canonical = CommandPolicy.canonical(path)
        return roots.contains { root in
            canonical == root || canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
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

    /// Applies `edit` to the file at `path`.
    ///
    /// - Parameters:
    ///   - edit: What to do.
    ///   - path: The file; created by `write` and `append` when absent, its directory must exist.
    /// - Returns: What happened.
    /// - Throws: `Failure`, or a file-system error from the write.
    public func apply(_ edit: Edit, to path: String) throws -> Result {
        guard permits(path) else { throw Failure.outsideWritableSet(path: path, roots: roots ?? []) }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw Failure.isDirectory(path) }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Failure.noParent(path) }
        let before = exists ? try Data(contentsOf: url) : Data()
        var result = Result(
            path: path, mode: edit.mode, created: !exists, bytesBefore: before.count, bytesAfter: 0, line: nil)
        let after: Data
        switch edit {
        case .write(let content):
            after = Data(content.utf8)
        case .append(let content):
            after = before + Data(content.utf8)
        case .replace(let find, let replacement):
            let text = try editableText(before, path: path)
            let ranges = text.ranges(of: find)
            guard let range = ranges.first, !find.isEmpty else { throw Failure.notFound(find: find) }
            guard ranges.count == 1 else { throw Failure.ambiguous(find: find, count: ranges.count) }
            let line = text[..<range.lowerBound].count(where: { $0 == "\n" }) + 1
            let replaced = text.replacingCharacters(in: range, with: replacement)
            // The lines the replacement now covers: one, plus one for each newline it holds, a final one
            // ending the replacement's last line rather than starting another.
            let newlines = replacement.count(where: { $0 == "\n" })
            let edited = max(1, replacement.hasSuffix("\n") ? newlines : newlines + 1)
            result.line = line
            result.editedLines = edited
            result.nowReads = replaced.split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst(line - 1).prefix(min(edited, Result.shownLines)).map(String.init)
            after = Data(replaced.utf8)
        case .replaceLine(let number, let content, let expecting):
            let text = try editableText(before, path: path)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let count = text.hasSuffix("\n") ? lines.count - 1 : lines.count
            guard number >= 1, number <= count else { throw Failure.noSuchLine(number, lines: count) }
            var target = number
            if let expecting, !lines[number - 1].contains(expecting) {
                // A stale number: the one line that holds `expecting` exactly is the line meant; none or
                // several is not knowable, so nothing changes.
                let holding = lines[..<count].indices.filter { lines[$0].contains(expecting) }
                guard holding.count == 1, let only = holding.first else {
                    throw Failure.lineMismatch(number, expected: expecting, actual: lines[number - 1])
                }
                target = only + 1
                result.movedFrom = .init(line: number, find: expecting)
            }
            // A line has no newline of its own: one trailing newline is dropped, any other is refused,
            // so a model that pastes the page marker or a neighbour cannot corrupt the file.
            let single = content.hasSuffix("\n") ? String(content.dropLast()) : content
            guard !single.contains("\n") else { throw Failure.notOneLine(number) }
            let written = Self.indented(single, replacing: lines[target - 1])
            lines[target - 1] = written.line
            result.line = target
            result.keptIndentation = written.kept
            result.editedLines = 1
            result.nowReads = [written.line]
            after = Data(lines.joined(separator: "\n").utf8)
        }
        try Self.writeAtomically(after, to: url, replacing: exists)
        result.bytesAfter = after.count
        return result
    }

    /// The file's text for a replacement, once it is known to be small enough and not binary.
    ///
    /// - Parameters:
    ///   - data: The file's bytes.
    ///   - path: The file, for the errors.
    /// - Returns: The bytes decoded as UTF-8.
    /// - Throws: `Failure.tooLarge` or `Failure.binary`.
    private func editableText(_ data: Data, path: String) throws -> String {
        guard data.count <= maxBytes else { throw Failure.tooLarge(path: path, bytes: data.count, limit: maxBytes) }
        guard !data.contains(0) else { throw Failure.binary(path) }
        return String(decoding: data, as: UTF8.self)
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
