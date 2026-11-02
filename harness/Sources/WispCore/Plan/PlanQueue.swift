import Foundation

/// Changes the person made from a terminal to the plan of a thread another process holds, waiting for that process to
/// apply them as the thread's next turn begins
/// ([ADR 0079](../../../../docs/decisions/0079-the-conversation-as-a-spine-with-task-trees.md), decision 23). A terminal
/// cannot write a held thread's record under its lock, and an MCP server holds its threads while it runs, so
/// `wisp threads plan ID …` files the change here instead, as an out-of-band answer is filed in `~/.wisp/pending`.
///
/// One directory a thread, `pending/plan/<thread>/`, mode 0700 and this user's, as the approvals channel's is, since
/// whoever writes here makes the person's change; one file a change, mode 0600, named so that a listing is in the order
/// they were filed. Taking a thread's changes removes their files, so each is applied once.
public struct PlanQueue: Sendable {
    /// One change waiting.
    public struct Item: Codable, Equatable, Sendable {
        /// Its id, from its file's name.
        public var id: String
        /// The change.
        public var edit: PlanEdit
        /// When it was filed.
        public var filed: Date
    }

    /// Why a change could not be filed.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The thread's id cannot be a directory's name.
        case invalidThread(String)
        /// The directory is unsafe, or a file could not be written.
        case io(String)

        /// The failure as the person reads it.
        public var description: String {
            switch self {
            case .invalidThread(let id): "\(id) is not a thread's id"
            case .io(let reason): reason
            }
        }
    }

    /// `pending/plan`, under which each thread has its directory.
    public let root: URL

    /// The queue under `home`'s pending directory.
    ///
    /// - Parameter home: wisp's home.
    public init(home: Home) {
        root = home.pending.appending(path: "plan", directoryHint: .isDirectory)
    }

    /// The queue of the home `store` is in, for a face that has the thread store and not the home: `pending/plan`
    /// beside its `threads/`.
    ///
    /// - Parameter store: The thread store.
    public init(beside store: ThreadStore) {
        root = store.root.deletingLastPathComponent().appending(path: "pending/plan", directoryHint: .isDirectory)
    }

    /// Thread `id`'s directory.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The directory.
    func directory(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// Files a change for thread `thread`, whose holder applies it at the thread's next turn.
    ///
    /// - Parameters:
    ///   - edit: The change.
    ///   - thread: The thread.
    ///   - now: The time.
    /// - Returns: The change as filed.
    /// - Throws: `Failure`.
    public func file(_ edit: PlanEdit, thread: String, now: Date = Date()) throws(Failure) -> Item {
        guard ThreadStore.isValid(thread) else { throw .invalidThread(thread) }
        let directory = directory(thread)
        for path in [root.deletingLastPathComponent().path, root.path, directory.path] {
            if mkdir(path, 0o700) != 0, errno != EEXIST {
                throw .io("could not create \(path): \(String(cString: strerror(errno)))")
            }
        }
        for path in [root.path, directory.path] {
            if let problem = PendingApprovals.problem(with: path) { throw .io(problem) }
        }
        // Milliseconds first, so a listing sorts in the order filed; a UUID after, so two filed at once differ.
        let id = String(format: "%013.0f", (now.timeIntervalSince1970 * 1000).rounded()) + "-" + UUID().uuidString
        let item = Item(id: id, edit: edit, filed: now)
        let data: Data
        do {
            data = try Self.encoder().encode(item)
        } catch {
            throw .io("could not encode the change: \(error)")
        }
        let temporary = directory.appending(path: ".\(UUID().uuidString).tmp")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw .io("could not write \(temporary.path)") }
        defer { unlink(temporary.path) }
        let final = directory.appending(path: "\(id).json")
        guard rename(temporary.path, final.path) == 0 else {
            throw .io("could not write \(final.path): \(String(cString: strerror(errno)))")
        }
        return item
    }

    /// Takes thread `thread`'s changes, in the order filed, removing their files. A file that cannot be read is
    /// removed and left out, with a diagnostic; a directory that is not safe is left alone and gives none, since
    /// another user may have written it.
    ///
    /// - Parameter thread: The thread.
    /// - Returns: The changes.
    public func take(thread: String) -> [Item] {
        guard ThreadStore.isValid(thread) else { return [] }
        let directory = directory(thread)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        if let problem = PendingApprovals.problem(with: directory.path) {
            Diagnostics.agent.error("queued plan changes left alone: \(problem)")
            return []
        }
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        return names.compactMap { name in
            let url = directory.appending(path: name)
            defer { unlink(url.path) }
            guard let data = FileManager.default.contents(atPath: url.path),
                let item = try? Self.decoder().decode(Item.self, from: data)
            else {
                Diagnostics.agent.error("a queued plan change could not be read and was removed: \(name)")
                return nil
            }
            return item
        }
    }

    /// A new encoder for the queue's files, made per use since `JSONEncoder` is not `Sendable`.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A new decoder for the queue's files.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
