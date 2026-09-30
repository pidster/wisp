import Foundation

/// How long a fact stays true, which also sets where it lives
/// ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), decision D2).
public enum TemporalClass: String, Codable, Sendable, CaseIterable {
    /// Names, codenames, settled decisions, the person's preferences: kept across sessions, in the shared
    /// store, once the person admits them.
    case permanent
    /// The state of the work (the tests, the branch, the task): kept by the conversation.
    case dynamic
    /// The state of the machine now (a running service, a port in use): kept by the session, shared by an MCP
    /// server's threads, gone when the process ends.
    case ephemeral

    /// Where a fact of this class is held once admitted: the shared store, the conversation, or the session.
    public var scope: FactScope {
        switch self {
        case .permanent: .permanent
        case .dynamic: .thread
        case .ephemeral: .session
        }
    }
}

/// Which store holds a fact.
public enum FactScope: String, Codable, Sendable, CaseIterable {
    /// The shared store under `~/.wisp`, across sessions (`PermanentFacts`).
    case permanent
    /// The thread's own store (`ThreadRecord.facts`), saved with it.
    case thread
    /// The session, shared by every thread of one `wisp` process (`SessionFacts`).
    case session

    /// The letter a fact id starts with in this scope, so an id names its store: `p3`, `c12`, `s1`.
    public var prefix: String {
        switch self {
        case .permanent: "p"
        case .thread: "c"
        case .session: "s"
        }
    }
}

/// Who asserted a fact. Precedence runs from the person down (D2): the person's word is a pin that a tool and
/// the model cannot outrank.
public enum FactSource: String, Codable, Sendable, CaseIterable {
    /// The person, in chat (`/fact`, `/task`).
    case person
    /// An MCP caller, the person's agent (`respond`'s `task`); ranked with the person, recorded apart.
    case caller
    /// A tool's output, extracted mechanically.
    case tool
    /// The conversation's model, distilled from prose.
    case model

    /// Precedence: higher wins. The person and an MCP caller rank together.
    public var rank: Int {
        switch self {
        case .person, .caller: 3
        case .tool: 2
        case .model: 1
        }
    }
}

/// How an assertion was made.
public enum FactMethod: String, Codable, Sendable {
    /// Stated directly, by the person or a caller.
    case stated
    /// Extracted from a tool's output without a model.
    case extracted
    /// Distilled by the model from turns leaving the active view.
    case distilled
    /// Noted by the model while it worked, with the `memory` tool's `note`; recorded when its turn ends.
    case noted
}

/// What a fact is about: `{scope, subject, name}`, such as `{thread, tests, swift test}` (D2).
public struct FactIdentity: Hashable, Codable, Sendable {
    /// Where it is held.
    public var scope: FactScope
    /// The subject kind (`SubjectKind.name`), such as `tests`.
    public var subject: String
    /// The name under the subject, normalised by the kind, such as `swift test`.
    public var name: String

    /// Creates an identity.
    public init(scope: FactScope, subject: String, name: String) {
        self.scope = scope
        self.subject = subject
        self.name = name
    }

    /// The identity without its scope: a proposed permanent fact held by the conversation and the one the
    /// shared store holds under the same subject and name are about the same thing.
    public var key: Key { Key(subject: subject, name: name) }

    /// `{subject, name}`, the part of an identity compared across scopes.
    public struct Key: Hashable, Codable, Sendable, Comparable {
        /// The subject kind.
        public var subject: String
        /// The normalised name.
        public var name: String

        /// Ordered by subject, then name.
        public static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.subject, lhs.name) < (rhs.subject, rhs.name)
        }
    }
}

/// One versioned assertion about an identity (D2): who said it, which version of theirs it is, its value, and
/// where it came from. The store keeps every version; composing shows only current heads.
public struct Fact: Codable, Sendable, Equatable, Identifiable {
    /// Whether the fact is in force.
    public enum State: String, Codable, Sendable {
        /// The newest version from its source, not deleted.
        case current
        /// Replaced by a newer version from the same source (`supersededBy`), or by its approval into the
        /// shared store.
        case superseded
        /// Deleted by the person; it leaves every later composition, and the store keeps it as history.
        case deleted
    }

    /// Unique within its store, with the scope's prefix: `c12`.
    public var id: String
    /// What it is about.
    public var identity: FactIdentity
    /// Who asserted it.
    public var source: FactSource
    /// The version of this identity from this source, from 1.
    public var version: Int
    /// The value, one short line.
    public var value: String
    /// The class its subject kind declares. A `permanent` fact held by the conversation is a proposal the
    /// person has not approved yet (`proposed`).
    public var temporalClass: TemporalClass
    /// How it was made.
    public var method: FactMethod
    /// Where exactly: the tool for an extracted fact (`run_command`), who spoke for a distilled one
    /// (`the person said`, `the model concluded`); nil when there is nothing to add.
    public var detail: String?
    /// The thread record entries it came from, by id; empty for a stated fact.
    public var entries: [Int]
    /// The audit events that recorded what it came from (D8), so it can be traced without the store.
    public var audit: [AuditReference]
    /// When it was recorded.
    public var recorded: Date
    /// The turn it was recorded during or after, in the recording session's numbering; nil when unknown.
    public var turn: Int?
    /// The fact that replaced it, when superseded.
    public var supersededBy: String?
    /// Whether it is in force.
    public var state: State
    /// When the person approved it into the shared store; nil for a fact not approved.
    public var approved: Date?

    /// Whether this is a permanent fact the conversation holds until the person approves it (D2).
    public var proposed: Bool { temporalClass == .permanent && identity.scope != .permanent }

    /// Precedence against other sources' heads: the source's rank, or the person's for a fact the person
    /// approved.
    public var rank: Int { approved == nil ? source.rank : FactSource.person.rank }
}
