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
        /// The `tool.result` event's id: the audit reference a thread's record keeps for the output,
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
        /// For a command that ran, whether the timeout stopped it.
        public var timedOut = false
        /// For a command turned away before it ran, the `policy.decision` verdict: `denied` by the policy's
        /// patterns, `disapproved` by the gate (the person declined, or did not answer in time); nil otherwise.
        public var verdict: String?
        /// The output, verbatim; nil when the call threw.
        public var output: String?
        /// The error, when the tool threw.
        public var error: String?

        /// The output's size in UTF-8 bytes; nil when the call threw.
        public var bytes: Int? { output?.utf8.count }
    }

    /// The turn.
    public var turn: Int
    /// The calls in the order the model made them, at most the `limit` they were folded with.
    public var calls: [Call] = []

    /// Folds the tool calls of `turn` from `events`: each `tool.call`, the `tool.result` or `error` with the
    /// same call id, and for `run_command` the first `command.outcome` and the first `policy.decision` of the
    /// same command line not yet matched after it (neither carries a call id). A command the person typed
    /// after `!` (`origin: "person"`, ADR 0049) is never matched to a model's call.
    ///
    /// - Parameters:
    ///   - events: Audit events of one session, in the order they were written.
    ///   - turn: The turn to fold.
    ///   - limit: The most calls kept; `respond`'s `calls` keeps `Receipt.maxEntries`, a count keeps every one.
    public init(events: [AuditEvent], turn: Int, limit: Int = Receipt.maxEntries) {
        self.turn = turn
        let mine = events.filter { $0.turn == turn }
        var index: [String: Int] = [:]
        let models = mine.enumerated().filter { $0.element.details["origin"]?.stringValue != "person" }
        var outcomes = models.filter { $0.element.kind == .commandOutcome }
        var decisions = models.filter { $0.element.kind == .policyDecision }
        for (position, event) in mine.enumerated() {
            let details = event.details
            switch event.kind {
            case .toolCall where calls.count < limit:
                let tool = details["tool"]?.stringValue ?? ""
                let arguments = details["arguments"]?.stringValue ?? ""
                var call = Call(
                    id: nil, call: event.call, tool: tool, arguments: arguments, command: nil, exitStatus: nil,
                    output: nil, error: nil)
                if tool == "run_command", let command = Self.command(in: arguments) {
                    call.command = command
                    let after = { (candidate: (offset: Int, element: AuditEvent)) in
                        candidate.offset > position && candidate.element.details["command"]?.stringValue == command
                    }
                    if let found = outcomes.firstIndex(where: after) {
                        call.exitStatus = outcomes[found].element.details["exitStatus"]?.intValue
                        call.timedOut = outcomes[found].element.details["timedOut"]?.boolValue ?? false
                        outcomes.remove(at: found)
                    }
                    if let found = decisions.firstIndex(where: after) {
                        let verdict = decisions[found].element.details["verdict"]?.stringValue
                        call.verdict = verdict == "allowed" ? nil : verdict
                        decisions.remove(at: found)
                    }
                }
                if let id = event.call { index[id] = calls.count }
                calls.append(call)
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
