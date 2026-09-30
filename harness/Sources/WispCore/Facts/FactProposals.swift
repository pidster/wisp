import Foundation
import Synchronization

/// A permanent fact a tool or the model proposed in one conversation, as the process keeps it until the person
/// decides (decisions D2 and D3 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), and the fact-approval
/// effect of [ADR 0044](../../../../docs/decisions/0044-host-effects.md)).
public struct FactProposal: Sendable, Equatable {
    /// Where the proposal stands.
    public enum Status: String, Sendable, Equatable {
        /// Not decided: it waits for the person, asked or not.
        case awaiting
        /// The person declined it; the conversation keeps it as its own proposal, and wisp does not ask about
        /// the same subject, name, and value again in this process.
        case declined
        /// The person approved it: the shared store holds it as `admitted`.
        case approved
        /// Its conversation no longer holds it: a newer version replaced it, or the person deleted it.
        case withdrawn
    }

    /// The conversation that holds it: its audit session, which for an MCP thread is the `thread_id`.
    public var conversation: String
    /// The fact as the conversation recorded it.
    public var fact: Fact
    /// Where it stands.
    public var status: Status
    /// Whether the person has been asked about it through the host's dialog.
    public var asked: Bool
    /// Its id in the shared store once approved.
    public var admitted: String?

    /// The id that names it across the process: `conversation/fact`, such as `git/c3`.
    public var reference: String { "\(conversation)/\(fact.id)" }

    /// Splits a reference into its conversation and fact id, or nil when `text` is not one.
    ///
    /// - Parameter text: Such as `git/c3`.
    /// - Returns: The conversation and the fact id.
    public static func parse(_ text: String) -> (conversation: String, fact: String)? {
        guard let slash = text.firstIndex(of: "/") else { return nil }
        let conversation = String(text[..<slash])
        let fact = String(text[text.index(after: slash)...])
        guard !conversation.isEmpty, !fact.isEmpty, !fact.contains("/") else { return nil }
        return (conversation, fact)
    }
}

/// Every proposed permanent fact of one `wisp` process, from every conversation and MCP thread, with the
/// person's decisions (D2: only the person admits a fact to the shared store). Conversations keep their
/// proposals in their own stores and mirror them here each time their facts change (`Agent.syncProposals`);
/// this is what a face lists (`/inspect facts`, `wisp://facts/proposed`), what the host's fact-approval
/// dialog asks about, and where an approval from outside the conversation is admitted from, so a proposal can
/// be approved after its conversation has gone.
///
/// A declined proposal is remembered by its subject, name, and value, so the person is not asked about the
/// same thing again, from any conversation, while the process lives.
///
/// Every operation is a short critical section, so this is a `final class` with a `Mutex` (`docs/design.md`,
/// "Concurrency"); `ask` holds no lock across a wait.
public final class FactProposals: Sendable {
    /// What a decline is remembered by: the fact's subject, name, and value as values are compared.
    struct DeclineKey: Hashable {
        /// The subject kind.
        var subject: String
        /// The normalised name.
        var name: String
        /// The value, case-folded with its whitespace collapsed (`FactView.folded`).
        var value: String

        /// The key of `fact`.
        init(_ fact: Fact) {
            subject = fact.identity.subject
            name = fact.identity.name
            value = FactView.folded(fact.value)
        }
    }

    /// The registry's contents.
    private struct Contents {
        /// Every proposal, oldest first.
        var entries: [FactProposal] = []
        /// Each conversation's audit log, where its proposals' decisions are recorded.
        var audits: [String: AuditLog] = [:]
        /// What the person declined.
        var declined: Set<DeclineKey> = []
    }

    /// The contents, behind the lock.
    private let contents = Mutex(Contents())
    /// How many decided and withdrawn proposals are kept; awaiting ones are always kept.
    static let historyLimit = 500

    /// An empty registry.
    public init() {}

    /// Every proposal, oldest first.
    public var all: [FactProposal] { contents.withLock { $0.entries } }

