import Foundation
import MCP
import WispCore

/// The resources about `respond` threads, all under `wisp://threads` (`docs/mcp.md`, "Resources"): the
/// list of threads, one thread's summary, its tool calls and each call's output, and its audit events.
/// Collections are JSON and paged with `?page=N` (and `&limit=M` for the audit); each row names the URI that
/// reads it. A thread's events are read under its audit sessions, one per opening: every one a saved thread's
/// `thread.json` records, so a resumed thread's resources cover its whole life (ADR 0066, D7), and the one session of
/// a thread closed here (`ThreadDirectory.Record.auditSession`), so a `thread_id` reused after `close_thread` shows
/// only the thread it names now.
extension WispServer {
    /// Rows a collection's page holds.
    static let rowsPerPage = 50
    /// Events an audit page holds by default; `?limit=M` changes it, up to `auditEventsLimit`.
    static let auditEventsPerPage = 100
    /// The most events one audit page may hold.
    static let auditEventsLimit = 500

    /// A URI under a collection's root (`wisp://threads` by default, `wisp://facts`, `wisp://session/facts`,
    /// `wisp://audit`) split into its path after the root and its query.
    struct ThreadURI: Equatable {
        /// The path's segments after the root, such as `["git", "output", "8a7b…"]` under `wisp://threads`.
        var path: [String]
        /// The `page` query value, from 1; 1 when absent.
        var page: Int
        /// Whether the query says `all=true`.
        var all = false
        /// The `limit` query value, rows per page where a collection takes one; nil when absent.
        var limit: Int?

        /// Parses `uri`, or nil when it is not under `root`.
        ///
        /// - Parameters:
        ///   - uri: The URI read.
        ///   - root: The collection's root.
        init?(_ uri: String, root: String = ToolCatalog.threadsResourceURI) {
            guard uri == root || uri.hasPrefix(root + "/") || uri.hasPrefix(root + "?") else { return nil }
            var rest = Substring(uri.dropFirst(root.count))
            page = 1
            if let query = rest.firstIndex(of: "?") {
                let items = rest[rest.index(after: query)...].split(separator: "&")
                rest = rest[..<query]
                for item in items where item.hasPrefix("page=") {
                    page = Int(item.dropFirst(5)) ?? 0
                }
                for item in items where item.hasPrefix("limit=") {
                    limit = min(WispServer.auditEventsLimit, max(1, Int(item.dropFirst(6)) ?? 0))
                }
                all = items.contains("all=true")
            }
            path = rest.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        }
    }

    /// Serves a resource under `wisp://threads`, or nil for a URI that is not one.
    ///
    /// - Parameter uri: The URI read.
    /// - Returns: The contents, or nil.
    /// - Throws: `MCPError.invalidParams` for a malformed URI, an unknown thread or output, or a page out of
    ///   range; file errors reading the audit log.
    func readThread(_ uri: String) async throws -> ReadResource.Result? {
        guard let parsed = ThreadURI(uri) else { return nil }
        guard parsed.page >= 1 else { throw MCPError.invalidParams("page must be a whole number from 1") }
        let path = parsed.path
        guard let id = path.first else { return try json(await threadList(page: parsed.page), uri: uri) }
        guard SafeName.isValid(id) else { throw MCPError.invalidParams("thread id must be \(SafeName.rule)") }
        let sessions = await auditSessions(of: id)
        switch Array(path.dropFirst()) {
        case []:
            return try json(await threadSummary(id), uri: uri)
        case ["output"]:
            return try json(outputList(id, sessions: sessions, page: parsed.page), uri: uri)
        case let parts where parts.count == 2 && parts[0] == "output":
            return try output(thread: id, id: parts[1], sessions: sessions, page: parsed.page, uri: uri)
        case ["reasoning"]:
            return try json(reasoningList(id, sessions: sessions, page: parsed.page), uri: uri)
        case let parts where parts.count == 2 && parts[0] == "reasoning":
            return try reasoning(thread: id, id: parts[1], sessions: sessions, uri: uri)
        case ["audit"]:
            let events = try session.introspection.audit(AuditQuery(sessions: Set(sessions)))
            return try json(
                Self.pagedEvents(
                    events, page: parsed.page, limit: parsed.limit ?? Self.auditEventsPerPage,
                    base: ToolCatalog.threadURI(id) + "/audit"), uri: uri)
        case let parts where parts.first == "facts" && parts.count <= 2:
            return try json(
                await readFacts(
                    thread: id, fact: parts.count == 2 ? parts[1] : nil, page: parsed.page, all: parsed.all),
                uri: uri)
        case ["summary"]:
            return try json(await readSummary(thread: id, all: parsed.all), uri: uri)
        case let parts where parts.first == "context":
            return try await readContext(thread: id, Array(parts.dropFirst()), page: parsed.page, uri: uri)
        default:
            throw MCPError.invalidParams("Unknown resource: \(uri)")
        }
    }

