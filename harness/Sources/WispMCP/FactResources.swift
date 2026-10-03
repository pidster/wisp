import Foundation
import MCP
import WispCore

/// The facts resources (decisions D2 and D3 of the layered-context proposal), each under what owns it:
/// `wisp://facts` is the shared store of permanent facts and `wisp://facts/{fact_id}` one of them with its
/// history; `wisp://facts/proposed` the permanent facts proposed in any conversation of the server, awaiting
/// the person; `wisp://session/facts` the session's ephemeral facts; `wisp://threads/{thread_id}/facts` a
/// thread's own facts and `…/facts/{fact_id}` one of them. Collections list current facts by default and
/// every version with `?all=true`, paged. All are read from memory, at no model cost.
extension WispServer {
    /// Serves a resource under `wisp://facts` or `wisp://session/facts`, or nil for a URI that is neither.
    ///
    /// - Parameter uri: The URI read.
    /// - Returns: The contents, or nil.
    /// - Throws: `MCPError.invalidParams` for an unknown fact, a malformed URI, or a page out of range.
    func readFactStores(_ uri: String) throws -> ReadResource.Result? {
        let permanent = ThreadURI(uri, root: ToolCatalog.factsResourceURI)
        let session = ThreadURI(uri, root: ToolCatalog.sessionFactsResourceURI)
        guard let parsed = permanent ?? session else { return nil }
        guard parsed.page >= 1 else { throw MCPError.invalidParams("page must be a whole number from 1") }
        let contents: JSONValue
        switch (permanent != nil, parsed.path) {
        case (true, []):
            contents = try listing(
                self.session.permanentFacts.facts, page: parsed.page, all: parsed.all,
                base: ToolCatalog.factsResourceURI)
        case (true, ["proposed"]):
            contents = try proposedFacts(page: parsed.page)
        case (true, let path) where path.count == 1 && Self.isPermanentFactID(path[0]):
            let id = path[0]
            contents = try history(
                of: id, in: self.session.permanentFacts.facts,
                missing: "no permanent fact \(id); wisp://facts lists them")
        case (true, let path) where path.count == 1:
            let id = path[0]
            throw MCPError.invalidParams(
                "\(id) is not a permanent fact's id (p1, p2, …); a thread's facts are under "
                    + "wisp://threads/{thread_id}/facts and the session's at \(ToolCatalog.sessionFactsResourceURI)")
        case (false, []):
            contents = try listing(
                self.session.sessionFacts.facts, page: parsed.page, all: parsed.all,
                base: ToolCatalog.sessionFactsResourceURI, linked: false)
        default:
            throw MCPError.invalidParams("Unknown resource: \(uri)")
        }
        return .init(contents: [.text(Introspection.render(contents), uri: uri, mimeType: "application/json")])
    }

    /// Whether `text` has the form of a permanent fact's id: `p` and a number, so `proposed` is never one.
    static func isPermanentFactID(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix(FactScope.permanent.prefix) && text.dropFirst().allSatisfy(\.isASCII)
            && text.dropFirst().allSatisfy(\.isNumber)
    }

