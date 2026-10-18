import Foundation
import FoundationModels
import MCP
import WispCore

/// A thread saved in the thread store and not open in this server, read from its files without loading a model
/// (ADR 0066, D8): its facts and running summary, from its saved record. What a resumed thread does not carry (D9),
/// such as session facts and the contexts of earlier turns, it does not show either.
struct SavedThread: RespondingThread {
    /// Why a saved thread cannot answer a prompt.
    enum Failure: Error, CustomStringConvertible, Equatable {
        /// It is not open; `respond` resumes it.
        case notOpen(String)

        /// Human-readable explanation.
        var description: String {
            switch self {
            case .notOpen(let id): "thread \(id) is saved, not open; respond resumes it"
            }
        }
    }

    /// The thread's id.
    let id: String
    /// Its store, rebuilt from its saved record.
    let record: ThreadRecord
    /// The permanent facts it would see when resumed; nil when facts are off.
    let permanent: [Fact]?

    /// Refused: a saved thread answers once `respond` resumes it.
    ///
    /// - Throws: `Failure.notOpen`.
    func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply { throw Failure.notOpen(id) }

    /// The permanent facts and the thread's own, in any state; nil when facts are off.
    func facts() async -> [Fact]? { permanent.map { $0 + record.facts.facts } }

    /// The running summary's versions; nil when facts are off.
    func summaries() async -> [RunningSummary]? { permanent == nil ? nil : record.summaries }
}

extension WispServer {
    /// The store of thread `id` when it is saved and this server does not hold it, for reading; nil when it is not
    /// saved (ADR 0066, D8).
    ///
    /// - Parameter id: The thread.
    /// - Returns: The store, or nil.
    /// - Throws: `MCPError.invalidParams` for another client's thread or one whose files cannot be read.
    func savedRecord(_ id: String) throws -> ThreadRecord? {
        guard ThreadStore.isValid(id) else { return nil }
        do {
            guard let settings = try threadStore.settings(id) else { return nil }
            guard settings.owner == clientName else {
                throw ThreadStore.Failure.owned(id, owner: settings.owner, client: clientName)
            }
            return try threadStore.record(id)
        } catch let failure as ThreadStore.Failure {
            throw MCPError.invalidParams(failure.description)
        }
    }

    /// The thread `id` to read about: the live one, or the saved one from its files; nil when neither is there.
    ///
    /// - Parameter id: The thread.
    /// - Returns: The thread, or nil.
    /// - Throws: As `savedRecord(_:)`.
    func viewedThread(_ id: String) async throws -> (any RespondingThread)? {
        if let open = await threads.peek(id) { return open.thread }
        guard let record = try savedRecord(id) else { return nil }
        return SavedThread(
            id: id, record: record, permanent: config.factsEnabled ? session.permanentFacts.facts : nil)
    }

    /// The audit sessions of thread `id`, oldest first: every opening its `thread.json` records, when it is live here
    /// or saved and this client's; the directory's one session otherwise, as for a closed thread (ADR 0066, D7).
    ///
    /// - Parameter id: The thread.
    /// - Returns: The sessions.
    func auditSessions(of id: String) async -> [String] {
        if let kept = await threads.peek(id)?.kept { return kept.settings.sessions }
        if ThreadStore.isValid(id), let settings = try? threadStore.settings(id), settings.owner == clientName {
            return settings.sessions
        }
        return [directory.auditSession(of: id)]
    }

    /// `wisp://threads/{thread_id}/context[/…]` for a saved thread: no turns listed, since the contexts of earlier
    /// turns did not carry over (D9), and `next`, the record as a resumed turn's request would carry it before the
    /// facts it adds.
    ///
    /// - Parameters:
    ///   - id: The thread.
    ///   - record: Its store.
    ///   - parts: The path after `context`.
    ///   - page: The page asked for.
    ///   - uri: The URI read.
    /// - Returns: The contents.
    /// - Throws: `MCPError.invalidParams` for a turn, or a page out of range.
    func savedContext(
        thread id: String, record: ThreadRecord, _ parts: [String], page: Int, uri: String
    ) throws -> ReadResource.Result {
        let base = ToolCatalog.threadURI(id) + "/context"
        switch parts {
        case []:
            var listing = try Self.paged([], page: page, base: base, key: "turns").objectValue ?? [:]
            listing["next_request"] = .string(base + "/next")
            listing["saved"] = .bool(true)
            return .init(
                contents: [.text(Introspection.render(.object(listing)), uri: uri, mimeType: "application/json")])
        case ["next"]:
            let composition = ContextComposer(policy: .target(config.contextTarget)).composition(record, atTurn: nil)
            let text = ContextView.markdown(
                composition, title: "The context a resumed turn of saved thread \(id) carries, before its facts")
            guard let shown = Paging.page(text, number: page) else {
                throw MCPError.invalidParams("page \(page) is past the last")
            }
            let head =
                shown.count > 1
                ? "(page \(page) of \(shown.count)"
                    + (page < shown.count ? "; the next is \(base)/next?page=\(page + 1))\n\n" : ")\n\n")
                : ""
            return .init(contents: [.text(head + shown.text, uri: uri, mimeType: "text/markdown")])
        default:
            throw MCPError.invalidParams(
                "thread \(id) is saved, and the contexts of its earlier turns did not carry over; \(base)/next shows "
                    + "what a resumed turn carries")
        }
    }
}
