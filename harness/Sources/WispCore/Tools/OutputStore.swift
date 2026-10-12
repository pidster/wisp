import CryptoKit
import Darwin
import Foundation
import Synchronization

/// The conversation's output store: every tool output larger than the tool-output budget, kept whole in a file
/// of its own, so nothing past the budget is dropped
/// ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)).
///
/// The model sees what fits its budget and a marker naming the stored output; `memory` pages, filters,
/// summarises, and condenses the stored file, and `wisp://threads/{thread_id}/output/{id}` serves it whole. An
/// output is kept under the audit call id of the tool call that produced it (`ToolCallContext.call`), the same
/// id its `tool.call` and `tool.result` events carry, so the three are joined without a new identifier. Each
/// output kept is audited as `output.kept`: its size, line count, and SHA-256, never its content, so the log
/// does not grow with it. One file per output, up to `ceiling` bytes (16 MiB): past that the output is cut,
/// and the cut is stated in the store's record, the marker, and the audit.
///
/// The store is a directory under wisp's home, `output/<audit session>/`, created when the first output is
/// kept; its files are user-only, like the audit log. A `final class` because its writers hold file handles
/// behind a `Mutex`, and its reads are synchronous file reads.
public final class OutputStore: Sendable {
    /// The most bytes one output's file holds; the rest is not kept, and the record says so.
    public static let ceiling = 16 << 20

    /// The record of one kept output, saved beside its file as `<id>.json`.
    public struct Kept: Codable, Equatable, Sendable {
        /// The output's id: the audit call id of the tool call.
        public var id: String
        /// The tool that produced it.
        public var tool: String
        /// Bytes in the file.
        public var bytes: Int
        /// Lines in the file; an unterminated last line counts.
        public var lines: Int
        /// SHA-256 of the file's bytes, in hex.
        public var sha256: String
        /// Whether the output passed the ceiling, so the file holds its first `bytes` only.
        public var cut: Bool
        /// Bytes the output had in all; more than `bytes` when cut.
        public var totalBytes: Int

        /// The record as audit details for `output.kept`.
        public var details: [String: JSONValue] {
            [
                "tool": .string(tool), "bytes": .int(bytes), "lines": .int(lines), "sha256": .string(sha256),
                "cut": .bool(cut), "totalBytes": .int(totalBytes),
            ]
        }
    }

    /// One piece of an output composed from several.
    public enum Part: Sendable {
        /// Text, appended as UTF-8.
        case text(String)
        /// A file's bytes, streamed in; the file is removed afterwards when `remove` is true.
        case file(URL, remove: Bool)
    }

    /// Where the files go.
    public let directory: URL
    /// The most bytes one file holds.
    public let ceiling: Int
    /// Where each kept output is recorded; nil records nothing.
    private let audit: AuditLog?

    /// Creates a store over `directory`, which is created when the first output is kept.
    ///
    /// - Parameters:
    ///   - directory: The directory.
    ///   - audit: Where `output.kept` events go.
    ///   - ceiling: The most bytes one file holds.
    public init(directory: URL, audit: AuditLog? = nil, ceiling: Int = OutputStore.ceiling) {
        self.directory = directory
        self.ceiling = ceiling
        self.audit = audit
    }

    /// The store for one conversation: `output/<session>/` under `home`.
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - audit: The conversation's audit log, whose session names the directory and which records each output
    ///     kept.
    /// - Returns: The store.
    public static func forThread(home: Home, audit: AuditLog) -> OutputStore {
        OutputStore(directory: home.outputs.appending(path: audit.session, directoryHint: .isDirectory), audit: audit)
    }

    /// The file holding output `id`.
    public func url(_ id: String) -> URL { directory.appending(path: id) }

    /// The record of output `id`.
    private func sidecar(_ id: String) -> URL { directory.appending(path: id + ".json") }

