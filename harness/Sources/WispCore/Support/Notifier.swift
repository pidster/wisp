import Foundation
import Synchronization

/// Posts macOS notifications for the model's `notify` tool and for `wisp notify`
/// ([ADR 0030](../../../../docs/decisions/0030-notifications.md), amended by
/// [ADR 0044](../../../../docs/decisions/0044-host-effects.md)).
///
/// Text is bounded and stripped of control characters, posts are limited per minute across the whole
/// process, and the off switch is checked, before any route; then the face's `NotificationRoutes` post it
/// by the first route that works: the front end, the terminal's escape sequence, the terminal app, or
/// `osascript`'s `display notification`. The AppleScript routes pass every piece of text as an argument,
/// never spliced into the script, so nothing the model writes can become AppleScript. Every attempt is
/// audited as `notification`, posted or not, with the route taken.
public final class Notifier: Sendable {
    /// One notification.
    public struct Message: Equatable, Sendable {
        /// The bold first line.
        public var title: String
        /// The body.
        public var body: String
        /// An optional second line under the title.
        public var subtitle: String?
        /// Whether to play the default sound.
        public var sound: Bool

        /// Creates a message; text is bounded when posted, not here.
        public init(title: String, body: String, subtitle: String? = nil, sound: Bool = false) {
            self.title = title
            self.body = body
            self.subtitle = subtitle
            self.sound = sound
        }
    }

    /// Who asked for a notification, for the audit.
    public enum Source: String, Sendable {
        /// The model, through its `notify` tool.
        case model
        /// A person, through `wisp notify`.
        case user
        /// `wisp watch`, when a watched command's outcome turns.
        case watch
        /// `wisp mcp`, when a command waits for the person's approval (ADR 0046).
        case approval
    }

    /// What happened to one request.
    public enum Outcome: Equatable, Sendable {
        /// Handed on by this route; delivery is not awaited.
        case posted(NotificationRoute)
        /// Not sent, and why.
        case refused(String)
    }

    /// Characters kept in each field.
    public static let titleLimit = 64
    /// Characters kept in the body.
    public static let bodyLimit = 256

    /// Runs `/usr/bin/osascript` with these arguments and returns its exit status: the app and `osascript`
    /// routes.
    public typealias Runner = @Sendable ([String]) -> Int32

    private let enabled: Bool
    private let perMinute: Int
    private let run: Runner
    private let clock: @Sendable () -> Date
    private let recent = Mutex<[Date]>([])

    /// Creates a notifier.
    ///
    /// - Parameters:
    ///   - enabled: Whether notifications are posted at all (`notifications.enabled`).
    ///   - perMinute: At most this many posts in any sixty seconds (`notifications.perMinute`).
    ///   - run: Runs `osascript`; the default spawns it with a five-second limit.
    ///   - clock: The time, for the rate limit.
    public init(
        enabled: Bool = true, perMinute: Int = 5, run: @escaping Runner = Notifier.osascript,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.enabled = enabled
        self.perMinute = perMinute
        self.run = run
        self.clock = clock
    }

    /// The AppleScript: every value comes from `argv`, so none of it is ever parsed as script.
    static let script = [
        "on run argv",
        "set theBody to item 1 of argv",
        "set theTitle to item 2 of argv",
        "set theSubtitle to item 3 of argv",
        "if item 4 of argv is \"sound\" then",
        "display notification theBody with title theTitle subtitle theSubtitle sound name \"default\"",
        "else",
        "display notification theBody with title theTitle subtitle theSubtitle",
        "end if",
        "end run",
    ]

    /// The app route's AppleScript: the same notification, sent to the terminal app named by its bundle
    /// identifier so it posts under the app's name; every value, the identifier included, comes from `argv`.
    static let appScript = [
        "on run argv",
        "set theBody to item 1 of argv",
        "set theTitle to item 2 of argv",
        "set theSubtitle to item 3 of argv",
        "tell application id (item 5 of argv)",
        "if item 4 of argv is \"sound\" then",
        "display notification theBody with title theTitle subtitle theSubtitle sound name \"default\"",
        "else",
        "display notification theBody with title theTitle subtitle theSubtitle",
        "end if",
        "end tell",
        "end run",
    ]

