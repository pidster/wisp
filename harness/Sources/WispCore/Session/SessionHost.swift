/// What the face that owns the person's screen can do for a session's tools: ADR 0044's `Host`, named
/// `SessionHost` because Foundation already has a `Host`. It holds the request-and-answer effects its face
/// carries; tools and the gate reach the person through these, never through a face directly.
///
/// Carried so far: command approval (`approver`, ADR 0011) and fact approval (`facts`, amended into ADR 0044
/// on 2026-09-30). The MCP server's host asks both through elicitation. Chat asks commands on its own screen
/// and carries no fact dialog: the person approves a proposed permanent fact with `/fact approve`.
public struct SessionHost: Sendable {
    /// Asks the person about a risky command.
    public var approver: any Approver
    /// Asks the person whether to keep a proposed permanent fact; nil when the face has no such dialog.
    public var facts: (any FactApprover)?

    /// Creates a host.
    ///
    /// - Parameters:
    ///   - approver: The command-approval effect.
    ///   - facts: The fact-approval effect, or nil.
    public init(approver: any Approver, facts: (any FactApprover)? = nil) {
        self.approver = approver
        self.facts = facts
    }
}
