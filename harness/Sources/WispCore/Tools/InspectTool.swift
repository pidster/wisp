import Foundation
import FoundationModels

/// Lets the model look at wisp's own state: the effective configuration, this conversation's
/// status, the standing approvals, and recent audit events. Read-only and bounded.
public struct InspectTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "inspect"
    /// What the model is told this tool does.
    public let description =
        "Shows wisp's own state: config (effective settings), status (this conversation), approvals "
        + "(standing command approvals), or audit (recent audit events). Read-only."
    /// Page size and what is redacted: nothing, because it is all the operator's own local state.
    public let limits =
        "Output is capped at 4 KiB. audit returns the last 20 events by default (last up to 100), filterable by "
        + "kind and session; the audit file itself has everything, via `wisp logs`."
    /// How to ask for it.
    public let examplePrompt =
        "Use inspect with what: audit, last: 5 and tell me which commands ran and their exit status."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// Which view.
        @Guide(description: "One of: config, status, approvals, audit.")
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
    }

    /// The largest output returned to the model.
    public static let maxBytes = 4096

    private let introspection: Introspection

    /// Creates the tool over the views it renders.
    public init(introspection: Introspection) {
        self.introspection = introspection
    }

    /// `call` for the chat's `/inspect` and `/audit`: a bare view, or `audit` followed by `sessions` (the
    /// sessions in the log) or a session id (that session's latest events).
    public func show(_ what: String) async -> String {
        let words = what.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2, words[0].lowercased() == "audit" else {
            return await call(arguments: .init(what: what, last: nil, kind: nil, session: nil))
        }
        guard words[1] == "sessions" else {
            return await call(arguments: .init(what: "audit", last: nil, kind: nil, session: words[1]))
        }
        do {
            let sessions = try introspection.sessions()
            guard !sessions.isEmpty else { return "no sessions in the audit log" }
            return ToolOutput.bounded(sessions.map(\.line).joined(separator: "\n"), maxBytes: Self.maxBytes)
        } catch {
            return ToolOutput.error(error)
        }
    }

    /// Renders the requested view, bounded.
    ///
    /// - Parameter arguments: Which view and, for audit, the filters.
    /// - Returns: Pretty JSON for config, status, and approvals; one summary line per event for audit.
    ///   Bad arguments are returned as text so the model can correct them.
    public func call(arguments: Arguments) async -> String {
        switch arguments.what.lowercased() {
        case "config":
            return ToolOutput.bounded(Introspection.render(introspection.configuration), maxBytes: Self.maxBytes)
        case "status":
            return ToolOutput.bounded(Introspection.render(.object(introspection.status())), maxBytes: Self.maxBytes)
        case "approvals":
            return ToolOutput.bounded(Introspection.render(await introspection.approvals()), maxBytes: Self.maxBytes)
        case "audit":
            var kinds: [AuditEvent.Kind] = []
            if let kind = arguments.kind {
                guard let parsed = AuditEvent.Kind(rawValue: kind) else {
                    return "error: unknown kind '\(kind)'; kinds: "
                        + AuditEvent.Kind.allCases.map(\.rawValue).joined(separator: ", ")
                }
                kinds = [parsed]
            }
            let last = min(max(arguments.last ?? 20, 1), 100)
            do {
                let events = try introspection.audit(AuditQuery(session: arguments.session, kinds: kinds, last: last))
                guard !events.isEmpty else { return "no matching audit events" }
                return ToolOutput.bounded(events.map(\.summary).joined(separator: "\n"), maxBytes: Self.maxBytes)
            } catch {
                return ToolOutput.error(error)
            }
        case let other:
            return "error: unknown view '\(other)'; use config, status, approvals, or audit"
        }
    }
}
