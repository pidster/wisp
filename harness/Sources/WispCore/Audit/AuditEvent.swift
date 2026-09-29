import Foundation

/// The running wisp's version, stamped on every audit event.
public enum WispVersion {
    /// Semantic version of this build.
    public static let current = "0.14.1"
}

/// One line of the audit log.
///
/// Every event carries enough identity to reconstruct an interaction: the
/// session (a CLI run, a chat, or an MCP thread), the turn within it, and for
/// tool activity the call id that pairs a call with its result.
public struct AuditEvent: Codable, Equatable, Sendable {
    /// What happened. The string values are the `kind` field in the file.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sessionStart = "session.start"
        case sessionEnd = "session.end"
        case modelResolved = "model.resolved"
        case prompt = "prompt"
        case response = "response"
        case toolCall = "tool.call"
        case toolResult = "tool.result"
        case policyDecision = "policy.decision"
        case commandOutcome = "command.outcome"
        case fileWrite = "file.write"
        case notification = "notification"
        case secretScan = "secrets.scan"
        case redaction = "redaction"
        case watchRun = "watch.run"
        case modelRouted = "model.routed"
        case classifierVerdict = "classifier.verdict"
        case classifierTrained = "classifier.train"
        case configChange = "config.change"
        case approvalRequested = "approval.requested"
        case approvalDecided = "approval.decided"
        case condensation = "context.condensation"
        case mcpRequest = "mcp.request"
        case mcpResult = "mcp.result"
        case error = "error"
    }

    /// Format version of the event schema; bump when fields change meaning.
    public static let schemaVersion = 1

    /// Schema version this event was written with.
    public var schema: Int
    /// When the event was recorded.
    public var time: Date
    /// wisp version that wrote it.
    public var version: String
    /// Process id, to separate concurrent wisps sharing one file.
    public var pid: Int32
    /// Session id: a CLI run, a chat, an MCP server, or an MCP thread.
    public var session: String
    /// 1-based turn within the session, where applicable.
    public var turn: Int?
    /// Pairs a tool call with its result.
    public var call: String?
    /// What happened.
    public var kind: Kind
    /// Kind-specific fields. Names are stable; see `docs/logging.md`.
    public var details: [String: JSONValue]

    /// Creates an event stamped with the current time, version, and pid.
    public init(
        session: String, kind: Kind, turn: Int? = nil, call: String? = nil, details: [String: JSONValue] = [:],
        time: Date = Date()
    ) {
        schema = Self.schemaVersion
        self.time = time
        version = WispVersion.current
        pid = ProcessInfo.processInfo.processIdentifier
        self.session = session
        self.turn = turn
        self.call = call
        self.kind = kind
        self.details = details
    }

    /// A one-line human summary used by `wisp logs`.
    public var summary: String {
        let stamp = Self.timestamp.format(time)
        var head = "\(stamp) \(kind.rawValue) session=\(session)"
        if let turn { head += " turn=\(turn)" }
        if let call { head += " call=\(call)" }
        let body: String
        switch kind {
        case .prompt, .response: body = details["text"]?.stringValue ?? ""
        case .toolCall: body = "\(details["tool"]?.stringValue ?? "?") \(details["arguments"]?.stringValue ?? "")"
        case .toolResult: body = details["output"]?.stringValue ?? ""
        case .policyDecision:
            body = "\(details["verdict"]?.stringValue ?? "?") \(details["command"]?.stringValue ?? "")"
        case .commandOutcome:
            body = "exit=\(details["exitStatus"]?.intValue ?? 0) \(details["command"]?.stringValue ?? "")"
        case .notification:
            body =
                "\(details["outcome"]?.stringValue ?? "?") from \(details["source"]?.stringValue ?? "?"): "
                + (details["title"]?.stringValue ?? "")
        case .fileWrite:
            body =
                "\(details["mode"]?.stringValue ?? "?") \(details["path"]?.stringValue ?? "") "
                + "\(details["bytesBefore"]?.intValue ?? 0)->\(details["bytesAfter"]?.intValue ?? 0) bytes"
        case .error: body = details["message"]?.stringValue ?? ""
        default:
            body = details.keys.sorted().compactMap { key in details[key]?.stringValue.map { "\(key)=\($0)" } }.joined(
                separator: " ")
        }
        let flat = body.replacingOccurrences(of: "\n", with: "\\n")
        return flat.isEmpty ? head : "\(head): \(flat.count > 200 ? String(flat.prefix(200)) + "…" : flat)"
    }

    /// Encoder for the file format: ISO 8601 with fractional seconds, sorted keys, one line.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp.format(date))
        }
        return encoder
    }

    /// Decoder matching `encoder`.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            do {
                return try timestamp.parse(text)
            } catch {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "bad time \(text)"))
            }
        }
        return decoder
    }

    /// `2023-11-14T22:13:20.500Z`; a value type, so safe to share.
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
