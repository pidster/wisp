import Foundation
import MCP
import WispCore

/// The resources about `respond` threads, all under `wisp://threads` (`docs/mcp.md`, "Resources"): the
/// list of threads, one thread's summary, its tool calls and each call's output, and its audit events.
/// Collections are JSON and paged with `?page=N`; each row names the URI that reads it.
extension WispServer {
    /// Rows a collection's page holds.
    static let rowsPerPage = 50

    /// A URI under a collection's root (`wisp://threads` by default, `wisp://facts`, `wisp://session/facts`)
    /// split into its path after the root and its query.
    struct ThreadURI: Equatable {
        /// The path's segments after the root, such as `["git", "output", "8a7b…"]` under `wisp://threads`.
        var path: [String]
        /// The `page` query value, from 1; 1 when absent.
        var page: Int
        /// Whether the query says `all=true`.
        var all = false

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
        guard let id = path.first else { return try json(threadList(page: parsed.page), uri: uri) }
        guard SafeName.isValid(id) else { throw MCPError.invalidParams("thread id must be \(SafeName.rule)") }
        switch Array(path.dropFirst()) {
        case []:
            return try json(await threadSummary(id), uri: uri)
        case ["output"]:
            return try json(outputList(id, page: parsed.page), uri: uri)
        case let parts where parts.count == 2 && parts[0] == "output":
            return try output(thread: id, id: parts[1], uri: uri)
        case ["audit"]:
            let events = try session.introspection.audit(AuditQuery(session: id))
            let text = try events.map { String(decoding: try AuditEvent.encoder.encode($0), as: UTF8.self) }
                .joined(separator: "\n")
            return .init(contents: [.text(text, uri: uri, mimeType: "application/x-ndjson")])
        case let parts where parts.first == "facts" && parts.count <= 2:
            return try json(
                await readFacts(
                    thread: id, fact: parts.count == 2 ? parts[1] : nil, page: parsed.page, all: parsed.all),
                uri: uri)
        case let parts where parts.first == "context":
            return try await readContext(thread: id, Array(parts.dropFirst()), page: parsed.page, uri: uri)
        default:
            throw MCPError.invalidParams("Unknown resource: \(uri)")
        }
    }

    /// `contents` as pretty JSON at `uri`.
    private func json(_ contents: JSONValue, uri: String) throws -> ReadResource.Result {
        .init(contents: [.text(Introspection.render(contents), uri: uri, mimeType: "application/json")])
    }

    /// Page `page` of `rows`, with the page count and the next page's URI under `base`.
    ///
    /// - Throws: `MCPError.invalidParams` for a page past the last.
    static func paged(_ rows: [JSONValue], page: Int, base: String, key: String) throws -> JSONValue {
        let pages = max(1, (rows.count + rowsPerPage - 1) / rowsPerPage)
        guard page <= pages else { throw MCPError.invalidParams("page \(page) of \(pages)") }
        let slice = rows.dropFirst((page - 1) * rowsPerPage).prefix(rowsPerPage)
        return .object([
            key: .array(Array(slice)), "page": .int(page), "pages": .int(pages), "total": .int(rows.count),
            "next": page < pages ? .string("\(base)?page=\(page + 1)") : .null,
        ])
    }

    /// `wisp://threads`: the server's threads, most recently active first, open or not.
    private func threadList(page: Int) throws -> JSONValue {
        let rows = directory.all.map { record -> JSONValue in
            .object([
                "thread_id": .string(record.id), "model": record.model.map { .string($0) } ?? .null,
                "turns": .int(record.turns), "created": .string(record.created.ISO8601Format()),
                "lastActive": .string(record.lastActive.ISO8601Format()), "state": .string(record.state.rawValue),
                "uri": .string(ToolCatalog.threadURI(record.id)),
            ])
        }
        return try Self.paged(rows, page: page, base: ToolCatalog.threadsResourceURI, key: "threads")
    }

    /// `wisp://threads/{thread_id}`: one thread's summary and the URIs of what can be read about it.
    private func threadSummary(_ id: String) async throws -> JSONValue {
        guard let record = directory.record(id) else {
            throw MCPError.invalidParams("no thread \(id) on this server; wisp://threads lists them")
        }
        let base = ToolCatalog.threadURI(id)
        return .object([
            "thread_id": .string(id), "model": record.model.map { .string($0) } ?? .null,
            "tools": .array(record.tools.map { .string($0) }), "instructions": .bool(record.instructions),
            "turns": .int(record.turns), "created": .string(record.created.ISO8601Format()),
            "lastActive": .string(record.lastActive.ISO8601Format()), "state": .string(record.state.rawValue),
            "task": await threadTask(id),
            "resources": .object([
                "context": .string(base + "/context"), "contextNext": .string(base + "/context/next"),
                "facts": .string(base + "/facts"), "sessionFacts": .string(ToolCatalog.sessionFactsResourceURI),
                "permanentFacts": .string(ToolCatalog.factsResourceURI),
                "proposedFacts": .string(ToolCatalog.proposedFactsResourceURI),
                "output": .string(base + "/output"), "audit": .string(base + "/audit"),
            ]),
        ])
    }

    /// `wisp://threads/{thread_id}/output`: the thread's tool calls, oldest first, from the audit log.
    private func outputList(_ id: String, page: Int) throws -> JSONValue {
        let events = try session.introspection.audit(AuditQuery(session: id))
        let turns = Set(events.compactMap(\.turn)).sorted()
        var rows: [JSONValue] = []
        for turn in turns {
            for call in TurnCalls(events: events, turn: turn).calls {
                var row: [String: JSONValue] = [
                    "turn": .int(turn), "tool": .string(call.tool), "arguments": .string(call.arguments),
                    "id": call.id.map { .string($0) } ?? .null, "bytes": call.bytes.map { .int($0) } ?? .null,
                    "uri": call.id.map { .string(ToolCatalog.outputURI(thread: id, id: $0)) } ?? .null,
                ]
                if let command = call.command { row["command"] = .string(command) }
                if let status = call.exitStatus { row["exitStatus"] = .int(status) }
                if let error = call.error { row["error"] = .string(error) }
                rows.append(.object(row))
            }
        }
        return try Self.paged(rows, page: page, base: ToolCatalog.threadURI(id) + "/output", key: "calls")
    }

    /// `wisp://threads/{thread_id}/output/{id}`: one output verbatim, from the audit log.
    private func output(thread: String, id: String, uri: String) throws -> ReadResource.Result {
        guard Self.isEventID(Substring(id)) else {
            throw MCPError.invalidParams(
                "expected wisp://threads/{thread_id}/output/{id} with an id from a respond result")
        }
        guard
            let event = try session.introspection.audit(AuditQuery(session: thread, kinds: [.toolResult])).last(
                where: { $0.id == id })
        else {
            throw MCPError.invalidParams(
                "no tool output \(id) in thread \(thread)\(config.auditEnabled ? "" : "; audit.enabled is false")")
        }
        return .init(contents: [.text(event.details["output"]?.stringValue ?? "", uri: uri, mimeType: "text/plain")])
    }
}