    /// Serves `wisp://threads/{thread_id}/facts[/{fact_id}]`: the thread's own facts, those its store holds,
    /// and the collection's `summary`, the running summary of the turns condensing dropped (null before the
    /// first), with every version in `summaries` under `?all=true`. The session's and the permanent facts have
    /// resources of their own.
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
        guard let seen = await open.thread.facts() else {
            throw MCPError.invalidParams("thread \(id) keeps no facts (facts.enabled is false)")
        }
        let view = FactView(seen)
        let own = seen.filter { $0.identity.scope == .thread }
        let base = ToolCatalog.threadURI(id) + "/facts"
        if let fact {
            guard own.contains(where: { $0.id == fact }) else {
                let elsewhere =
                    fact.hasPrefix(FactScope.permanent.prefix)
                    ? "; permanent facts are at \(ToolCatalog.factsResourceURI)/\(fact)"
                    : fact.hasPrefix(FactScope.session.prefix)
                        ? "; the session's are at \(ToolCatalog.sessionFactsResourceURI)" : ""
                throw MCPError.invalidParams("no fact \(fact) in thread \(id); \(base) lists them\(elsewhere)")
            }
            return Self.with(
                try history(of: fact, in: own, missing: "", view: view), "request",
                keepRequest(thread: id, fact: fact))
        }
        var listing = try listing(own, page: page, all: all, base: base, view: view)
        let keys = Set(own.filter { $0.state == .current }.map(\.identity.key))
        listing = Self.with(listing, "conflicts", .int(view.conflicts.intersection(keys).count))
        let summaries = await open.thread.summaries() ?? []
        listing = Self.with(listing, "summary", summaries.last.map(FactReport.json) ?? .null)
        if all { listing = Self.with(listing, "summaries", .array(summaries.map(FactReport.json))) }
        return listing
    }

    /// The thread's current task and who set it, or null when it has none or keeps no facts.
    func threadTask(_ id: String) async -> JSONValue {
        guard let open = await threads.peek(id), let facts = await open.thread.facts(),
            let task = facts.last(where: { $0.identity.subject == "task" && $0.state == .current })
        else { return .null }
        return .object(["text": .string(task.value), "source": .string(task.source.rawValue), "id": .string(task.id)])
    }

    /// A page of `facts` (current ones, or every version with `all`), each with its URI under `base` when
    /// `linked`, and the count of conflicts among them.
    ///
    /// - Parameters:
    ///   - facts: Every fact of the store, in any state.
    ///   - page: The page.
    ///   - all: Whether to include superseded and deleted versions.
    ///   - base: The collection's URI.
    ///   - linked: Whether each fact has a URI of its own under `base`.
    ///   - view: The facts in force, for each fact's conflict; the store's own current facts when nil.
    /// - Returns: The page.
    /// - Throws: `MCPError.invalidParams` for a page past the last.
    private func listing(
        _ facts: [Fact], page: Int, all: Bool, base: String, linked: Bool = true, view: FactView? = nil
    ) throws -> JSONValue {
        let view = view ?? FactView(facts)
        let shown = facts.filter { all || $0.state == .current }.sorted { lhs, rhs in
            lhs.identity.key != rhs.identity.key ? lhs.identity.key < rhs.identity.key : lhs.recorded < rhs.recorded
        }
        let rows = shown.map { fact -> JSONValue in
            linked
                ? Self.with(FactReport.json(fact, view: view), "uri", .string("\(base)/\(fact.id)"))
                : FactReport
                    .json(fact, view: view)
        }
        var listing = try Self.paged(rows, page: page, base: base, key: "facts").objectValue ?? [:]
        if all, let next = listing["next"]?.stringValue {
            listing["next"] = .string(next.replacing("?page=", with: "?all=true&page="))
        }
        listing["conflicts"] = .int(view.conflicts.count)
        return .object(listing)
    }

    /// One fact of `facts` and every version of what it is about, oldest first.
    ///
    /// - Parameters:
    ///   - id: The fact.
    ///   - facts: The store's facts.
    ///   - missing: The error when there is no such fact.
    ///   - view: The facts in force, for conflicts; the store's own current facts when nil.
    /// - Returns: `fact` and `history`.
    /// - Throws: `MCPError.invalidParams` with `missing`.
    private func history(of id: String, in facts: [Fact], missing: String, view: FactView? = nil) throws -> JSONValue {
        guard let found = facts.first(where: { $0.id == id }) else { throw MCPError.invalidParams(missing) }
        let view = view ?? FactView(facts)
        let history = facts.filter { $0.identity.key == found.identity.key }.sorted { $0.recorded < $1.recorded }
        return .object([
            "fact": FactReport.json(found, view: view),
            "history": .array(history.map { FactReport.json($0, view: view) }),
        ])
    }

    /// `wisp://facts/proposed`: the proposals awaiting the person, oldest first, each with its conversation,
    /// the reference chat's `/fact` takes, the thread fact's URI when the conversation is a thread of this
    /// server, and the latest request to keep it (ADR 0048), or null.
    private func proposedFacts(page: Int) throws -> JSONValue {
        let view = FactView([])
        let rows = session.factProposals.awaiting.map { proposal -> JSONValue in
            var row = FactReport.json(proposal.fact, view: view).objectValue ?? [:]
            row["thread_id"] = .string(proposal.threadID)
            row["reference"] = .string(proposal.reference)
            row["request"] = keepRequest(thread: proposal.threadID, fact: proposal.fact.id)
            row["uri"] =
                directory.record(proposal.threadID) == nil
                ? .null : .string("\(ToolCatalog.threadURI(proposal.threadID))/facts/\(proposal.fact.id)")
            return .object(row)
        }
        return try Self.paged(rows, page: page, base: ToolCatalog.proposedFactsResourceURI, key: "facts")
    }

    /// The facts a turn recorded or changed, for `respond`'s `structuredContent.facts`: each with `id`, `scope`,
    /// `subject`, `name`, `value`, `source`, `proposed`, and `uri`, where the person or a caller can read it
    /// (a thread's fact under the thread, a session fact in the session's collection, a permanent one under
    /// `wisp://facts`).
    ///
    /// - Parameters:
    ///   - facts: The turn's facts (`Agent.Reply.facts`).
    ///   - thread: The thread that ran the turn.
    /// - Returns: The array.
    static func turnFacts(_ facts: [Fact], thread: String) -> JSONValue {
        let rows = FactReport.newFactsJSON(facts).arrayValue ?? []
        return .array(
            zip(facts, rows).map { fact, row in
                let uri =
                    switch FactTarget(holding: fact) {
                    case .thread: "\(ToolCatalog.threadURI(thread))/facts/\(fact.id)"
                    case .session: ToolCatalog.sessionFactsResourceURI
                    case .permanent: "\(ToolCatalog.factsResourceURI)/\(fact.id)"
                    }
                return with(row, "uri", .string(uri))
            })
    }

    /// `object` with `key` set to `value`.
    private static func with(_ object: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var fields = object.objectValue ?? [:]
        fields[key] = value
        return .object(fields)
    }
}
