import Darwin
import Foundation
import ServiceManagement

/// The LaunchAgent that keeps wisp's own llama.cpp server running
/// ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 4). It runs the hidden
/// `wisp llamacpp serve`, which checks the binary and replaces itself with `llama-server` (`LlamaCppRouter`), so
/// launchd supervises the server: it starts it at login and when registered, and starts it again after a crash.
///
/// `Wisp.app` carries the agent's file, `Contents/Library/LaunchAgents/com.pidster.wisp.llamacpp.plist`, and registers
/// it with `SMAppService`, so it shows in Login Items, where the person can turn it off. A Homebrew install, or a
/// build, writes `~/Library/LaunchAgents/com.pidster.wisp.llamacpp.plist` naming its own `wisp`, and loads it with
/// `launchctl bootstrap`. A home other than the person's (`WISP_HOME`), or `WISP_LLAMACPP_AGENT=off`, registers
/// nothing: the person runs `wisp llamacpp serve` themselves. Every call to launchd or `SMAppService` is behind
/// `LlamaCppAgentControl`, so tests use a fake.
public enum LlamaCppAgent {
    /// The agent's label, after the notifier's `com.pidster.wisp.notifier`.
    public static let label = "com.pidster.wisp.llamacpp"
    /// The agent file's name, in `Wisp.app`'s `Contents/Library/LaunchAgents` or `~/Library/LaunchAgents`.
    public static let plistName = "\(label).plist"
    /// The environment variable that, set to `off`, keeps wisp from registering the agent.
    public static let environmentKey = "WISP_LLAMACPP_AGENT"
    /// The arguments after the program: the hidden subcommand.
    public static let serveArguments = ["llamacpp", "serve"]
    /// Seconds launchd waits before starting the server again after it ended.
    public static let throttleSeconds = 30

    /// Where the agent is registered, or not.
    public enum State: Equatable, Sendable {
        /// Registered and loaded: launchd runs it.
        case registered
        /// Not registered.
        case notRegistered
        /// Registered with `SMAppService` and waiting for the person to allow it in Login Items.
        case requiresApproval
        /// wisp registers nothing here, for this reason: the person runs the server.
        case manual(String)
        /// The state could not be read, for this reason.
        case unknown(String)

        /// The state in words, for `wisp doctor`.
        public var text: String {
            switch self {
            case .registered: "registered"
            case .notRegistered: "not registered"
            case .requiresApproval: "waiting for your approval in Login Items"
            case .manual(let reason): "none (\(reason)); run wisp llamacpp serve yourself"
            case .unknown(let reason): "unknown (\(reason))"
            }
        }
    }

    /// How this wisp registers the agent.
    public enum Means: Equatable, Sendable {
        /// `Wisp.app`'s own agent file, through `SMAppService`.
        case loginItem(app: URL)
        /// A file wisp writes in `~/Library/LaunchAgents`, running `program`.
        case launchAgent(program: URL, file: URL)
        /// None: the person runs the server, for this reason.
        case manual(String)
        /// None: this wisp cannot register one, for this reason.
        case refused(String)

        /// The means in words.
        public var text: String {
            switch self {
            case .loginItem(let app):
                "a Login Item of \(app.path) (System Settings > General > Login Items & Extensions)"
            case .launchAgent(let program, let file): "a LaunchAgent, \(file.path), running \(program.path)"
            case .manual(let reason): "none (\(reason))"
            case .refused(let reason): "none (\(reason))"
            }
        }

        /// The means' name for the audit.
        var kind: String {
            switch self {
            case .loginItem: "login item"
            case .launchAgent: "launch agent"
            case .manual: "manual"
            case .refused: "refused"
            }
        }
    }

