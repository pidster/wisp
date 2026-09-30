import Foundation

/// The running wisp's version, stamped on every audit event.
public enum WispVersion {
    /// Semantic version of this build.
    public static let current = "0.14.1"
}

/// Where one audit event is: its session and turn, to narrow a search of the audit files, and its id.
/// A conversation's store holds these instead of copies of what the events recorded.
public struct AuditReference: Codable, Hashable, Sendable {
    /// The event's session.
    public var session: String
    /// The event's turn, where it has one.
    public var turn: Int?
    /// The event's id (`AuditEvent.id`).
    public var event: String

    /// Creates a reference.
    public init(session: String, turn: Int?, event: String) {
        self.session = session
        self.turn = turn
        self.event = event
    }

    /// A reference to `event`; an event read from a line without an id refers to nothing and gets an
    /// empty one.
    public init(_ event: AuditEvent) {
        self.init(session: event.session, turn: event.turn, event: event.id ?? "")
    }
}

/// One line of the audit log.
///
/// Every event carries enough identity to reconstruct an interaction: the
/// session (a CLI run, a chat, or an MCP thread), the turn within it, and for
/// tool activity the call id that pairs a call with its result. Each event also
/// has its own id, which a conversation's store refers to instead of copying the
/// content (`ConversationStore`; the audit log stays the one verbatim record).
public struct AuditEvent: Codable, Equatable, Sendable {
    /// What happened. The string values are the `kind` field in the file. A kind this build does not know
    /// (written by another release) reads as `.unknown` with its text kept, so `wisp logs` and the audit
    /// resources show the line as it is instead of dropping it.
    public enum Kind: Codable, Hashable, Sendable, RawRepresentable, CaseIterable {
        case sessionStart
        case sessionEnd
        case modelResolved
        case prompt
        case response
        case toolCall
        case toolResult
        case policyDecision
        case commandOutcome
        case fileWrite
        case notification
        case secretScan
        case redaction
        case watchRun
        case modelRouted
        case classifierVerdict
        case classifierTrained
        case configChange
        case approvalRequested
        case approvalDecided
        case condensation
        case presentationCut
        case outputReferenced
        case distillation
        case factRecorded
        case factSuperseded
        case factDeleted
        case factScopeChanged
        case factConflict
        case factResolved
        case mcpRequest
        case mcpResult
        case error
        /// A kind this build does not know, with its `kind` text as written.
        case unknown(String)

        /// The kinds this build writes, in declaration order; `unknown` is never one of them.
        public static let allCases: [Kind] = [
            .sessionStart,
            .sessionEnd,
            .modelResolved,
            .prompt,
            .response,
            .toolCall,
            .toolResult,
            .policyDecision,
            .commandOutcome,
            .fileWrite,
            .notification,
            .secretScan,
            .redaction,
            .watchRun,
            .modelRouted,
            .classifierVerdict,
            .classifierTrained,
            .configChange,
            .approvalRequested,
            .approvalDecided,
            .condensation,
            .presentationCut,
            .outputReferenced,
            .distillation,
            .factRecorded,
            .factSuperseded,
            .factDeleted,
            .factScopeChanged,
            .factConflict,
            .factResolved,
            .mcpRequest,
            .mcpResult,
            .error,
        ]

        /// The `kind` text in the file.
        public var rawValue: String {
            switch self {
            case .sessionStart: "session.start"
            case .sessionEnd: "session.end"
            case .modelResolved: "model.resolved"
            case .prompt: "prompt"
            case .response: "response"
            case .toolCall: "tool.call"
            case .toolResult: "tool.result"
            case .policyDecision: "policy.decision"
            case .commandOutcome: "command.outcome"
            case .fileWrite: "file.write"
            case .notification: "notification"
            case .secretScan: "secrets.scan"
            case .redaction: "redaction"
            case .watchRun: "watch.run"
            case .modelRouted: "model.routed"
            case .classifierVerdict: "classifier.verdict"
            case .classifierTrained: "classifier.train"
            case .configChange: "config.change"
            case .approvalRequested: "approval.requested"
            case .approvalDecided: "approval.decided"
            case .condensation: "context.condensation"
            case .presentationCut: "context.cut"
            case .outputReferenced: "context.reference"
            case .distillation: "context.distillation"
            case .factRecorded: "fact.recorded"
            case .factSuperseded: "fact.superseded"
            case .factDeleted: "fact.deleted"
            case .factScopeChanged: "fact.scope.changed"
            case .factConflict: "fact.conflict.raised"
            case .factResolved: "fact.conflict.resolved"
            case .mcpRequest: "mcp.request"
            case .mcpResult: "mcp.result"
            case .error: "error"
            case .unknown(let text): text
            }
        }

        /// The known kind written as `rawValue`; nil for any other text, so a filter can refuse a typo.
        public init?(rawValue: String) {
            guard let known = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
            self = known
        }

        /// Reads a `kind` value; text this build does not know becomes `.unknown`.
        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: text) ?? .unknown(text)
        }

        /// Writes the `kind` text.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Format version of the event schema; bump when fields change meaning.
    public static let schemaVersion = 1

    /// Schema version this event was written with.
    public var schema: Int
    /// This event's own id: 16 lowercase hex characters, random, so a reference to it stays valid
    /// across rotation, processes, and sessions that reuse a name (an MCP `thread_id`). Nil only in lines
    /// written by versions before event ids, which had none.
    public var id: String?
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

    /// Creates an event stamped with a fresh id, the current time, version, and pid.
    public init(
        session: String, kind: Kind, turn: Int? = nil, call: String? = nil, details: [String: JSONValue] = [:],
        time: Date = Date()
    ) {
        schema = Self.schemaVersion
        id = Self.makeID()
        self.time = time
        version = WispVersion.current
        pid = ProcessInfo.processInfo.processIdentifier
        self.session = session
        self.turn = turn
        self.call = call
        self.kind = kind
        self.details = details
    }

    /// A fresh event id: the first 16 hex characters of a random UUID, lowercased; 60 random bits, so
    /// ids do not collide across the audit files wisp keeps.
    static func makeID() -> String {
        String(UUID().uuidString.filter { $0 != "-" }.prefix(16)).lowercased()
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
