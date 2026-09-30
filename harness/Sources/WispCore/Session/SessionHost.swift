/// What the face that owns the person's screen can do for a session's tools: ADR 0044's `Host`, named
/// `SessionHost` because Foundation already has a `Host`. It holds the effects its face carries; tools and
/// the gate reach the person through these, never through a face directly. Every face builds one: plain
/// chat and the one-shot commands, `wisp chat --json`, and `wisp mcp` (`Session.host`).
///
/// Carried: command approval (`approver`, a request-and-answer effect, ADR 0011) and notification
/// (`notify`, fire and forget, ADR 0030), whose routes depend on the face. A fact's scope is a state the
/// person sets by command, not a host effect (ADR 0044, amended 2026-09-30).
public struct SessionHost: Sendable {
    /// Asks the person about a risky command.
    public var approver: any Approver
    /// How this face posts a notification: which of the front end, the terminal, the terminal app, and
    /// `osascript` it can use.
    public var notifications: NotificationRoutes
    /// The session's notifier: the bounds, the off switch, and the per-minute limit across the process.
    public let notifier: Notifier

    /// Creates a host.
    ///
    /// - Parameters:
    ///   - approver: The command-approval effect.
    ///   - notifier: The session's notifier, shared by every conversation.
    ///   - notifications: The face's notification routes; by default only the process routes.
    public init(approver: any Approver, notifier: Notifier, notifications: NotificationRoutes = .headless) {
        self.approver = approver
        self.notifier = notifier
        self.notifications = notifications
    }

    /// Posts a notification by this face's first route that works, after the notifier's bounds, off switch,
    /// and limit, and audits it.
    ///
    /// - Parameters:
    ///   - message: What to show.
    ///   - source: Who asked.
    ///   - audit: Where the `notification` event goes.
    /// - Returns: The route taken, or why it was not posted.
    @discardableResult
    public func notify(_ message: Notifier.Message, source: Notifier.Source, audit: AuditLog?) -> Notifier.Outcome {
        notifier.post(message, source: source, audit: audit, routes: notifications)
    }
}
