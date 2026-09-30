import Foundation
import Logging
import MCP
import WispCore

/// Wraps a transport and normalises incoming messages the MCP Swift SDK cannot decode although the
/// protocol allows them, so a compliant client is not refused at the door.
///
/// One case today: `initialize` from Codex carries `capabilities.experimental` with object values
/// (`{"codex/auth-change": {}}`), which the specification permits, while SDK 0.12.1 declares the field
/// as `[String: String]` and fails the whole request with `-32603`. Each non-string value is replaced
/// by its compact JSON text, so nothing is lost and the SDK decodes it. wisp never reads the field.
actor CompatibilityTransport: Transport {
    /// The transport this one wraps.
    private let base: any Transport
    /// The logger the SDK uses for this transport.
    nonisolated let logger: Logger

    /// Wraps `base`.
    init(_ base: any Transport, logger: Logger = DiagnosticsLogHandler.logger()) {
        self.base = base
        self.logger = logger
    }

    /// Connects the base transport.
    func connect() async throws { try await base.connect() }

    /// Disconnects the base transport.
    func disconnect() async { await base.disconnect() }

    /// Sends unchanged.
    func send(_ data: Data) async throws { try await base.send(data) }

    /// Receives from the base transport, normalising each message.
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let base = base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in await base.receive() {
                        continuation.yield(Self.normalise(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rewrites an `initialize` request whose `capabilities.experimental` has non-string values, and
    /// returns anything else unchanged, including bytes that are not JSON.
    static func normalise(_ data: Data) -> Data {
        guard var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] as? String == "initialize",
            var params = message["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimental = capabilities["experimental"] as? [String: Any],
            experimental.values.contains(where: { !($0 is String) })
        else { return data }
        capabilities["experimental"] = experimental.mapValues { value -> Any in
            if let text = value as? String { return text }
            guard JSONSerialization.isValidJSONObject(value),
                let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            else { return "\(value)" }
            return String(decoding: encoded, as: UTF8.self)
        }
        params["capabilities"] = capabilities
        message["params"] = params
        guard let rewritten = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            return data
        }
        Diagnostics.mcp.debug("normalised initialize: experimental capability values stringified for the SDK")
        return rewritten
    }
}

extension Value {
    /// The MCP value with the same shape as a wisp JSON value.
    init(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map { Value(json: $0) })
        case .object(let o): self = .object(o.mapValues { Value(json: $0) })
        }
    }
}

extension JSONValue {
    /// The wisp JSON value with the same shape as an MCP value; binary data becomes its base64 text.
    init(_ value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .data(mimeType: _, let data): self = .string(data.base64EncodedString())
        case .array(let a): self = .array(a.map(JSONValue.init))
        case .object(let o): self = .object(o.mapValues(JSONValue.init))
        }
    }
}
