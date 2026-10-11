import Foundation
import FoundationModels

/// Lets the model look at wisp's own state: the effective configuration, this conversation's
/// status, the standing approvals, recent audit events, and the tool calls of a turn, one line each.
/// Read-only and bounded to the tool-output budget; a view that does not fit is kept whole in the output store
/// and its head and tail shown ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)).
public struct InspectTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "inspect"
    /// What the model is told this tool does.
    public let description =
        "Shows wisp's own state: config (effective settings), status (this conversation), approvals "
        + "(standing command approvals), audit (audit events, by turn or the most recent), or calls (one line per "
        + "tool call of a turn: the tool, its arguments, its outcome). Read-only."
    /// Page size and what is redacted: nothing, because it is all the operator's own local state.
    public var limits: String {
        "Output is bounded to the tool-output budget (\(budget.bytes) bytes now); a view past it is kept in the output "
            + "store and its first and last lines shown. audit returns the last 20 events by default (last up to 100), "
            + "filterable by kind, session, and turn; calls lists a turn's tool calls (this turn by default); the audit "
            + "file itself has everything, via `wisp logs`."
    }
    /// How to ask for it.
    public let examplePrompt =
        "Use inspect with what: calls to list the tool calls of this turn, then check each claim against them."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// Which view.
        @Guide(description: "One of: config, status, approvals, audit, calls.")
        public var what: String
        /// For audit: how many most recent events.
        @Guide(description: "For audit: how many of the most recent events to show (default 20, max 100).")
        public var last: Int?
        /// For audit: one event kind, such as `command.outcome`.
        @Guide(description: "For audit: only events of this kind, such as command.outcome or approval.decided.")
        public var kind: String?
        /// For audit: one session or thread id.
        @Guide(description: "For audit: only events of this session or thread id.")
        public var session: String?
        /// For audit and calls: one turn of this conversation.
        @Guide(description: "For audit and calls: only this turn of this conversation (default for calls: this turn).")
        public var turn: Int?
    }

    private let introspection: Introspection
    /// The bound on a view.
    private let budget: ToolBudget
    /// Where a view past the bound is kept whole; nil keeps nothing.
    private let store: OutputStore?

    /// Creates the tool over the views it renders.
    ///
    /// - Parameters:
    ///   - introspection: The views.
    ///   - budget: The conversation's tool-output budget; a fresh one gives the floor.
    ///   - store: The conversation's output store.
    public init(introspection: Introspection, budget: ToolBudget = ToolBudget(), store: OutputStore? = nil) {
        self.introspection = introspection
        self.budget = budget
        self.store = store
    }

    /// `value` as pretty JSON when that fits `bytes`, else as compact JSON, so a view near the bound is not cut
    /// short for its indentation (the configuration, with the default deny list, ADR 0054).
    static func fitted(_ value: JSONValue, within bytes: Int) -> String {
        let pretty = Introspection.render(value)
        guard pretty.utf8.count > bytes else { return pretty }
        return Introspection.render(value, compact: true)
    }

    /// `call` for the chat's `/inspect` and `/audit`: a bare view, or `audit` followed by `sessions` (the
    /// sessions in the log) or a session id (that session's latest events).
    public func show(_ what: String) async -> String {
        let words = what.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2, words[0].lowercased() == "audit" else {
            return await call(arguments: .init(what: what, last: nil, kind: nil, session: nil, turn: nil))
        }
        guard words[1] == "sessions" else {
            return await call(arguments: .init(what: "audit", last: nil, kind: nil, session: words[1], turn: nil))
        }
        do {
            let sessions = try introspection.sessions()
            guard !sessions.isEmpty else { return "no sessions in the audit log" }
            return bounded(sessions.map(\.line).joined(separator: "\n"))
        } catch {
            return ToolOutput.error(error)
        }
    }

    /// `text` within the budget, the rest kept in the store.
    private func bounded(_ text: String) -> String {
        ToolOutput.fitted(text, tool: name, budget: budget, store: store)
    }

    /// This conversation's audit session, from the status view.
    private var ownSession: String? { introspection.status()["session"]?.stringValue }

    /// Renders the requested view, bounded.
    ///
    /// - Parameter arguments: Which view and, for audit and calls, the filters.
    /// - Returns: Pretty JSON for config, status, and approvals; one summary line per event for audit; one line
    ///   per call for calls. Bad arguments are returned as text so the model can correct them.
    public func call(arguments: Arguments) async -> String {
        switch arguments.what.lowercased() {
        case "config":
            return bounded(Self.fitted(introspection.configuration, within: budget.bytes))
        case "status":
            return bounded(Introspection.render(.object(introspection.status())))
        case "approvals":
            return bounded(Introspection.render(await introspection.approvals()))
        case "audit":
            var kinds: [AuditEvent.Kind] = []
            if let kind = arguments.kind {
                guard let parsed = AuditEvent.Kind(rawValue: kind) else {
                    return "error: unknown kind '\(kind)'; kinds: "
                        + AuditEvent.Kind.allCases.map(\.rawValue).joined(separator: ", ")
                }
                kinds = [parsed]
            }
            do {
                let events: [AuditEvent]
                if let turn = arguments.turn {
                    // A turn is this conversation's unless a session is named; every event of it, not the last N.
                    let session = arguments.session ?? ownSession
                    events = try introspection.audit(AuditQuery(session: session, kinds: kinds)).filter {
                        $0.turn == turn
                    }
                } else {
                    let last = min(max(arguments.last ?? 20, 1), 100)
                    events = try introspection.audit(AuditQuery(session: arguments.session, kinds: kinds, last: last))
                }
                guard !events.isEmpty else { return "no matching audit events" }
                return bounded(events.map(\.summary).joined(separator: "\n"))
            } catch {
                return ToolOutput.error(error)
            }
        case "calls":
            do {
                let session = arguments.session ?? ownSession
                let turn = arguments.turn ?? introspection.status()["turn"]?.intValue ?? 0
                let events = try introspection.audit(AuditQuery(session: session))
                let calls = TurnCalls(events: events, turn: turn, limit: .max).calls
                guard !calls.isEmpty else { return "no tool calls in turn \(turn)" }
                return bounded(Self.callLines(calls, turn: turn).joined(separator: "\n"))
            } catch {
                return ToolOutput.error(error)
            }
        case let other:
            return "error: unknown view '\(other)'; use config, status, approvals, audit, or calls"
        }
    }

    /// One line per call of a turn, numbered: the tool, its arguments (shortened), and its outcome: a command's
    /// exit status or verdict, an error, or the result's size.
    ///
    /// - Parameters:
    ///   - calls: The turn's calls (`TurnCalls`).
    ///   - turn: The turn.
    /// - Returns: A header and the lines.
    static func callLines(_ calls: [TurnCalls.Call], turn: Int) -> [String] {
        var lines = ["turn \(turn): \(calls.count) tool call\(calls.count == 1 ? "" : "s")"]
        for (index, call) in calls.enumerated() {
            let arguments = OutputReference.shortened(
                call.arguments.replacingOccurrences(of: "\n", with: " "), to: OutputReference.argumentCharacters)
            let outcome: String
            if let verdict = call.verdict {
                outcome = verdict == "disapproved" ? "not approved; did not run" : "denied by policy; did not run"
            } else if let error = call.error {
                outcome = "threw: " + OutputReference.shortened(error, to: 100)
            } else if call.command != nil {
                outcome =
                    call.exitStatus.map { "exit status \($0)" + (call.timedOut ? ", timed out" : "") }
                    ?? "did not run"
            } else if let output = call.output {
                outcome =
                    output.hasPrefix("error:")
                    ? OutputReference.shortened(output.split(separator: "\n").first.map(String.init) ?? output, to: 100)
                    : "ok, \(output.utf8.count) bytes"
            } else {
                outcome = "no result"
            }
            lines.append("\(index + 1). \(call.tool) \(arguments) → \(outcome)")
        }
        return lines
    }
}