    /// Why the agent could not be registered, unregistered, or restarted.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `launchctl` refused.
        case launchctl(arguments: [String], status: Int32, output: String)
        /// `SMAppService` refused.
        case loginItem(String)
        /// The agent's file could not be written or removed.
        case file(String)
        /// This wisp cannot register one.
        case refused(String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .launchctl(let arguments, let status, let output):
                "launchctl \(arguments.joined(separator: " ")) failed (status \(status))"
                    + (output.isEmpty ? "" : ": \(output)")
            case .loginItem(let reason): "the Login Item could not be changed: \(reason)"
            case .file(let reason): "the LaunchAgent's file could not be changed: \(reason)"
            case .refused(let reason): "wisp cannot register its llama.cpp server here: \(reason)"
            }
        }
    }

    /// How a wisp registers the agent: none when `WISP_LLAMACPP_AGENT` is `off` or the home is not the person's own;
    /// `SMAppService` from `Wisp.app`; none from the disk image or a translocated copy; a file in
    /// `~/Library/LaunchAgents` naming this `wisp` otherwise, through Homebrew's stable `opt` link for a Homebrew
    /// install, so an upgrade does not leave the agent naming a removed version.
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - environment: The process environment.
    ///   - source: Where the running `wisp` came from (`AppInstall.source`).
    ///   - executable: The running `wisp`, links resolved.
    ///   - userHome: The person's home folder.
    /// - Returns: The means.
    public static func means(
        home: Home, environment: [String: String], source: AppInstall.Source, executable: URL?, userHome: URL
    ) -> Means {
        if environment[environmentKey]?.lowercased() == "off" { return .manual("\(environmentKey) is off") }
        guard home.isPersons else {
            return .manual("the home is \(home.root.path), not ~/.wisp, and the LaunchAgent serves the person's own")
        }
        switch source {
        case .app(let app): return .loginItem(app: app)
        case .diskImage, .translocated: return .refused(source.refusal ?? "Wisp.app is not in Applications")
        case .homebrew, .elsewhere:
            guard let executable else { return .refused("wisp cannot tell where its own executable is") }
            return .launchAgent(
                program: stableProgram(executable),
                file: userHome.appending(path: "Library/LaunchAgents/\(plistName)"))
        }
    }

    /// The path that keeps naming this `wisp` across upgrades: for a file in Homebrew's Cellar,
    /// `<prefix>/Cellar/wisp/<version>/…`, the same under `<prefix>/opt/wisp/…`, the link Homebrew keeps to the version
    /// installed; any other path as it is.
    ///
    /// - Parameter executable: The running `wisp`, links resolved.
    /// - Returns: The path to run.
    static func stableProgram(_ executable: URL) -> URL {
        let parts = executable.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 2 < parts.count, parts[cellar + 1] == "wisp"
        else { return executable }
        let stable = parts[..<cellar] + ["opt", "wisp"] + parts[(cellar + 3)...]
        return URL(filePath: stable.joined(separator: "/"))
    }

    /// The agent's properties, as both of its files carry them (`scripts/wisp-app` writes the app's with the same
    /// keys): the label; the program and its arguments; started when loaded; started again only after a crash
    /// (`KeepAlive` `Crashed`), so a refusal to start, which exits non-zero, waits for the person rather than looping;
    /// and `ThrottleInterval`.
    ///
    /// - Parameter program: The program's absolute path.
    /// - Returns: The dictionary.
    static func properties(program: URL) -> [String: Any] {
        [
            "Label": label, "ProgramArguments": [program.path] + serveArguments, "RunAtLoad": true,
            "KeepAlive": ["Crashed": true], "ThrottleInterval": throttleSeconds,
        ]
    }

    /// The agent's file for `~/Library/LaunchAgents`.
    ///
    /// - Parameter program: The program's absolute path.
    /// - Returns: An XML property list.
    /// - Throws: `Failure.file` when it cannot be serialised.
    static func plist(program: URL) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: properties(program: program), format: .xml, options: 0)
        } catch {
            throw Failure.file(error.localizedDescription)
        }
    }

    /// What led to registering, unregistering, or restarting the agent.
    public enum Trigger: Equatable, Sendable {
        /// `llamacpp.server` was set or unset.
        case server
        /// A setting the router runs with (`LlamaCppRouter.restartingSettings`) or the approved binary changed.
        case setting(String)
        /// A model was added to or removed from the router's folder, which the router reads only when it starts
        /// (probed on 2026-10-30: a link added while it ran was not listed).
        case models(String)
        /// `wisp uninstall`, which unregisters the agent whatever the setting.
        case uninstall

        /// The trigger as the audit's `trigger` names it.
        var name: String {
            switch self {
            case .server: "llamacpp.server"
            case .setting(let path): path
            case .models(let model): model
            case .uninstall: "uninstall"
            }
        }
    }

    /// Registers, unregisters, or restarts the agent as `trigger` asks, saying what it does before it does it, and
    /// records each action as `llamacpp.agent`:
    ///
    /// - `llamacpp.server` set to `wisp` registers the agent, which starts the server (again, when it ran);
    /// - set to anything else, or `wisp uninstall`, unregisters it when it is registered, which stops the server;
    /// - a setting, the approved binary, or the models changing under `wisp` restarts it when registered.
    ///
    /// - Parameters:
    ///   - trigger: What changed.
    ///   - server: `llamacpp.server` after the change.
    ///   - control: The agent's control.
    ///   - audit: Where actions are recorded.
    ///   - source: Who changed it (`cli`, `chat`).
    ///   - say: Says a line to the person.
    /// - Returns: False when an action failed, which was said.
    @discardableResult
    public static func follow(
        _ trigger: Trigger, server: LlamaCppServer, control: any LlamaCppAgentControl, audit: AuditLog?,
        source: String, say: (String) -> Void
    ) -> Bool {
        func record(_ action: String, _ outcome: String, _ reason: String?) {
            audit?.record(
                .llamaCppAgent,
                details: [
                    "action": .string(action), "means": .string(control.means.kind), "trigger": .string(trigger.name),
                    "outcome": .string(outcome), "reason": reason.map { .string($0) } ?? .null,
                    "source": .string(source),
                ])
        }
        func act(_ action: String, _ body: () throws -> Void) -> Bool {
            do {
                try body()
                record(action, "done", nil)
                return true
            } catch {
                record(action, "failed", "\(error)")
                say("error: \(error)")
                return false
            }
        }
        let means = control.means
        let wanted = trigger != .uninstall && server == .wisp
        switch (trigger, means) {
        case (.server, .manual(let reason)) where wanted:
            record("register", "skipped", reason)
            say(
                "wisp registers no LaunchAgent here (\(reason)); start its llama.cpp server yourself with "
                    + "wisp llamacpp serve")
            return true
        case (.server, .refused(let reason)) where wanted:
            record("register", "failed", reason)
            say("error: \(Failure.refused(reason))")
            return false
        case (_, .manual), (_, .refused):
            return true
        default:
            break
        }
        let state = control.state()
        let present = state == .registered || state == .requiresApproval
        switch trigger {
        case .server where wanted:
            say(
                "registering wisp's llama.cpp server as \(means.text); launchd starts it now and at each login, and "
                    + "again if it crashes")
            guard act("register", { try control.register() }) else { return false }
            if control.state() == .requiresApproval {
                say(
                    "it waits for your approval: turn on Wisp in System Settings > General > Login Items & "
                        + "Extensions")
            }
            return true
        case .server, .uninstall:
            guard present else { return true }
            say("unregistering wisp's llama.cpp server's LaunchAgent (\(means.text)); launchd stops the server")
            return act("unregister", { try control.unregister() })
        case .setting(let path):
            guard server == .wisp, state == .registered else { return true }
            say(
                "restarting wisp's llama.cpp server so it runs with the new \(path); a model loads again on its next "
                    + "request")
            return act("restart", { try control.restart() })
        case .models(let model):
            guard server == .wisp, state == .registered else { return true }
            say(
                "restarting wisp's llama.cpp server, which reads its models only when it starts, so it serves "
                    + "\(model) as it now stands")
            return act("restart", { try control.restart() })
        }
    }

    /// The control for `home`, from where this `wisp` came from: what the CLI and chat use. A home other than the
    /// person's gets one that registers nothing, so tests and scratch homes never reach launchd.
    ///
    /// - Parameter home: wisp's home.
    /// - Returns: The control.
    public static func control(home: Home) -> any LlamaCppAgentControl {
        let means = means(
            home: home, environment: ProcessInfo.processInfo.environment,
            source: AppInstall.source(of: PackageLayout.current), executable: ExecutablePath.current,
            userHome: FileManager.default.homeDirectoryForCurrentUser)
        switch means {
        case .loginItem(let app): return LoginItemAgent(app: app)
        case .launchAgent(let program, let file): return LaunchAgentFile(program: program, file: file)
        case .manual, .refused: return UnregisteredAgent(means: means)
        }
    }

    /// The launchd domain target of this user's agent: `gui/<uid>/<label>`.
    static var service: String { "gui/\(getuid())/\(label)" }

    /// Runs `launchctl` with `arguments`.
    ///
    /// - Parameter arguments: The arguments.
    /// - Returns: The exit status and output.
    @Sendable static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        AppUpdate.run("/bin/launchctl", arguments)
    }
}

