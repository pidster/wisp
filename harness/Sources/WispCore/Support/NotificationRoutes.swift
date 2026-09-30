import Foundation

/// How a notification reached the person ([ADR 0044](../../../../docs/decisions/0044-host-effects.md)),
/// in the order they are tried.
public enum NotificationRoute: String, Sendable, CaseIterable {
    /// The front end, which declared `notify` in its `hello`, posts it (`wisp-tui` writes the terminal's
    /// sequence between its frames).
    case host
    /// wisp writes the terminal's escape sequence to `/dev/tty`, and the terminal posts it under its name.
    case terminal
    /// `display notification` sent to the terminal app by bundle identifier (`notifications.viaTerminalApp`).
    case app
    /// `display notification` in wisp's own process, attributed to Script Editor.
    case osascript
}

/// The escape sequences terminals post a notification for, and how wisp writes one safely.
public enum TerminalNotification {
    /// A terminal's notification sequence.
    public enum Sequence: String, Sendable {
        /// `ESC ] 9 ; text BEL`: Ghostty, iTerm2, WezTerm.
        case osc9 = "OSC 9"
        /// `ESC ] 99 ; metadata ; text ESC \`: kitty, title and body as two chunks of one notification.
        case osc99 = "OSC 99"
    }

    /// The terminal the environment names, and the sequence it posts, if any.
    public struct Terminal: Equatable, Sendable {
        /// Its name for people: `Ghostty`, `Terminal.app`, or the variable's own value.
        public var name: String
        /// The sequence it posts; nil when it has none.
        public var sequence: Sequence?
    }

    /// The terminal named by `TERM_PROGRAM`, which decides when set (so `tmux` inside kitty is tmux, which
    /// does not pass the sequence through), or else by `TERM`; nil when neither names one. The same table
    /// as `wisp-tui`'s `notify::detect`.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: The terminal, or nil.
    public static func terminal(in environment: [String: String]) -> Terminal? {
        if let program = environment["TERM_PROGRAM"], !program.isEmpty {
            switch program {
            case "ghostty": return Terminal(name: "Ghostty", sequence: .osc9)
            case "iTerm.app": return Terminal(name: "iTerm2", sequence: .osc9)
            case "WezTerm": return Terminal(name: "WezTerm", sequence: .osc9)
            case "kitty": return Terminal(name: "kitty", sequence: .osc99)
            case "Apple_Terminal": return Terminal(name: "Terminal.app", sequence: nil)
            default: return Terminal(name: program, sequence: nil)
            }
        }
        switch environment["TERM"] {
        case "xterm-ghostty": return Terminal(name: "Ghostty", sequence: .osc9)
        case "wezterm": return Terminal(name: "WezTerm", sequence: .osc9)
        case "xterm-kitty": return Terminal(name: "kitty", sequence: .osc99)
        default: return nil
        }
    }

