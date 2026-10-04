import Foundation
import FoundationModels

/// What an agent needs to keep facts (decisions D1 and D2 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): the subject kinds, the
/// session's ephemeral facts and the shared store of permanent ones, which it shares with other
/// conversations, and whether turns leaving the active view are distilled.
public struct FactSettings: Sendable {
    /// The subject kinds and test commands.
    public var kinds: SubjectKinds
    /// The session's ephemeral facts.
    public var session: SharedFacts
    /// The shared store of permanent facts.
    public var permanent: SharedFacts
    /// Whether turns leaving the active view are distilled by the model.
    public var distils: Bool
    /// Whether the running summary is written in the same model call as the facts when both are due
    /// (`SummaryWriter.Combined`), rather than in a call of its own after the facts'.
    public var summaryWithFacts: Bool
    /// The process's proposed permanent facts, from every conversation, which it shares with them.
    public var proposals: FactProposals

    /// Whether the summary shares the facts' call by default: yes, since the eval found one call as reliable
    /// as two on the on-device model and granite, faster, and no worse (proposal, "Summary, 2026-09-30").
    public static let summaryWithFactsDefault = true

    /// Creates settings. The defaults keep every fact in memory, which is what a test wants.
    public init(
        kinds: SubjectKinds = .defaults, session: SharedFacts = .session(),
        permanent: SharedFacts = SharedFacts(scope: .permanent), distils: Bool = true,
        proposals: FactProposals = FactProposals(), summaryWithFacts: Bool = FactSettings.summaryWithFactsDefault
    ) {
        self.summaryWithFacts = summaryWithFacts
        self.kinds = kinds
        self.session = session
        self.permanent = permanent
        self.distils = distils
        self.proposals = proposals
    }
}

/// Why the person's change to a fact was refused.
public enum FactFailure: Error, CustomStringConvertible, Equatable {
    /// The conversation keeps no facts (`facts.enabled` is false).
    case off
    /// No subject kind of that name.
    case unknownSubject(String, known: [String])
    /// No current fact with that id.
    case noSuchFact(String)
    /// The fact is not a proposed permanent fact.
    case notProposed(String)
    /// No proposal awaiting the person with that reference (`conversation/fact`).
    case noSuchProposal(String)
    /// The fact is already where the person asked to move it.
    case alreadyThere(String, FactTarget)
    /// Another conversation's proposal cannot move into this conversation.
    case otherThread(String)
    /// The value is empty.
    case emptyValue
    /// The shared store could not be written.
    case unwritable(String)
    /// The fact is no longer what the person was asked about: superseded, deleted, moved, or changed in value.
    case changed(String)

    /// Human-readable explanation.
    public var description: String {
        switch self {
        case .off: "this conversation keeps no facts (facts.enabled is false)"
        case .unknownSubject(let name, let known):
            "no subject \(name); the subjects are \(known.joined(separator: ", "))"
        case .noSuchFact(let id): "no current fact \(id); /inspect facts lists them"
        case .notProposed(let id): "fact \(id) is not a proposed permanent fact"
        case .noSuchProposal(let reference):
            "no proposal \(reference) awaiting approval; /inspect facts lists those of other conversations"
        case .alreadyThere(let id, let target): "fact \(id) is already in scope \(target.rawValue)"
        case .otherThread(let id):
            "\(id) is another conversation's proposal; it can be moved to permanent or session"
        case .emptyValue: "a fact needs a value"
        case .unwritable(let reason): reason
        case .changed(let id): "fact \(id) changed after the person was asked about it; it was not kept"
        }
    }
}

extension Agent {
    /// Every current fact the conversation sees, from the shared store, the conversation, and the session,
    /// grouped by what it is about; empty when it keeps no facts.
    public var factView: FactView {
        guard let facts else { return FactView([]) }
        return FactView(facts.permanent.current + store.facts.current + facts.session.current)
    }

    /// Every fact the conversation sees, in any state: the shared store's, the conversation's, the session's.
    public var allFacts: [Fact] {
        guard let facts else { return [] }
        return facts.permanent.facts + store.facts.facts + facts.session.facts
    }

