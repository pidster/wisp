import Foundation
import MCP
import Synchronization
import WispCore

/// What the connected client advertised at initialize, shared between the server and its approver.
final class ClientCapabilityFlags: Sendable {
    /// Whether the client supports form elicitation.
    let elicitation = Mutex(false)
    /// The client's name, from its `clientInfo`.
    let name = Mutex<String?>(nil)
}

/// The JSON-RPC ids of the approval dialogs in flight, so one can be withdrawn with `notifications/cancelled`
/// when the person answers another way first (ADR 0046). The SDK does not return a request's id, so each
/// dialog carries a key in its `_meta` (`wisp/approval`) and `CompatibilityTransport` records the id of the
/// outgoing `elicitation/create` that carries it.
final class ElicitationTracker: Sendable {
    /// The `_meta` field that carries the key.
    static let metaKey = "wisp/approval"

    /// Request ids by key.
    private let ids = Mutex<[String: ID]>([:])

    /// Creates an empty tracker.
    init() {}

    /// Records the id of an outgoing message if it is an `elicitation/create` carrying a key.
    ///
    /// - Parameter data: One outgoing JSON-RPC message.
    func observe(_ data: Data) {
        guard data.count < 65_536, let text = String(data: data, encoding: .utf8), text.contains("elicitation/create"),
            let message = try? JSONDecoder().decode(Outgoing.self, from: data), message.method == "elicitation/create",
            let key = message.params?.meta?[Self.metaKey]
        else { return }
        ids.withLock { $0[key] = message.id }
    }

    /// The id recorded for `key`, forgetting it.
    func take(_ key: String) -> ID? {
        ids.withLock { $0.removeValue(forKey: key) }
    }

    /// The parts of an outgoing request the tracker reads.
    private struct Outgoing: Decodable {
        /// The request's `params`, as far as `_meta` goes.
        struct Params: Decodable {
            /// String fields of `_meta`.
            var meta: [String: String]?

            /// The JSON key.
            enum CodingKeys: String, CodingKey { case meta = "_meta" }

            /// Decodes `_meta`'s string fields, ignoring any other kind of value.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let raw = try container.decodeIfPresent([String: Value].self, forKey: .meta)
                meta = raw?.compactMapValues(\.stringValue)
            }
        }

        /// The method.
        var method: String?
        /// The id.
        var id: ID
        /// The params.
        var params: Params?
    }
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
    /// The dialogs in flight, for withdrawing one.
    let tracker: ElicitationTracker

    /// Creates an approver over `server`; support is learned from the initialize hook.
    init(server: Server, client: ClientCapabilityFlags, timeout: Duration?, tracker: ElicitationTracker = .init()) {
        self.server = server
        self.client = client
        self.timeout = timeout
        self.tracker = tracker
    }

    /// The dialog as one way of asking among others (ADR 0046), or nil when the client has none. A dialog that
    /// cannot be sent is a failure, not a refusal, so another way can still answer; cancelling the task that
    /// awaits it withdraws the dialog with `notifications/cancelled`.
    var ask: OutOfBandApprover.Ask? {
        guard client.elicitation.withLock({ $0 }) else { return nil }
        let approver = self
        return { request in await approver.leg(request) }
    }

    /// Sends the dialog and maps the answer to a leg of the race.
    func leg(_ request: ApprovalRequest) async -> OutOfBandApprover.Leg {
        let key = UUID().uuidString
        let server = server
        let tracker = tracker
        return await withTaskCancellationHandler {
            switch await elicit(request, key: key) {
            case .success(let decision): .answered(decision)
            case .failure(let failure): .failed(failure.description)
            }
        } onCancel: {
            guard let id = tracker.take(key) else { return }
            Task { try? await server.cancelRequest(id, reason: "answered another way") }
        }
    }

    /// Why a dialog could not be asked.
    struct Failure: Error, CustomStringConvertible {
        /// What went wrong.
        let description: String
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
        switch await elicit(request, key: UUID().uuidString) {
        case .success(let decision): return decision
        case .failure(let failure): return .denied("approval request failed: \(failure)")
        }
    }

    /// Sends the dialog, tagged with `key` so it can be withdrawn, and waits for the answer within `timeout`.
    private func elicit(_ request: ApprovalRequest, key: String) async -> Result<ApprovalDecision, Failure> {
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
        let meta = Metadata(additionalFields: [ElicitationTracker.metaKey: .string(key)])
        do {
            let result = try await Timeout.run(timeout) {
                try await server.requestElicitation(message: text, requestedSchema: schema, _meta: meta)
            }
            switch result.action {
            case .accept: return .success(.approved(Self.scope(from: result.content?["scope"])))
            case .decline: return .success(.denied("declined by the user"))
            case .cancel: return .success(.denied("cancelled by the user"))
            }
        } catch Timeout.Failure.elapsed(let waited) {
            Diagnostics.mcp.info("approval unanswered: \(waited)")
            return .success(.unanswered(waited))
        } catch {
            Diagnostics.mcp.error("elicitation failed: \(error)")
            return .failure(Failure(description: "\(error)"))
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