/// Registers, unregisters, restarts, and reads the state of wisp's llama.cpp server's LaunchAgent; the one seam between
/// wisp and launchd or `SMAppService`, so tests use a fake.
public protocol LlamaCppAgentControl: Sendable {
    /// How it registers.
    var means: LlamaCppAgent.Means { get }
    /// The agent's state now.
    func state() -> LlamaCppAgent.State
    /// Registers the agent, which starts the server; when registered already, starts it again with the agent's file
    /// as it now is.
    ///
    /// - Throws: `LlamaCppAgent.Failure`.
    func register() throws
    /// Unregisters the agent, which stops the server.
    ///
    /// - Throws: `LlamaCppAgent.Failure`.
    func unregister() throws
    /// Stops the server and starts it again (`launchctl kickstart -k`).
    ///
    /// - Throws: `LlamaCppAgent.Failure`.
    func restart() throws
}

/// The control where wisp registers nothing: a scratch home, `WISP_LLAMACPP_AGENT=off`, or a wisp that cannot.
struct UnregisteredAgent: LlamaCppAgentControl {
    /// Why nothing is registered.
    let means: LlamaCppAgent.Means

    /// `manual`, with the reason.
    func state() -> LlamaCppAgent.State {
        switch means {
        case .manual(let reason), .refused(let reason): .manual(reason)
        default: .manual("nothing registered")
        }
    }