    /// The fact `id` in whichever store its prefix names, or nil.
    public func fact(_ id: String) -> Fact? { allFacts.first { $0.id == id } }

    /// The facts recorded or changed since the current turn began that are still in force, oldest first: what
    /// the turn's tools and the model added (`Reply.facts`).
    var factsChangedThisTurn: [Fact] {
        var seen: Set<String> = []
        return turnFactIDs.compactMap { id in
            guard seen.insert(id).inserted, let fact = fact(id), fact.state == .current else { return nil }
            return fact
        }
    }

    /// Every version, from every store, of what the fact `id` is about, oldest first; empty for an unknown id.
    public func factHistory(_ id: String) -> [Fact] {
        guard let key = fact(id)?.identity.key else { return [] }
        return allFacts.filter { $0.identity.key == key }.sorted { $0.recorded < $1.recorded }
    }

    /// The task's versions, oldest first.
    public var taskHistory: [Fact] { store.facts.history(of: FactIdentity.Key(subject: "task", name: "")) }

    /// The conversation's name among the process's proposals: its audit session, which for an MCP thread is
    /// the `thread_id`, with `.N` after the Nth `reset` (chat's `/new`), whose store numbers its facts afresh.
    public var threadID: String { (audit?.session ?? "unaudited") + (generation == 0 ? "" : ".\(generation)") }

    /// The proposed permanent facts of the process's other conversations that await the person, oldest first.
    public var proposalsElsewhere: [FactProposal] {
        guard let facts else { return [] }
        let own = threadID
        return facts.proposals.awaiting.filter { $0.threadID != own }
    }

    /// Mirrors the conversation's current proposals into the process's registry, and marks superseded any that
    /// the person moved from outside the conversation (chat moving another conversation's proposal). The move
    /// was audited when it was made.
    public func syncProposals() {
        guard let facts else { return }
        let current = store.facts.current.filter(\.proposed)
        let moved = facts.proposals.sync(thread: threadID, audit: audit, current: current)
        for (id, admitted) in moved { store.facts.supersede(id, by: admitted) }
    }

    /// Recomputes the facts the next request carries, and audits conflicts that began or ended since the
    /// last check. Without facts, the composer carries none.
    ///
    /// - Parameter quietly: Take the conflicts as they stand without auditing them, as when facts are first
    ///   switched on over a resumed store.
    func refreshFacts(quietly: Bool = false) {
        guard facts != nil else {
            composer.facts = requestNotes(.empty, view: nil)
            return
        }
        syncProposals()
        let view = factView
        composer.facts = requestNotes(
            composer.factFrame(view, store: store, window: contextSize ?? Self.assumedWindow), view: view)
        let now = view.conflicts
        defer { factConflicts = now }
        guard !quietly else { return }
        for key in now.subtracting(factConflicts).sorted() {
            let group = view.group(key)
            audit?.record(
                .factConflict,
                details: AuditEvent.Details.factConflict(
                    key, winner: group?.winner.id, others: group?.disagreeing.map(\.id) ?? []))
        }
        for key in factConflicts.subtracting(now).sorted() {
            audit?.record(
                .factResolved,
                details: AuditEvent.Details.factConflict(key, winner: view.group(key)?.winner.id, others: []))
        }
    }

    /// The window assumed for the facts' cap when the model states none.
    static let assumedWindow = 8192