    /// Streams one output into the store, counting what passes and hashing it, and keeps at most the ceiling.
    public final class Writer: Sendable {
        /// What has been written so far.
        private struct State {
            /// The open file; nil once finished or when the file could not be opened.
            var handle: FileHandle?
            /// Bytes in the file.
            var written = 0
            /// Bytes seen.
            var total = 0
            /// Newlines in the file.
            var newlines = 0
            /// The last byte written, to count an unterminated last line.
            var lastByte: UInt8?
            /// The hash of the file's bytes.
            var hasher = SHA256()
            /// Whether a write failed, in which case the output is not kept.
            var failed = false
        }

        /// The id the output is kept under.
        public let id: String
        /// The tool that produced it.
        public let tool: String
        /// The store.
        private let store: OutputStore
        /// The progress.
        private let state: Mutex<State>

        /// Opens the file; `handle` is nil when it could not be opened.
        fileprivate init(id: String, tool: String, store: OutputStore, handle: FileHandle?) {
            self.id = id
            self.tool = tool
            self.store = store
            state = Mutex(State(handle: handle, failed: handle == nil))
        }

        /// Appends `data`, up to the ceiling; bytes past it are counted, not written.
        ///
        /// - Parameter data: The bytes.
        public func append(_ data: Data) {
            guard !data.isEmpty else { return }
            state.withLock { state in
                state.total += data.count
                guard let handle = state.handle, !state.failed else { return }
                let room = store.ceiling - state.written
                guard room > 0 else { return }
                let piece = data.count > room ? data.prefix(room) : data[...]
                do {
                    try handle.write(contentsOf: piece)
                } catch {
                    state.failed = true
                    Diagnostics.tools.error("output store write failed for \(id): \(error)")
                    return
                }
                state.written += piece.count
                state.newlines += piece.count(where: { $0 == 0x0A })
                state.lastByte = piece.last
                state.hasher.update(data: piece)
            }
        }

        /// Closes the file and records the output; nil when nothing was kept (a write failed, or nothing was
        /// written and the file is removed).
        ///
        /// - Returns: The record, or nil.
        public func finish() -> Kept? {
            let kept: Kept? = state.withLock { state in
                defer { state.handle = nil }
                try? state.handle?.close()
                guard !state.failed, state.written > 0 else { return nil }
                let digest = state.hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return Kept(
                    id: id, tool: tool, bytes: state.written,
                    lines: state.newlines + (state.lastByte == 0x0A ? 0 : 1), sha256: digest,
                    cut: state.total > state.written, totalBytes: state.total)
            }
            guard let kept else {
                try? FileManager.default.removeItem(at: store.url(id))
                return nil
            }
            store.record(kept)
            return kept
        }
    }

    /// A writer for output `id`, with its file open; the store's directory is created first. A writer whose
    /// file could not be opened keeps nothing and says so at `finish`.
    ///
    /// - Parameters:
    ///   - id: The output's id, a safe name.
    ///   - tool: The tool producing it.
    /// - Returns: The writer.
    public func writer(id: String, tool: String) -> Writer {
        Writer(id: id, tool: tool, store: self, handle: open(id))
    }

    /// Keeps `text` whole as output `id`.
    ///
    /// - Parameters:
    ///   - text: The output.
    ///   - id: Its id.
    ///   - tool: The tool.
    /// - Returns: The record, or nil when it could not be kept.
    @discardableResult
    public func keep(_ text: String, id: String, tool: String) -> Kept? {
        let writer = writer(id: id, tool: tool)
        writer.append(Data(text.utf8))
        return writer.finish()
    }

    /// Keeps an output composed of `parts`, streamed in order, as output `id`.
    ///
    /// - Parameters:
    ///   - parts: The pieces.
    ///   - id: Its id.
    ///   - tool: The tool.
    /// - Returns: The record, or nil when it could not be kept.
    @discardableResult
    public func compose(_ parts: [Part], id: String, tool: String) -> Kept? {
        let writer = writer(id: id, tool: tool)
        for part in parts {
            switch part {
            case .text(let text):
                writer.append(Data(text.utf8))
            case .file(let url, let remove):
                if let handle = try? FileHandle(forReadingFrom: url) {
                    while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty { writer.append(chunk) }
                    try? handle.close()
                }
                if remove { try? FileManager.default.removeItem(at: url) }
            }
        }
        return writer.finish()
    }

