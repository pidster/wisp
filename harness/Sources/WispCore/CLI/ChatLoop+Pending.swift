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
            let questions = waiting.filter { $0.kind == .question }
            if !commands.isEmpty {
                for line in ListingLayout.pending(commands, width: width ?? 120) { io.print(line) }
            }
            if !facts.isEmpty {
                if !commands.isEmpty { io.print("") }
                for line in ListingLayout.factRequests(facts, width: width ?? 120) { io.print(line) }
            }
            if !questions.isEmpty {
                if !commands.isEmpty || !facts.isEmpty { io.print("") }
                for line in ListingLayout.questions(questions, width: width ?? 120) { io.print(line) }
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

    /// `/questions`: the model's questions waiting in `wisp mcp` servers, or the person's answer to one (ADR 0062).
    /// `answer` shows the question and reads the answer at a prompt, as `wisp questions answer` does, so it is never
    /// part of a typed command line; under `wisp-tui`, whose picker shows the question already, it points there.
    ///
    /// - Parameter request: What was asked.
    func questions(_ request: QuestionsRequest) async {
        guard let pending = context.pending else { return io.note(Self.notWatched) }
        switch request {
        case .pending:
            let questions = pending.waiting(.question)
            guard !questions.isEmpty else { return io.note("no questions waiting") }
            for line in ListingLayout.questions(questions, width: context.width() ?? 120) { io.print(line) }
        case .answer(let id):
            guard pending.canAnswer else {
                return io.note(
                    style.ember(
                        "this chat's input is not a terminal, so it does not answer for the person; answer in "
                            + "wisp-tui, or with wisp questions answer from a terminal"))
            }
            guard pending.shows else {
                return io.note(
                    "the question is open in wisp-tui's picker; answer it there, or decline it with /questions decline")
            }
            guard let chosen = await choose(id, kind: .question, title: "Which question is answered?") else { return }
            await answerQuestion(chosen, pending: pending)
        case .decline(let id):
            guard let chosen = await choose(id, kind: .question, title: "Which question is declined?") else { return }
            await settle(chosen, decision: "decline", text: nil, pending: pending)
        case .unknown(let words):
            io.note("unknown /questions \(words); \(QuestionsRequest.usage)")
        }
    }

    /// Shows question `id` and reads the person's answer at the prompt: a number or an option for a choice, asked
    /// again up to three times; a line of text otherwise; an empty line writes nothing.
    ///
    /// - Parameters:
    ///   - id: The question's request.
    ///   - pending: The watcher.
    private func answerQuestion(_ id: String, pending: ChatPending) async {
        let request: PendingApprovals.Request
        do {
            request = try pending.channel.request(id: id)
        } catch {
            let failure = error as? PendingApprovals.Failure ?? .io("\(error)")
            return note(PendingAnswer.ending(for: failure))
        }
        guard let question = request.asked else {
            return note(PendingAnswer.ending(for: .otherKind(id, request.kind)))
        }
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self).joined(separator: ", ")
        var shown = Question(
            id: question.id, text: question.text, options: question.options, thread: from.isEmpty ? nil : from)
        shown.timeout = question.timeout
        io.write(TerminalAsker.render(shown, style: style))
        var outcome: Question.Outcome?
        for _ in 0..<3 {
            if let found = question.outcome(typed: io.readLine()) {
                outcome = found
                break
            }
            io.write(
                style.muted("  type a number from 1 to \(question.options.count + 1)") + " " + style.prompt("›") + " ")
        }
        switch outcome ?? .declined {
        case .answered(let text): await settle(id, decision: "answer", text: text, pending: pending)
        case .chose(let text): await settle(id, decision: "chose", text: text, pending: pending)
        case .noneOfThese: await settle(id, decision: "none", text: nil, pending: pending)
        default: io.note("no answer written; /questions decline \(id) declines it")
        }
    }

    /// What a face without a watcher says: `wisp-tui` shows waiting requests in its own dialog.
    static var notWatched: String {
        "waiting requests are not shown here; answer them in wisp-tui's dialog, or with wisp approvals, "
            + "wisp facts, or wisp questions from a terminal"
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
        guard let chosen = await choose(id, kind: kind, title: title) else { return }
        await settle(chosen, decision: decision, text: nil, pending: pending)
    }

    /// The request to answer: `id`, or one of `kind` chosen from those waiting when no id was given; nil, with a note
    /// saying why, when none is chosen.
    ///
    /// - Parameters:
    ///   - id: The request, or nil to choose one of `kind`.
    ///   - kind: The kind to choose from.
    ///   - title: The question when choosing.
    /// - Returns: The id, or nil.
    private func choose(_ id: String?, kind: PendingApprovals.Kind, title: String) async -> String? {
        if let id { return id }
        guard let pending = context.pending else {
            io.note(Self.notWatched)
            return nil
        }
        let waiting = pending.waiting(kind)
        guard !waiting.isEmpty else {
            let none =
                switch kind {
                case .command: "no commands waiting for approval"
                case .fact: "no facts waiting to be kept"
                case .question: "no questions waiting"
                }
            io.note(none)
            return nil
        }
        let options = waiting.map { request in
            ChatChoice.Option(
                value: request.id, label: request.subject,
                detail: String(ChatPending.describe(request).drop { $0 != " " }.dropFirst()))
        }
        guard let chosen = await ask(ChatChoice(title: title, options: options)) else {
            io.note("left as it was")
            return nil
        }
        return chosen
    }

    /// Writes the answer and notes how it went.
    ///
    /// - Parameters:
    ///   - id: The request.
    ///   - decision: The answer.
    ///   - text: A question's answer text.
    ///   - pending: The watcher.
    private func settle(_ id: String, decision: String, text: String?, pending: ChatPending) async {
        note(await pending.answer(id, decision: decision, text: text, audit: agent.audit))
    }

    /// Notes how an answer ended: a line, or in ember why it was not used.
    ///
    /// - Parameter ending: How it ended.
    private func note(_ ending: PendingAnswer.Ending) {
        switch ending {
        case .printed(let line): io.note(line)
        case .usage(let message), .failed(let message): io.note(style.ember(message))
        }
    }
}
