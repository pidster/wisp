import Darwin
import Foundation
import Synchronization

/// Where audit events go. Implementations must be safe to call from any thread.
public protocol AuditSink: Sendable {
    /// Persists one event. Failures are reported to diagnostics, never thrown to the caller.
    func write(_ event: AuditEvent)
}

/// Records audit events for one session.
///
/// Cheap to create: several logs (one per MCP thread, say) can share a sink.
/// Turn numbers come from the conversation's `TurnClock` so every event in a turn carries the same one.
public final class AuditLog: Sendable {
    /// The session id stamped on every event.
    public let session: String
    /// The conversation's turn counter; the approval gate and the agent share it.
    public let turns: TurnClock
    private let sink: any AuditSink

    /// Creates a log for `session` writing to `sink`.
    ///
    /// - Parameters:
    ///   - session: The id stamped on every event.
    ///   - sink: Where events go.
    ///   - turns: The conversation's clock; a fresh one by default.
    public init(session: String, sink: any AuditSink, turns: TurnClock = TurnClock()) {
        self.session = session
        self.turns = turns
        self.sink = sink
    }

    /// A log that records nothing.
    public static func disabled(session: String) -> AuditLog {
        AuditLog(session: session, sink: NullAuditSink())
    }

    /// A sibling log for another session on the same sink.
    public func log(forSession session: String) -> AuditLog {
        AuditLog(session: session, sink: sink)
    }

    /// The same session and clock, also writing every event to `other`; a conversation records its
    /// receipts this way.
    public func alsoRecording(to other: any AuditSink) -> AuditLog {
        AuditLog(session: session, sink: TeeAuditSink([sink, other]), turns: turns)
    }

    /// The current turn number (0 before the first turn).
    public var currentTurn: Int { turns.current }

    /// Advances to the next turn and returns its number.
    @discardableResult
    public func beginTurn() -> Int { turns.advance() }

    /// Records an event in the current turn and returns where it is: its session, turn, and id.
    @discardableResult
    public func record(
        _ kind: AuditEvent.Kind, call: String? = nil, details: [String: JSONValue] = [:]
    ) -> AuditReference {
        let current = currentTurn
        let event = AuditEvent(
            session: session, kind: kind, turn: current == 0 ? nil : current, call: call, details: details)
        sink.write(event)
        return AuditReference(event)
    }

    /// Records an error with its description.
    public func error(_ error: some Error, call: String? = nil, context: String? = nil) {
        record(
            .error, call: call, details: AuditEvent.Details.error(message: String(describing: error), context: context))
    }
}

/// Discards events.
public struct NullAuditSink: AuditSink {
    /// Creates the sink.
    public init() {}
    /// Does nothing.
    public func write(_ event: AuditEvent) {}
}

/// Keeps events in memory, for tests and for `wisp logs` filtering.
public final class MemoryAuditSink: AuditSink {
    private let storage = Mutex<[AuditEvent]>([])

    /// Creates an empty sink.
    public init() {}

    /// Everything written so far, in order.
    public var events: [AuditEvent] { storage.withLock { $0 } }

    /// Appends the event.
    public func write(_ event: AuditEvent) {
        storage.withLock { $0.append(event) }
    }
}

/// Appends JSON Lines to a file owned by the user (mode 0600), rotating by size.
///
/// Rotation renames `audit.jsonl` to `audit.1.jsonl` and shifts older files up,
/// discarding the oldest beyond `keepFiles`.
public final class FileAuditSink: AuditSink {
    /// Size and retention limits.
    public struct Limits: Codable, Equatable, Sendable {
        /// Rotate when the file would exceed this many bytes.
        public var maxFileBytes: Int
        /// Rotated files to keep besides the current one.
        public var keepFiles: Int

        /// Creates limits; defaults are 10 MiB and 5 files.
        public init(maxFileBytes: Int = 10 * 1024 * 1024, keepFiles: Int = 5) {
            self.maxFileBytes = maxFileBytes
            self.keepFiles = keepFiles
        }
    }

    private struct State {
        var handle: FileHandle?
        var bytes: Int
    }

    /// The current file.
    public let url: URL
    private let limits: Limits
    private let state: Mutex<State>

    /// Opens (creating if needed) the file at `url`.
    ///
    /// - Throws: File-system errors.
    public init(url: URL, limits: Limits = Limits()) throws {
        self.url = url
        self.limits = limits
        let handle = try Self.open(url)
        state = Mutex(State(handle: handle, bytes: Int(try handle.seekToEnd())))
    }

    /// Encodes the event as one line and appends it, rotating first if it would overflow.
    public func write(_ event: AuditEvent) {
        guard var line = try? AuditEvent.encoder.encode(event) else {
            Diagnostics.audit.error("could not encode audit event \(event.kind.rawValue)")
            return
        }
        line.append(0x0A)
        state.withLock { state in
            do {
                if state.bytes + line.count > limits.maxFileBytes, state.bytes > 0 {
                    try state.handle?.close()
                    try rotate()
                    state.handle = try Self.open(url)
                    state.bytes = 0
                }
                try state.handle?.write(contentsOf: line)
                state.bytes += line.count
            } catch {
                Diagnostics.audit.error("audit write failed: \(error)")
            }
        }
    }

    /// Rotated file names, newest first, for readers.
    public static func rotatedFiles(for url: URL, keep: Int) -> [URL] {
        (1...max(keep, 1)).map { rotated(url, $0) }
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = Self.rotated(url, limits.keepFiles)
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        if limits.keepFiles > 1 {
            for index in stride(from: limits.keepFiles - 1, through: 1, by: -1) {
                let from = Self.rotated(url, index)
                if manager.fileExists(atPath: from.path) {
                    try manager.moveItem(at: from, to: Self.rotated(url, index + 1))
                }
            }
        }
        if limits.keepFiles >= 1 {
            try manager.moveItem(at: url, to: Self.rotated(url, 1))
        } else {
            try manager.removeItem(at: url)
        }
    }

    private static func rotated(_ url: URL, _ index: Int) -> URL {
        url.deletingPathExtension().appendingPathExtension("\(index).\(url.pathExtension)")
    }

    /// Opens for appending with `O_APPEND`, so concurrent wisps (an MCP server plus a CLI run)
    /// interleave whole lines instead of overwriting each other, and creates the file user-only.
    private static func open(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// Reads and filters audit files for `wisp logs`.
public struct AuditQuery: Equatable, Sendable {
    /// Only this session.
    public var session: String?
    /// Only these kinds; empty means all.
    public var kinds: [AuditEvent.Kind]
    /// Only tool events for this tool name.
    public var tool: String?
    /// Keep only the last N matching events; nil means all.
    public var last: Int?

    /// Creates a query.
    public init(session: String? = nil, kinds: [AuditEvent.Kind] = [], tool: String? = nil, last: Int? = nil) {
        self.session = session
        self.kinds = kinds
        self.tool = tool
        self.last = last
    }

    /// Applies the query to events already in order.
    public func filter(_ events: [AuditEvent]) -> [AuditEvent] {
        var matched = events.filter { event in
            if let session, event.session != session { return false }
            if !kinds.isEmpty, !kinds.contains(event.kind) { return false }
            if let tool, event.details["tool"]?.stringValue != tool { return false }
            return true
        }
        if let last, matched.count > last { matched = Array(matched.suffix(last)) }
        return matched
    }

    /// Parses JSON Lines, skipping lines that do not decode.
    public static func events(in data: Data) -> [AuditEvent] {
        data.split(separator: 0x0A).compactMap { try? AuditEvent.decoder.decode(AuditEvent.self, from: $0) }
    }
}
