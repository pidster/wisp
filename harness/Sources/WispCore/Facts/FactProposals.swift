import Foundation
import Synchronization

/// A permanent fact a tool or the model proposed in one conversation, as the process keeps it until the person
/// moves it (decisions D2 and D3 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): a proposal is a
/// state of a fact, not a question wisp asks; the person changes its scope by command (`Agent.setFactScope`).
public struct FactProposal: Sendable, Equatable {
    /// Where the proposal stands.
    public enum Status: String, Sendable, Equatable {
        /// Not moved: it waits for the person.
        case awaiting
        /// The person moved it to another scope: the store of that scope holds it as `admitted`.
        case moved
        /// Its conversation no longer holds it: a newer version replaced it, it was moved within the
        /// conversation, or the person deleted it.
        case withdrawn
    }

    /// The conversation that holds it: its audit session, which for an MCP thread is the `thread_id`.
    public var threadID: String
    /// The fact as the conversation recorded it.
    public var fact: Fact
    /// Where it stands.
    public var status: Status
    /// Its id in the store it was moved to, once moved.
    public var admitted: String?

    /// The id that names it across the process: `conversation/fact`, such as `git/c3`.
    public var reference: String { "\(threadID)/\(fact.id)" }

    /// Splits a reference into its conversation and fact id, or nil when `text` is not one.
    ///
    /// - Parameter text: Such as `git/c3`.
    /// - Returns: The conversation and the fact id.
    public static func parse(_ text: String) -> (thread: String, fact: String)? {
        guard let slash = text.firstIndex(of: "/") else { return nil }
        let thread = String(text[..<slash])
        let fact = String(text[text.index(after: slash)...])
        guard !thread.isEmpty, !fact.isEmpty, !fact.contains("/") else { return nil }
        return (thread, fact)
    }
}

/// Every proposed permanent fact of one `wisp` process, from every conversation and MCP thread (D2: only the
/// person moves a fact into the shared store). Conversations keep their proposals in their own stores and
/// mirror them here each time their facts change (`Agent.syncProposals`); this is what a face lists
/// (`/inspect facts`, `wisp://facts/proposed`), and where a move from outside the conversation is recorded, so
/// a proposal can be moved after its conversation has gone.
///
/// Every operation is a short critical section, so this is a `final class` with a `Mutex` (`docs/design.md`,
/// "Concurrency").
public final class FactProposals: Sendable {
    /// The registry's contents.
    private struct Contents {
        /// Every proposal, oldest first.
        var entries: [FactProposal] = []
        /// Each conversation's audit log, where changes to its proposals are recorded.
        var audits: [String: AuditLog] = [:]
    }

    /// The contents, behind the lock.
    private let contents = Mutex(Contents())
    /// How many moved and withdrawn proposals are kept; awaiting ones are always kept.
    static let historyLimit = 500

    /// An empty registry.
    public init() {}

    /// Every proposal, oldest first.
    public var all: [FactProposal] { contents.withLock { $0.entries } }

    /// The proposals awaiting the person, oldest first.
    public var awaiting: [FactProposal] { all.filter { $0.status == .awaiting } }

    /// The proposal `reference` (`conversation/fact`), or nil.
    public func proposal(_ reference: String) -> FactProposal? { all.first { $0.reference == reference } }

    /// The audit log of `conversation`, when known.
    func audit(_ thread: String) -> AuditLog? { contents.withLock { $0.audits[thread] } }

    /// Mirrors one conversation's current proposals: adds the new ones, withdraws those it no longer holds,
    /// and returns the ones moved from outside the conversation since, with their ids in the store they went
    /// to, so the conversation can mark its own copies superseded.
    ///
    /// - Parameters:
    ///   - thread: The thread's audit session.
    ///   - audit: Its audit log.
    ///   - current: Its current proposed permanent facts (`Fact.proposed`).
    /// - Returns: Moved proposals' fact ids mapped to the ids the other store gave them.
    @discardableResult
    func sync(thread: String, audit: AuditLog?, current: [Fact]) -> [String: String] {
        contents.withLock { contents in
            if let audit { contents.audits[thread] = audit }
            var moved: [String: String] = [:]
            let held = Set(current.map(\.id))
            for index in contents.entries.indices where contents.entries[index].threadID == thread {
                let entry = contents.entries[index]
                if entry.status == .moved, held.contains(entry.fact.id), let admitted = entry.admitted {
                    moved[entry.fact.id] = admitted
                } else if !held.contains(entry.fact.id), entry.status == .awaiting {
                    contents.entries[index].status = .withdrawn
                }
            }
            for fact in current
            where !contents.entries.contains(where: { $0.threadID == thread && $0.fact.id == fact.id }) {
                contents.entries.append(FactProposal(threadID: thread, fact: fact, status: .awaiting))
            }
            Self.trim(&contents.entries)
            return moved
        }
    }

    /// Records that the awaiting proposal `reference` was moved to another store, where it is `admitted`. Its
    /// conversation marks its own copy superseded the next time it syncs.
    ///
    /// - Parameters:
    ///   - reference: `conversation/fact`.
    ///   - admitted: Its id in the store it was moved to.
    func markMoved(_ reference: String, admitted: String) {
        contents.withLock { contents in
            guard
                let index = contents.entries.firstIndex(where: { $0.reference == reference && $0.status == .awaiting })
            else { return }
            contents.entries[index].status = .moved
            contents.entries[index].admitted = admitted
        }
    }

    /// Drops the oldest moved and withdrawn proposals past `historyLimit`.
    private static func trim(_ entries: inout [FactProposal]) {
        let decided = entries.indices.filter { entries[$0].status != .awaiting }
        guard decided.count > historyLimit else { return }
        let drop = Set(decided.prefix(decided.count - historyLimit))
        entries = entries.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
