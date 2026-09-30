import Foundation
import Synchronization

/// A fact book shared beyond one conversation, behind a lock (decision D2 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): the session's
/// ephemeral facts, shared by every conversation of one `wisp` process and gone when it ends, or the shared
/// store of permanent facts under `~/.wisp`, read at start and written, user-only, on every change.
///
/// Every operation is one short critical section, so this is a `final class` with a `Mutex` rather than an
/// actor (`docs/design.md`, "Concurrency").
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

    /// The scope whose facts it holds.
    public let scope: FactScope
    /// Where the book is saved; nil keeps it in memory only.
    public let url: URL?
    /// The book.
    private let book: Mutex<FactBook>
    /// How many superseded and deleted versions the book keeps.
    static let historyLimit = 500

    /// Creates a book for `scope`, read from `url` when it exists. A file that cannot be read or decoded
    /// starts an empty book, and is logged; it is only replaced when a change is saved.
    ///
    /// - Parameters:
    ///   - scope: The scope.
    ///   - url: Where to read and save it; nil for memory only.
    public init(scope: FactScope, url: URL? = nil) {
        self.scope = scope
        self.url = url
        var loaded = FactBook(scope: scope)
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(FactBook.self, from: data), decoded.scope == scope {
                loaded = decoded
            } else {
                Diagnostics.agent.error("the facts at \(url.path) cannot be read; starting empty")
            }
        }
        book = Mutex(loaded)
    }

    /// The session's facts: ephemeral, in memory.
    public static func session() -> SharedFacts { SharedFacts(scope: .session) }

    /// The shared store of permanent facts under `home`.
    public static func permanent(home: Home) -> SharedFacts { SharedFacts(scope: .permanent, url: home.factsFile) }

    /// Every fact, current or not.
    public var facts: [Fact] { book.withLock { $0.facts } }

    /// The facts in force.
    public var current: [Fact] { book.withLock { $0.current } }

    /// Records an assertion, saving the book when it changed.
    ///
    /// - Parameter assertion: What to record.
    /// - Returns: What changed.
    /// - Throws: `Failure.unwritable` when the book could not be saved; the change stays in memory.
    @discardableResult
    public func record(_ assertion: FactBook.Assertion) throws -> FactBook.Change {
        let (change, snapshot) = book.withLock { book -> (FactBook.Change, FactBook) in
            let change = book.record(assertion)
            book.trimHistory(to: Self.historyLimit)
            return (change, book)
        }
        if case .unchanged = change { return change }
        try save(snapshot)
        return change
    }

    /// Admits a fact from another book, as an approval does, and saves.
    ///
    /// - Parameter fact: The fact.
    /// - Returns: The fact as this book holds it.
    /// - Throws: `Failure.unwritable`.
    public func admit(_ fact: Fact) throws -> Fact {
        let (admitted, snapshot) = book.withLock { book in (book.admit(fact), book) }
        try save(snapshot)
        return admitted
    }

    /// Deletes the current fact `id` and saves.
    ///
    /// - Parameter id: The fact.
    /// - Returns: The deleted fact, or nil when there is no current fact with that id.
    /// - Throws: `Failure.unwritable`.
    public func delete(_ id: String) throws -> Fact? {
        let (deleted, snapshot) = book.withLock { book in (book.delete(id), book) }
        if deleted != nil { try save(snapshot) }
        return deleted
    }

    /// Marks the current fact `id` superseded by `other`, a fact in another book, and saves: the fact moved
    /// there (`Agent.setFactScope`).
    ///
    /// - Parameters:
    ///   - id: The fact.
    ///   - other: The id of the fact that replaces it.
    /// - Throws: `Failure.unwritable`.
    func supersede(_ id: String, by other: String) throws {
        let snapshot = book.withLock { book -> FactBook in
            book.supersede(id, by: other)
            return book
        }
        try save(snapshot)
    }

    /// Writes `snapshot` to `url`, user-only, when there is one.
    private func save(_ snapshot: FactBook) throws {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw Failure.unwritable(path: url.path, reason: "\(error)")
        }
    }
}