    /// A file in the store's directory for a stream to spill into as it arrives (`OutputBuffer`), open for
    /// writing, user-only and close-on-exec; not a kept output, and not recorded: the runner composes the kept
    /// output from it when the command ends. Nil when it cannot be opened.
    ///
    /// - Parameter name: The file's name, a safe name such as `<call>.out`.
    /// - Returns: The handle and the file's URL, or nil.
    public func spill(_ name: String) -> (handle: FileHandle, url: URL)? {
        guard let handle = open(name) else { return nil }
        return (handle, url(name))
    }

    /// The record of output `id`, or nil when the store does not hold it.
    public func kept(_ id: String) -> Kept? {
        guard SafeName.isValid(id), let data = try? Data(contentsOf: sidecar(id)) else { return nil }
        return try? JSONDecoder().decode(Kept.self, from: data)
    }

    /// Output `id`'s bytes, or nil when the store does not hold it.
    public func data(_ id: String) -> Data? {
        guard SafeName.isValid(id), FileManager.default.fileExists(atPath: sidecar(id).path) else { return nil }
        return try? Data(contentsOf: url(id))
    }

    /// Output `id` as text, decoded as UTF-8 with replacement, or nil when the store does not hold it.
    public func text(_ id: String) -> String? {
        data(id).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Output `id` as lines, without their newlines; an unterminated last line is one, and a trailing newline
    /// adds none. Nil when the store does not hold it.
    public func lines(_ id: String) -> [String]? {
        guard let text = text(id) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Page `number` (from 1) of output `id`, `Paging.bytePage`'s pages of `size` bytes, read from the file without
    /// loading the rest of it, and how many pages there are: how a face shows a stored output of up to the ceiling
    /// a page at a time (`wisp-tui`'s expanded view, ADR 0050). Nil when the store does not hold it or the page is out
    /// of range.
    ///
    /// - Parameters:
    ///   - id: The output's id.
    ///   - number: The page, from 1.
    ///   - size: The page size in bytes.
    /// - Returns: The page as text, decoded as UTF-8 with replacement, and the page count, or nil.
    public func page(_ id: String, number: Int, size: Int) -> (text: String, count: Int)? {
        guard let kept = kept(id), let handle = try? FileHandle(forReadingFrom: url(id)) else { return nil }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()).map { Int($0) } ?? kept.bytes
        let page = Paging.bytePage(number: number, size: size, total: total) { range in
            guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil else { return Data() }
            return (try? handle.read(upToCount: range.count)) ?? Data()
        }
        return page.map { (String(decoding: $0.data, as: UTF8.self), $0.count) }
    }

    /// Bytes the store's files take, for `doctor`.
    public var bytes: Int {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Saves the record beside the file and audits it.
    private func record(_ kept: Kept) {
        if let data = try? JSONEncoder().encode(kept) {
            try? data.write(to: sidecar(kept.id), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar(kept.id).path)
        }
        audit?.record(.outputKept, call: kept.id, details: kept.details)
    }

    /// Opens output `id`'s file for writing, user-only and close-on-exec, creating the directory; nil on failure.
    private func open(_ id: String) -> FileHandle? {
        guard SafeName.isValid(id) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Diagnostics.tools.error("output store directory \(directory.path) could not be made: \(error)")
            return nil
        }
        let descriptor = Darwin.open(url(id).path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            Diagnostics.tools.error(
                "output store file for \(id) could not be opened: \(String(cString: strerror(errno)))")
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// The audit call id of the tool call under way, set by `AuditedTool` for the base tool's call, so what the
/// tool keeps in the output store (`OutputStore`) is kept under the id its `tool.call` and `tool.result` carry.
public enum ToolCallContext {
    /// The call id; nil outside a tool call.
    @TaskLocal public static var call: String?

    /// The id an output kept now goes under: the call's, or a fresh one outside a tool call.
    public static var outputID: String { call ?? ShortID.make() }
}