    /// Records an assertion in the store its identity's scope names, and audits it. A permanent fact from a
    /// tool or the model is not admitted to the shared store: the conversation holds it as a proposal until
    /// the person approves it (D2).
    ///
    /// - Parameter assertion: What to record.
    /// - Returns: The fact now current for it, or nil when nothing could be kept.
    @discardableResult
    func record(_ assertion: FactBook.Assertion) -> Fact? {
        guard let facts else { return nil }
        var assertion = assertion
        if assertion.identity.scope == .permanent, assertion.source.rank < FactSource.person.rank {
            assertion.identity.scope = .thread
        }
        let change: FactBook.Change
        switch assertion.identity.scope {
        case .thread:
            change = store.facts.record(assertion)
            store.facts.trimHistory(to: SharedFacts.historyLimit)
        case .session:
            guard let recorded = try? facts.session.record(assertion) else { return nil }
            change = recorded
        case .permanent:
            do {
                change = try facts.permanent.record(assertion)
            } catch {
                Diagnostics.agent.error("could not keep a permanent fact: \(error)")
                return nil
            }
        }
        switch change {
        case .recorded(let fact):
            turnFactIDs.append(fact.id)
            audit?.record(.factRecorded, details: AuditEvent.Details.factRecorded(fact, supersedes: nil))
        case .superseded(let old, let fact):
            turnFactIDs.append(fact.id)
            audit?.record(.factRecorded, details: AuditEvent.Details.factRecorded(fact, supersedes: old.id))
            audit?.record(.factSuperseded, details: AuditEvent.Details.factSuperseded(old, by: fact.id))
        case .replaced(let olds, let fact):
            turnFactIDs.append(fact.id)
            audit?.record(.factRecorded, details: AuditEvent.Details.factRecorded(fact, supersedes: olds.first?.id))
            for old in olds {
                audit?.record(.factSuperseded, details: AuditEvent.Details.factSuperseded(old, by: fact.id))
            }
        case .retired(let old, let fact):
            audit?.record(.factSuperseded, details: AuditEvent.Details.factSuperseded(old, by: fact.id))
        case .unchanged:
            break
        }
        return change.fact
    }

    /// Extracts the facts a turn's tool calls give (`FactExtraction`) and records them.
    ///
    /// - Parameters:
    ///   - events: The turn's `tool.call` and `tool.result` events.
    ///   - turn: The turn.
    func extractFacts(from events: [AuditEvent], turn: Int) {
        guard let facts, !events.isEmpty else { return }
        var entries: [String: Int] = [:]
        for entry in store.entries where entry.kind == .toolOutput {
            if let event = entry.sources.first?.event { entries[event] = entry.id }
        }
        let assertions = FactExtraction.assertions(
            from: FactExtraction.calls(from: events), kinds: facts.kinds, turn: turn, entries: entries)
        for assertion in assertions { record(assertion) }
    }

    /// Distils the prose of `leaving`, entries about to leave the active view, into facts with one call to
    /// the conversation's model in a session of its own, and records them. The call and its outcome are
    /// audited as `context.distillation`; a failure is audited and logged and never fails the turn.
    ///
    /// - Parameters:
    ///   - leaving: The store entries a condensation is about to drop.
    ///   - staying: The entries it keeps, whose prompts the distiller reads for the latest values.
    nonisolated(nonsending) func distil(
        _ leaving: [ThreadRecord.Entry], staying: [ThreadRecord.Entry] = []
    )
        async
    {
        guard let facts, facts.distils else { return }
        let distilled = FactDistiller.turns(in: leaving)
        guard !distilled.isEmpty else { return }
        let window = contextSize ?? Self.assumedWindow
        let prompt = FactDistiller.prompt(
            turns: distilled, kinds: facts.kinds, existing: factView.groups.map(\.key),
            budgetBytes: min(12_000, window * ContextComposer.bytesPerToken / 3),
            later: FactDistiller.turns(in: staying))
        let prose = leaving.filter { $0.kind == .prompt || $0.kind == .response }
        let started = Date()
        var recorded: [String] = []
        var failure: String?
        do {
            try model.checkGuidedGeneration()
            let session = model.session(tools: [], instructions: FactDistiller.instructions)
            let answer = try await session.respond(
                to: prompt, generating: FactDistiller.Distillation.self,
                options: GenerationOptions(
                    samplingMode: .greedy, maximumResponseTokens: FactDistiller.maximumResponseTokens)
            ).content
            let assertions = FactDistiller.assertions(
                from: answer.facts, kinds: facts.kinds, turns: distilled, entries: prose.map(\.id),
                audit: prose.flatMap(\.sources), turn: turns.current, time: Date())
            recorded = assertions.compactMap { record($0)?.id }
        } catch {
            failure = "\(error)"
            Diagnostics.agent.error("distilling \(distilled.count) turn(s) failed: \(error)")
        }
        audit?.record(
            .distillation,
            details: AuditEvent.Details.distillation(
                turns: distilled.map(\.number), entries: prose.count, bytes: prompt.utf8.count, facts: recorded,
                seconds: Date().timeIntervalSince(started), model: model.selection, failure: failure))
    }

