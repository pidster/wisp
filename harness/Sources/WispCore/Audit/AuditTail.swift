import Foundation

/// Follows the audit log as it grows, for `wisp logs --follow`: each `read` returns the events appended
/// since the last one. A line still being written is left for the next read. When the file is rotated
/// (it is shorter than what was read), reading starts again at its beginning.
public struct AuditTail: Sendable {
    /// The log file.
    public let url: URL
    /// Bytes of it consumed, up to the end of the last whole line.
    public private(set) var offset: UInt64

    /// Follows `url` from `offset`: 0 for the whole file, its size for only what comes next.
    public init(url: URL, offset: UInt64 = 0) {
        self.url = url
        self.offset = offset
    }

    /// Follows `url` from its current end.
    public static func atEnd(of url: URL) -> AuditTail {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        return AuditTail(url: url, offset: size)
    }

    /// The events appended since the last read; none when the file is missing or unchanged.
    ///
    /// - Throws: A file error other than the file being absent.
    public mutating func read() throws -> [AuditEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < offset { offset = 0 }
        guard size > offset else { return [] }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        guard let end = data.lastIndex(of: 0x0A) else { return [] }
        let whole = data[data.startIndex...end]
        offset += UInt64(whole.count)
        return AuditQuery.events(in: Data(whole))
    }
}
