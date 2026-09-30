/// What the face that owns the person's screen can do for a session's tools: ADR 0044's `Host`, named
/// `SessionHost` because Foundation already has a `Host`. It holds the request-and-answer effects its face
/// carries; tools and the gate reach the person through these, never through a face directly.
///
/// Carried so far: command approval (`approver`, ADR 0011), and nothing else. A fact's scope is a state the
/// person sets by command, not a host effect (ADR 0044, amended 2026-09-30), so the host is a wrapper around
/// one effect for now; the notification effect ADR 0044 plans will be its second.
public struct SessionHost: Sendable {
    /// Asks the person about a risky command.
    public var approver: any Approver

    /// Creates a host.
    ///
    /// - Parameter approver: The command-approval effect.
    public init(approver: any Approver) {
        self.approver = approver
    }
}