    /// Refuses: nothing is registered here.
    func register() throws { throw LlamaCppAgent.Failure.refused(means.text) }
    /// Nothing to do.
    func unregister() throws {}
    /// Refuses: nothing is registered here.
    func restart() throws { throw LlamaCppAgent.Failure.refused(means.text) }
}

/// The agent as a file in `~/Library/LaunchAgents`, loaded with `launchctl bootstrap`: a Homebrew install or a build.
struct LaunchAgentFile: LlamaCppAgentControl {
    /// The `wisp` the agent runs.
    let program: URL
    /// The agent's file.
    let file: URL
    /// The launchd domain target, `gui/<uid>/<label>`.
    let service: String
    /// Runs `launchctl`; a fake in tests.
    let launchctl: @Sendable ([String]) -> (status: Int32, output: String)

    /// A control for the file, through the real `launchctl` unless one is given.
    init(
        program: URL, file: URL, service: String = LlamaCppAgent.service,
        launchctl: @escaping @Sendable ([String]) -> (status: Int32, output: String) = LlamaCppAgent.launchctl
    ) {
        self.program = program
        self.file = file
        self.service = service
        self.launchctl = launchctl
    }

    /// The means.
    var means: LlamaCppAgent.Means { .launchAgent(program: program, file: file) }

