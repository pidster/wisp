import Foundation
import MCP
import Synchronization
import WispCore

/// What the connected client advertised at initialize, shared between the server and its approver.
final class ClientCapabilityFlags: Sendable {
    /// Whether the client supports form elicitation.
    let elicitation = Mutex(false)
}

/// Asks the MCP client's user through elicitation.
///
/// When the client did not advertise elicitation support, denies with a
/// message that tells the calling harness how to proceed, so an unattended
/// caller never runs a risky command by accident.
struct ElicitationApprover: Approver {
    /// The running server, which owns the connection to the client.
    let server: Server
    /// What the client advertised during initialize.
    let client: ClientCapabilityFlags
    /// How long to wait for an answer before treating silence as a denial; nil waits forever.
    let timeout: Duration?

    /// Creates an approver over `server`; support is learned from the initialize hook.
    init(server: Server, client: ClientCapabilityFlags, timeout: Duration?) {
        self.server = server
        self.client = client
        self.timeout = timeout
    }

    /// Sends an elicitation with the command and reasons. Accept runs it with the chosen scope
    /// (once by default); Decline, Cancel, or silence refuses.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard client.elicitation.withLock({ $0 }) else {
            return .denied(
                "approval required (\(request.assessment.level.rawValue): "
                    + "\(request.assessment.reasons.joined(separator: "; "))) and this client does not support "
                    + "elicitation; run the command from the calling harness, or start wisp mcp with --yes to "
                    + "auto-approve, or lower approval.threshold in config.json")
        }
        // Clients render different parts of an elicitation, so the command appears in the title, the
        // message, and the description, and the scope picker's labels say exactly what each choice keeps.
        let level = request.assessment.level.rawValue
        let reasons = request.assessment.reasons.map { "- \($0)" }.joined(separator: "\n")
        let context = request.line == request.command ? "" : "\nPart of: \(request.line)"
        let text = """
            Command:
            \(request.command)\(context)

            Directory: \(request.workingDirectory)
            Risk: \(level)
            \(reasons)
            Remembered as: \(request.pattern)

            Accept runs it. Decline refuses.\(timeout.map { " No answer within \($0) counts as Decline." } ?? "")
            """
        let schema = Elicitation.RequestSchema(
            title: "wisp: approve command? (\(level) risk)",
            description: text,
            properties: [
                "scope": .object([
                    "type": .string("string"),
                    "title": .string("Remember this approval"),
                    "description": .string("How long to keep approving \(request.pattern)"),
                    "enum": .array(ApprovalScope.allCases.map { .string($0.rawValue) }),
                    "enumNames": .array([
                        .string("This turn"), .string("This session"),
                        .string("This project (30 days, this directory)"), .string("Always (30 days, any directory)"),
                    ]),
                    "default": .string("once"),
                ])
            ],
            required: []
        )
        let server = server
        do {
            let result = try await Timeout.run(timeout) {
                try await server.requestElicitation(message: text, requestedSchema: schema)
            }
            switch result.action {
            case .accept: return .approved(Self.scope(from: result.content?["scope"]))
            case .decline: return .denied("declined by the user")
            case .cancel: return .denied("cancelled by the user")
            }
        } catch Timeout.Failure.elapsed(let waited) {
            Diagnostics.mcp.info("approval unanswered: \(waited)")
            return .unanswered(waited)
        } catch {
            Diagnostics.mcp.error("elicitation failed: \(error)")
            return .denied("approval request failed: \(error)")
        }
    }

    /// Reads the optional `scope` field leniently: raw values, labels, or nothing (which means once).
    static func scope(from value: Value?) -> ApprovalScope {
        guard let text = value?.stringValue?.lowercased() else { return .once }
        if let scope = ApprovalScope(rawValue: text) { return scope }
        if text.hasPrefix("this session") { return .session }
        if text.hasPrefix("this project") { return .project }
        if text.hasPrefix("always") { return .always }
        return .once
    }
}

/// Asks the MCP client's user whether to keep a proposed permanent fact, through elicitation: the
/// fact-approval effect of the server's host (ADR 0044, amended 2026-09-30).
///
/// The dialog is fieldless, Accept or Decline, because a form picker once made Claude Code's dialog
/// unresponsive (ADR 0011). Without elicitation the server does not ask, and the proposal waits in
/// `wisp://facts/proposed`.
struct ElicitationFactApprover: FactApprover {
    /// The running server, which owns the connection to the client.
    let server: Server
    /// What the client advertised during initialize.
    let client: ClientCapabilityFlags
    /// How long to wait for an answer; nil waits forever.
    let timeout: Duration?

    /// Whether the client advertised elicitation.
    var canAsk: Bool { client.elicitation.withLock { $0 } }

    /// The dialog's text: the question, where the proposal came from, and what each answer does.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - timeout: The wait, for the note on silence.
    /// - Returns: The text.
    static func message(_ request: FactApprovalRequest, timeout: Duration?) -> String {
        let fact = request.proposal.fact
        return """
            \(request.question)

            Subject: \(fact.identity.subject)
            Conversation: \(request.proposal.conversation) (fact \(fact.id))

            Accept keeps it in ~/.wisp/facts.json as approved by you, and every later conversation is given it. \
            Decline leaves it with this conversation only, and wisp will not ask about this value again.\
            \(timeout.map { " No answer within \($0.components.seconds) seconds leaves it waiting in wisp://facts/proposed." } ?? "")
            """
    }

    /// Sends the fieldless elicitation and maps the answer; silence past the timeout is `unanswered`.
    func decide(_ request: FactApprovalRequest) async -> FactApprovalDecision {
        guard canAsk else { return .failed("this client does not support elicitation") }
        let text = Self.message(request, timeout: timeout)
        let schema = Elicitation.RequestSchema(title: request.title, description: text, properties: [:], required: [])
        let server = server
        do {
            let result = try await Timeout.run(timeout) {
                try await server.requestElicitation(message: text, requestedSchema: schema)
            }
            switch result.action {
            case .accept: return .approved
            case .decline: return .declined
            case .cancel: return .cancelled
            }
        } catch Timeout.Failure.elapsed(let waited) {
            Diagnostics.mcp.info("fact approval unanswered: \(waited)")
            return .unanswered(waited)
        } catch {
            Diagnostics.mcp.error("fact elicitation failed: \(error)")
            return .failed("\(error)")
        }
    }
}

/// Runs the server's fact-approval dialogs one after another, off the calls that proposed them, so no
/// `tools/call` waits on the person and two threads' questions never overlap.
actor FactAskQueue {
    /// The last dialog batch queued; each waits for the one before.
    private var last: Task<Void, Never>?

    /// Queues `work` after whatever is queued already, and returns at once.
    ///
    /// - Parameter work: A batch of questions.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits until everything queued so far has been asked and answered; tests use it.
    func settled() async {
        while let task = last {
            await task.value
            if last == task { return }
        }
    }
}
