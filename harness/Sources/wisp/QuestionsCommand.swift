import ArgumentParser
import Darwin
import Foundation
import WispCore

/// `wisp questions`: the model's questions waiting under `wisp mcp`, and the person's answer to each
/// ([ADR 0062](../../../docs/decisions/0062-the-inquiry-verb.md)). Only the person answers; the calling agent
/// cannot, and `answer` and `decline` run only from a terminal. `answer` prompts for the text, so an answer never
/// lands in the shell's history or in `ps`.
struct QuestionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "questions",
        abstract: "Answer the model's questions waiting under wisp mcp.",
        discussion:
            "A model running under wisp mcp with the ask tool may ask you one question mid-turn. The question waits in "
            + "~/.wisp/pending until you answer it, and a notification names it. 'pending' lists the questions; "
            + "'answer' shows one and prompts for your answer (a number or an option for a choice, a line of text "
            + "otherwise); 'decline' sends none. Both run only from a terminal; a running wisp-tui shows the same "
            + "questions. Your answer goes to the model, and the agent that called wisp can read the thread.",
        subcommands: [Pending.self, Answer.self, Decline.self],
        defaultSubcommand: Pending.self)

    /// Lists the questions waiting, removing stale requests first.
    struct Pending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the model's questions waiting in wisp mcp servers.")

        func run() async throws {
            let channel = PendingApprovals(home: Wisp.home)
            QuestionsCommand.sweep(channel)
            let requests = channel.waiting(.question)
            guard !requests.isEmpty else {
                print("no questions waiting")
                return
            }
            for line in ListingLayout.questions(requests, width: TerminalTable.detectWidth()) { print(line) }
        }
    }

    /// Answers one question, prompting for the answer.
    struct Answer: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Answer one of the model's questions, from a terminal; the answer is typed at a prompt.")

        @Argument(
            help: "The id shown by 'wisp questions pending' and in the notification.",
            completion: DynamicCompletions.pendingQuestions)
        var id: String

        func run() async throws {
            try QuestionsCommand.answer(id)
        }
    }

    /// Declines one question: the model is told to say what it needed.
    struct Decline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Decline to answer one of the model's questions.")

        @Argument(
            help: "The id shown by 'wisp questions pending' and in the notification.",
            completion: DynamicCompletions.pendingQuestions)
        var id: String

        func run() async throws {
            try QuestionsCommand.write(id, decision: "decline", text: nil)
        }
    }

    /// Removes stale requests and records each question among them as withdrawn, under a session of its own.
    static func sweep(_ channel: PendingApprovals) {
        let removed = channel.sweep().filter { $0.kind == .question }
        guard !removed.isEmpty, let session = try? Wisp.begin(.init(entryPoint: .questions)) else { return }
        for request in removed {
            if let question = request.asked {
                session.audit.record(
                    .inquirySettled,
                    details: AuditEvent.Details.inquirySettled(
                        question, outcome: .withdrawn, via: nil, delivered: nil, redacted: [],
                        reason: "its server stopped or its wait expired; removed by a sweep"))
            }
        }
        session.end()
    }

    /// Shows question `id` and prompts for the person's answer, then writes it. Only from a terminal.
    ///
    /// - Throws: A validation error when not at a terminal, or `ExitCode.failure` as `write` does.
    static func answer(_ id: String) throws {
        try requireTerminal()
        let channel = PendingApprovals(home: Wisp.home)
        sweep(channel)
        let request: PendingApprovals.Request
        do {
            request = try channel.request(id: id)
        } catch let failure as PendingApprovals.Failure {
            try Approvals.end(PendingAnswer.ending(for: failure))
            return
        }
        guard let question = request.asked else {
            try Approvals.end(PendingAnswer.ending(for: .otherKind(id, request.kind)))
            return
        }
        let style = Style.detect(isTerminal: isatty(FileHandle.standardError.fileDescriptor) != 0)
        let from = [request.client, request.thread.map { "thread \($0)" }].compactMap(\.self).joined(separator: ", ")
        var shown = Question(
            id: question.id, text: question.text, options: question.options, thread: from.isEmpty ? nil : from)
        shown.timeout = question.timeout
        FileHandle.standardError.write(Data(TerminalAsker.render(shown, style: style).utf8))
        var outcome: Question.Outcome?
        for _ in 0..<3 {
            let line = readLine()
            guard let found = question.outcome(typed: line) else {
                FileHandle.standardError.write(
                    Data(
                        (style.muted("  type a number from 1 to \(question.options.count + 1)") + " "
                            + style.prompt("›") + " ").utf8))
                continue
            }
            outcome = found
            break
        }
        switch outcome ?? .declined {
        case .answered(let text): try write(id, decision: "answer", text: text)
        case .chose(let text): try write(id, decision: "chose", text: text)
        case .noneOfThese: try write(id, decision: "none", text: nil)
        default:
            Wisp.note("no answer written; wisp questions decline \(id) declines it")
        }
    }

    /// Refuses to run without a terminal on standard input, which an agent's shell tool does not give.
    private static func requireTerminal() throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError(
                "wisp questions answer and decline answer for the person, so they run only from a terminal; "
                    + "answer in the terminal, or in wisp-tui")
        }
    }

    /// Writes the person's answer to question `id` and reports whether the waiting server took it.
    ///
    /// - Throws: A validation error when not at a terminal; `ExitCode.failure` when the request cannot be answered
    ///   or the answer came too late (`PendingAnswer`).
    static func write(_ id: String, decision: String, text: String?) throws {
        try requireTerminal()
        let channel = PendingApprovals(home: Wisp.home)
        sweep(channel)
        let session = try Wisp.begin(.init(entryPoint: .questions))
        defer { session.end() }
        let request: PendingApprovals.Request
        do {
            request = try channel.answer(id, decision: decision, text: text, via: "cli")
        } catch let failure as PendingApprovals.Failure {
            session.audit.record(
                .inquiryAnswered,
                details: AuditEvent.Details.inquiryAnswered(id, via: "cli", delivery: "refused", reason: "\(failure)"))
            try Approvals.end(PendingAnswer.ending(for: failure))
            return
        }
        // The server looks every 200 ms; give it a few seconds to take the answer.
        var delivery = channel.delivery(of: id)
        for _ in 0..<15 where delivery == .waiting {
            usleep(200_000)
            delivery = channel.delivery(of: id)
        }
        let delivered: String =
            switch delivery {
            case .taken: "taken"
            case .tooLate: "too-late"
            case .waiting: "waiting"
            }
        session.audit.record(
            .inquiryAnswered, details: AuditEvent.Details.inquiryAnswered(id, via: "cli", delivery: delivered))
        try Approvals.end(PendingAnswer.ending(of: request, decision: decision, delivery: delivery))
    }
}
