import Foundation
import Synchronization

/// A fact book shared beyond one conversation, behind a lock (decision D2 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): the session's
/// ephemeral facts, shared by every conversation of one `wisp` process and gone when it ends, or the shared
/// store of permanent facts under `~/.wisp`, read at start and written, user-only, on every change.
///
/// Every operation is one short critical section, so this is a `final class` with a `Mutex` rather than an
/// actor (`docs/design.md`, "Concurrency"). The store under `~/.wisp` is shared with every other `wisp` process,
/// so a change is made to the file as it is now, not to what this process read earlier: under the mutex and an
/// advisory `flock` on a lock file beside it, the change re-reads the file, applies itself to what it holds, and
/// writes the result before either lock is let go. A fact another process admitted is kept and one it deleted
/// stays deleted, and two changes in one process are written in the order they were made. A reader takes the file
/// again when it has changed since it was last read. A file that cannot be decoded is never overwritten: it is
/// moved aside as `facts.json.unreadable-<time>` (`setAside`) and the book starts empty.
public final class SharedFacts: Sendable {
    /// Why a change could not be kept.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Writing the shared store failed.
        case unwritable(path: String, reason: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unwritable(let path, let reason): "could not write \(path): \(reason)"
            }
        }
    }

    /// What the lock guards: the book as last read or written, and the file's state when it was.
    private struct State {
        /// The book.
        var book: FactBook
        /// The file's modification time and size when it was last read or written; nil when it did not exist.
        var stamp: Stamp?
        /// Where an unreadable file was moved, the latest time it happened.
        var setAside: URL?
    }

    /// A file's modification time and size, which say whether it changed since it was read.
    private struct Stamp: Equatable {
        /// When it was last modified.
        var modified: Date
        /// Its size, in bytes.
        var size: Int
    }

    /// What reading the file found.
    private enum Read {
        /// No file.
        case absent
        /// A book for this scope.
        case book(FactBook)
        /// A file that cannot be read or decoded, or holds another scope's facts.
        case unreadable
    }

    /// The scope whose facts it holds.
    public let scope: FactScope
    /// Where the book is saved; nil keeps it in memory only.
    public let url: URL?
    /// The book and the file's state.
    private let state: Mutex<State>
    /// How many superseded and deleted versions the book keeps.
    static let historyLimit = 500
    /// The suffix, before the time, of the name an unreadable store is moved to.
    public static let unreadableSuffix = ".unreadable-"

    /// Creates a book for `scope`, read from `url` when it exists. A file that cannot be read or decoded is moved
    /// aside (`setAside`) and logged, and the book starts empty.
    ///
    /// - Parameters:
    ///   - scope: The scope.
    ///   - url: Where to read and save it; nil for memory only.
    public init(scope: FactScope, url: URL? = nil) {
        self.scope = scope
        self.url = url
        var initial = State(book: FactBook(scope: scope), stamp: nil)
        if let url {
            Self.withFileLock(url) {
                switch Self.read(url, scope: scope) {
                case .absent: break
                case .book(let book): initial.book = book
                case .unreadable: initial.setAside = Self.setAside(url)
                }
                initial.stamp = Self.stamp(url)
            }
        }
        state = Mutex(initial)
    }

    /// The session's facts: ephemeral, in memory.
    public static func session() -> SharedFacts { SharedFacts(scope: .session) }

    /// The shared store of permanent facts under `home`.
    public static func permanent(home: Home) -> SharedFacts { SharedFacts(scope: .permanent, url: home.factsFile) }

    /// Where a store that could not be decoded was moved when this book read it, for the person to look at; nil
    /// when every read succeeded.
    public var setAside: URL? { state.withLock { $0.setAside } }

    /// Every fact, current or not.
    public var facts: [Fact] { refreshed().facts }

    /// The facts in force.
    public var current: [Fact] { refreshed().current }

    /// Records an assertion, saving the book when it changed.
    ///
    /// - Parameter assertion: What to record.
    /// - Returns: What changed.
    /// - Throws: `Failure.unwritable` when the book could not be saved; the change stays in memory.
    @discardableResult
    public func record(_ assertion: FactBook.Assertion) throws -> FactBook.Change {
        try change { book in
            let change = book.record(assertion)
            return (change, change.changed)
        }
    }

    /// Admits a fact from another book, as an approval does, and saves.
    ///
    /// - Parameter fact: The fact.
    /// - Returns: The fact as this book holds it.
    /// - Throws: `Failure.unwritable`.
    public func admit(_ fact: Fact) throws -> Fact {
        try change { book in (book.admit(fact), true) }
    }

    /// Deletes the current fact `id` and saves.
    ///
    /// - Parameter id: The fact.
    /// - Returns: The deleted fact, or nil when there is no current fact with that id.
    /// - Throws: `Failure.unwritable`.
    public func delete(_ id: String) throws -> Fact? {
        try change { book in
            let deleted = book.delete(id)
            return (deleted, deleted != nil)
        }
    }

    /// Marks the current fact `id` superseded by `other`, a fact in another book, and saves: the fact moved
    /// there (`Agent.setFactScope`).
    ///
    /// - Parameters:
    ///   - id: The fact.
    ///   - other: The id of the fact that replaces it.
    /// - Throws: `Failure.unwritable`.
    func supersede(_ id: String, by other: String) throws {
        try change { book in
            book.supersede(id, by: other)
            return ((), true)
        }
    }

    /// The book as the file now holds it, read again when the file changed since this book last read or wrote
    /// it; what this process holds when there is no file to read, or it cannot be decoded (a change sets it aside).
    private func refreshed() -> FactBook {
        state.withLock { state in
            guard let url else { return state.book }
            let stamp = Self.stamp(url)
            guard stamp != state.stamp else { return state.book }
            switch Self.read(url, scope: scope) {
            case .absent: state.book = FactBook(scope: scope)
            case .book(let book): state.book = book
            case .unreadable: return state.book
            }
            state.stamp = stamp
            return state.book
        }
    }

    /// Applies `body` to the book and saves it when `body` says it changed, all under the mutex and, for a book
    /// with a file, the file's lock, applied to the file as it is now: the latest book another process wrote, an
    /// empty one when there is no file, or this process's own after an unreadable file is moved aside.
    ///
    /// - Parameter body: The change; returns its result and whether the book changed.
    /// - Returns: `body`'s result.
    /// - Throws: `Failure.unwritable` when the book could not be saved; the change stays in memory.
    private func change<T>(_ body: (inout FactBook) -> (T, Bool)) throws -> T {
        var result: T?
        try state.withLock { state throws(Failure) in
            guard let url else {
                result = body(&state.book).0
                state.book.trimHistory(to: Self.historyLimit)
                return
            }
            try Self.withFileLock(url) { () throws(Failure) in
                switch Self.read(url, scope: scope) {
                case .absent: state.book = FactBook(scope: scope)
                case .book(let book): state.book = book
                case .unreadable: state.setAside = Self.setAside(url)
                }
                let (value, changed) = body(&state.book)
                result = value
                state.book.trimHistory(to: Self.historyLimit)
                if changed { try Self.write(state.book, to: url) }
                state.stamp = Self.stamp(url)
            }
        }
        // Both paths above run the change; the guard only satisfies the type.
        guard let result else {
            throw Failure.unwritable(path: url?.path ?? "memory", reason: "the change did not run")
        }
        return result
    }

    /// What `url` holds for `scope`.
    private static func read(_ url: URL, scope: FactScope) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let book = try? decoder.decode(FactBook.self, from: data),
            book.scope == scope
        else { return .unreadable }
        return .book(book)
    }

    /// The file's modification time and size; nil when it does not exist.
    private static func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int
        else { return nil }
        return Stamp(modified: modified, size: size)
    }

    /// Moves the unreadable store at `url` aside, to `<name>.unreadable-<time>` beside it, so no change overwrites
    /// it, and logs where; nil when it could not be moved, which is logged too.
    ///
    /// - Parameter url: The store.
    /// - Returns: Where it went.
    private static func setAside(_ url: URL) -> URL? {
        let time = Date().formatted(
            Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().time(includingFractionalSeconds: false)
                .dateTimeSeparator(.standard).timeSeparator(.omitted))
        var target = url.deletingLastPathComponent().appending(path: url.lastPathComponent + unreadableSuffix + time)
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            attempt += 1
            target = url.deletingLastPathComponent().appending(
                path: url.lastPathComponent + unreadableSuffix + time + "-\(attempt)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            Diagnostics.agent.error("the facts at \(url.path) cannot be read; moved to \(target.path), starting empty")
            return target
        } catch {
            Diagnostics.agent.error("the facts at \(url.path) cannot be read, nor moved aside: \(error)")
            return nil
        }
    }

    /// Writes `book` to `url`, user-only, replacing the file whole.
    ///
    /// - Throws: `Failure.unwritable`.
    private static func write(_ book: FactBook, to url: URL) throws(Failure) {
        do {
            if FileManager.default.fileExists(atPath: url.path), case .unreadable = read(url, scope: book.scope) {
                // Still unreadable after being set aside (it could not be moved): never overwrite it.
                throw CocoaError(.fileWriteFileExists)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(book).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .unwritable(path: url.path, reason: "\(error)")
        }
    }

    /// Runs `body` holding an exclusive advisory lock on `<url>.lock`, so no other process changes the store
    /// between this process's read and its write. The lock file is created, user-only, with the directory; when
    /// either cannot be made, `body` runs unlocked and its write reports the failure.
    ///
    /// - Parameters:
    ///   - url: The store.
    ///   - body: What to run.
    /// - Returns: `body`'s result.
    /// - Throws: What `body` throws.
    private static func withFileLock<T, E: Error>(_ url: URL, _ body: () throws(E) -> T) throws(E) -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return try body() }
        defer { _ = close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return try body() }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