    /// Page `page` of `rows`, with the page count and the next page's URI under `base`.
    ///
    /// - Throws: `MCPError.invalidParams` for a page past the last.
    static func paged(
        _ rows: [JSONValue], page: Int, base: String, key: String, rowsPerPage: Int = rowsPerPage
    )
        throws -> JSONValue
    {
        let pages = max(1, (rows.count + rowsPerPage - 1) / rowsPerPage)
        guard page <= pages else { throw MCPError.invalidParams("page \(page) of \(pages)") }
        let slice = rows.dropFirst((page - 1) * rowsPerPage).prefix(rowsPerPage)
        return .object([
            key: .array(Array(slice)), "page": .int(page), "pages": .int(pages), "total": .int(rows.count),
            "next": page < pages ? .string("\(base)?page=\(page + 1)") : .null,
        ])
    }

    /// Page `page` of `events`, oldest first, `limit` to a page, as `events`, with `page`, `pages`, `total`,
    /// `next`, and `last` (the newest page's URI), each event as the audit file holds it.
    ///
    /// - Throws: `MCPError.invalidParams` for a page past the last.
    static func pagedEvents(_ events: [AuditEvent], page: Int, limit: Int, base: String) throws -> JSONValue {
        let rows = try events.map { event -> JSONValue in
            try JSONDecoder().decode(JSONValue.self, from: AuditEvent.encoder.encode(event))
        }
        let pages = max(1, (rows.count + limit - 1) / limit)
        guard page <= pages else { throw MCPError.invalidParams("page \(page) of \(pages)") }
        let slice = rows.dropFirst((page - 1) * limit).prefix(limit)
        let query = limit == auditEventsPerPage ? "" : "&limit=\(limit)"
        return .object([
            "events": .array(Array(slice)), "page": .int(page), "pages": .int(pages), "total": .int(rows.count),
            "limit": .int(limit), "next": page < pages ? .string("\(base)?page=\(page + 1)\(query)") : .null,
            "last": .string("\(base)?page=\(pages)\(query)"),
        ])
    }

    /// `wisp://threads`: the threads this client may open, most recently active first: this server's, open or not,
    /// and those saved in the thread store under this client's name (ADR 0066, D8). `state` is `open`, `saved`,
    /// `open elsewhere` (another process holds it), `closed`, or `evicted` (dropped from memory and not saved).
    private func threadList(page: Int) async throws -> JSONValue {
        let live = Set(await threads.ids)
        let owner = clientName
        var rows: [(lastActive: Date, id: String, row: JSONValue)] = []
        var listed: Set<String> = []
        for record in directory.all {
            listed.insert(record.id)
            let saved = live.contains(record.id) ? nil : try? threadStore.settings(record.id)
            let state = live.contains(record.id) ? "open" : saved.map { savedState($0) } ?? record.state.rawValue
            rows.append(
                (
                    record.lastActive, record.id,
                    threadRow(
                        id: record.id, auditSession: record.auditSession, model: record.model, think: record.think,
                        turns: record.turns, created: record.created, lastActive: record.lastActive, state: state,
                        owner: record.owner ?? owner)
                ))
        }
        for settings in threadStore.all where settings.owner == owner && !listed.contains(settings.id) {
            rows.append(
                (
                    settings.lastUsed, settings.id,
                    threadRow(
                        id: settings.id, auditSession: settings.sessions.last ?? settings.id, model: settings.model,
                        think: settings.think, turns: settings.turns, created: settings.created,
                        lastActive: settings.lastUsed, state: savedState(settings), owner: settings.owner)
                ))
        }
        let sorted = rows.sorted { ($0.lastActive, $0.id) > ($1.lastActive, $1.id) }.map(\.row)
        return try Self.paged(sorted, page: page, base: ToolCatalog.threadsResourceURI, key: "threads")
    }

    /// `saved`, or `open elsewhere` when another process holds the saved thread.
    private func savedState(_ settings: ThreadStore.Settings) -> String {
        threadStore.holder(of: settings.id) == nil ? "saved" : "open elsewhere"
    }