    /// States a fact as `source` (the person, or an MCP caller): a person's assertion outranks a tool's and the
    /// model's. A permanent kind's fact goes straight to the shared store, since the person admits it.
    ///
    /// - Parameters:
    ///   - subject: The subject kind.
    ///   - name: The name under it; ignored by kinds with one fact per conversation.
    ///   - value: The value.
    ///   - source: `person` or `caller`.
    /// - Returns: The fact now current.
    /// - Throws: `FactFailure`.
    @discardableResult
    public func stateFact(
        subject: String, name: String, value: String, source: FactSource = .person
    ) throws(FactFailure) -> Fact {
        guard let facts else { throw .off }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw .emptyValue }
        guard let (identity, temporalClass) = facts.kinds.identity(subject: subject, name: name) else {
            throw .unknownSubject(subject, known: facts.kinds.kinds.map(\.name))
        }
        let fact = record(
            FactBook.Assertion(
                identity: identity, source: source, value: value, temporalClass: temporalClass, method: .stated,
                turn: turns.current))
        refreshFacts()
        guard let fact else { throw .unwritable("the fact could not be kept") }
        return fact
    }

    /// Sets the conversation's task as `source` (D6).
    ///
    /// - Parameters:
    ///   - text: The task.
    ///   - source: `person` in chat, `caller` over MCP.
    /// - Returns: The task fact now current.
    /// - Throws: `FactFailure`.
    @discardableResult
    public func setTask(_ text: String, source: FactSource = .person) throws(FactFailure) -> Fact {
        try stateFact(subject: "task", name: "", value: text, source: source)
    }

    /// Deletes the current fact `id` from whichever store holds it: the person's action (D3). The store keeps
    /// it as history, marked deleted; later requests leave it out.
    ///
    /// - Parameter id: The fact.
    /// - Returns: The deleted fact.
    /// - Throws: `FactFailure`.
    @discardableResult
    public func deleteFact(_ id: String) throws(FactFailure) -> Fact {
        guard let facts else { throw .off }
        let deleted: Fact?
        switch id.first {
        case "c": deleted = store.facts.delete(id)
        case "s": deleted = try? facts.session.delete(id)
        case "p":
            do {
                deleted = try facts.permanent.delete(id)
            } catch {
                throw .unwritable("\(error)")
            }
        default: deleted = nil
        }
        guard let deleted else { throw .noSuchFact(id) }
        audit?.record(.factDeleted, details: AuditEvent.Details.factDeleted(deleted))
        refreshFacts()
        return deleted
    }

    /// Records what wisp knows of where the conversation works without a model: the directory it starts in
    /// and its git branch, as tool facts from `observer` (chat passes `chat`).
    ///
    /// - Parameters:
    ///   - directory: The working directory.
    ///   - branch: The git branch, when known.
    ///   - observer: What observed them, recorded as the facts' tool.
    public func observe(directory: String, branch: String?, observer: String) {
        guard let facts else { return }
        var observed = [("workdir", directory)]
        if let branch, !branch.isEmpty { observed.append(("branch", branch)) }
        for (subject, value) in observed {
            guard let (identity, temporalClass) = facts.kinds.identity(subject: subject, name: "") else { continue }
            record(
                FactBook.Assertion(
                    identity: identity, source: .tool, value: value, temporalClass: temporalClass, method: .extracted,
                    detail: observer, turn: turns.current))
        }
        refreshFacts()
    }
}
