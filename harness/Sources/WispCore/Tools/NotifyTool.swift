import Foundation
import FoundationModels

/// Lets the model show the user a macOS notification: to say a long task has finished, or that it needs
/// them. Posted through the session's host, which picks the face's route (front end, terminal, terminal
/// app, or `osascript`, [ADR 0044](../../../../docs/decisions/0044-host-effects.md)); bounded,
/// rate-limited, and audited; no approval, since a banner changes nothing on the Mac
/// ([ADR 0030](../../../../docs/decisions/0030-notifications.md)).
public struct NotifyTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "notify"
    /// What the model is told this tool does.
    public let description =
        "Shows the user a macOS notification. Use it when a long task finishes or you need their attention."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The notification's first line.
        @Guide(description: "A short title, a few words.")
        public var title: String
        /// The notification's text.
        @Guide(description: "The message, one or two sentences.")
        public var message: String
    }

    private let host: SessionHost
    private let audit: AuditLog?

    /// Bounds, from the notifier's limits.
    public var limits: String {
        "Title up to \(Notifier.titleLimit) characters, message up to \(Notifier.bodyLimit); a few per minute at most."
    }
    /// How to ask for it.
    public let examplePrompt = "Use notify with title `Build done` and message `The tests pass.`"

    /// Creates the tool over the session's host.
    ///
    /// - Parameters:
    ///   - host: The face's effects; its notifier is shared across the session so the rate limit covers
    ///     every conversation.
    ///   - audit: Where `notification` events go.
    public init(host: SessionHost, audit: AuditLog? = nil) {
        self.host = host
        self.audit = audit
    }

    /// Posts the notification.
    ///
    /// - Parameter arguments: Title and message.
    /// - Returns: `notification posted via <route>`, or `error: …` saying why not.
    public func call(arguments: Arguments) async -> String {
        switch host.notify(.init(title: arguments.title, body: arguments.message), source: .model, audit: audit) {
        case .posted(let route): "notification posted via \(route.rawValue)"
        case .refused(let reason): "error: notification not shown: \(reason)"
        }
    }
}
