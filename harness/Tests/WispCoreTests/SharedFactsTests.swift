import Foundation
import Synchronization
import Testing

@testable import WispCore

/// The shared store of permanent facts as several processes and threads use it: every change is applied to the
/// file as it now is, under a lock, so no change is lost or undone, and a file that cannot be read is set aside
/// rather than overwritten.
@Suite struct SharedFactsTests {
    /// A fresh directory for a store.
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-shared-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An assertion the person makes about entity `name`.
    private func stated(_ name: String, _ value: String = "v") -> FactBook.Assertion {
        FactBook.Assertion(
            identity: FactIdentity(scope: .permanent, subject: "entity", name: name), source: .person, value: value,
            temporalClass: .permanent, method: .stated, turn: 1)
    }

    /// What the file holds now, read by a book of its own.
    private func onDisk(_ url: URL) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: SharedFacts(scope: .permanent, url: url).current.map { ($0.identity.name, $0.value) })
    }

    @Test func twoBooksOnOneFileKeepEachOthersChangesAndNeverUndoADeletion() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "facts.json")
        // Two processes, each opened before the other wrote anything.
        let first = SharedFacts(scope: .permanent, url: url)
        let second = SharedFacts(scope: .permanent, url: url)
        let codename = try first.record(stated("codename", "BLUE HERON")).fact
        try second.record(stated("ticket", "HARB-212"))
        #expect(onDisk(url) == ["codename": "BLUE HERON", "ticket": "HARB-212"])
        // Ids stay unique across them: the second numbered its fact after the first's.
        #expect(Set(SharedFacts(scope: .permanent, url: url).facts.map(\.id)).count == 2)
        // The first reads the second's fact once the file has changed.
        #expect(first.current.map(\.identity.name).sorted() == ["codename", "ticket"])
        // A deletion in one is not undone by a later change in the other, whose memory still held the fact.
        #expect(try first.delete(codename.id) != nil)
        try second.record(stated("office", "Leeds"))
        #expect(onDisk(url) == ["ticket": "HARB-212", "office": "Leeds"])
        #expect(!second.current.contains { $0.identity.name == "codename" })
    }

    @Test func concurrentChangesFromTwoBooksAreAllKept() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "facts.json")
        let books = [SharedFacts(scope: .permanent, url: url), SharedFacts(scope: .permanent, url: url)]
        let failures = Atomic(0)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try books[index % 2].record(stated("n\(index)", "\(index)"))
            } catch {
                failures.add(1, ordering: .relaxed)
            }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
        let saved = SharedFacts(scope: .permanent, url: url)
        #expect(saved.current.count == 40)
        #expect(Set(saved.facts.map(\.id)).count == 40)
        #expect(Set(books[0].current.map(\.identity.name)) == Set(saved.current.map(\.identity.name)))
    }

    @Test func oneBooksChangesAreWrittenInTheOrderTheyWereMade() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "facts.json")
        let book = SharedFacts(scope: .permanent, url: url)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            _ = try? book.record(stated("n\(index)"))
        }
        // Whatever order the threads ran in, the file holds every change: no save of an older snapshot won.
        #expect(onDisk(url).count == 20)
        #expect(book.current.count == 20)
    }

    @Test func anUnreadableStoreIsSetAsideNotOverwritten() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "facts.json")
        try Data("{nope".utf8).write(to: url)
        let book = SharedFacts(scope: .permanent, url: url)
        let aside = try #require(book.setAside)
        #expect(aside.lastPathComponent.hasPrefix("facts.json\(SharedFacts.unreadableSuffix)"))
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{nope")
        #expect(book.current.isEmpty && !FileManager.default.fileExists(atPath: url.path))
        // A change writes a new store; the one set aside is left as it was.
        try book.record(stated("codename", "BLUE HERON"))
        #expect(onDisk(url) == ["codename": "BLUE HERON"])
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{nope")
        // Another scope's book in the file is unreadable to this one, and set aside too.
        try JSONEncoder().encode(FactBook(scope: .session)).write(to: url)
        let other = SharedFacts(scope: .permanent, url: url)
        #expect(other.setAside != nil && other.setAside != aside)
    }

    @Test func aStoreCorruptedWhileOpenIsSetAsideByTheNextChange() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "facts.json")
        let book = SharedFacts(scope: .permanent, url: url)
        try book.record(stated("codename", "BLUE HERON"))
        try Data("garbage".utf8).write(to: url)
        // A read keeps what it held; the next change moves the bad file aside and writes what this book knows.
        #expect(book.current.map(\.value) == ["BLUE HERON"])
        try book.record(stated("ticket", "HARB-212"))
        let aside = try #require(book.setAside)
        #expect(try String(contentsOf: aside, encoding: .utf8) == "garbage")
        #expect(onDisk(url) == ["codename": "BLUE HERON", "ticket": "HARB-212"])
    }

    @Test func theSessionNotesAStoreItSetAside() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try Data("{nope".utf8).write(to: home.factsFile)
        let session = try Session.begin(Session.Request(entryPoint: .respond), home: home, dependencies: .testing())
        defer { session.end() }
        #expect(session.notes.contains { $0.contains("could not be read") && $0.contains(".unreadable-") })
        #expect(session.permanentFacts.current.isEmpty)
    }
}