    /// One row of `wisp://threads`.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - auditSession: Its latest audit session.
    ///   - model: Its model.
    ///   - think: Its thinking.
    ///   - turns: Its turns.
    ///   - created: When it was created.
    ///   - lastActive: When it was last used.
    ///   - state: Its state.
    ///   - owner: Its owner.
    /// - Returns: The row.
    private func threadRow(
        id: String, auditSession: String, model: String?, think: String?, turns: Int, created: Date, lastActive: Date,
        state: String, owner: String
    ) -> JSONValue {
        .object([
            "thread_id": .string(id), "auditSession": .string(auditSession),
            "model": model.map { .string($0) } ?? .null, "think": think.map { .string($0) } ?? .null,
            "turns": .int(turns), "created": .string(created.ISO8601Format()),
            "lastActive": .string(lastActive.ISO8601Format()), "state": .string(state), "owner": .string(owner),
            "uri": .string(ToolCatalog.threadURI(id)),
        ])
    }

    /// `wisp://threads/{thread_id}`: one thread's summary and the URIs of what can be read about it; a thread saved in
    /// the thread store is summarised from its `thread.json` (ADR 0066).
    private func threadSummary(_ id: String) async throws -> JSONValue {
        let live = await threads.peek(id)
        let saved = live == nil && ThreadStore.isValid(id) ? try? threadStore.settings(id) : nil
        if let saved, saved.owner != clientName {
            throw MCPError.invalidParams(
                ThreadStore.Failure.owned(id, owner: saved.owner, client: clientName).description)
        }
        let record = directory.record(id)
        guard record != nil || saved != nil else {
            throw MCPError.invalidParams("no thread \(id) on this server; wisp://threads lists them")
        }
        let settings = live?.kept?.settings ?? saved
        let state = live != nil ? "open" : saved.map { savedState($0) } ?? record?.state.rawValue ?? "saved"
        let sessions = await auditSessions(of: id)
        let base = ToolCatalog.threadURI(id)
        // The model's questions to the person (ADR 0062), waiting and settled, while the thread is open.
        let questions = live?.inquiries.records.map(\.json) ?? []
        let created = record?.created ?? saved?.created ?? Date()
        let lastActive = record?.lastActive ?? saved?.lastUsed ?? created
        return .object([
            "thread_id": .string(id), "auditSession": .string(record?.auditSession ?? sessions.last ?? id),
            "sessions": .array(sessions.map { .string($0) }),
            "owner": .string(settings?.owner ?? record?.owner ?? clientName),
            "model": (record?.model ?? settings?.model).map { .string($0) } ?? .null,
            "think": (record?.think ?? settings?.think).map { .string($0) } ?? .null,
            "tools": .array((record?.tools ?? settings?.tools ?? []).map { .string($0) }),
            "instructions": .bool(record?.instructions ?? (settings?.instructions != nil)),
            "turns": .int(record?.turns ?? settings?.turns ?? 0), "created": .string(created.ISO8601Format()),
            "lastActive": .string(lastActive.ISO8601Format()), "state": .string(state),
            "task": await threadTask(id),
            "questions": .array(questions),
            "resources": .object([
                "context": .string(base + "/context"), "contextNext": .string(base + "/context/next"),
                "facts": .string(base + "/facts"), "summary": .string(base + "/summary"),
                "sessionFacts": .string(ToolCatalog.sessionFactsResourceURI),
                "permanentFacts": .string(ToolCatalog.factsResourceURI),
                "proposedFacts": .string(ToolCatalog.proposedFactsResourceURI),
                "output": .string(base + "/output"), "reasoning": .string(base + "/reasoning"),
                "audit": .string(base + "/audit"),
            ]),
        ])
    }

    /// The output store of audit session `session`, where a thread's tools kept outputs past the budget in that
    /// opening.
    private func outputStore(ofSession session: String) -> OutputStore {
        OutputStore(directory: self.session.home.outputs.appending(path: session, directoryHint: .isDirectory))
    }

