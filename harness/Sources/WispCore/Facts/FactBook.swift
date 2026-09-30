import Foundation

/// The versioned facts of one scope (decision D2 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): every assertion ever
/// recorded, in order, each marked current, superseded, or deleted. A newer assertion about the same identity
/// from the same source supersedes the older one, which stays as history; assertions from different sources
/// stand side by side, and `FactView` orders them by precedence and shows where they disagree.
///
/// A value type: the conversation's book lives in its `ConversationStore` and is saved with it; the session's
/// and the shared store's are held behind a lock (`SessionFacts`, `PermanentFacts`).
public struct FactBook: Codable, Sendable, Equatable {
    /// One assertion to record: an identity, its source, and what it says.
    public struct Assertion: Sendable, Equatable {
        /// What it is about.
        public var identity: FactIdentity
        /// Who asserts it.
        public var source: FactSource
        /// The value, one short line.
        public var value: String
        /// The class the subject kind declares.
        public var temporalClass: TemporalClass
        /// How it was made.
        public var method: FactMethod
        /// The tool, or who spoke; nil for none.
        public var detail: String?
        /// The store entries it came from.
        public var entries: [Int]
        /// The audit events that recorded what it came from.
        public var audit: [AuditReference]
        /// When it was made.
        public var time: Date
        /// The turn, when there is one.
        public var turn: Int?

        /// Creates an assertion.
        public init(
            identity: FactIdentity, source: FactSource, value: String, temporalClass: TemporalClass,
            method: FactMethod, detail: String? = nil, entries: [Int] = [], audit: [AuditReference] = [],
            time: Date = Date(), turn: Int? = nil
        ) {
            self.identity = identity
            self.source = source
            self.value = value
            self.temporalClass = temporalClass
            self.method = method
            self.detail = detail
            self.entries = entries
            self.audit = audit
            self.time = time
            self.turn = turn
        }
    }

    /// What recording an assertion did.
    public enum Change: Sendable, Equatable {
        /// A new identity, or a new source for one: the fact is its first version.
        case recorded(Fact)
        /// A new version replaced the source's previous one.
        case superseded(old: Fact, by: Fact)
        /// The source's current version already says this; nothing was added.
        case unchanged(Fact)

        /// The fact now current for the assertion's identity and source.
        public var fact: Fact {
            switch self {
            case .recorded(let fact), .unchanged(let fact), .superseded(_, let fact): fact
            }
        }
    }

    /// The scope whose facts this book holds; every id starts with its prefix.
    public let scope: FactScope
    /// Every fact, in the order recorded.
    public private(set) var facts: [Fact] = []
    /// The number the next fact's id takes.
    private var next = 1

    /// An empty book for `scope`.
    public init(scope: FactScope) {
        self.scope = scope
    }

    /// The facts in force, in the order recorded.
    public var current: [Fact] { facts.filter { $0.state == .current } }

    /// The fact with `id`, or nil.
    public func fact(_ id: String) -> Fact? { facts.first { $0.id == id } }

    /// Every version of the identity `key`, from every source, oldest first.
    public func history(of key: FactIdentity.Key) -> [Fact] { facts.filter { $0.identity.key == key } }

    /// Records `assertion`: a first fact for its identity and source, a new version superseding the source's
    /// current one, or nothing when the current one already has the same value. The assertion's scope is
    /// taken as given; it should be this book's.
    ///
    /// - Parameter assertion: What to record.
    /// - Returns: What changed.
    @discardableResult
    public mutating func record(_ assertion: Assertion) -> Change {
        let head = facts.lastIndex {
            $0.identity == assertion.identity && $0.source == assertion.source && $0.state == .current
        }
        if let head, facts[head].value == assertion.value { return .unchanged(facts[head]) }
        let version =
            (facts.filter { $0.identity == assertion.identity && $0.source == assertion.source }.map(\.version).max()
                ?? 0) + 1
        let fact = Fact(
            id: "\(scope.prefix)\(next)", identity: assertion.identity, source: assertion.source, version: version,
            value: assertion.value, temporalClass: assertion.temporalClass, method: assertion.method,
            detail: assertion.detail, entries: assertion.entries, audit: assertion.audit, recorded: assertion.time,
            turn: assertion.turn, supersededBy: nil, state: .current, approved: nil)
        next += 1
        facts.append(fact)
        guard let head else { return .recorded(fact) }
        facts[head].state = .superseded
        facts[head].supersededBy = fact.id
        return .superseded(old: facts[head], by: fact)
    }

    /// Adds `fact` as it is, under a new id of this book, superseding any current fact of the same identity
    /// and source: how an approved proposal enters the shared store.
    ///
    /// - Parameter fact: The fact, from another book.
    /// - Returns: The fact as this book holds it.
    mutating func admit(_ fact: Fact) -> Fact {
        var admitted = fact
        admitted.id = "\(scope.prefix)\(next)"
        admitted.identity.scope = scope
        admitted.state = .current
        admitted.supersededBy = nil
        next += 1
        if let head = facts.lastIndex(where: {
            $0.identity == admitted.identity && $0.source == admitted.source && $0.state == .current
        }) {
            facts[head].state = .superseded
            facts[head].supersededBy = admitted.id
            admitted.version = facts[head].version + 1
        }
        facts.append(admitted)
        return admitted
    }

    /// Marks the fact `id` deleted, if it is current; the person's action (D3).
    ///
    /// - Parameter id: The fact.
    /// - Returns: The fact as deleted, or nil when there is no current fact with that id.
    public mutating func delete(_ id: String) -> Fact? {
        guard let index = facts.firstIndex(where: { $0.id == id }), facts[index].state == .current else { return nil }
        facts[index].state = .deleted
        return facts[index]
    }

    /// Marks the current fact `id` superseded by `other`, a fact in another book: an approval.
    ///
    /// - Parameters:
    ///   - id: The fact.
    ///   - other: The id of the fact that replaces it.
    mutating func supersede(_ id: String, by other: String) {
        guard let index = facts.firstIndex(where: { $0.id == id }), facts[index].state == .current else { return }
        facts[index].state = .superseded
        facts[index].supersededBy = other
    }

    /// Changes the temporal class of the current fact `id` in place, which is how a proposed permanent fact
    /// becomes one of the conversation's own (`Agent.setFactScope`).
    ///
    /// - Parameters:
    ///   - id: The fact.
    ///   - temporalClass: The class it takes.
    /// - Returns: The fact as changed, or nil when there is no current fact with that id.
    mutating func retarget(_ id: String, to temporalClass: TemporalClass) -> Fact? {
        guard let index = facts.firstIndex(where: { $0.id == id }), facts[index].state == .current else { return nil }
        facts[index].temporalClass = temporalClass
        return facts[index]
    }

    /// Keeps at most `limit` superseded and deleted versions, dropping the oldest first; current facts are
    /// always kept. Bounds a long session's book.
    ///
    /// - Parameter limit: How many historical versions to keep.
    mutating func trimHistory(to limit: Int) {
        let historical = facts.indices.filter { facts[$0].state != .current }
        guard historical.count > limit else { return }
        let drop = Set(historical.prefix(historical.count - limit))
        facts = facts.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
