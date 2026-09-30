import Foundation
import MCP
import WispCore

/// The model's context of a live `respond` thread, viewable at no cost to the model (decision D12 of the
/// layered-context proposal): `wisp://threads/{thread_id}/context` lists the thread's turns with what
/// changed at each, `…/context/{turn}` is the context composed at the start of that turn, and
/// `…/context/next` the one the next request carries, which is what chat's `/inspect context` saves.
/// The contexts are Markdown, paged at `Paging.pageBytes` with `?page=N`.
extension WispServer {
    /// Serves `wisp://threads/{thread_id}/context[/…]`.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - parts: The path after `context`: empty, `next`, or a turn number.
    ///   - page: The page asked for.
    ///   - uri: The URI read.
    /// - Returns: The contents.
    /// - Throws: `MCPError.invalidParams` for a thread that is not open, a turn it cannot show, or a page out
    ///   of range.
    func readContext(
        thread id: String, _ parts: [String], page: Int, uri: String
    ) async throws
        -> ReadResource.Result
    {
        guard let open = await threads.peek(id) else {
            if let record = directory.record(id) {
                throw MCPError.invalidParams(
                    "thread \(id) is \(record.state.rawValue); its context went with it, and its output and audit "
                        + "remain under \(ToolCatalog.threadURI(id))")
            }
            throw MCPError.invalidParams("no thread \(id) on this server; wisp://threads lists them")
        }
        let base = ToolCatalog.threadURI(id) + "/context"
        switch parts {
        case []:
            guard let turns = await open.thread.contextTurns() else {
                throw MCPError.invalidParams("thread \(id) cannot show its context")
            }
            let rows = turns.map { turn -> JSONValue in
                .object([
                    "turn": .int(turn.number), "time": turn.time.map { .string($0.ISO8601Format()) } ?? .null,
                    "prompt": .string(turn.prompt), "tokens": .int(turn.tokens),
                    "changed": .object([
                        "condensed": .int(turn.condensed), "cut": .int(turn.cut), "referenced": .int(turn.referenced),
                    ]),
                    "uri": .string("\(base)/\(turn.number)"),
                ])
            }
            var listing = try Self.paged(rows, page: page, base: base, key: "turns").objectValue ?? [:]
            listing["next_request"] = .string(base + "/next")
            return .init(
                contents: [.text(Introspection.render(.object(listing)), uri: uri, mimeType: "application/json")])
        case let path where path.count == 1 && (path[0] == "next" || Int(path[0]) != nil):
            let which = path[0]
            guard let result = await open.thread.context(which) else {
                throw MCPError.invalidParams("thread \(id) cannot show its context")
            }
            switch result {
            case .failure(let failure):
                throw MCPError.invalidParams(failure.description)
            case .success(let view):
                guard let shown = Paging.page(view.text, number: page) else {
                    throw MCPError.invalidParams("page \(page) is past the last")
                }
                let head =
                    shown.count > 1
                    ? "(page \(page) of \(shown.count)"
                        + (page < shown.count ? "; the next is \(base)/\(which)?page=\(page + 1))\n\n" : ")\n\n")
                    : ""
                return .init(contents: [.text(head + shown.text, uri: uri, mimeType: "text/markdown")])
            }
        default:
            throw MCPError.invalidParams(
                "expected \(base), \(base)/next, or \(base)/{turn} with a turn number")
        }
    }
}
