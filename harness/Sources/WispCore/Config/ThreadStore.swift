import Foundation
import FoundationModels

/// Every thread saved as it goes, one directory per thread under wisp's home, `threads/<id>/`
/// ([ADR 0066](../../../../docs/decisions/0066-one-thread-store.md)): its start settings in `thread.json`, beside its
/// record (`record.json` and `record.store`, in the format `TranscriptStore` wrote for chat's `/save` before 0.27.0), and the
/// lock that keeps it to one process (`ThreadLock`).
///
/// The directory is user-only, and so is every file: a record holds tool output, which may hold secrets, as the
/// audit log does. Each file is staged and renamed, `thread.json` last, so a reader never sees settings for a record
/// that is not there; a record without `thread.json` (a save cut short before its first settings) is not resumable,
/// and the next opening of the id starts afresh.
public struct ThreadStore: Sendable {
    /// Whether a saved thread is held by a process.
    public enum State: String, Codable, Sendable, Equatable {
        /// A process held it when this was written.
        case open
        /// No process holds it: it was saved at eviction or at its client's end, and can be resumed.
        case saved
    }

    /// A fact the person dropped for this thread, which it does not ask about again (`FactKeeper`, ADR 0048).
    public struct DroppedFact: Codable, Sendable, Equatable {
        /// The fact as the request named it.
        public var fact: PendingApprovals.ProposedFact
        /// The request the person answered.
        public var request: String
        /// When the request was filed.
        public var asked: Date
        /// When the person answered it.
        public var settled: Date?

        /// Creates a record.
        ///
        /// - Parameters:
        ///   - fact: The fact.
        ///   - request: The request's id.
        ///   - asked: When it was filed.
        ///   - settled: When it was answered.
        public init(fact: PendingApprovals.ProposedFact, request: String, asked: Date, settled: Date?) {
            self.fact = fact
            self.request = request
            self.asked = asked
            self.settled = settled
        }
    }

    /// `thread.json`: who owns the thread, the settings it started with, and its history in the audit log.
    public struct Settings: Codable, Sendable, Equatable {
        /// The format this build reads and writes.
        public static let currentVersion = 1

        /// The format version.
        public var version: Int
        /// The thread's id: its directory's name, and an MCP caller's `thread_id`.
        public var id: String
        /// Who owns it: `chat`, or the MCP client's `clientInfo.name` (D3).
        public var owner: String
        /// Its model, as `ModelSelection` spells it.
        public var model: String
        /// The tools its model may call, in order; empty for a text-only thread.
        public var tools: [String]
        /// The caller's instructions (the conversation layer); nil when it gave none.
        public var instructions: String?
        /// The thinking its turns ask of the model (`true`, `false`, or a level); nil for the model's default.
        public var think: String?
        /// Its own limit for `run_command`, in seconds, as asked; nil for the operator's default.
        public var commandTimeoutSeconds: Int?
        /// When it was first opened.
        public var created: Date
        /// When it was last saved: after its last turn, or when it was evicted or its client went.
        public var lastUsed: Date
        /// Turns it has had, over every opening.
        public var turns: Int
        /// The audit sessions it has had, one per opening, oldest first.
        public var sessions: [String]
        /// The facts the person dropped for it (D9).
        public var droppedFacts: [DroppedFact]
        /// Whether a process held it when this was written.
        public var state: State

        /// The settings of a thread opened now for the first time.
        ///
        /// - Parameters:
        ///   - id: Its id.
        ///   - owner: Its owner.
        ///   - model: Its model.
        ///   - tools: Its tools.
        ///   - instructions: The caller's instructions.
        ///   - think: Its thinking, as text.
        ///   - commandTimeoutSeconds: Its own command limit.
        ///   - session: The audit session of this opening.
        ///   - now: The time.
        public init(
            id: String, owner: String, model: String, tools: [String], instructions: String? = nil,
            think: String? = nil, commandTimeoutSeconds: Int? = nil, session: String, now: Date = Date()
        ) {
            version = Self.currentVersion
            self.id = id
            self.owner = owner
            self.model = model
            self.tools = tools
            self.instructions = instructions
            self.think = think
            self.commandTimeoutSeconds = commandTimeoutSeconds
            created = now
            lastUsed = now
            turns = 0
            sessions = [session]
            droppedFacts = []
            state = .open
        }

