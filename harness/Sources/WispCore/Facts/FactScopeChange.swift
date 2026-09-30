import Foundation

/// Where the person can put a fact: a scope named as a target state (decisions D2 and D3 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), and the withdrawal
/// recorded in [ADR 0044](../../../../docs/decisions/0044-host-effects.md)). A scope and a temporal class move
/// together: `permanent` is the shared store, `thread` the conversation's own facts (dynamic), `session` the
/// process's ephemeral ones.
public enum FactTarget: String, Sendable, Equatable, CaseIterable {
    /// The shared store under `~/.wisp`, kept across sessions and ranked with the person.
    case permanent
    /// The conversation's own facts.
    case thread
    /// The session's facts, shared by the server's threads and gone when the process ends.
    case session

    /// The store this target names.
    public var scope: FactScope {
        switch self {
        case .permanent: .permanent
        case .thread: .thread
        case .session: .session
        }
    }

    /// The temporal class a fact has once it is there.
    public var temporalClass: TemporalClass {
        switch self {
        case .permanent: .permanent
        case .thread: .dynamic
        case .session: .ephemeral
        }
    }

    /// Where `fact` is held. A proposed permanent fact is the conversation's, so it is `thread` until the
    /// person moves it.
    public init(holding fact: Fact) {
        switch fact.identity.scope {
        case .permanent: self = .permanent
        case .thread: self = .thread
        case .session: self = .session
        }
    }
}

extension Agent {
    /// Moves the current fact `id` to `target`: the person's action in chat (`/fact ID SCOPE`) or a caller's
    /// over MCP (`set_fact_scope`). Scope and temporal class move together. A move to `permanent` writes the
    /// fact to the shared store as the person's, ranking with the person as an approved fact does; a move out
    /// of `permanent` takes it out of the shared store into the target scope of this conversation. The old
    /// copy stays as history, superseded by the new one; a proposed permanent fact moved to `thread` is
    /// changed in place. Audited as `fact.scope.changed`.
    ///
    /// - Parameters:
    ///   - id: A fact of this conversation (`c3`), the session (`s1`), or the shared store (`p2`), or another
    ///     conversation's awaiting proposal by its reference (`git/c3`), which can go to `permanent` or
    ///     `session`.
    ///   - target: The scope to move it to.
    ///   - by: Who asked: `person` in chat, `caller` over MCP.
    /// - Returns: The fact as its new scope holds it.
    /// - Throws: `FactFailure`: no such fact, already there, another conversation's proposal to `thread`, or
    ///   a store that cannot be written.
    @discardableResult
    public func setFactScope(_ id: String, to target: FactTarget, by: FactSource = .person) throws(FactFailure) -> Fact
    {
        guard let facts else { throw .off }
        syncProposals()
        var local = id
        var elsewhere: FactProposal?
        if let (thread, fact) = FactProposal.parse(id) {
            if thread == threadID {
                local = fact
            } else {
                guard let proposal = facts.proposals.proposal(id), proposal.status == .awaiting else {
                    throw .noSuchProposal(id)
                }
                guard target != .thread else { throw .otherThread(id) }
                elsewhere = proposal
            }
        }
        let before: Fact
        if let elsewhere {
            before = elsewhere.fact
        } else {
            let found: Fact? =
                switch local.first {
                case FactScope.thread.prefix.first: store.facts.fact(local)
                case FactScope.session.prefix.first: facts.session.facts.first { $0.id == local }
                case FactScope.permanent.prefix.first: facts.permanent.facts.first { $0.id == local }
                default: nil
                }
            guard let found, found.state == .current else { throw .noSuchFact(local) }
            before = found
        }
        if FactTarget(holding: before) == target, !before.proposed { throw .alreadyThere(id, target) }

        let after: Fact
        if elsewhere == nil, target == .thread, before.identity.scope == .thread {
            guard let changed = store.facts.retarget(local, to: target.temporalClass) else { throw .noSuchFact(local) }
            after = changed
        } else {
            var candidate = before
            candidate.temporalClass = target.temporalClass
            if target == .permanent { candidate.approved = Date() }
            do {
                switch target {
                case .permanent: after = try facts.permanent.admit(candidate)
                case .session: after = try facts.session.admit(candidate)
                case .thread: after = store.facts.admit(candidate)
                }
                if let elsewhere {
                    facts.proposals.markMoved(elsewhere.reference, admitted: after.id)
                } else {
                    switch before.identity.scope {
                    case .thread: store.facts.supersede(local, by: after.id)
                    case .session: try facts.session.supersede(local, by: after.id)
                    case .permanent: try facts.permanent.supersede(local, by: after.id)
                    }
                }
            } catch {
                throw .unwritable("\(error)")
            }
        }
        let details = AuditEvent.Details.factScopeChanged(named: id, before: before, after: after, to: target, by: by)
        audit?.record(.factScopeChanged, details: details)
        if let elsewhere, let owner = facts.proposals.audit(elsewhere.threadID), owner !== audit {
            owner.record(.factScopeChanged, details: details)
        }
        if after.id != before.id {
            audit?.record(.factSuperseded, details: AuditEvent.Details.factSuperseded(before, by: after.id))
        }
        syncProposals()
        refreshFacts()
        return after
    }
}
