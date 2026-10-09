import Darwin
import Foundation

/// How long an approval lasts.
public enum ApprovalScope: String, Codable, Equatable, Sendable, CaseIterable {
    /// The rest of this turn: the current prompt's tool loop, however many calls it makes.
    case once
    /// Until the process exits.
    case session
    /// Until it expires, for this exact command in this exact directory; persisted.
    case project
    /// Until it expires, for this exact command in any directory; persisted.
    case always

    /// Whether the scope outlives the process.
    public var isPersistent: Bool {
        self == .project || self == .always
    }
}

/// Approvals that outlive the process, kept in `~/.wisp/approvals.json`.
///
/// A persisted approval is a standing permission, so it is bound to a pattern
/// (`head *`: the program, any arguments; and the directory for `project`),
/// expires, covers verdicts only up to the level it was granted at, is never used
/// for a dangerous verdict, and can be listed and revoked with `wisp approvals`.
/// Deny patterns and the sandbox still apply to every use.
///
/// Several processes share the file (a `wisp mcp` server and `wisp approvals revoke` in a terminal),
/// so every operation reads it afresh, and every change is made under an advisory `flock` on
/// `approvals.json.lock` beside it: read, change, write atomically, unlock. A revocation made by
/// another process is therefore never undone by this one's next grant.
public actor ApprovalStore {
    /// One standing approval.
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// Short random id, for `wisp approvals revoke`.
        public var id: String
        /// The approval key, such as `head *`.
        public var pattern: String
        /// The directory, for `project` scope; nil for `always`.
        public var workingDirectory: String?
        /// `project` or `always`.
        public var scope: ApprovalScope
        /// The classifier level when granted; the entry covers verdicts at this level or below.
        public var level: RiskLevel
        /// When it was granted.
        public var grantedAt: Date
        /// When it stops applying.
        public var expiresAt: Date
        /// Which entry point granted it.
        public var source: String

        /// Whether `pattern` in `directory` is covered at `now`.
        func covers(pattern: String, directory: String, now: Date) -> Bool {
            guard now < expiresAt, self.pattern == pattern else { return false }
            return scope == .always || workingDirectory == directory
        }
    }

    /// Where entries are written; nil keeps them in memory only (tests).
    public let url: URL?
    private let lifetime: Duration
    /// The entries of an in-memory store; a store with a file reads the file instead.
    private var memory: [Entry] = []

    /// A store over `url` (missing or unreadable means empty); expired entries are ignored and dropped
    /// at the next change.
    ///
    /// - Parameters:
    ///   - url: The JSON file, or nil for an in-memory store.
    ///   - lifetime: How long a new grant lasts.
    public init(url: URL?, lifetime: Duration = .seconds(30 * 24 * 3600)) {
        self.url = url
        self.lifetime = lifetime
    }

    /// Live entries, newest first.
    public var all: [Entry] {
        load().filter { $0.expiresAt > Date() }.sorted { $0.grantedAt > $1.grantedAt }
    }

    /// The entry covering `pattern` in `directory`, if any, granted at `level` or above when a level is given.
    ///
    /// - Parameters:
    ///   - pattern: The approval key.
    ///   - directory: Where the command would run.
    ///   - level: The verdict to cover; nil covers any.
    /// - Returns: The first entry that covers it.
    public func find(pattern: String, directory: String, level: RiskLevel? = nil) -> Entry? {
        let now = Date()
        return load().first { entry in
            entry.covers(pattern: pattern, directory: directory, now: now) && level.map { entry.level >= $0 } ?? true
        }
    }

    /// Records a standing approval and writes the file.
    ///
    /// - Returns: The new entry.
    /// - Throws: File-system errors from writing.
    @discardableResult
    public func grant(
        pattern: String, directory: String, scope: ApprovalScope, level: RiskLevel, source: String
    ) throws -> Entry {
        precondition(scope.isPersistent, "only project and always are persisted")
        let now = Date()
        let entry = Entry(
            id: ShortID.make(), pattern: pattern,
            workingDirectory: scope == .project ? directory : nil, scope: scope, level: level, grantedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(lifetime.components.seconds)), source: source)
        try change { $0.append(entry) }
        return entry
    }

    /// Removes the entry with `id`.
    ///
    /// - Returns: Whether anything was removed.
    /// - Throws: File-system errors from writing.
    public func revoke(id: String) throws -> Bool {
        var removed = false
        try change { entries in
            let before = entries.count
            entries.removeAll { $0.id == id }
            removed = entries.count < before
        }
        return removed
    }

    /// Removes every entry.
    ///
    /// - Throws: File-system errors from writing.
    public func clear() throws {
        try change { $0.removeAll() }
    }

    /// The entries as they stand now: the file's, read afresh, or the in-memory list.
    private func load() -> [Entry] {
        guard let url else { return memory }
        return Self.read(url)
    }

    /// The entries in the file at `url`; missing or unreadable is empty.
    private static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url), let decoded = try? decoder.decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    /// Applies `edit` to the entries as they stand on disk, under the lock, and writes them back without the
    /// expired ones.
    ///
    /// - Throws: File-system errors from locking or writing.
    private func change(_ edit: (inout [Entry]) -> Void) throws {
        guard let url else {
            edit(&memory)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = try Self.lock(url.appendingPathExtension("lock"))
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        var entries = Self.read(url)
        edit(&entries)
        let now = Date()
        try Self.write(entries.filter { $0.expiresAt > now }, to: url)
    }

    /// Opens (creating, mode 0600) and exclusively locks the lock file, waiting for another process to release it.
    ///
    /// - Returns: The open descriptor, which holds the lock until it is unlocked or closed.
    /// - Throws: A POSIX error when it cannot be opened or locked.
    private static func lock(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let code = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        return descriptor
    }

    /// Writes `entries` to a temporary file beside `url`, mode 0600 from the start, and renames it over `url`.
    ///
    /// - Throws: An encoding or file-system error; the temporary file is removed on failure.
    private static func write(_ entries: [Entry], to url: URL) throws {
        let data = try encoder.encode(entries)
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(ShortID.make())")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw POSIXError(.EIO) }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
