import Foundation

/// The person's view of the thread store, behind `wisp threads` ([ADR 0066](../../../../docs/decisions/0066-one-thread-store.md),
/// phase 3): every saved thread listed, one shown in full, one deleted with its stored outputs, and one handed to
/// another owner (D3) so that client's agent may resume it.
///
/// Listing and showing only read. Deleting and handing change what an agent may open, so they are the person's: the
/// command runs them only from a terminal, and `CommandPolicy`'s defaults refuse them to wisp's model. Both take the
/// thread's lock first, so a thread a process holds is refused, naming the holder, and none is changed from under a
/// process that has it open.
public struct ThreadAdmin: Sendable {
    /// Why a thread could not be shown, deleted, or handed.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The store has no thread of this id.
        case notFound(String)
        /// The owner to hand a thread to cannot be one.
        case invalidOwner(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notFound(let id): "no saved thread '\(id)'; wisp threads lists them"
            case .invalidOwner(let owner):
                "'\(owner)' cannot own a thread: name the client as its MCP clientInfo.name gives it (claude-code, "
                    + "codex), or chat, in 1-64 printable characters"
            }
        }
    }

    /// A saved thread as `wisp threads` lists it.
    public struct Entry: Codable, Sendable, Equatable {
        /// Its id.
        public var id: String
        /// Its owner.
        public var owner: String
        /// Its model.
        public var model: String
        /// Turns it has had.
        public var turns: Int
        /// When it was last saved.
        public var lastUsed: Date
        /// `saved`, or `open elsewhere` while a process holds it.
        public var state: String
        /// The process holding it, when one does.
        public var holder: ThreadLock.Holder?
    }

    /// One thread in full, as `wisp threads show` gives it.
    public struct Details: Codable, Sendable, Equatable {
        /// `thread.json`.
        public var settings: ThreadStore.Settings
        /// The process holding it, when one does.
        public var holder: ThreadLock.Holder?
        /// Bytes its directory takes: its settings, record, and lock.
        public var bytes: Int
        /// Bytes its stored outputs take, over every audit session it has had.
        public var outputBytes: Int
        /// When the sweep deletes it if it is not used again, `threads.keepDays` after its last use; nil when
        /// `keepDays` is 0.
        public var sweepsAfter: Date?
    }

    /// A thread `delete` removed, as `thread.deleted` records it.
    public struct Deleted: Sendable, Equatable {
        /// Its id.
        public var id: String
        /// Its owner; nil when its settings could not be read.
        public var owner: String?
        /// Turns it had.
        public var turns: Int
        /// The audit sessions it had.
        public var sessions: [String]
        /// The sessions whose stored outputs went with it: those no other thread in the store names.
        public var outputSessions: [String]
        /// Bytes those outputs took.
        public var outputBytes: Int

        /// The audit details of `thread.deleted`.
        public var details: [String: JSONValue] {
            [
                "thread": .string(id), "owner": owner.map { .string($0) } ?? .null, "turns": .int(turns),
                "sessions": .array(sessions.map { .string($0) }),
                "outputSessions": .array(outputSessions.map { .string($0) }), "outputBytes": .int(outputBytes),
            ]
        }
    }

    /// A thread `hand` gave to another owner, as `thread.handed` records it.
    public struct Handed: Sendable, Equatable {
        /// Its id.
        public var id: String
        /// Its owner before.
        public var from: String
        /// Its owner now.
        public var to: String

        /// The audit details of `thread.handed`.
        public var details: [String: JSONValue] { ["thread": .string(id), "from": .string(from), "to": .string(to)] }
    }

    /// The longest owner `hand` takes.
    public static let ownerLimit = 64

    /// The store.
    public let store: ThreadStore
    /// The output store's root, `output/` under wisp's home.
    public let outputs: URL

    /// The view of `home`'s thread store.
    ///
    /// - Parameter home: wisp's home.
    public init(home: Home) {
        store = ThreadStore(home: home)
        outputs = home.outputs
    }

    /// Every saved thread whose settings read, most recently used first, with who holds it.
    public var list: [Entry] {
        store.all.map { settings in
            let holder = store.holder(of: settings.id)
            return Entry(
                id: settings.id, owner: settings.owner, model: settings.model, turns: settings.turns,
                lastUsed: settings.lastUsed, state: holder == nil ? "saved" : "open elsewhere", holder: holder)
        }
    }

    /// Thread `id` in full.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - keepDays: `threads.keepDays`.
    /// - Returns: Its details.
    /// - Throws: `Failure.notFound`, or `ThreadStore.Failure` when its settings cannot be read.
    public func show(_ id: String, keepDays: Int) throws -> Details {
        guard let settings = try store.settings(id) else { throw Failure.notFound(id) }
        let sweepsAfter = keepDays > 0 ? settings.lastUsed.addingTimeInterval(Double(keepDays) * 86_400) : nil
        return Details(
            settings: settings, holder: store.holder(of: id), bytes: Self.size(of: store.directory(of: id)),
            outputBytes: settings.sessions.reduce(0) { $0 + outputSize($1) }, sweepsAfter: sweepsAfter)
    }

    /// Thread `id`'s plan as last saved, after its last turn ([ADR 0081](../../../../docs/decisions/0081-the-plan-tool.md)):
    /// read from its record without opening a model, so an open thread's shows its last turn.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The plan; empty when the thread kept none.
    /// - Throws: `Failure.notFound`, or `ThreadStore.Failure` when its record cannot be read.
    public func plan(_ id: String) throws -> Plan {
        guard let record = try store.record(id) else { throw Failure.notFound(id) }
        return record.plan
    }

    /// Deletes thread `id` under its lock: its directory, and the stored outputs of each audit session it had that no
    /// other thread names (a chat's `/new` carries its session into the next thread). A thread whose settings cannot
    /// be read is deleted too, with no outputs, which is how the person clears one this build cannot resume.
    ///
    /// - Parameter id: The thread.
    /// - Returns: What was deleted.
    /// - Throws: `Failure.notFound`, `ThreadStore.Failure.invalidID` or `held`, or the file system's error.
    public func delete(_ id: String) throws -> Deleted {
        guard ThreadStore.isValid(id) else { throw ThreadStore.Failure.invalidID(id) }
        guard FileManager.default.fileExists(atPath: store.directory(of: id).path) else { throw Failure.notFound(id) }
        let lock = try store.lock(id, owner: "wisp threads")
        defer { lock.release() }
        let settings = try? store.settings(id)
        let sessions = settings?.sessions ?? []
        let named = Set(store.ids.filter { $0 != id }.flatMap { (try? store.settings($0))?.sessions ?? [] })
        var removed: [String] = []
        var bytes = 0
        for session in sessions where SafeName.isValid(session) && !named.contains(session) {
            let directory = outputs.appending(path: session, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let size = Self.size(of: directory)
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Diagnostics.tools.error("wisp threads could not remove \(directory.path): \(error)")
                continue
            }
            removed.append(session)
            bytes += size
        }
        try store.delete(id)
        return Deleted(
            id: id, owner: settings?.owner, turns: settings?.turns ?? 0, sessions: sessions, outputSessions: removed,
            outputBytes: bytes)
    }

    /// Gives thread `id` to `owner` under its lock, so that client's agent may resume it; its record and settings stay
    /// as they are. Nil when it is `owner`'s already.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - owner: The new owner: an MCP client's name, or `chat`.
    /// - Returns: The change, or nil when there was none.
    /// - Throws: `Failure.invalidOwner` or `notFound`, `ThreadStore.Failure` (invalid id, unreadable, `held`), or the
    ///   file system's error.
    public func hand(_ id: String, to owner: String) throws -> Handed? {
        guard Self.isValidOwner(owner) else { throw Failure.invalidOwner(owner) }
        guard try store.settings(id) != nil else { throw Failure.notFound(id) }
        let lock = try store.lock(id, owner: "wisp threads")
        defer { lock.release() }
        guard var settings = try store.settings(id) else { throw Failure.notFound(id) }
        guard settings.owner != owner else { return nil }
        let from = settings.owner
        settings.owner = owner
        try store.save(settings, record: nil)
        return Handed(id: id, from: from, to: owner)
    }

    /// Thread `details` as `wisp threads show` prints it: one line a field, the instructions in full beneath.
    ///
    /// - Parameters:
    ///   - details: The thread.
    ///   - keepDays: `threads.keepDays`, named beside when it is swept.
    /// - Returns: The lines.
    public static func lines(_ details: Details, keepDays: Int) -> [String] {
        let settings = details.settings
        let state =
            details.holder.map { holder in
                "open elsewhere"
                    + (holder.pid > 0 ? " (pid \(holder.pid)\(holder.owner.map { ", \($0)" } ?? ""))" : "")
            } ?? settings.state.rawValue
        let swept =
            details.sweepsAfter.map {
                "after \(ChatThread.shortTime($0)) unless used again (threads.keepDays \(keepDays))"
            } ?? "never (threads.keepDays 0)"
        var rows: [(String, String)] = [
            ("owner", settings.owner), ("model", settings.model),
            ("tools", settings.tools.isEmpty ? "none" : settings.tools.joined(separator: ", ")),
        ]
        if let think = settings.think { rows.append(("think", think)) }
        if let limit = settings.commandTimeoutSeconds { rows.append(("command limit", "\(limit) s")) }
        rows += [
            ("turns", String(settings.turns)), ("created", ChatThread.shortTime(settings.created)),
            ("last used", ChatThread.shortTime(settings.lastUsed)), ("state", state),
            ("sessions", settings.sessions.joined(separator: ", ")),
        ]
        if !settings.droppedFacts.isEmpty {
            rows.append(("dropped facts", settings.droppedFacts.map(\.fact.name).joined(separator: ", ")))
        }
        rows += [
            ("on disk", bytes(details.bytes) + ", stored outputs " + bytes(details.outputBytes)),
            ("swept", swept),
        ]
        let width = rows.map(\.0.count).max() ?? 0
        var lines = ["thread \(settings.id)"]
        lines += rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
        if let instructions = settings.instructions {
            lines.append("  instructions:")
            lines += instructions.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
        }
        return lines
    }

    /// Bytes for people, such as `2.3 MB`, or `none`.
    public static func bytes(_ count: Int) -> String {
        count == 0 ? "none" : ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// Whether `owner` can own a thread: 1 to 64 characters, none a control character or a space at either end.
    ///
    /// - Parameter owner: The name.
    /// - Returns: Whether `hand` takes it.
    static func isValidOwner(_ owner: String) -> Bool {
        !owner.isEmpty && owner.count <= ownerLimit && owner.trimmingCharacters(in: .whitespaces) == owner
            && !owner.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Bytes the stored outputs of audit session `session` take.
    private func outputSize(_ session: String) -> Int {
        guard SafeName.isValid(session) else { return 0 }
        return Self.size(of: outputs.appending(path: session, directoryHint: .isDirectory))
    }

    /// Bytes the regular files under `directory` take, at any depth; 0 when it is not there.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The bytes.
    static func size(of directory: URL) -> Int {
        guard
            let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
