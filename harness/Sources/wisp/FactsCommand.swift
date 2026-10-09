import ArgumentParser
import Darwin
import Foundation
import WispCore

/// `wisp facts`: the facts a caller asked, over MCP, to keep as permanent facts, and the person's answer to each
/// ([ADR 0048](../../../docs/decisions/0048-permanent-facts-over-mcp.md)). Only the person admits a permanent
/// fact; the calling agent can only ask, and `keep` and `drop` answer only from a terminal.
struct FactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "facts",
        abstract: "Answer requests to keep a fact as a permanent fact.",
        discussion:
            "A caller of wisp mcp may ask for one of its thread's facts to be kept across sessions, in "
            + "~/.wisp/facts.json. Only you admit a permanent fact: the request waits in ~/.wisp/pending and a "
            + "notification names it. 'pending' lists the requests; 'keep' admits the fact as yours, and 'drop' "
            + "leaves it in its thread, where the thread does not ask about it again. Both answer only from a "
            + "terminal; a running wisp-tui shows the same requests.",
        subcommands: [Pending.self, Keep.self, Drop.self],
        defaultSubcommand: Pending.self)

    /// Lists the facts waiting to be kept, removing stale requests first.
    struct Pending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List facts wisp mcp callers asked to keep as permanent facts.")

        func run() async throws {
            let channel = PendingApprovals(home: Wisp.home)
            FactsCommand.sweep(channel)
            let requests = channel.waiting(.fact)
            guard !requests.isEmpty else {
                print("no facts waiting to be kept")
                return
            }
            for line in ListingLayout.factRequests(requests, width: TerminalTable.detectWidth()) { print(line) }
        }
    }

    /// Keeps one fact as a permanent fact.
    struct Keep: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Keep a fact as a permanent fact, as yours, from a terminal.")

        @Argument(
            help: "The id shown by 'wisp facts pending' and in the notification.",
            completion: DynamicCompletions.pendingFacts)
        var id: String

        func run() async throws {
            try FactsCommand.answer(id, decision: "keep")
        }
    }

    /// Declines one fact: it stays in its thread.
    struct Drop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Leave a fact in its thread rather than keep it; the thread does not ask again.")

        @Argument(
            help: "The id shown by 'wisp facts pending' and in the notification.",
            completion: DynamicCompletions.pendingFacts)
        var id: String

        func run() async throws {
            try FactsCommand.answer(id, decision: "drop")
        }
    }

    /// Removes stale requests and records each as settled `stale`, under a session of its own.
    static func sweep(_ channel: PendingApprovals) {
        let removed = channel.sweep()
        guard !removed.isEmpty, let session = try? Wisp.begin(.init(entryPoint: .facts)) else { return }
        for request in removed {
            session.audit.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(
                    request, outcome: "stale", reason: "its server stopped or its wait expired"))
        }
        session.end()
    }

    /// What `keep` or `drop` prints once the server has looked, or the error it fails with.
    ///
    /// - Parameters:
    ///   - request: The request answered.
    ///   - decision: `keep` or `drop`.
    ///   - delivery: What became of the answer.
    /// - Returns: The line to print, or the message of the error to raise.
    static func outcome(
        of request: PendingApprovals.Request, decision: String, delivery: PendingApprovals.Delivery
    ) -> Result<String, ValidationError> {
        let verb = decision == "keep" ? "kept as a permanent fact" : "dropped, left in its thread"
        let from = request.thread.map { " (thread \($0))" } ?? ""
        switch delivery {
        case .taken: return .success("\(verb): \(request.subject)\(from)")
        case .waiting: return .success("\(verb): \(request.subject)\(from); wisp has not read the answer yet")
        case .tooLate:
            return .failure(ValidationError("\(request.subject) stopped waiting first; your answer was not used"))
        }
    }

    /// Writes the person's answer to fact request `id` and reports whether the waiting server took it. Only
    /// from a terminal: an agent's shell, which has none, cannot answer for the person (ADR 0046's rule).
    ///
    /// - Throws: A validation error when not at a terminal or when the request cannot be answered.
    static func answer(_ id: String, decision: String) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError(
                "wisp facts keep and drop answer for the person, so they run only from a terminal; "
                    + "answer in the terminal, or in wisp-tui")
        }
        let channel = PendingApprovals(home: Wisp.home)
        sweep(channel)
        let session = try Wisp.begin(.init(entryPoint: .facts))
        defer { session.end() }
        let request: PendingApprovals.Request
        do {
            request = try channel.answer(id, decision: decision, via: "cli")
        } catch let failure as PendingApprovals.Failure {
            session.audit.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: id, try? channel.request(id: id), decision: decision, via: "cli", delivery: "refused",
                    reason: "\(failure)"))
            throw ValidationError("\(failure)")
        }
        // The server looks every 200 ms; give it a few seconds to take the answer.
        var delivery = channel.delivery(of: id)
        for _ in 0..<15 where delivery == .waiting {
            usleep(200_000)
            delivery = channel.delivery(of: id)
        }
        let text: String =
            switch delivery {
            case .taken: "taken"
            case .tooLate: "too-late"
            case .waiting: "waiting"
            }
        session.audit.record(
            .approvalAnswered,
            details: AuditEvent.Details.approvalAnswered(
                request: id, request, decision: decision, via: "cli", delivery: text))
        switch outcome(of: request, decision: decision, delivery: delivery) {
        case .success(let line): print(line)
        case .failure(let error): throw error
        }
    }
}
