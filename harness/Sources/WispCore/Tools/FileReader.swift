import Foundation

/// Reads a window of lines from a text file without loading the whole file.
///
/// The file is streamed in fixed-size chunks; lines before `offset` are
/// skipped and reading stops as soon as the window is full, so very large
/// files cost only the bytes up to the end of the window.
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
            case .binary(let path): "file appears to be binary: \(path)"
            case .invalidRange: "offset and limit must be at least 1"
            case .notApproved(let reason): "read not approved: \(reason)"
            }
        }
    }

    /// Maximum bytes of line content returned per window.
    public var maxBytes: Int
    /// Bytes read from disk per chunk.
    var chunkSize: Int

    /// Creates a reader with a byte budget per window (default 4 KiB).
    public init(maxBytes: Int = 4096, chunkSize: Int = 65536) {
        self.maxBytes = maxBytes
        self.chunkSize = chunkSize
    }

    /// Reads up to `limit` lines starting at 1-based line `offset`.
    ///
    /// - Throws: `Failure` for missing (or wildcard), directory, or binary files, or a bad range.
    public func read(path: String, offset: Int = 1, limit: Int = 100) throws -> Window {
        guard offset >= 1, limit >= 1 else { throw Failure.invalidRange }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // A file can really be named with a wildcard character, so only a path that does not exist is a pattern.
            throw path.contains(where: { "*?[".contains($0) }) ? Failure.pattern(path) : Failure.notFound(path)
        }
        guard !isDirectory.boolValue else { throw Failure.isDirectory(path) }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.notFound(path) }
        defer { try? handle.close() }

        var scanner = LineScanner()
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
            if bytesUsed + line.count > maxBytes, !lines.isEmpty {
                truncatedByBytes = true
                return true
            }
            lines.append(Self.utf8Prefix(line, maxBytes: maxBytes))
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

/// Splits a byte stream into newline-terminated lines across chunk boundaries.
struct LineScanner {
    /// Bytes after the last newline seen, carried into the next feed.
    private var pending = Data()

    /// Whether an unterminated partial line is buffered.
    var hasPending: Bool { !pending.isEmpty }

    /// Feeds a chunk and returns the complete lines it closed, without their newlines.
    mutating func feed(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            pending = Data(pending[(newline + 1)...])
        }
        return lines
    }

    /// Returns the unterminated final line, if any.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
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
