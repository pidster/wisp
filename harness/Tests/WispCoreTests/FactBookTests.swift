import Foundation
import Testing

@testable import WispCore

/// Versioned facts under a composite key (decision D2 of the layered-context proposal): a newer version from
/// the same source supersedes, other sources stand beside it, precedence picks the winner, and a
/// disagreement is a conflict.
@Suite struct FactBookTests {
    /// The CI identity the eval's changed fact uses.
    static let ci = FactIdentity(scope: .thread, subject: "tests", name: "ci")

    /// An assertion about `identity` from `source`.
    static func assertion(
        _ value: String, about identity: FactIdentity = ci, source: FactSource = .tool,
        time: Date = Date(timeIntervalSince1970: 1000), turn: Int? = nil
    ) -> FactBook.Assertion {
        FactBook.Assertion(
            identity: identity, source: source, value: value, temporalClass: .dynamic,
            method: source == .tool ? .extracted : .stated, time: time, turn: turn)
    }

    @Test func aChangedFactSupersedesTheOldVersionWhichStaysAsHistory() throws {
        var book = FactBook(scope: .thread)
        let failing = book.record(Self.assertion("failed (exit status 1)", turn: 2))
        #expect(failing == .recorded(failing.fact) && failing.fact.id == "c1" && failing.fact.version == 1)
        // The same value again adds nothing.
        #expect(book.record(Self.assertion("failed (exit status 1)", turn: 3)) == .unchanged(failing.fact))
        let green = book.record(Self.assertion("passed (exit status 0)", time: Date(timeIntervalSince1970: 2000)))
        guard case .superseded(let old, let new) = green else {
            Issue.record("expected a supersession, got \(green)")
            return
        }
        #expect(old.id == "c1" && old.state == .superseded && old.supersededBy == "c2")
        #expect(new.id == "c2" && new.version == 2 && new.state == .current)
        #expect(book.current.map(\.value) == ["passed (exit status 0)"])
        #expect(book.history(of: Self.ci.key).map(\.value) == ["failed (exit status 1)", "passed (exit status 0)"])
        // The view shows the current value only.
        #expect(FactView(book.facts).groups.map(\.winner.value) == ["passed (exit status 0)"])
    }

    @Test func sourcesStandSideBySideAndThePersonWins() {
        var book = FactBook(scope: .thread)
        book.record(Self.assertion("passed", source: .model, time: Date(timeIntervalSince1970: 3000)))
        book.record(Self.assertion("failed", source: .tool, time: Date(timeIntervalSince1970: 2000)))
        var view = FactView(book.current)
        #expect(book.current.count == 2)
        let group = view.groups[0]
        #expect(group.winner.source == .tool && group.inConflict && group.disagreeing.map(\.source) == [.model])
        #expect(view.conflicts == [Self.ci.key])
        // The person's word is a pin: it outranks the tool, even when older.
        book.record(Self.assertion("failed", source: .person, time: Date(timeIntervalSince1970: 1)))
        view = FactView(book.current)
        #expect(view.groups[0].winner.source == .person && view.groups[0].disagreeing.map(\.source) == [.model])
        // A caller ranks with the person; on a tie the newer wins.
        book.record(Self.assertion("flaky", source: .caller, time: Date(timeIntervalSince1970: 4000)))
        #expect(FactView(book.current).groups[0].winner.source == .caller)
        // Values that differ only in case and spacing agree.
        var agreeing = FactBook(scope: .thread)
        agreeing.record(Self.assertion("Passed  now", source: .tool))
        agreeing.record(Self.assertion("passed now", source: .model))
        #expect(FactView(agreeing.current).conflicts.isEmpty)
    }

    @Test func deletingAndAdmittingAndTrimming() throws {
        var book = FactBook(scope: .thread)
        let first = book.record(Self.assertion("a")).fact
        #expect(book.delete(first.id)?.state == .deleted && book.current.isEmpty)
        #expect(book.delete(first.id) == nil, "only a current fact can be deleted")
        #expect(book.delete("c99") == nil)
        // A new version after a deletion takes the next version number.
        #expect(book.record(Self.assertion("b")).fact.version == 2)
        // Admitting into another book renumbers it and supersedes that book's head of the same source.
        var shared = FactBook(scope: .permanent)
        let entity = FactIdentity(scope: .permanent, subject: "entity", name: "codename")
        shared.record(Self.assertion("RED FOX", about: entity, source: .model))
        var proposal = Self.assertion(
            "BLUE HERON", about: FactIdentity(scope: .thread, subject: "entity", name: "codename"), source: .model
        )
        proposal.temporalClass = .permanent
        let proposed = book.record(proposal).fact
        #expect(proposed.proposed)
        let admitted = shared.admit(proposed)
        #expect(admitted.id == "p2" && admitted.identity.scope == .permanent && admitted.version == 2)
        #expect(shared.current.map(\.value) == ["BLUE HERON"] && !admitted.proposed)
        book.supersede(proposed.id, by: admitted.id)
        #expect(book.fact(proposed.id)?.supersededBy == "p2")
        // History is bounded; current facts are always kept.
        for index in 0..<10 { book.record(Self.assertion("v\(index)")) }
        book.trimHistory(to: 3)
        #expect(book.facts.filter { $0.state != .current }.count == 3 && book.current.map(\.value) == ["v9"])
        // A book round-trips through JSON, its numbering with it.
        let decoded = try JSONDecoder().decode(FactBook.self, from: JSONEncoder().encode(book))
        #expect(decoded == book)
    }

    @Test func anApprovedFactRanksWithThePersonAndProvenanceSaysSo() {
        var book = FactBook(scope: .permanent)
        var fact = book.record(
            Self.assertion("y", about: FactIdentity(scope: .permanent, subject: "entity", name: "x"), source: .model)
        ).fact
        #expect(fact.rank == FactSource.model.rank)
        fact.approved = Date()
        #expect(fact.rank == FactSource.person.rank)
        #expect(FactComposition.provenance(fact) == "model, approved by the person")
    }
}
