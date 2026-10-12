import Foundation
import MCP
import WispCore

/// Asks the model's question through the MCP client's elicitation form
/// ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md), section 4): a `string` field `answer` for a
/// free-text question, an enum of the options (with `none of these`) for a choice. Accept with the field answers;
/// Decline declines; Cancel is no answer, and the question goes on waiting out of band. Behind
/// `inquiry.elicitation`, off by default, until the form has been tried by hand in Claude Code (D8): a text field
/// has never been sent there, and a form control once made its dialog unresponsive (ADR 0011). The dialog is
/// tagged like an approval's, so withdrawing it sends `notifications/cancelled`.
struct ElicitationAsker: Sendable {
    /// The running server, which owns the connection to the client.
    let server: Server
    /// What the client advertised during initialize.
    let client: ClientCapabilityFlags
    /// The dialogs in flight, for withdrawing one.
    let tracker: ElicitationTracker

    /// The dialog as one way of asking (`OutOfBandAsker.Ask`), or nil when the client has none. Cancelling the task
    /// that awaits it withdraws the dialog.
    var ask: OutOfBandAsker.Ask? {
        guard client.elicitation.withLock({ $0 }) else { return nil }
        let asker = self
        return { question in await asker.leg(question) }
    }

    /// Sends the dialog and maps the answer to a leg of the race.
    func leg(_ question: Question) async -> OutOfBandAsker.Leg {
        let key = UUID().uuidString
        let server = server
        let tracker = tracker
        return await withTaskCancellationHandler {
            await elicit(question, key: key)
        } onCancel: {
            guard let id = tracker.cancel(key) else { return }
            Task { try? await server.cancelRequest(id, reason: "answered another way, or the hold lapsed") }
        }
    }

    /// The form for `question`: the title says the model asks, the message carries the question, where the
    /// answer goes, and the thread; the one field is `answer`.
    ///
    /// - Parameters:
    ///   - question: The question.
    ///   - client: The client's name, told where the answer goes.
    /// - Returns: The message and the schema.
    static func form(for question: Question, client: String?) -> (message: String, schema: Elicitation.RequestSchema) {
        let shown = ApprovalRequest.visible
        let thread = question.thread.map { "\nThread: \(shown($0))" } ?? ""
        let message = """
            The model asks:
            \(shown(question.text))\(thread)

            Your answer goes to the model, and to \(client ?? "the MCP client"), which can read this thread. \
            Decline sends no answer. Never type a password here.
            """
        var field: [String: Value] = ["type": .string("string"), "title": .string("Your answer")]
        if question.isChoice {
            let options = question.options + [Question.noneOfThese]
            field["enum"] = .array(options.map { .string($0) })
            field["enumNames"] = .array(options.map { .string(shown($0)) })
            field["description"] = .string("Pick one")
        } else {
            field["maxLength"] = .int(Question.answerBytes)
            field["description"] = .string("One line, at most \(Question.answerBytes) characters")
        }
        let schema = Elicitation.RequestSchema(
            title: "wisp: the model asks", description: message, properties: ["answer": .object(field)],
            required: ["answer"])
        return (message, schema)
    }

    /// Sends the dialog, tagged with `key` so it can be withdrawn, and waits for the answer: the hold is the
    /// asker's, which cancels this leg when it lapses.
    private func elicit(_ question: Question, key: String) async -> OutOfBandAsker.Leg {
        let form = Self.form(for: question, client: client.name.withLock { $0 })
        let meta = Metadata(additionalFields: [ElicitationTracker.metaKey: .string(key)])
        tracker.begin(key)
        defer { tracker.end(key) }
        do {
            let result = try await server.requestElicitation(
                message: form.message, requestedSchema: form.schema, _meta: meta)
            switch result.action {
            case .accept:
                return .answered(question.outcome(typed: result.content?["answer"]?.stringValue) ?? .declined)
            case .decline: return .answered(.declined)
            case .cancel: return .failed("cancelled in the client's dialog; the question waits out of band")
            }
        } catch {
            Diagnostics.mcp.error("elicitation for a question failed: \(error)")
            return .failed("\(error)")
        }
    }
}