    /// The user's domain, `gui/<uid>`.
    var domain: String { service.split(separator: "/").prefix(2).joined(separator: "/") }

    /// Registered when launchd has it loaded (`launchctl print` succeeds); not registered otherwise.
    func state() -> LlamaCppAgent.State {
        guard FileManager.default.fileExists(atPath: file.path) else { return .notRegistered }
        return launchctl(["print", service]).status == 0 ? .registered : .notRegistered
    }

    /// Unloads any earlier agent, writes the file naming `program`, and loads it, which starts the server.
    func register() throws {
        _ = launchctl(["bootout", service])
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LlamaCppAgent.plist(program: program).write(to: file, options: .atomic)
        } catch let failure as LlamaCppAgent.Failure {
            throw failure
        } catch {
            throw LlamaCppAgent.Failure.file("\(file.path): \(error.localizedDescription)")
        }
        let arguments = ["bootstrap", domain, file.path]
        let result = launchctl(arguments)
        guard result.status == 0 else {
            throw LlamaCppAgent.Failure.launchctl(arguments: arguments, status: result.status, output: result.output)
        }
    }

    /// Unloads the agent, which stops the server, and removes its file.
    func unregister() throws {
        _ = launchctl(["bootout", service])
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw LlamaCppAgent.Failure.file("\(file.path): \(error.localizedDescription)")
        }
    }

    /// `launchctl kickstart -k`.
    func restart() throws {
        let arguments = ["kickstart", "-k", service]
        let result = launchctl(arguments)
        guard result.status == 0 else {
            throw LlamaCppAgent.Failure.launchctl(arguments: arguments, status: result.status, output: result.output)
        }
    }
}

/// The agent as `Wisp.app`'s own, registered with `SMAppService`, so it shows in Login Items. `SMAppService` finds the
/// agent's file in the main bundle, which is the app only when `wisp` runs from it by its real path; started through
/// a link, Foundation's main bundle is the link's folder, so the app's own `wisp` is asked to do it
/// (`wisp llamacpp agent register|unregister|status`).
struct LoginItemAgent: LlamaCppAgentControl {
    /// The app.
    let app: URL

    /// The means.
    var means: LlamaCppAgent.Means { .loginItem(app: app) }

    /// Whether the main bundle is the app, so `SMAppService` reads the app's agent file.
    var inBundle: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            == app.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The app's own `wisp`.
    var executable: URL { app.appending(path: "Contents/MacOS/wisp") }

    /// Asks the app's own `wisp` to do `verb`.
    ///
    /// - Parameter verb: `register`, `unregister`, or `status`.
    /// - Returns: Its output.
    /// - Throws: `Failure.loginItem` with its output when it fails.
    func delegate(_ verb: String) throws -> String {
        let result = AppUpdate.run(executable.path, ["llamacpp", "agent", verb])
        guard result.status == 0 else { throw LlamaCppAgent.Failure.loginItem(result.output) }
        return result.output
    }

    /// `SMAppService`'s status, read here or by the app's `wisp`.
    func state() -> LlamaCppAgent.State {
        guard inBundle else {
            do {
                return Self.state(named: try delegate("status"))
            } catch {
                return .unknown("\(error)")
            }
        }
        return Self.state(of: SMAppService.agent(plistName: LlamaCppAgent.plistName).status)
    }

    /// Registers with `SMAppService`, or, registered already, starts the server again.
    func register() throws {
        guard inBundle else {
            _ = try delegate("register")
            return
        }
        try Self.registerHere()
    }

