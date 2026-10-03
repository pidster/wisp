import Foundation
import MCP
import WispCore

/// Permanent facts over MCP ([ADR 0048](../../../docs/decisions/0048-permanent-facts-over-mcp.md)): a caller asks,
/// the person answers through another face, and the outcome is readable later. The caller cannot keep a fact
/// itself, and cannot move or remove a permanent one.
extension WispServer {
    /// `set_fact_scope` with `scope: permanent`: files a request for the person to keep the fact and returns at
    /// once, with `state` `pending` and the request's id. A request already waiting for the fact is returned
    /// again rather than asked twice; a fact the person dropped for this thread is refused, since the thread
    /// is not to ask about it again.
    ///
    /// - Parameters:
    ///   - request: The decoded arguments.
    ///   - open: The thread.
    /// - Returns: The result: `thread_id`, `from`, `state`, `request`, `expiresAt`, `fact`, and `uri`, where the
    ///   outcome will show.
    func askToKeep(_ request: SetFactScopeRequest, open: OpenThread) async -> CallTool.Result {
        let id = request.threadID
        guard let facts = await open.thread.facts() else { return failure(FactFailure.off.description) }
        guard let fact = facts.first(where: { $0.id == request.factID && $0.state == .current }) else {
            return failure(
                "no current fact \(request.factID) in thread \(id); \(ToolCatalog.threadURI(id))/facts lists them")
        }
        let thread = open.thread
        let asked: FactKeeper.Asked
        do {
            asked = try factKeeper.ask(fact, thread: id, audit: open.audit) { decision, requestID in
                let shown = FactKeeper.proposed(fact)
                do {
                    if decision == "keep" { return .kept(try await thread.keepAsked(shown, request: requestID).id) }
                    _ = try await thread.dropAsked(shown, request: requestID)
                    return .dropped
                } catch {
                    return .failed("\(error)")
                }
            }
        } catch {
            return failure("could not ask the person to keep \(request.factID): \(error)")
        }
        let uri = Self.factURI(fact, thread: id)
        let record: FactKeeper.Record
        switch asked {
        case .dropped(let earlier):
            let when = earlier.settledAt?.ISO8601Format() ?? "earlier"
            return failure(
                "the person dropped \(fact.identity.name) = \(fact.value) for thread \(id) (request "
                    + "\(earlier.request.id), \(when)); wisp does not ask about it again in this thread")
        case .filed(let filed), .waiting(let filed):
            record = filed
        }
        let rows = Self.turnFacts([fact], thread: id).arrayValue ?? []
        let again = if case .waiting = asked { " (already waiting)" } else { "" }
        return .init(
            content: [
                .text(
                    text: "asked the person to keep \(request.factID) (\(fact.identity.name) = \(fact.value)) as a "
                        + "permanent fact\(again): request \(record.request.id), answered with wisp facts keep or "
                        + "drop; the outcome shows on \(uri)", annotations: nil, _meta: nil)
            ],
            structuredContent: .object([
                "thread_id": .string(id), "from": .string(request.factID), "state": .string(record.state.rawValue),
                "request": .string(record.request.id),
                "expiresAt": record.request.expiresAt.map { .string($0.ISO8601Format()) } ?? .null,
                "fact": Value(json: rows.first ?? .null), "uri": .string(uri),
            ]),
            isError: false)
    }

    /// Where a fact can be read: under its thread, in the session's collection, or under `wisp://facts`.
    static func factURI(_ fact: Fact, thread: String) -> String {
        switch FactTarget(holding: fact) {
        case .thread: "\(ToolCatalog.threadURI(thread))/facts/\(fact.id)"
        case .session: ToolCatalog.sessionFactsResourceURI
        case .permanent: "\(ToolCatalog.factsResourceURI)/\(fact.id)"
        }
    }

    /// The latest request to keep fact `fact` of `thread`, as JSON (`id`, `state`, `kept`, `via`, `reason`,
    /// `asked`, `expiresAt`, `settled`), or null when none was made.
    func keepRequest(thread: String, fact: String) -> JSONValue {
        guard let record = factKeeper.record(thread: thread, fact: fact) else { return .null }
        return .object([
            "id": .string(record.request.id), "state": .string(record.state.rawValue),
            "kept": record.kept.map { .string($0) } ?? .null, "via": record.via.map { .string($0) } ?? .null,
            "reason": record.reason.map { .string($0) } ?? .null,
            "asked": .string(record.request.createdAt.ISO8601Format()),
            "expiresAt": record.request.expiresAt.map { .string($0.ISO8601Format()) } ?? .null,
            "settled": record.settledAt.map { .string($0.ISO8601Format()) } ?? .null,
        ])
    }

    /// `respond`'s `factsProposed`: how many permanent facts proposed in this server's conversations await the
    /// person (`count`), how many of them are this thread's (`thread`), and where they are listed (`uri`). The
    /// model's proposals are not announced by a notification; this is how the caller learns of them.
    ///
    /// - Parameter thread: The thread that ran the turn.
    /// - Returns: The object.
    func factsProposed(thread: String) -> JSONValue {
        let awaiting = session.factProposals.awaiting
        return .object([
            "count": .int(awaiting.count), "thread": .int(awaiting.filter { $0.threadID == thread }.count),
            "uri": .string(ToolCatalog.proposedFactsResourceURI),
        ])
    }
}
