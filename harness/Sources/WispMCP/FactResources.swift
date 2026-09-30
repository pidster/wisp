import Foundation
import MCP
import WispCore

/// The facts of a live `respond` thread (decisions D2 and D3 of the layered-context proposal):
/// `wisp://threads/{thread_id}/facts` lists the facts the thread's model is given, current by default and
/// every version with `?all=true`, paged; `…/facts/{fact_id}` is one fact with every version of what it is
/// about. Read from the thread's store and the session's, at no model cost.
extension WispServer {
    /// Serves `wisp://threads/{thread_id}/facts[/{fact_id}]`.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - fact: A fact's id, or nil for the collection.
    ///   - page: The page asked for.
    ///   - all: Whether the collection includes superseded and deleted versions.
    /// - Returns: The JSON.
    /// - Throws: `MCPError.invalidParams` for a thread that is not open or keeps no facts, an unknown fact, or
    ///   a page out of range.
    func readFacts(thread id: String, fact: String?, page: Int, all: Bool) async throws -> JSONValue {
        guard let open = await threads.peek(id) else {
            if let record = directory.record(id) {
                throw MCPError.invalidParams(
                    "thread \(id) is \(record.state.rawValue); its facts went with it, and its audit remains under "
                        + "\(ToolCatalog.threadURI(id))/audit")
            }
            throw MCPError.invalidParams("no thread \(id) on this server; wisp://threads lists them")
        }
        guard let facts = await open.thread.facts() else {
            throw MCPError.invalidParams("thread \(id) keeps no facts (facts.enabled is false)")
        }
        let view = FactView(facts)
        let base = ToolCatalog.threadURI(id) + "/facts"
        if let fact {
            guard let found = facts.first(where: { $0.id == fact }) else {
                throw MCPError.invalidParams("no fact \(fact) in thread \(id); \(base) lists them")
            }
            let history = facts.filter { $0.identity.key == found.identity.key }.sorted { $0.recorded < $1.recorded }
            return .object([
                "fact": FactReport.json(found, view: view),
                "history": .array(history.map { FactReport.json($0, view: view) }),
            ])
        }
        let shown = facts.filter { all || $0.state == .current }.sorted { lhs, rhs in
            lhs.identity.key != rhs.identity.key ? lhs.identity.key < rhs.identity.key : lhs.recorded < rhs.recorded
        }
        let rows = shown.map { fact -> JSONValue in
            var row = FactReport.json(fact, view: view).objectValue ?? [:]
            row["uri"] = .string("\(base)/\(fact.id)")
            return .object(row)
        }
        var listing = try Self.paged(rows, page: page, base: base, key: "facts").objectValue ?? [:]
        if all, let next = listing["next"]?.stringValue {
            listing["next"] = .string(next.replacing("?page=", with: "?all=true&page="))
        }
        listing["conflicts"] = .int(view.conflicts.count)
        return .object(listing)
    }

    /// The thread's current task and who set it, or null when it has none or keeps no facts.
    func threadTask(_ id: String) async -> JSONValue {
        guard let open = await threads.peek(id), let facts = await open.thread.facts(),
            let task = facts.last(where: { $0.identity.subject == "task" && $0.state == .current })
        else { return .null }
        return .object(["text": .string(task.value), "source": .string(task.source.rawValue), "id": .string(task.id)])
    }
}
