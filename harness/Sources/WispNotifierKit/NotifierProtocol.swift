/// What `wisp` and `Wisp Notifier.app` say to each other: the helper's command line, its answers, and its exit
/// statuses ([ADR 0070](../../../docs/decisions/0070-a-notification-helper.md)). Shared by both, so neither can drift
/// from the other; Foundation-free, so the helper stays small.
public enum NotifierProtocol {
    /// The helper bundle's file name, beside `wisp`.
    public static let bundleName = "Wisp Notifier.app"
    /// The helper's bundle identifier; macOS keeps the person's permission under it, so it never changes.
    public static let bundleIdentifier = "com.pidster.wisp.notifier"
    /// The executable inside the bundle, `Contents/MacOS/WispNotifier`.
    public static let executableName = "WispNotifier"
    /// The name banners and Notification settings show.
    public static let displayName = "Wisp"

    /// One notification for the helper to post.
    public struct Request: Equatable, Sendable {
        /// Names the notification; posting the same identifier again replaces the banner, never adds one.
        public var id: String
        /// The bold first line.
        public var title: String
        /// An optional second line under the title.
        public var subtitle: String?
        /// The body.
        public var body: String
        /// Whether to play the default sound.
        public var sound: Bool
        /// The bundle identifier of the app to bring forward when the banner is clicked: the terminal wisp ran in.
        public var activate: String?

        /// Creates a request; the text is bounded by wisp before it gets here.
        public init(
            id: String, title: String, subtitle: String? = nil, body: String, sound: Bool = false,
            activate: String? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.sound = sound
            self.activate = activate
        }
    }

    /// What the helper is asked to do.
    public enum Command: Equatable, Sendable {
        /// Print the permission, ask nothing.
        case status
        /// Ask the person for permission, and print the answer.
        case ask
        /// Post a notification, when the person has allowed it.
        case post(Request)
    }

    /// The person's answer, as the helper prints it: `UNAuthorizationStatus` in words.
    public enum Permission: String, Equatable, Sendable {
        /// Not asked yet.
        case notDetermined = "not-determined"
        /// Refused, or turned off in System Settings.
        case denied
        /// Allowed.
        case authorized
        /// Allowed quietly, to Notification Center only.
        case provisional
        /// A status this helper does not know.
        case unknown

        /// Whether a notification can be posted.
        public var allowsPosting: Bool { self == .authorized || self == .provisional }
    }

    /// The helper's exit statuses.
    public enum Exit: Int32, Sendable {
        /// Done: posted, or the permission printed.
        case done = 0
        /// The framework failed; the error is on standard error.
        case failed = 1
        /// The person has not allowed notifications; the permission is printed.
        case notAllowed = 3
        /// The command line was not understood.
        case usage = 64
    }

    /// The command line for `command`, without the executable.
    ///
    /// - Parameter command: What to ask.
    /// - Returns: The arguments.
    public static func arguments(_ command: Command) -> [String] {
        switch command {
        case .status: return ["--status"]
        case .ask: return ["--ask"]
        case .post(let request):
            var arguments = ["--post", "--id", request.id, "--title", request.title, "--body", request.body]
            if let subtitle = request.subtitle { arguments += ["--subtitle", subtitle] }
            if request.sound { arguments.append("--sound") }
            if let activate = request.activate { arguments += ["--activate", activate] }
            return arguments
        }
    }

    /// What the helper reads from its command line.
    public enum Parsed: Equatable, Sendable {
        /// A command.
        case command(Command)
        /// No arguments at all: macOS launched it for a click on one of its banners.
        case launched
        /// Not understood; the text says why.
        case invalid(String)
    }

    /// Reads the helper's command line. Each option's value is the argument after it, whatever it holds, so a title
    /// that starts with `--` is still a title.
    ///
    /// - Parameter arguments: The arguments, without the executable.
    /// - Returns: The command, `launched`, or why the line is invalid.
    public static func parse(_ arguments: [String]) -> Parsed {
        guard let first = arguments.first else { return .launched }
        switch first {
        case "--status": return arguments.count == 1 ? .command(.status) : .invalid("--status takes nothing")
        case "--ask": return arguments.count == 1 ? .command(.ask) : .invalid("--ask takes nothing")
        case "--post": return post(Array(arguments.dropFirst()))
        default: return .invalid("unknown command \(first)")
        }
    }

    /// Reads `--post`'s options.
    ///
    /// - Parameter options: The arguments after `--post`.
    /// - Returns: The request, or why it is invalid.
    private static func post(_ options: [String]) -> Parsed {
        var values: [String: String] = [:]
        var sound = false
        var index = 0
        while index < options.count {
            let option = options[index]
            switch option {
            case "--sound":
                sound = true
                index += 1
            case "--id", "--title", "--subtitle", "--body", "--activate":
                guard index + 1 < options.count else { return .invalid("\(option) needs a value") }
                guard values[option] == nil else { return .invalid("\(option) given twice") }
                values[option] = options[index + 1]
                index += 2
            default:
                return .invalid("unknown option \(option)")
            }
        }
        guard let id = values["--id"], !id.isEmpty else { return .invalid("--post needs --id") }
        guard let body = values["--body"], !body.isEmpty else { return .invalid("--post needs --body") }
        return .command(
            .post(
                Request(
                    id: id, title: values["--title"] ?? "", subtitle: values["--subtitle"], body: body, sound: sound,
                    activate: values["--activate"])))
    }
}
