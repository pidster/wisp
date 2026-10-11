import Darwin
import Foundation

/// Reads a window of lines from a text file without loading the whole file.
///
/// The file is streamed in fixed-size chunks; lines before `offset` are
/// skipped and reading stops as soon as the window is full, so very large
/// files cost only the bytes up to the end of the window. A line longer than the page is read by bytes, never
/// buffered whole: the scanner keeps a page of it and drops the rest while it looks for the newline, so a file
/// with no newlines at all costs a page of memory. Only regular files are read: a FIFO, a device, or a socket
/// is refused before it is opened, since reading one can block forever or never end (the 2026-10-09 review).
public struct FileReader: Sendable {
    /// A page of a file.
    public struct Window: Equatable, Sendable {
        /// 1-based number of the first line returned.
        public var firstLine: Int
        /// The lines, without trailing newlines.
        public var lines: [String]
        /// Whether the file continues after the last returned line.
        public var hasMore: Bool
        /// Whether the byte budget cut the window short of `limit` lines.
        public var truncatedByBytes: Bool

        /// 1-based number of the line to request next, or nil at end of file.
        public var nextOffset: Int? { hasMore ? firstLine + lines.count : nil }

        /// Model-facing rendering: numbered lines and a continuation hint.
        public var rendered: String {
            var out = lines.enumerated().map { "\(firstLine + $0.offset)\t\($0.element)" }
            if lines.isEmpty { out.append("(no lines in range)") }
            if let next = nextOffset {
                out.append("[more: call again with offset \(next)]")
            } else {
                out.append("[end of file]")
            }
            return out.joined(separator: "\n")
        }
    }

    /// Why a file could not be read.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No regular file exists at the path.
        case notFound(String)
        /// The path is a wildcard pattern, not a file: it has `*`, `?` or `[` and no file has that name.
        case pattern(String)
        /// The path is a directory.
        case isDirectory(String)
        /// The path is not a regular file: a FIFO, a device, or a socket, which a read could wait on forever.
        case notRegular(String, kind: String)
        /// The file contains NUL bytes and is treated as binary.
        case binary(String)
        /// `offset` or `limit` is below 1.
        case invalidRange
        /// The approval gate refused the read.
        case notApproved(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notFound(let path): "file not found: \(path)"
            case .pattern(let path):
                "read_file takes one path, not a pattern: \(path); list matches with run_command, e.g. ls \(path)"
            case .isDirectory(let path): "path is a directory: \(path)"
            case .notRegular(let path, let kind):
                "not a regular file: \(path) is a \(kind); only regular files are read"
            case .binary(let path): "file appears to be binary: \(path)"
            case .invalidRange: "offset and limit must be at least 1"
            case .notApproved(let reason): "read not approved: \(reason)"
            }
        }
    }

    /// Maximum bytes of line content returned per window when there is no `budget`.
    public var maxBytes: Int
    /// The conversation's tool-output budget, which sets the page when given (ADR 0050); nil keeps `maxBytes`.
    public var budget: ToolBudget?
    /// Bytes read from disk per chunk.
    var chunkSize: Int

    /// Creates a reader with a byte budget per window (default 4 KiB, the tool-output budget's floor).
    public init(maxBytes: Int = ToolBudget.floor, chunkSize: Int = 65536) {
        self.maxBytes = maxBytes
        self.chunkSize = chunkSize
    }

    /// The page in bytes now: the budget's, or `maxBytes`.
    public var pageBytes: Int { budget?.bytes ?? maxBytes }

    /// What `path` is, for the refusal: `fifo`, `character device`, `block device`, `socket`, or `symlink`; nil
    /// for a regular file, and for a path that does not exist.
    static func kind(of path: String) -> String? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        switch status.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR: return nil
        case S_IFIFO: return "fifo"
        case S_IFCHR: return "character device"
        case S_IFBLK: return "block device"
        case S_IFSOCK: return "socket"
        default: return "special file"
        }
    }

    /// Reads up to `limit` lines starting at 1-based line `offset`.
    ///
    /// - Throws: `Failure` for missing (or wildcard), directory, special, or binary files, or a bad range.
    public func read(path: String, offset: Int = 1, limit: Int = 100) throws -> Window {
        guard offset >= 1, limit >= 1 else { throw Failure.invalidRange }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // A file can really be named with a wildcard character, so only a path that does not exist is a pattern.
            throw path.contains(where: { "*?[".contains($0) }) ? Failure.pattern(path) : Failure.notFound(path)
        }
        guard !isDirectory.boolValue else { throw Failure.isDirectory(path) }
        if let kind = Self.kind(of: path) { throw Failure.notRegular(path, kind: kind) }
        // Non-blocking, so a path that became a FIFO since the check cannot hold the open; close-on-exec, so no
        // command inherits it; checked again once open, against the file actually opened.
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.notFound(path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        if fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT != S_IFREG {
            throw Failure.notRegular(path, kind: Self.kind(of: path) ?? "special file")
        }

        let page = pageBytes
        var scanner = LineScanner(keep: page)
        var lineNumber = 0
        var lines: [String] = []
        var bytesUsed = 0
        var truncatedByBytes = false
        var checkedForBinary = false

        // Returns true when the window is complete and reading can stop.
        func consume(_ line: Data) -> Bool {
            lineNumber += 1
            guard lineNumber >= offset else { return false }
            if lines.count == limit { return true }
            if bytesUsed + line.count > page, !lines.isEmpty {
                truncatedByBytes = true
                return true
            }
            lines.append(Self.utf8Prefix(line, maxBytes: page))
            bytesUsed += line.count
            return lines.count == limit
        }

        var hasMore = false
        var filled = false
        chunks: while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            if !checkedForBinary {
                checkedForBinary = true
                if chunk.contains(0) { throw Failure.binary(path) }
            }
            let batch = scanner.feed(chunk)
            for (index, line) in batch.enumerated() where consume(line) {
                filled = true
                // More only if something follows: further lines in this batch, an unterminated tail,
                // or bytes still unread in the file.
                hasMore =
                    index + 1 < batch.count || scanner.hasPending
                    || ((try? handle.read(upToCount: 1))?.isEmpty == false)
                break chunks
            }
        }
        if !filled, let last = scanner.finish(), consume(last) {
            hasMore = lineNumber > offset + lines.count - 1
        }
        return Window(
            firstLine: offset, lines: lines, hasMore: hasMore || truncatedByBytes, truncatedByBytes: truncatedByBytes)
    }
}