    /// The proposals awaiting the person, oldest first.
    public var awaiting: [FactProposal] { all.filter { $0.status == .awaiting } }

    /// The proposal `reference` (`conversation/fact`), or nil.
    public func proposal(_ reference: String) -> FactProposal? { all.first { $0.reference == reference } }

    /// Mirrors one conversation's current proposals: adds the new ones, withdraws those it no longer holds,
    /// and returns the ones approved from outside the conversation since, with their ids in the shared store,
    /// so the conversation can mark its own copies superseded.
    ///
    /// - Parameters:
    ///   - conversation: The conversation's audit session.
    ///   - audit: Its audit log, where decisions about its proposals are recorded.
    ///   - current: Its current proposed permanent facts (`Fact.proposed`).
    /// - Returns: Approved proposals' fact ids mapped to the ids the shared store gave them.
    @discardableResult
    func sync(conversation: String, audit: AuditLog?, current: [Fact]) -> [String: String] {
        contents.withLock { contents in
            if let audit { contents.audits[conversation] = audit }
            var approved: [String: String] = [:]
            let held = Set(current.map(\.id))
            for index in contents.entries.indices where contents.entries[index].conversation == conversation {
                let entry = contents.entries[index]
                if entry.status == .approved, held.contains(entry.fact.id), let admitted = entry.admitted {
                    approved[entry.fact.id] = admitted
                } else if !held.contains(entry.fact.id), entry.status == .awaiting || entry.status == .declined {
                    contents.entries[index].status = .withdrawn
                }
            }
            for fact in current
            where !contents.entries.contains(where: { $0.conversation == conversation && $0.fact.id == fact.id }) {
                contents.entries.append(
                    FactProposal(conversation: conversation, fact: fact, status: .awaiting, asked: false))
            }
            Self.trim(&contents.entries)
            return approved
        }
    }

    /// Takes the proposals to ask the person about, marking them asked so no other caller asks too: those
    /// awaiting and not yet asked, leaving out any whose subject, name, and value the person declined, and any
    /// the shared store already holds with the same value.
    ///
    /// - Parameter permanent: The shared store.
    /// - Returns: The proposals, oldest first.
    public func claim(permanent: SharedFacts) -> [FactProposal] {
        let kept = Set(permanent.current.map(DeclineKey.init))
        return contents.withLock { contents in
            var claimed: [FactProposal] = []
            for index in contents.entries.indices {
                let entry = contents.entries[index]
                guard entry.status == .awaiting, !entry.asked else { continue }
                let key = DeclineKey(entry.fact)
                guard !contents.declined.contains(key), !kept.contains(key) else { continue }
                contents.entries[index].asked = true
                claimed.append(contents.entries[index])
            }
            return claimed
        }
    }

    /// Admits the proposal `reference` to the shared store as approved by the person, and records it:
    /// `fact.approved` and `fact.superseded` on its conversation's audit log. Its conversation marks its own
    /// copy superseded the next time it syncs. A declined proposal can still be approved, which forgets the
    /// decline.
    ///
    /// - Parameters:
    ///   - reference: `conversation/fact`.
    ///   - permanent: The shared store.
    ///   - via: Where the person approved it: `chat` or `elicitation`.
    /// - Returns: The fact as the shared store holds it.
    /// - Throws: `FactFailure.noSuchFact` when there is no such proposal awaiting or declined;
    ///   `FactFailure.unwritable` when the shared store cannot be saved.
    @discardableResult
    public func approve(_ reference: String, permanent: SharedFacts, via: String) throws(FactFailure) -> Fact {
        let found = contents.withLock { contents -> (FactProposal, AuditLog?)? in
            guard
                let entry = contents.entries.first(where: {
                    $0.reference == reference && ($0.status == .awaiting || $0.status == .declined)
                })
            else { return nil }
            return (entry, contents.audits[entry.conversation])
        }
        guard let (proposal, audit) = found else { throw .noSuchFact(reference) }
        var candidate = proposal.fact
        candidate.approved = Date()
        let admitted: Fact
        do {
            admitted = try permanent.admit(candidate)
        } catch {
            throw .unwritable("\(error)")
        }
        contents.withLock { contents in
            if let index = contents.entries.firstIndex(where: { $0.reference == reference }) {
                contents.entries[index].status = .approved
                contents.entries[index].admitted = admitted.id
            }
            contents.declined.remove(DeclineKey(proposal.fact))
        }
        audit?.record(
            .factApproved, details: AuditEvent.Details.factApproved(proposal.fact, admitted: admitted, via: via))
        audit?.record(.factSuperseded, details: AuditEvent.Details.factSuperseded(proposal.fact, by: admitted.id))
        return admitted
    }