        /// The same thread opened again under `session`: held again, with the session added once.
        ///
        /// - Parameter session: The new opening's audit session.
        /// - Returns: The settings to write.
        public func reopened(as session: String) -> Settings {
            var next = self
            next.state = .open
            if !next.sessions.contains(session) { next.sessions.append(session) }
            return next
        }

        /// The settings in a few words for a message: `model ollama:granite4.1:8b, tools run_command`, then
        /// instructions, think, and the command limit when set.
        public var described: String {
            var parts = ["model \(model)", tools.isEmpty ? "no tools" : "tools \(tools.joined(separator: ", "))"]
            if instructions != nil { parts.append("instructions set") }
            if let think { parts.append("think \(think)") }
            if let commandTimeoutSeconds { parts.append("commandTimeoutSeconds \(commandTimeoutSeconds)") }
            return parts.joined(separator: ", ")
        }
    }

    /// A saved thread, ready to resume: its settings, and the record as `TranscriptStore.loadThread` reads it.
    public struct Saved: Sendable {
        /// `thread.json`.
        public let settings: Settings
        /// The transcript, which carries the instructions.
        public let transcript: Transcript
        /// The store links saved beside it.
        public let links: ThreadRecord.Snapshot
    }

    /// Why a thread could not be read, saved, or opened.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The id cannot name a directory in the store.
        case invalidID(String)
        /// `thread.json` cannot be read or decoded.
        case unreadable(String, reason: String)
        /// `thread.json` is of a format this build does not read.
        case version(String, Int)
        /// The record beside `thread.json` cannot be resumed.
        case record(String, reason: String)
        /// The thread belongs to another owner (D3).
        case owned(String, owner: String, client: String)
        /// Another process holds the thread (D6).
        case held(String, ThreadLock.Holder?)
        /// The lock could not be taken, for a reason other than another holder.
        case unlockable(String, reason: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidID(let id):
                "thread id '\(id)' cannot be saved: use 1-48 of [A-Za-z0-9._-], not starting with '.'"
            case .unreadable(let id, let reason):
                "thread \(id) cannot be resumed: its thread.json cannot be read (\(reason)); \(ThreadStore.deleting(id))"
            case .version(let id, let version):
                "thread \(id) cannot be resumed: its thread.json is format \(version), and this wisp reads format "
                    + "\(Settings.currentVersion); resume it with the wisp that saved it"
            case .record(let id, let reason):
                "thread \(id) cannot be resumed: \(reason); \(ThreadStore.deleting(id))"
            case .owned(let id, let owner, let client):
                "thread \(id) belongs to \(owner), and this client is \(client); choose another thread_id, or the "
                    + "person gives it to you with wisp threads hand \(id) \(client)"
            case .held(let id, let holder):
                "thread \(id) is open in another wisp"
                    + (holder.flatMap { $0.pid > 0 ? " (pid \($0.pid)\($0.owner.map { ", \($0)" } ?? ""))" : nil } ?? "")
            case .unlockable(let id, let reason): "thread \(id) cannot be locked: \(reason)"
            }
        }
    }

    /// How to delete a thread that cannot be resumed, from either face: `wisp threads delete` for the person, or
    /// `close_thread` for its agent.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The advice.
    static func deleting(_ id: String) -> String {
        "wisp threads delete \(id) deletes it, or close_thread \(id) from its agent"
    }

    /// The ids of the thread directories whose `thread.json` is there but cannot be read by this build, sorted.
    public var unreadable: [String] {
        ids.filter { id in
            do {
                _ = try settings(id)
                return false
            } catch {
                return true
            }
        }
    }

    /// The longest id the store takes: an audit session is `<id>-<8 characters>`, and must itself be a `SafeName`.
    public static let idLimit = 48
    /// The name `TranscriptStore` saves the record under, so its files are `record.json` and `record.store`.
    static let recordName = "record"

    /// The store's root, `threads/` under wisp's home.
    public let root: URL

    /// The store under `home`.
    ///
    /// - Parameter home: wisp's home.
    public init(home: Home) {
        root = home.threads
    }

    /// Whether `id` can name a thread: a `SafeName` of at most 48 characters that does not start with a dot, so it is
    /// never `.`, `..`, or a staged file's name.
    ///
    /// - Parameter id: The id.
    /// - Returns: Whether the store takes it.
    public static func isValid(_ id: String) -> Bool {
        SafeName.isValid(id) && id.unicodeScalars.count <= idLimit && !id.hasPrefix(".")
    }

    /// The directory of thread `id`.
    ///
    /// - Parameter id: The thread.
    /// - Returns: `threads/<id>/`.
    public func directory(of id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// `thread.json` of thread `id`.
    func settingsFile(_ id: String) -> URL { directory(of: id).appending(path: "thread.json") }

    /// The lock file of thread `id`.
    func lockFile(_ id: String) -> URL { directory(of: id).appending(path: "lock") }

    /// The record's store under thread `id`'s directory.
    func records(_ id: String) -> TranscriptStore { TranscriptStore(directory: directory(of: id)) }

    /// The encoder `thread.json` is written with: sorted keys, ISO 8601 dates, indented for a person to read.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The settings saved for thread `id`, or nil when it has none: never saved, or a save cut short before its
    /// first settings.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The settings, or nil.
    /// - Throws: `Failure.invalidID`, `unreadable`, or `version`.
    public func settings(_ id: String) throws -> Settings? {
        guard Self.isValid(id) else { throw Failure.invalidID(id) }
        let file = settingsFile(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings: Settings
        do {
            settings = try decoder.decode(Settings.self, from: Data(contentsOf: file))
        } catch {
            // A newer format may not decode at all; its version field says so when it can be read.
            if let data = try? Data(contentsOf: file),
                let version = (try? JSONDecoder().decode(VersionOnly.self, from: data))?.version,
                version != Settings.currentVersion
            {
                throw Failure.version(id, version)
            }
            throw Failure.unreadable(id, reason: "\(error)")
        }
        guard settings.version == Settings.currentVersion else { throw Failure.version(id, settings.version) }
        return settings
    }

    /// Just a file's `version`, read when the rest does not decode.
    private struct VersionOnly: Decodable {
        /// The format version.
        var version: Int
    }

    /// Thread `id` as saved, ready to resume, or nil when it is not saved.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The saved thread, or nil.
    /// - Throws: As `settings(_:)`, and `Failure.record` when the record beside the settings cannot be resumed.
    public func load(_ id: String) throws -> Saved? {
        guard let settings = try settings(id) else { return nil }
        do {
            let saved = try records(id).loadThread(Self.recordName)
            return Saved(settings: settings, transcript: saved.transcript, links: saved.links)
        } catch let failure as TranscriptStore.Failure {
            throw Failure.record(id, reason: Self.reason(failure))
        } catch {
            throw Failure.record(id, reason: "its record cannot be read (\(error))")
        }
    }

    /// The thread's store rebuilt from its saved record, for reading it without opening a model, or nil when it is
    /// not saved.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The store, or nil.
    /// - Throws: As `load(_:)`.
    public func record(_ id: String) throws -> ThreadRecord? {
        guard let saved = try load(id) else { return nil }
        guard let record = saved.links.restored(over: saved.transcript) else {
            throw Failure.record(id, reason: "its record does not match its store")
        }
        return record
    }

    /// What is wrong with a record, in the store's words rather than a transcript's.
    private static func reason(_ failure: TranscriptStore.Failure) -> String {
        switch failure {
        case .notFound: "its record, record.json, is missing"
        case .notResumable: "its record has no record.store beside it"
        case .unreadableStore(_, let reason): "its record.store cannot be read (\(reason))"
        case .storeVersion(_, let version):
            "its record.store is format \(version), and this wisp reads format \(ThreadRecord.Snapshot.currentVersion)"
        case .mismatchedStore: "its record.store does not match record.json"
        case .invalidName(let name): "invalid record name \(name)"
        }
    }

    /// Saves thread `settings.id`: the record when given (`record.json` and `record.store`), then `thread.json`, each
    /// staged and renamed, in a user-only directory.
    ///
    /// - Parameters:
    ///   - settings: `thread.json`.
    ///   - record: The thread's store; nil writes the settings alone, over a record already saved.
    /// - Throws: `Failure.invalidID`, or file-system and encoding errors.
    public func save(_ settings: Settings, record: ThreadRecord?) throws {
        guard Self.isValid(settings.id) else { throw Failure.invalidID(settings.id) }
        try ensure(settings.id)
        if let record { try records(settings.id).save(record, as: Self.recordName) }
        let file = settingsFile(settings.id)
        let pending = try TranscriptStore.staged(data: try Self.encoder().encode(settings), for: file)
        defer { try? FileManager.default.removeItem(at: pending) }
        try TranscriptStore.place(pending, at: file)
    }

    /// Creates the store and thread `id`'s directory, user-only, when they do not exist.
    ///
    /// - Parameter id: The thread.
    /// - Throws: File-system errors.
    func ensure(_ id: String) throws {
        let user: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: user)
        try FileManager.default.createDirectory(
            at: directory(of: id), withIntermediateDirectories: true, attributes: user)
    }

    /// Deletes thread `id` from the store: its directory and everything in it. Nothing when it is not there.
    ///
    /// - Parameter id: The thread.
    /// - Throws: `Failure.invalidID`, or the file system's error.
    public func delete(_ id: String) throws {
        guard Self.isValid(id) else { throw Failure.invalidID(id) }
        let directory = directory(of: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The ids of every thread directory in the store, sorted; what has no `thread.json` included.
    public var ids: [String] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
            let id = url.lastPathComponent
            return Self.isValid(id) ? id : nil
        }.sorted()
    }

    /// Every saved thread whose settings can be read, most recently used first.
    public var all: [Settings] {
        ids.compactMap { try? settings($0) }.sorted { ($0.lastUsed, $0.id) > ($1.lastUsed, $1.id) }
    }

    /// Takes thread `id`'s lock for this process, creating its directory if need be, and records `owner` and this
    /// process's pid in it.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - owner: Who opens it.
    /// - Returns: The lock; release it when the thread is closed, evicted, or saved at its client's end.
    /// - Throws: `Failure.invalidID`, `held` when another process (or another opening in this one) holds it, or
    ///   `unlockable`.
    public func lock(_ id: String, owner: String) throws -> ThreadLock {
        guard Self.isValid(id) else { throw Failure.invalidID(id) }
        do {
            try ensure(id)
        } catch {
            throw Failure.unlockable(id, reason: "\(error)")
        }
        switch ThreadLock.take(at: lockFile(id), holder: .init(pid: getpid(), owner: owner)) {
        case .acquired(let lock): return lock
        case .held(let holder): throw Failure.held(id, holder)
        case .failed(let reason): throw Failure.unlockable(id, reason: reason)
        }
    }

    /// Who holds thread `id` now, when another open file description does: nil when nobody does.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The holder as its lock file records it (its fields unknown when the file does not say), or nil.
    public func holder(of id: String) -> ThreadLock.Holder? {
        guard Self.isValid(id), ThreadLock.isHeld(lockFile(id)) else { return nil }
        return ThreadLock.holder(in: lockFile(id)) ?? ThreadLock.Holder(pid: 0, owner: nil)
    }
}
