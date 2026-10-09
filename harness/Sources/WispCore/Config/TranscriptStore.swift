import Foundation
import FoundationModels

/// Saves and loads conversation transcripts as JSON files named by the user.
public struct TranscriptStore: Sendable {
    /// Why a transcript name or file was rejected.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The name contains characters outside `[A-Za-z0-9._-]` or is too long.
        case invalidName(String)
        /// No transcript has this name.
        case notFound(String)
        /// The transcript has no store beside it (`<name>.store` is missing), so it was saved by a wisp that did not
        /// keep one, or by `save(_:as:)` with a transcript alone, and cannot be resumed.
        case notResumable(String)
        /// The store beside the transcript cannot be read or decoded.
        case unreadableStore(String, reason: String)
        /// The store beside the transcript is of a format version this build does not read.
        case storeVersion(String, version: Int)
        /// The store beside the transcript does not describe it: another conversation's, or one half of a save that
        /// did not finish.
        case mismatchedStore(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidName(let name): "invalid transcript name '\(name)': use 1-64 of [A-Za-z0-9._-]"
            case .notFound(let name): "no saved transcript named '\(name)'"
            case .notResumable(let name):
                "transcript '\(name)' was saved by an older wisp and cannot be resumed; start a new conversation"
            case .unreadableStore(let name, let reason):
                "transcript '\(name)' cannot be resumed: its store, \(name).store, cannot be read (\(reason)); start a "
                    + "new conversation"
            case .storeVersion(let name, let version):
                "transcript '\(name)' cannot be resumed: its store is format \(version), and this wisp reads format "
                    + "\(ThreadRecord.Snapshot.currentVersion); resume it with the wisp that saved it"
            case .mismatchedStore(let name):
                "transcript '\(name)' cannot be resumed: its store does not match it (another conversation's, or a "
                    + "save that did not finish); start a new conversation"
            }
        }
    }

    /// A saved conversation: the transcript, and the store links saved beside it.
    public struct Saved: Sendable {
        /// The transcript, as `load` returns it.
        public let transcript: Transcript
        /// The links to the audit log, checked to match the transcript.
        public let links: ThreadRecord.Snapshot
    }

    /// The directory holding `<name>.json` files.
    public let directory: URL

    /// Creates a store over `directory`; the directory must already exist to save.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The file a name maps to.
    ///
    /// - Throws: `Failure.invalidName`.
    public func url(for name: String) throws -> URL {
        try Self.validate(name)
        return directory.appending(path: "\(name).json")
    }

    /// The file beside `<name>.json` that holds the store links: `<name>.store`. It has no `.json`
    /// extension so `list` never shows it and a transcript named `x.store` (`x.store.json`) cannot collide
    /// with the links of `x`.
    ///
    /// - Throws: `Failure.invalidName`.
    public func linksURL(for name: String) throws -> URL {
        try Self.validate(name)
        return directory.appending(path: "\(name).store")
    }

    /// Writes `transcript` under `name`, replacing any existing file, and removes links a previous save of
    /// that name left, which no longer describe it.
    ///
    /// - Throws: `Failure.invalidName` or file-system errors.
    public func save(_ transcript: Transcript, as name: String) throws {
        let file = try url(for: name)
        // The links go first, so a failed write never leaves them beside a transcript they do not describe.
        let links = try linksURL(for: name)
        if FileManager.default.fileExists(atPath: links.path) { try FileManager.default.removeItem(at: links) }
        try write(transcript, to: file)
    }

    /// Writes the store's active view under `name` as `save(_:as:)` does, and the whole store's links
    /// (dropped entries included) beside it, both readable by the user only. Both are encoded and written in full
    /// beside their places before either takes its name, store first, so a save that fails part way leaves the
    /// previous pair, or at worst a new store beside the old transcript, which `loadThread` reports as mismatched;
    /// never a stale store that a new transcript would be resumed with.
    ///
    /// - Throws: `Failure.invalidName` or file-system errors.
    public func save(_ store: ThreadRecord, as name: String) throws {
        let file = try url(for: name)
        let links = try linksURL(for: name)
        let pendingLinks = try staged(store.snapshot, for: links)
        defer { try? FileManager.default.removeItem(at: pendingLinks) }
        let pendingFile = try staged(store.active, for: file)
        defer { try? FileManager.default.removeItem(at: pendingFile) }
        try place(pendingLinks, at: links)
        try place(pendingFile, at: file)
    }

    /// Encodes `value` to `file` atomically, mode 0600.
    private func write(_ value: some Encodable, to file: URL) throws {
        try place(try staged(value, for: file), at: file)
    }

    /// Encodes `value` into a new file, mode 0600, beside `file`, under a name `list` never shows.
    ///
    /// - Returns: The new file.
    /// - Throws: Encoding or file-system errors.
    private func staged(_ value: some Encodable, for file: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let pending = file.deletingLastPathComponent().appending(
            path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard
            FileManager.default.createFile(atPath: pending.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: pending.path]) }
        return pending
    }

    /// Gives `pending` the name `file`, replacing what was there in one step (`rename(2)`).
    ///
    /// - Throws: The file system's error.
    private func place(_ pending: URL, at file: URL) throws {
        guard rename(pending.path, file.path) == 0 else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: file.path, NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }

    /// Reads the transcript saved under `name` and the store links saved beside it. A transcript without
    /// links, or with ones that do not decode or do not match it, cannot be resumed, each said apart.
    ///
    /// - Throws: As `load`, and `Failure.notResumable`, `unreadableStore`, `storeVersion`, or `mismatchedStore`.
    public func loadThread(_ name: String) throws -> Saved {
        let transcript = try load(name)
        let file = try linksURL(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notResumable(name) }
        let snapshot: ThreadRecord.Snapshot
        do {
            snapshot = try JSONDecoder().decode(ThreadRecord.Snapshot.self, from: Data(contentsOf: file))
        } catch {
            throw Failure.unreadableStore(name, reason: Self.reason(error))
        }
        guard snapshot.version == ThreadRecord.Snapshot.currentVersion else {
            throw Failure.storeVersion(name, version: snapshot.version)
        }
        guard snapshot.restored(over: transcript) != nil else { throw Failure.mismatchedStore(name) }
        return Saved(transcript: transcript, links: snapshot)
    }

    /// A read or decoding error in a few words.
    private static func reason(_ error: any Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context),
                .valueNotFound(_, let context):
                return context.debugDescription
            @unknown default: return "\(decoding)"
            }
        }
        return error.localizedDescription
    }

    /// Reads the transcript saved under `name`.
    ///
    /// - Throws: `Failure.invalidName`, `Failure.notFound`, or decoding errors.
    public func load(_ name: String) throws -> Transcript {
        let file = try url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound(name) }
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: file))
    }

    /// Names of saved transcripts, sorted.
    public func list() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Validates a name: 1 to 64 characters from `[A-Za-z0-9._-]`.
    ///
    /// - Throws: `Failure.invalidName`.
    public static func validate(_ name: String) throws {
        guard SafeName.isValid(name) else { throw Failure.invalidName(name) }
    }
}