/// Splits a byte stream into newline-terminated lines across chunk boundaries, keeping at most `keep` bytes of
/// a line still open: a longer line is cut there (the reader cuts it to the page anyway) and the rest is counted,
/// not held, so memory is bounded by the page whatever the file holds.
struct LineScanner {
    /// Bytes after the last newline seen, carried into the next feed; at most `keep`.
    private var pending = Data()
    /// Bytes of the open line dropped past `keep`.
    private var overflow = 0
    /// The most bytes of an open line kept.
    let keep: Int

    /// Creates a scanner that keeps `keep` bytes of an open line (the page by default).
    init(keep: Int = ToolBudget.ceiling) {
        self.keep = max(1, keep)
    }

    /// Whether an unterminated partial line is buffered.
    var hasPending: Bool { !pending.isEmpty || overflow > 0 }

    /// Bytes held for the open line, for tests of the bound.
    var pendingBytes: Int { pending.count }

    /// Feeds a chunk and returns the complete lines it closed, without their newlines, each cut to `keep` bytes.
    mutating func feed(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            take(rest[rest.startIndex..<newline])
            var line = pending
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            pending = Data()
            overflow = 0
            rest = rest[rest.index(after: newline)...]
        }
        take(rest)
        return lines
    }

    /// Adds `bytes` to the open line, keeping at most `keep` of it.
    private mutating func take(_ bytes: Data.SubSequence) {
        guard !bytes.isEmpty else { return }
        let room = keep - pending.count
        if bytes.count <= room {
            pending.append(bytes)
        } else {
            if room > 0 { pending.append(bytes.prefix(room)) }
            overflow += bytes.count - max(0, room)
        }
    }

    /// Returns the unterminated final line, if any.
    mutating func finish() -> Data? {
        defer {
            pending = Data()
            overflow = 0
        }
        return pending.isEmpty && overflow == 0 ? nil : pending
    }
}

extension FileReader {
    /// The longest prefix of `data` within `maxBytes` that ends on a UTF-8 scalar boundary.
    static func utf8Prefix(_ data: Data, maxBytes: Int) -> String {
        guard data.count > maxBytes else { return String(decoding: data, as: UTF8.self) }
        var cut = maxBytes
        // Step back over up to three continuation bytes and a lead byte that would be left incomplete.
        for _ in 0..<4 {
            if let text = String(data: data.prefix(cut), encoding: .utf8) { return text }
            cut -= 1
        }
        return String(decoding: data.prefix(cut), as: UTF8.self)
    }
}