    /// The `osascript` arguments for `message`: the script lines, then the bounded values.
    public static func arguments(for message: Message) -> [String] {
        script.flatMap { ["-e", $0] } + values(message)
    }

    /// The `osascript` arguments that send `message` to the app with identifier `bundle`.
    ///
    /// - Parameters:
    ///   - message: The notification.
    ///   - bundle: The app's bundle identifier (`__CFBundleIdentifier`).
    /// - Returns: The app script's lines, then the bounded values and the identifier.
    public static func appArguments(for message: Message, bundle: String) -> [String] {
        appScript.flatMap { ["-e", $0] } + values(message) + [bundle]
    }

    /// The bounded values both scripts read: body, title, subtitle, and whether to play the sound.
    private static func values(_ message: Message) -> [String] {
        [
            cleaned(message.body, limit: bodyLimit), cleaned(message.title, limit: titleLimit),
            cleaned(message.subtitle ?? "", limit: titleLimit), message.sound ? "sound" : "quiet",
        ]
    }

    /// `message` with every field bounded and cleaned, as each route receives it.
    static func bounded(_ message: Message) -> Message {
        Message(
            title: cleaned(message.title, limit: titleLimit), body: cleaned(message.body, limit: bodyLimit),
            subtitle: message.subtitle.map { cleaned($0, limit: titleLimit) }, sound: message.sound)
    }

    /// `text` with control characters turned into spaces, trimmed, and cut to `limit` with an ellipsis.
    public static func cleaned(_ text: String, limit: Int) -> String {
        let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// Posts `message` unless notifications are off, the body is empty, or the rate limit is reached, by
    /// the first of `routes` that works, and records the attempt.
    ///
    /// - Parameters:
    ///   - message: What to show.
    ///   - source: Who asked.
    ///   - audit: Where the `notification` event goes; nil records nothing.
    ///   - routes: The face's routes; a face's `SessionHost` passes its own. By default only the process
    ///     routes.
    /// - Returns: The route it was handed to, or why it was not posted.
    @discardableResult
    public func post(
        _ message: Message, source: Source, audit: AuditLog?, routes: NotificationRoutes = .headless
    ) -> Outcome {
        let (outcome, skipped) = decide(message, routes: routes)
        audit?.record(
            .notification,
            details: AuditEvent.Details.notification(
                title: Self.cleaned(message.title, limit: Self.titleLimit),
                body: Self.cleaned(message.body, limit: Self.bodyLimit), source: source.rawValue,
                outcome: outcome, skipped: skipped))
        return outcome
    }

    private func decide(_ message: Message, routes: NotificationRoutes) -> (Outcome, skipped: [String]) {
        guard enabled else { return (.refused("notifications are turned off (notifications.enabled)"), []) }
        guard !Self.cleaned(message.body, limit: Self.bodyLimit).isEmpty else {
            return (.refused("a notification needs a message"), [])
        }
        let now = clock()
        let allowed = recent.withLock { times in
            times.removeAll { now.timeIntervalSince($0) >= 60 }
            guard times.count < perMinute else { return false }
            times.append(now)
            return true
        }
        guard allowed else { return (.refused("at most \(perMinute) notifications a minute; try again shortly"), []) }
        return routes.deliver(Self.bounded(message), run: run)
    }

    /// Spawns `/usr/bin/osascript` with the arguments, giving it five seconds.
    public static let osascript: Runner = spawner("/usr/bin/osascript", timeout: 5)

    /// A runner that spawns `path` with the arguments and returns its exit status: -1 when it cannot
    /// start or outlives `timeout` seconds (it is then terminated).
    static func spawner(_ path: String, timeout: TimeInterval) -> Runner {
        { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return -1 }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                return -1
            }
            return process.terminationStatus
        }
    }
}