    /// `wisp://threads/{thread_id}/output`: the thread's tool calls, oldest first, from the audit log, over every
    /// opening (`session` says which; turns are numbered per opening); a call whose output was kept whole in the output
    /// store says so (`stored`, its size in `storedBytes`).
    private func outputList(_ id: String, sessions: [String], page: Int) throws -> JSONValue {
        let all = try session.introspection.audit(AuditQuery(sessions: Set(sessions)))
        var rows: [JSONValue] = []
        for opening in sessions {
            let events = all.filter { $0.session == opening }
            let turns = Set(events.compactMap(\.turn)).sorted()
            let store = outputStore(ofSession: opening)
            for turn in turns {
                for call in TurnCalls(events: events, turn: turn).calls {
                    var row: [String: JSONValue] = [
                        "session": .string(opening), "turn": .int(turn), "tool": .string(call.tool),
                        "arguments": .string(call.arguments), "id": call.id.map { .string($0) } ?? .null,
                        "bytes": call.bytes.map { .int($0) } ?? .null,
                        "uri": call.id.map { .string(ToolCatalog.outputURI(thread: id, id: $0)) } ?? .null,
                    ]
                    if let command = call.command { row["command"] = .string(command) }
                    if let status = call.exitStatus { row["exitStatus"] = .int(status) }
                    if let error = call.error { row["error"] = .string(error) }
                    if let callID = call.call, let kept = store.kept(callID) {
                        row["stored"] = .string(callID)
                        row["storedBytes"] = .int(kept.bytes)
                        row["storedLines"] = .int(kept.lines)
                    }
                    rows.append(.object(row))
                }
            }
        }
        return try Self.paged(rows, page: page, base: ToolCatalog.threadURI(id) + "/output", key: "calls")
    }

    /// `wisp://threads/{thread_id}/output/{id}`: one output verbatim: the whole output from the output store when
    /// the model saw only part of it, paged at `Paging.pageBytes` with `?page=N`; else what the tool returned, from
    /// the audit log.
    private func output(
        thread: String, id: String, sessions: [String], page: Int, uri: String
    ) throws -> ReadResource.Result {
        guard Self.isEventID(Substring(id)) else {
            throw MCPError.invalidParams(
                "expected wisp://threads/{thread_id}/output/{id} with an id from a respond result")
        }
        guard
            let event = try session.introspection.audit(AuditQuery(kinds: [.toolResult], sessions: Set(sessions))).last(
                where: { $0.id == id })
        else {
            throw MCPError.invalidParams(
                "no tool output \(id) in thread \(thread)\(config.auditEnabled ? "" : "; audit.enabled is false")")
        }
        let text: String
        if let call = event.call, let whole = outputStore(ofSession: event.session).text(call) {
            text = whole
        } else {
            text = event.details["output"]?.stringValue ?? ""
        }
        guard let shown = Paging.page(text, number: page) else {
            throw MCPError.invalidParams("page \(page) is past the last")
        }
        let base = ToolCatalog.outputURI(thread: thread, id: id)
        let head =
            shown.count > 1
            ? "(page \(page) of \(shown.count)"
                + (page < shown.count ? "; the next is \(base)?page=\(page + 1))\n" : ")\n")
            : ""
        return .init(contents: [.text(head + shown.text, uri: uri, mimeType: "text/plain")])
    }

    /// The `model.reasoning` events of `thread` that ended a stretch of thinking (ADR 0053), oldest first.
    private func thoughts(_ sessions: [String]) throws -> [AuditEvent] {
        try session.introspection.audit(AuditQuery(kinds: [.modelReasoning], sessions: Set(sessions))).filter {
            $0.details["phase"]?.stringValue == "end"
        }
    }

    /// `wisp://threads/{thread_id}/reasoning`: each stretch of the model's thinking, oldest first, from the audit log.
    private func reasoningList(_ id: String, sessions: [String], page: Int) throws -> JSONValue {
        let rows = try thoughts(sessions).map { event -> JSONValue in
            .object([
                "session": .string(event.session), "turn": event.turn.map { .int($0) } ?? .null,
                "id": event.id.map { .string($0) } ?? .null,
                "tokens": event.details["tokens"] ?? .null, "seconds": event.details["seconds"] ?? .null,
                "bytes": event.details["bytes"] ?? .null,
                "uri": event.id.map { .string(ToolCatalog.reasoningURI(thread: id, id: $0)) } ?? .null,
            ])
        }
        return try Self.paged(rows, page: page, base: ToolCatalog.threadURI(id) + "/reasoning", key: "reasoning")
    }

    /// `wisp://threads/{thread_id}/reasoning/{id}`: one stretch of thinking verbatim, from the audit log.
    private func reasoning(thread: String, id: String, sessions: [String], uri: String) throws -> ReadResource.Result {
        guard Self.isEventID(Substring(id)) else {
            throw MCPError.invalidParams("expected wisp://threads/{thread_id}/reasoning/{id} with an id from its list")
        }
        guard let event = try thoughts(sessions).last(where: { $0.id == id }) else {
            throw MCPError.invalidParams(
                "no thinking \(id) in thread \(thread)\(config.auditEnabled ? "" : "; audit.enabled is false")")
        }
        return .init(contents: [.text(event.details["text"]?.stringValue ?? "", uri: uri, mimeType: "text/plain")])
    }
}