    /// Unregisters with `SMAppService`.
    func unregister() throws {
        guard inBundle else {
            _ = try delegate("unregister")
            return
        }
        try Self.unregisterHere()
    }

    /// `launchctl kickstart -k`, which reaches an agent `SMAppService` registered by its label.
    func restart() throws {
        let arguments = ["kickstart", "-k", LlamaCppAgent.service]
        let result = LlamaCppAgent.launchctl(arguments)
        guard result.status == 0 else {
            throw LlamaCppAgent.Failure.launchctl(arguments: arguments, status: result.status, output: result.output)
        }
    }

    /// Registers the main bundle's agent with `SMAppService`; when it is registered already, starts it again.
    ///
    /// - Throws: `Failure.loginItem`.
    static func registerHere() throws {
        let service = SMAppService.agent(plistName: LlamaCppAgent.plistName)
        if service.status == .enabled {
            let result = LlamaCppAgent.launchctl(["kickstart", "-k", LlamaCppAgent.service])
            guard result.status == 0 else { throw LlamaCppAgent.Failure.loginItem(result.output) }
            return
        }
        do {
            try service.register()
        } catch {
            throw LlamaCppAgent.Failure.loginItem(error.localizedDescription)
        }
    }

    /// Unregisters the main bundle's agent from `SMAppService`, when registered.
    ///
    /// - Throws: `Failure.loginItem`.
    static func unregisterHere() throws {
        let service = SMAppService.agent(plistName: LlamaCppAgent.plistName)
        guard service.status != .notRegistered, service.status != .notFound else { return }
        do {
            try service.unregister()
        } catch {
            throw LlamaCppAgent.Failure.loginItem(error.localizedDescription)
        }
    }

    /// The main bundle's agent's status, as `wisp llamacpp agent status` prints it.
    static var statusHere: String { name(of: SMAppService.agent(plistName: LlamaCppAgent.plistName).status) }

    /// A status's name.
    ///
    /// - Parameter status: `SMAppService`'s status.
    /// - Returns: `registered`, `requires-approval`, `not-registered`, or `not-found`.
    static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "registered"
        case .requiresApproval: "requires-approval"
        case .notRegistered: "not-registered"
        case .notFound: "not-found"
        @unknown default: "unknown"
        }
    }

    /// The state a status means.
    ///
    /// - Parameter status: `SMAppService`'s status.
    /// - Returns: The state.
    static func state(of status: SMAppService.Status) -> LlamaCppAgent.State {
        state(named: name(of: status))
    }

    /// The state a status's name means.
    ///
    /// - Parameter name: As `name(of:)` gives it.
    /// - Returns: The state.
    static func state(named name: String) -> LlamaCppAgent.State {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "registered": .registered
        case "requires-approval": .requiresApproval
        case "not-registered": .notRegistered
        case "not-found": .unknown("Wisp.app carries no agent file \(LlamaCppAgent.plistName)")
        case let other: .unknown(other)
        }
    }
}

extension LlamaCppAgent {
    /// What `wisp llamacpp agent VERB` does in the app's own `wisp`, for a `wisp` started through a link: the
    /// `SMAppService` call, here, where the main bundle is the app.
    ///
    /// - Parameter verb: `register`, `unregister`, or `status`.
    /// - Returns: What to print.
    /// - Throws: `Failure`, or `Failure.refused` for another verb or outside the app.
    public static func loginItem(_ verb: String) throws -> String {
        guard case .app = AppInstall.source(of: PackageLayout.current) else {
            throw Failure.refused("wisp llamacpp agent is for Wisp.app's own wisp")
        }
        switch verb {
        case "register":
            try LoginItemAgent.registerHere()
            return LoginItemAgent.statusHere
        case "unregister":
            try LoginItemAgent.unregisterHere()
            return LoginItemAgent.statusHere
        case "status": return LoginItemAgent.statusHere
        default: throw Failure.refused("no verb \(verb); register, unregister, or status")
        }
    }
}
