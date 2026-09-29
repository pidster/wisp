import Foundation

/// The tool calls of one turn with what each produced, folded from the turn's audit events, for the `calls`
/// field of an MCP `respond` result ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md),
/// decision D9).
///
/// The output reported is the `tool.result` event's, which is what the tool returned to the model, never
/// the model's account of it. Small output is carried inline; larger output is left to a reference the
/// caller resolves when it wants it, so the caller decides whether to spend its own context on it
/// (`json(inlineBytes:reference:)`). Like `Receipt`, this is derived, never recorded: the audit log stays the
/// one verbatim record (D8), and a reference points into it.
public struct TurnCalls: Equatable, Sendable {
    /// One tool call of the turn.
    public struct Call: Equatable, Sendable {
        /// The `tool.result` event's id: the audit reference a conversation's store keeps for the output,
        /// and what a reference resolves. Nil when the call threw before a result.
        public var id: String?
        /// The audit call id that pairs the `tool.call` event with its result.
        public var call: String?
        /// The tool's name.
        public var tool: String
        /// The arguments the model produced, as JSON.
        public var arguments: String
        /// For `run_command`, the command line.
        public var command: String?
        /// For a command that ran, its exit status; nil when it did not run (denied, refused, or not a
        /// command).
        public var exitStatus: Int?
        /// The output, verbatim; nil when the call threw.
        public var output: String?
        /// The error, when the tool threw.
        public var error: String?

        /// The output's size in UTF-8 bytes; nil when the call threw.
        public var bytes: Int? { output?.utf8.count }
    }

    /// The turn.
    public var turn: Int
    /// The calls in the order the model made them, at most `Receipt.maxEntries`.
    public var calls: [Call] = []

    /// Folds the tool calls of `turn` from `events`: each `tool.call`, the `tool.result` or `error` with the
    /// same call id, and for `run_command` the first `command.outcome` of the same command line not yet
    /// matched after it (a `command.outcome` carries no call id).
    ///
    /// - Parameters:
    ///   - events: Audit events of one session, in the order they were written.
    ///   - turn: The turn to fold.
    public init(events: [AuditEvent], turn: Int) {
        self.turn = turn
        let mine = events.filter { $0.turn == turn }
        var index: [String: Int] = [:]
        var outcomes = mine.enumerated().filter { $0.element.kind == .commandOutcome }
        for (position, event) in mine.enumerated() {
            let details = event.details
            switch event.kind {
            case .toolCall where calls.count < Receipt.maxEntries:
                let tool = details["tool"]?.stringValue ?? ""
                let arguments = details["arguments"]?.stringValue ?? ""
                var command: String?
                var exitStatus: Int?
                if tool == "run_command" {
                    command = Self.command(in: arguments)
                    if let command,
                        let found = outcomes.firstIndex(where: {
                            $0.offset > position && $0.element.details["command"]?.stringValue == command
                        })
                    {
                        exitStatus = outcomes[found].element.details["exitStatus"]?.intValue
                        outcomes.remove(at: found)
                    }
                }
                if let call = event.call { index[call] = calls.count }
                calls.append(
                    Call(
                        id: nil, call: event.call, tool: tool, arguments: arguments, command: command,
                        exitStatus: exitStatus, output: nil, error: nil))
            case .toolResult:
                guard let call = event.call, let at = index[call] else { continue }
                calls[at].id = event.id
                calls[at].output = details["output"]?.stringValue ?? ""
            case .error:
                guard let call = event.call, let at = index[call] else { continue }
                calls[at].error = details["message"]?.stringValue ?? ""
            default:
                continue
            }
        }
    }

    /// The `command` field of a `run_command` call's arguments JSON, or nil.
    static func command(in arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return object.objectValue?["command"]?.stringValue
    }

    /// The calls as JSON, the shape `respond` returns in `calls` (`docs/mcp.md`). Output of at most
    /// `inlineBytes` is inline as `output`; larger output is `outputURI`, what `reference` makes of the
    /// call's `id`, or left out when `reference` gives nil (no audit file to resolve it from).
    ///
    /// - Parameters:
    ///   - inlineBytes: The largest output carried inline.
    ///   - reference: The URI that resolves a call's output by its id, or nil when none can.
    /// - Returns: An array with one object per call.
    public func json(inlineBytes: Int, reference: (String) -> String?) -> JSONValue {
        .array(
            calls.map { call in
                var fields: [String: JSONValue] = [
                    "tool": .string(call.tool), "arguments": .string(call.arguments),
                    "id": call.id.map { .string($0) } ?? .null,
                ]
                if let command = call.command { fields["command"] = .string(command) }
                if let status = call.exitStatus { fields["exitStatus"] = .int(status) }
                if let error = call.error { fields["error"] = .string(error) }
                if let output = call.output, let bytes = call.bytes {
                    fields["bytes"] = .int(bytes)
                    if bytes <= inlineBytes {
                        fields["output"] = .string(output)
                    } else if let id = call.id, let uri = reference(id) {
                        fields["outputURI"] = .string(uri)
                    }
                }
                return .object(fields)
            })
    }
}
