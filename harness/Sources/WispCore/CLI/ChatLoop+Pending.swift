import Foundation

extension ChatLoop {
    /// Notes, before the prompt, the requests that began or stopped waiting in `wisp mcp` servers since the last look
    /// (`ChatPending`); nothing when nothing changed, or when this face has no watcher.
    func notePending() {
        for line in context.pending?.notes(style: style) ?? [] { io.note(line) }
    }

    /// `/approvals pending`, `/approvals approve`, and `/approvals deny`: what waits in `wisp mcp` servers, and the
    /// person's answer to a command among it (ADR 0046).
    ///
    /// - Parameter request: What was asked.
    func waiting(_ request: ApprovalsRequest) async {
        guard let pending = context.pending else { return io.note(Self.notWatched) }
        switch request {
        case .pending:
            let waiting = pending.waiting()
            guard !waiting.isEmpty else { return io.note("nothing waits in wisp mcp servers") }
            let width = context.width()
            let commands = waiting.filter { $0.kind == .command }
            let facts = waiting.filter { $0.kind == .fact }
            if !commands.isEmpty {
                for line in ListingLayout.pending(commands, width: width ?? 120) { io.print(line) }
            }
            if !facts.isEmpty {
                if !commands.isEmpty { io.print("") }
                for line in ListingLayout.factRequests(facts, width: width ?? 120) { io.print(line) }
            }
        case .approve(let id, let scope):
            await answer(id, kind: .command, decision: scope.rawValue, title: "Which command is approved?")
        case .deny(let id):
            await answer(id, kind: .command, decision: "no", title: "Which command is refused?")
        case .list, .revoke, .unknown:
            break
        }
    }

    /// `/facts`: the facts waiting to be kept, or the person's answer to one (ADR 0048).
    ///
    /// - Parameter request: What was asked.
    func pendingFacts(_ request: PendingFactsRequest) async {
        guard let pending = context.pending else { return io.note(Self.notWatched) }
        switch request {
        case .pending:
            let facts = pending.waiting(.fact)
            guard !facts.isEmpty else { return io.note("no facts waiting to be kept") }
            for line in ListingLayout.factRequests(facts, width: context.width() ?? 120) { io.print(line) }
        case .keep(let id):
            await answer(id, kind: .fact, decision: "keep", title: "Which fact is kept as a permanent fact?")
        case .drop(let id):
            await answer(id, kind: .fact, decision: "drop", title: "Which fact stays in its thread?")
        case .unknown(let words):
            io.note("unknown /facts \(words); \(PendingFactsRequest.usage)")
        }
    }

    /// What a face without a watcher says: `wisp-tui` shows waiting requests in its own dialog.
    static var notWatched: String {
        "waiting requests are not shown here; answer them in wisp-tui's dialog, or with wisp approvals or "
            + "wisp facts from a terminal"
    }

    /// Writes the person's answer to a waiting request, chosen from those waiting when no id was given, and notes how
    /// it went.
    ///
    /// - Parameters:
    ///   - id: The request, or nil to choose one of `kind`.
    ///   - kind: The kind to choose from.
    ///   - decision: The answer.
    ///   - title: The question when choosing.
    private func answer(_ id: String?, kind: PendingApprovals.Kind, decision: String, title: String) async {
        guard let pending = context.pending else { return io.note(Self.notWatched) }
        var chosen = id
        if chosen == nil {
            let waiting = pending.waiting(kind)
            guard !waiting.isEmpty else {
                return io.note(kind == .fact ? "no facts waiting to be kept" : "no commands waiting for approval")
            }
            let options = waiting.map { request in
                ChatChoice.Option(
                    value: request.id, label: request.subject,
                    detail: ChatPending.describe(request).replacingOccurrences(of: "⚠ ", with: ""))
            }
            chosen = await ask(ChatChoice(title: title, options: options))
        }
        guard let chosen else { return io.note("left as it was") }
        switch await pending.answer(chosen, decision: decision, audit: agent.audit) {
        case .printed(let line): io.note(line)
        case .usage(let message), .failed(let message): io.note(style.ember(message))
        }
    }
}
