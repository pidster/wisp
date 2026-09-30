import Foundation
import MCP
import Synchronization

/// The responses the server has written to its transport, by JSON-RPC id, so work that must follow a call's
/// result (the fact-approval dialogs, ADR 0044 amended 2026-09-30) can wait until that result is on its way.
///
/// Measured 2026-09-30 in `FactApprovalWireTests`: an elicitation queued from inside a `tools/call` handler
/// reached the SDK's client before the call's own response, and a client that handles its messages in order
/// held the result until the dialog was answered. Waiting for the response to be written first keeps the
/// turn's reply independent of the person.
final class ResponseLedger: Sendable {
    /// Ids of the responses written, newest last, at most `capacity`.
    private let sent = Mutex<[String]>([])
    /// How many ids are remembered.
    static let capacity = 256

    /// Creates an empty ledger.
    init() {}

    /// Records the message `data` the server is writing, when it is a response.
    ///
    /// - Parameter data: One JSON-RPC message.
    func record(_ data: Data) {
        guard let id = Self.responseID(of: data) else { return }
        sent.withLock { ids in
            ids.append(id)
            if ids.count > Self.capacity { ids.removeFirst(ids.count - Self.capacity) }
        }
    }

    /// Whether the response to request `id` has been written.
    func hasSent(_ id: String) -> Bool { sent.withLock { $0.contains(id) } }

    /// Waits until the response to request `id` has been written, or `limit` has passed (a cancelled request
    /// gets no response); returns at once for nil, a call made outside a request handler.
    ///
    /// - Parameters:
    ///   - id: The request's key (`key(_:)`), or nil.
    ///   - limit: The longest to wait.
    func waitForResponse(to id: String?, atMost limit: Duration) async {
        guard let id else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !hasSent(id), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The key of the request whose handler is running, from the SDK's handler context; nil outside one.
    ///
    /// The SDK keeps the id `package`-internal, so it is read by reflection; if a later SDK renames it, this
    /// returns nil and the work simply does not wait.
    static func currentRequest() -> String? {
        guard let context = Server.currentHandlerContext else { return nil }
        guard let id = Mirror(reflecting: context).children.first(where: { $0.label == "id" })?.value as? ID else {
            return nil
        }
        return key(id)
    }

    /// A request id as the ledger keys it.
    static func key(_ id: ID) -> String {
        switch id {
        case .string(let text): "s:\(text)"
        case .number(let number): "n:\(number)"
        }
    }

    /// The id of `data` when it is a response (an `id` with a `result` or an `error`, and no `method`).
    static func responseID(of data: Data) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] == nil, message["result"] != nil || message["error"] != nil
        else { return nil }
        switch message["id"] {
        case let text as String: return key(.string(text))
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return key(.number(number.intValue))
        default: return nil
        }
    }
}