    /// Records the person's decline of `reference`: the proposal stays with its conversation, and the same
    /// subject, name, and value are not asked about again.
    ///
    /// - Parameter reference: `conversation/fact`.
    func decline(_ reference: String) {
        contents.withLock { contents in
            guard
                let index = contents.entries.firstIndex(where: { $0.reference == reference && $0.status == .awaiting })
            else { return }
            contents.entries[index].status = .declined
            contents.declined.insert(DeclineKey(contents.entries[index].fact))
        }
    }

    /// Whether the person declined this subject, name, and value in this process.
    ///
    /// - Parameter fact: A fact.
    /// - Returns: Whether a decline covers it.
    public func isDeclined(_ fact: Fact) -> Bool { contents.withLock { $0.declined.contains(DeclineKey(fact)) } }

    /// The audit log of `conversation`, when known.
    private func audit(_ conversation: String) -> AuditLog? { contents.withLock { $0.audits[conversation] } }

    /// Asks the person about each of `proposals` in turn through `approver`, one dialog each, and carries out
    /// each answer: Accept admits it (`approve`, via `elicitation`), Decline or Cancel records a decline, no
    /// answer within the approver's wait leaves it awaiting, and a failed dialog leaves it awaiting too. Each
    /// question and answer is recorded on the proposal's conversation's audit log as `fact.approval.asked` and
    /// `fact.approval.decided`. A proposal decided meanwhile (approved in chat, withdrawn) is skipped.
    ///
    /// - Parameters:
    ///   - proposals: What `claim` returned.
    ///   - approver: The host's fact-approval effect.
    ///   - permanent: The shared store.
    public func ask(_ proposals: [FactProposal], via approver: any FactApprover, permanent: SharedFacts) async {
        for (offset, proposal) in proposals.enumerated() {
            guard self.proposal(proposal.reference)?.status == .awaiting, !isDeclined(proposal.fact) else { continue }
            let audit = audit(proposal.conversation)
            let request = FactApprovalRequest(proposal: proposal, position: offset + 1, count: proposals.count)
            audit?.record(
                .factApprovalAsked,
                details: AuditEvent.Details.factApprovalAsked(proposal, position: offset + 1, count: proposals.count))
            let started = Date()
            let decision = await approver.decide(request)
            let seconds = Date().timeIntervalSince(started)
            var admitted: String?
            var reason: String?
            switch decision {
            case .approved:
                do {
                    admitted = try approve(proposal.reference, permanent: permanent, via: "elicitation").id
                } catch {
                    reason = error.description
                }
            case .declined, .cancelled:
                decline(proposal.reference)
            case .unanswered:
                break
            case .failed(let why):
                reason = why
            }
            audit?.record(
                .factApprovalDecided,
                details: AuditEvent.Details.factApprovalDecided(
                    proposal, decision: admitted == nil && decision == .approved ? "failed" : decision.name,
                    admitted: admitted, reason: reason, seconds: seconds))
        }
    }

    /// Drops the oldest decided and withdrawn proposals past `historyLimit`.
    private static func trim(_ entries: inout [FactProposal]) {
        let decided = entries.indices.filter { entries[$0].status != .awaiting }
        guard decided.count > historyLimit else { return }
        let drop = Set(decided.prefix(decided.count - historyLimit))
        entries = entries.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