    /// `text` safe inside an escape sequence: every C0 and C1 control character and DEL (ESC, BEL, and
    /// the 8-bit string terminator among them) becomes a space, and `;`, the sequences' field separator,
    /// becomes `,`, so the text can neither end the sequence nor be read as its parameters. Applied on
    /// top of `Notifier.cleaned`, whatever it already removed.
    ///
    /// - Parameter text: The text.
    /// - Returns: The text, trimmed.
    public static func sanitised(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F: " "
            case 0x3B: ","
            default: Character(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// The title, with the subtitle after it when there is one.
    private static func heading(_ message: Notifier.Message) -> String {
        let title = sanitised(message.title)
        let subtitle = sanitised(message.subtitle ?? "")
        if subtitle.isEmpty { return title }
        return title.isEmpty ? subtitle : "\(title) — \(subtitle)"
    }

    /// The bytes that post `message` with `sequence`: for OSC 9 `ESC ] 9 ; heading: body BEL`; for OSC 99
    /// the heading as the title chunk (`d=0`) and the body as the body chunk, both under `id`, each ended
    /// by `ESC \`.
    ///
    /// - Parameters:
    ///   - sequence: The terminal's sequence.
    ///   - message: The notification.
    ///   - id: Names a kitty notification's chunks.
    /// - Returns: The bytes to write.
    public static func bytes(_ sequence: Sequence, message: Notifier.Message, id: String) -> [UInt8] {
        let heading = heading(message)
        let body = sanitised(message.body)
        switch sequence {
        case .osc9:
            let text = heading.isEmpty ? body : "\(heading): \(body)"
            return Array("\u{1B}]9;\(text)\u{07}".utf8)
        case .osc99:
            let id = String(sanitised(id).map { ":= ".contains($0) ? "-" : $0 })
            return Array(
                ("\u{1B}]99;i=\(id):d=0:p=title;\(heading)\u{1B}\\" + "\u{1B}]99;i=\(id):p=body;\(body)\u{1B}\\").utf8)
        }
    }

    /// Writes bytes to the terminal; returns nil when written, or why not.
    public typealias Writer = @Sendable ([UInt8]) -> String?

    /// Writes to `/dev/tty`, the controlling terminal, never to stdout: stdout is the reply stream in chat.
    /// Opened for each notification, without becoming the controlling terminal, and without blocking on a
    /// terminal that has stopped output.
    public static let tty: Writer = { bytes in
        let descriptor = open("/dev/tty", O_WRONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return "no terminal (/dev/tty does not open)" }
        defer { close(descriptor) }
        let written = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
        return written == bytes.count ? nil : "writing to /dev/tty failed"
    }

    /// Whether `/dev/tty` opens for writing, as the terminal route needs; writes nothing. For `wisp doctor`.
    public static let ttyOpens: @Sendable () -> Bool = {
        let descriptor = open("/dev/tty", O_WRONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}

/// The routes a face can post a notification by, tried in ADR 0044's order, first that works: the front
/// end, the terminal, the terminal app by bundle identifier, and `osascript`. The bounds, the rate limit,
/// and the off switch (`Notifier`) apply before any route.
public struct NotificationRoutes: Sendable {
    /// A front end that can post notifications itself: `wisp-tui` over `wisp chat --json`.
    public struct FrontEnd: Sendable {
        /// Whether the front end's `hello` declared `notify`; asked at each notification, since `hello`
        /// arrives after the session opens.
        public var declared: @Sendable () -> Bool
        /// Sends the `notify` line.
        public var send: @Sendable (Notifier.Message) -> Void

        /// Creates a front end.
        ///
        /// - Parameters:
        ///   - declared: Whether `hello` declared `notify`.
        ///   - send: Sends one notification to it.
        public init(declared: @escaping @Sendable () -> Bool, send: @escaping @Sendable (Notifier.Message) -> Void) {
            self.declared = declared
            self.send = send
        }
    }

    /// Which face this is, which decides whether the front end and the terminal routes can be used.
    public enum Face: Sendable {
        /// Plain chat and the one-shot commands: wisp's own terminal, if it has one.
        case terminal
        /// `wisp chat --json`: the front end owns the terminal, so wisp never writes to it.
        case frontEnd(FrontEnd)
        /// `wisp mcp`: the client owns the terminal, if any (a client in a terminal, such as Claude Code, is
        /// itself drawing on it; its MCP servers share its controlling terminal).
        case mcp
        /// No screen of its own: only the process routes.
        case headless
    }

    /// One route in the plan: tried, or skipped and why.
    enum Step: Equatable, Sendable {
        /// Skipped, with the reason.
        case skip(NotificationRoute, String)
        /// Tried; the text says why it can work.
        case attempt(NotificationRoute, String)
    }

    /// The face.
    public var face: Face
    /// Whether the app route is on (`notifications.viaTerminalApp`).
    public var viaTerminalApp: Bool
    /// Only this route, for `wisp notify --route`: the others are not tried, and the app route is tried
    /// even when the setting is off, so an operator can probe it.
    public var only: NotificationRoute?
    /// The process environment: `TERM_PROGRAM`, `TERM`, `__CFBundleIdentifier`.
    var environment: [String: String]
    /// Writes the sequence to the terminal.
    var writeTerminal: TerminalNotification.Writer

    /// Creates the routes for a face.
    ///
    /// - Parameters:
    ///   - face: Which face.
    ///   - viaTerminalApp: `notifications.viaTerminalApp`.
    ///   - only: A single route to use, for `wisp notify --route`.
    ///   - environment: The environment; tests inject one.
    ///   - writeTerminal: Writes to the terminal; tests inject one, and never write to the real terminal.
    public init(
        face: Face, viaTerminalApp: Bool = false, only: NotificationRoute? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        writeTerminal: @escaping TerminalNotification.Writer = TerminalNotification.tty
    ) {
        self.face = face
        self.viaTerminalApp = viaTerminalApp
        self.only = only
        self.environment = environment
        self.writeTerminal = writeTerminal
    }

    /// Only the process routes: the app route when on, then `osascript`.
    public static var headless: NotificationRoutes { NotificationRoutes(face: .headless) }

    /// The plan: each route in order, tried or skipped with the reason.
    func steps() -> [Step] {
        var steps = [
            hostStep(), terminalStep(), appStep(forced: only == .app),
            .attempt(.osascript, "banners come from Script Editor"),
        ]
        if let only {
            steps = steps.filter {
                switch $0 {
                case .skip(let route, _), .attempt(let route, _): route == only
                }
            }
        }
        return steps
    }

    private func hostStep() -> Step {
        switch face {
        case .frontEnd(let frontEnd):
            frontEnd.declared()
                ? .attempt(.host, "the front end declared notify") : .skip(.host, "the front end declared no notify")
        case .mcp: .skip(.host, "MCP has no notification")
        case .terminal, .headless: .skip(.host, "no front end")
        }
    }

    private func terminalStep() -> Step {
        switch face {
        case .frontEnd: return .skip(.terminal, "the front end owns the terminal")
        case .mcp: return .skip(.terminal, "the MCP client owns the terminal")
        case .headless: return .skip(.terminal, "not used by this face")
        case .terminal:
            guard let terminal = TerminalNotification.terminal(in: environment) else {
                return .skip(.terminal, "TERM_PROGRAM names no terminal")
            }
            guard let sequence = terminal.sequence else {
                return .skip(.terminal, "\(terminal.name) has no notification sequence")
            }
            return .attempt(.terminal, "\(terminal.name) posts \(sequence.rawValue) notifications")
        }
    }

    private func appStep(forced: Bool) -> Step {
        guard viaTerminalApp || forced else { return .skip(.app, "off (notifications.viaTerminalApp)") }
        guard let bundle = environment["__CFBundleIdentifier"], !bundle.isEmpty else {
            return .skip(.app, "no __CFBundleIdentifier")
        }
        return .attempt(.app, "posted as \(bundle)")
    }

    /// Posts `message` by the first route that works.
    ///
    /// - Parameters:
    ///   - message: The notification, already bounded.
    ///   - run: Runs `osascript` with arguments, for the app and `osascript` routes.
    /// - Returns: The outcome, and why each earlier route was not taken (`route: reason`).
    func deliver(_ message: Notifier.Message, run: Notifier.Runner) -> (Notifier.Outcome, skipped: [String]) {
        var skipped: [String] = []
        for step in steps() {
            switch step {
            case .skip(let route, let reason):
                skipped.append("\(route.rawValue): \(reason)")
            case .attempt(.host, _):
                guard case .frontEnd(let frontEnd) = face else { continue }
                frontEnd.send(message)
                return (.posted(.host), skipped)
            case .attempt(.terminal, _):
                guard let sequence = TerminalNotification.terminal(in: environment)?.sequence else { continue }
                let bytes = TerminalNotification.bytes(sequence, message: message, id: "wisp-" + ShortID.make())
                if let failure = writeTerminal(bytes) {
                    skipped.append("terminal: \(failure)")
                } else {
                    return (.posted(.terminal), skipped)
                }
            case .attempt(.app, _):
                let status = run(Notifier.appArguments(for: message, bundle: environment["__CFBundleIdentifier"] ?? ""))
                if status == 0 { return (.posted(.app), skipped) }
                skipped.append("app: osascript exited with status \(status)")
            case .attempt(.osascript, _):
                let status = run(Notifier.arguments(for: message))
                if status == 0 { return (.posted(.osascript), skipped) }
                return (.refused("osascript exited with status \(status)"), skipped)
            }
        }
        return (.refused(skipped.last ?? "no route can post it"), skipped)
    }
}
