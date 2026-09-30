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
        /// The transcript has no usable store beside it (`<name>.store` is missing, unreadable, or does not
        /// match it), so it was saved by a wisp that did not keep one and cannot be resumed.
        case notResumable(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidName(let name): "invalid transcript name '\(name)': use 1-64 of [A-Za-z0-9._-]"
            case .notFound(let name): "no saved transcript named '\(name)'"
            case .notResumable(let name):
                "transcript '\(name)' was saved by an older wisp and cannot be resumed; start a new conversation"
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
        try write(transcript, to: file)
        try? FileManager.default.removeItem(at: linksURL(for: name))
    }

    /// Writes the store's active view under `name` as `save(_:as:)` does, and the whole store's links
    /// (dropped entries included) beside it, both readable by the user only.
    ///
    /// - Throws: `Failure.invalidName` or file-system errors.
    public func save(_ store: ThreadRecord, as name: String) throws {
        let file = try url(for: name)
        let links = try linksURL(for: name)
        try write(store.active, to: file)
        try write(store.snapshot, to: links)
    }

    /// Encodes `value` to `file` atomically, mode 0600.
    private func write(_ value: some Encodable, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Reads the transcript saved under `name` and the store links saved beside it. A transcript without
    /// links, or with ones that do not decode or do not match it, cannot be resumed.
    ///
    /// - Throws: As `load`, and `Failure.notResumable`.
    public func loadThread(_ name: String) throws -> Saved {
        let transcript = try load(name)
        let file = try linksURL(for: name)
        guard let data = try? Data(contentsOf: file),
            let snapshot = try? JSONDecoder().decode(ThreadRecord.Snapshot.self, from: data),
            snapshot.restored(over: transcript) != nil
        else { throw Failure.notResumable(name) }
        return Saved(transcript: transcript, links: snapshot)
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
