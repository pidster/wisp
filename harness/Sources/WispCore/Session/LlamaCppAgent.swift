import Darwin
import Foundation
import ServiceManagement

/// The LaunchAgent that keeps wisp's own llama.cpp server running
/// ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 4). It runs the hidden
/// `wisp llamacpp serve`, which checks the binary and replaces itself with `llama-server` (`LlamaCppRouter`), so
/// launchd supervises the server: it starts it at login and when registered, and starts it again after a crash or a
/// kill.
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
        /// Not registered by `SMAppService`'s account, while launchd still holds a job of the agent's label: on
        /// 2026-10-30, after `wisp update`, `SMAppService` said the app's agent was not found and launchd kept its job.
        case orphaned
        /// Registered, and launchd refused to start it: its last exit was 78 (`EX_CONFIG`) and nothing runs. Seen on
        /// 2026-10-30 after `wisp update`, with a launch constraint listing no code hashes; registering the app with
        /// Launch Services again, then the agent, mended it.
        case refusedByLaunchd
        /// Not registered by this install, while launchd holds a job of the agent's label that another one registered:
        /// on 2026-10-30 a `wisp` outside the app (the release's staged binary) found no file in
        /// `~/Library/LaunchAgents` while `Wisp.app`'s Login Item ran the server, and `wisp doctor` failed.
        case registeredElsewhere(Holder)
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
            case .orphaned:
                "not registered, but launchd still holds its job; \(repairCommand) removes the job and registers "
                    + "the agent again"
            case .refusedByLaunchd:
                "registered, but launchd refused to start it (last exit code 78, EX_CONFIG); \(repairCommand) "
                    + "registers Wisp.app with Launch Services and the agent again"
            case .registeredElsewhere(let holder):
                "registered by \(holder.text), not by this wisp; launchd holds its job"
            case .manual(let reason): "none (\(reason)); run wisp llamacpp serve yourself"
            case .unknown(let reason): "unknown (\(reason))"
            }
        }

        /// Whether there is an agent to unregister or register again: registered, waiting for approval, or held by
        /// launchd.
        var isPresent: Bool {
            switch self {
            case .registered, .requiresApproval, .orphaned, .refusedByLaunchd: true
            case .notRegistered, .registeredElsewhere, .manual, .unknown: false
            }
        }

        /// Whether launchd holds a job that a restart (`launchctl kickstart -k`) reaches: registered here or by another
        /// install. The router reads the same `~/.wisp`, so either one runs with a changed setting once restarted.
        var isRestartable: Bool {
            switch self {
            case .registered, .registeredElsewhere: true
            default: false
            }
        }
    }

    /// Who registered a job launchd holds for the agent's label, as `launchctl print` says it.
    public enum Holder: Equatable, Sendable {
        /// `Wisp.app`'s Login Item: launchd says `managed_by = com.apple.xpc.ServiceManagement`.
        case loginItem
        /// A LaunchAgent file, at the path `launchctl print` names.
        case file(String)
        /// Another install, of which launchd says nothing more.
        case other

        /// The holder in words.
        public var text: String {
            switch self {
            case .loginItem: "Wisp.app's Login Item"
            case .file(let path): "the LaunchAgent file \(path)"
            case .other: "another install"
            }
        }

        /// The `wisp` that registered the job, which alone changes it, for the person to run `arguments` with.
        ///
        /// - Parameter arguments: What to run, after `wisp`.
        /// - Returns: The command, or where to run it.
        func command(_ arguments: String) -> String {
            switch self {
            case .loginItem: "\(LlamaCppAgent.appWisp) \(arguments)"
            case .file(let path): "wisp \(arguments), run with the wisp \(path) names"
            case .other: "wisp \(arguments), run with the wisp that registered it"
            }
        }
    }

    /// `Wisp.app`'s own `wisp`, which alone changes the app's Login Item.
    public static let appWisp = "/Applications/Wisp.app/Contents/MacOS/wisp"

    /// Who registered the job `launchctl print` describes: `Wisp.app`'s Login Item when `SMAppService` manages it, a
    /// LaunchAgent file when it names one as its `path`, another install otherwise.
    ///
    /// - Parameter printed: `launchctl print gui/<uid>/<label>`'s output.
    /// - Returns: The holder.
    static func holder(_ printed: String) -> Holder {
        let lines = printed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("managed_by = com.apple.xpc.ServiceManagement") { return .loginItem }
        if let path = lines.first(where: { $0.hasPrefix("path = /") })?.dropFirst("path = ".count) {
            return .file(String(path))
        }
        return .other
    }

    /// The command that registers the agent again from scratch (`mend(_:app:control:launchServices:audit:source:say:)`).
    public static let repairCommand = "wisp llamacpp agent repair"

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
    /// keys): the label; the program and its arguments; started when loaded; started again after any exit but a
    /// clean one (`KeepAlive` `SuccessfulExit` false), so a crash or a kill, such as one that frees memory, is
    /// started again, while a refusal to start, which exits 0, waits for the person rather than looping; and
    /// `ThrottleInterval`.
    ///
    /// - Parameter program: The program's absolute path.
    /// - Returns: The dictionary.
    static func properties(program: URL) -> [String: Any] {
        [
            "Label": label, "ProgramArguments": [program.path] + serveArguments, "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": throttleSeconds,
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
    /// - set to anything else, or `wisp uninstall`, unregisters it when it is registered, waiting for approval, or held
    ///   by launchd (`State.isPresent`), which stops the server;
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
        let present = state.isPresent
        switch trigger {
        case .server where wanted:
            if case .registeredElsewhere = state {
                say(
                    "wisp's llama.cpp server is \(state.text); this wisp registers no second job of the same label, "
                        + "and starts that one again")
                return act("restart", { try control.restart() })
            }
            say(
                "registering wisp's llama.cpp server as \(means.text); launchd starts it now and at each login, and "
                    + "again if it crashes or is killed")
            guard act("register", { try control.register() }) else { return false }
            if control.state() == .requiresApproval {
                say(
                    "it waits for your approval: turn on Wisp in System Settings > General > Login Items & "
                        + "Extensions")
            }
            return true
        case .server, .uninstall:
            if case .registeredElsewhere(let holder) = state {
                let why = "\(state.text); \(holder.command("config set llamacpp.server off")) unregisters it"
                guard trigger == .uninstall else {
                    record("unregister", "refused", why)
                    say("error: wisp's llama.cpp server is \(why)")
                    return false
                }
                record("unregister", "skipped", why)
                say("wisp's llama.cpp server is \(why); this wisp leaves it")
                return true
            }
            guard present else { return true }
            say(
                "unregistering wisp's llama.cpp server's LaunchAgent (\(means.text))"
                    + (state == .orphaned ? ", and the job launchd still holds for it" : "")
                    + "; launchd stops the server")
            return act("unregister", { try control.unregister() })
        case .setting(let path):
            guard server == .wisp, state.isRestartable else { return true }
            say(
                "restarting wisp's llama.cpp server so it runs with the new \(path); a model loads again on its next "
                    + "request")
            return act("restart", { try control.restart() })
        case .models(let model):
            guard server == .wisp, state.isRestartable else { return true }
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

    /// Launch Services' registration tool, which has no other path.
    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Registers `app` with Launch Services again (`lsregister -f`), so what it knows of the bundle identifier is the
    /// app as it now is.
    ///
    /// - Parameter app: The app.
    /// - Returns: The exit status and output.
    @Sendable static func launchServices(_ app: URL) -> (status: Int32, output: String) {
        AppUpdate.run(lsregister, ["-f", app.path])
    }

    /// Whether `launchctl print`'s output says launchd refused to start the job: its last exit code is 78
    /// (`EX_CONFIG`, launchd's own for a job it cannot spawn) and it is not running. `wisp llamacpp serve` never exits
    /// 78: its refusals exit 0.
    ///
    /// - Parameter printed: `launchctl print gui/<uid>/<label>`'s output.
    /// - Returns: True when refused.
    static func refusedByLaunchd(_ printed: String) -> Bool {
        let lines = printed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let exited78 = lines.contains { $0 == "last exit code = 78" || $0.hasPrefix("last exit code = 78:") }
        return exited78 && !lines.contains("state = running")
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

    /// Registered when the file is there and launchd has it loaded (`launchctl print` succeeds), or refused when
    /// launchd could not start it; registered elsewhere when launchd holds a job of the label that this file did not
    /// make (`Wisp.app`'s Login Item, or another file); not registered otherwise.
    func state() -> LlamaCppAgent.State {
        let printed = launchctl(["print", service])
        guard printed.status == 0 else { return .notRegistered }
        let holder = LlamaCppAgent.holder(printed.output)
        let exists = FileManager.default.fileExists(atPath: file.path)
        switch holder {
        case .file(let path) where path == file.path:
            guard exists else { return .notRegistered }
        case .other where exists:
            break
        default:
            return .registeredElsewhere(holder)
        }
        return LlamaCppAgent.refusedByLaunchd(printed.output) ? .refusedByLaunchd : .registered
    }

    /// Unloads any earlier agent, writes the file naming `program`, and loads it, which starts the server. Refuses when
    /// another install registered the label's job (`State.registeredElsewhere`), so a second job never competes with
    /// it; `LlamaCppAgent.follow` restarts that one instead.
    func register() throws {
        if case .registeredElsewhere(let holder) = state() {
            throw LlamaCppAgent.Failure.refused(
                "launchd holds its job, registered by \(holder.text); "
                    + holder.command("config set llamacpp.server wisp") + " changes it")
        }
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

    /// Unloads the agent, which stops the server, and removes its file; leaves a job another install registered.
    func unregister() throws {
        if case .registeredElsewhere = state() {} else { _ = launchctl(["bootout", service]) }
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

/// `SMAppService`'s agent, as `LoginItemAgent` uses it; a fake in tests.
protocol LoginItemService: Sendable {
    /// The agent's status.
    var status: SMAppService.Status { get }
    /// Registers the agent.
    ///
    /// - Throws: `SMAppService`'s error.
    func register() throws
    /// Unregisters the agent.
    ///
    /// - Throws: `SMAppService`'s error.
    func unregister() throws
}

/// The main bundle's agent file, `com.pidster.wisp.llamacpp.plist`, through `SMAppService`.
struct AppServiceAgent: LoginItemService {
    /// The service, asked afresh each time as `SMAppService` reads it.
    private var service: SMAppService { SMAppService.agent(plistName: LlamaCppAgent.plistName) }
    /// The agent's status.
    var status: SMAppService.Status { service.status }
    /// Registers the agent.
    func register() throws { try service.register() }
    /// Unregisters the agent.
    func unregister() throws { try service.unregister() }
}

/// The agent as `Wisp.app`'s own, registered with `SMAppService`, so it shows in Login Items. `SMAppService` finds the
/// agent's file in the main bundle, which is the app only when `wisp` runs from it by its real path; started through
/// a link, Foundation's main bundle is the link's folder, so the app's own `wisp` is asked to do it
/// (`wisp llamacpp agent register|unregister|status`).
struct LoginItemAgent: LlamaCppAgentControl {
    /// The app.
    let app: URL
    /// The main bundle's folder.
    let mainBundle: URL
    /// The agent's `SMAppService`; a fake in tests.
    let service: any LoginItemService
    /// The launchd domain target, `gui/<uid>/<label>`.
    let target: String
    /// Runs `launchctl`; a fake in tests.
    let launchctl: @Sendable ([String]) -> (status: Int32, output: String)
    /// Runs a program with arguments (the app's own `wisp`); a fake in tests.
    let run: @Sendable (String, [String]) -> (status: Int32, output: String)
    /// Whether to ask the app's own `wisp` even when the main bundle is the app: for `wisp update`, whose own bundle
    /// was the app it has just replaced.
    let delegates: Bool

    /// A control for `app`, through the real main bundle, `SMAppService`, `launchctl`, and processes unless given.
    init(
        app: URL, mainBundle: URL = Bundle.main.bundleURL, service: any LoginItemService = AppServiceAgent(),
        target: String = LlamaCppAgent.service,
        launchctl: @escaping @Sendable ([String]) -> (status: Int32, output: String) = LlamaCppAgent.launchctl,
        run: @escaping @Sendable (String, [String]) -> (status: Int32, output: String) = AppUpdate.run,
        delegates: Bool = false
    ) {
        self.app = app
        self.mainBundle = mainBundle
        self.service = service
        self.target = target
        self.launchctl = launchctl
        self.run = run
        self.delegates = delegates
    }

    /// The means.
    var means: LlamaCppAgent.Means { .loginItem(app: app) }

    /// Whether the main bundle is the app, so `SMAppService` reads the app's agent file, and this control does not
    /// always ask the app's own `wisp`.
    var inBundle: Bool {
        !delegates
            && mainBundle.resolvingSymlinksInPath().standardizedFileURL.path
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
        let result = run(executable.path, ["llamacpp", "agent", verb])
        guard result.status == 0 else { throw LlamaCppAgent.Failure.loginItem(result.output) }
        return result.output
    }

    /// `SMAppService`'s status with what launchd holds, read here or by the app's `wisp`.
    func state() -> LlamaCppAgent.State {
        guard inBundle else {
            do {
                return Self.state(named: try delegate("status"))
            } catch {
                return .unknown("\(error)")
            }
        }
        return Self.state(named: Self.status(service: service, target: target, launchctl: launchctl))
    }

    /// Registers with `SMAppService`, or, registered already, starts the server again.
    func register() throws {
        guard inBundle else {
            _ = try delegate("register")
            return
        }
        try Self.registerHere(service: service, target: target, launchctl: launchctl)
    }

    /// Unregisters with `SMAppService`.
    func unregister() throws {
        guard inBundle else {
            _ = try delegate("unregister")
            return
        }
        _ = try Self.unregisterHere(service: service, target: target, launchctl: launchctl)
    }

    /// `launchctl kickstart -k`, which reaches an agent `SMAppService` registered by its label.
    func restart() throws {
        let arguments = ["kickstart", "-k", target]
        let result = launchctl(arguments)
        guard result.status == 0 else {
            throw LlamaCppAgent.Failure.launchctl(arguments: arguments, status: result.status, output: result.output)
        }
    }

    /// Registers the main bundle's agent with `SMAppService`; when it is registered already, starts it again. A
    /// status of enabled that launchd has no job for is registered again: on 2026-10-30 a LaunchAgent file of the same
    /// label, loaded by `launchctl` and since removed, left Background Items reporting the app's agent enabled, and
    /// the restart failed with "Could not find service". A job of the label that launchd holds while `SMAppService`
    /// reports none (`State.orphaned`) is removed first, as unregistering does, so the registration is the only one.
    ///
    /// - Parameters:
    ///   - service: The agent's `SMAppService`.
    ///   - target: The launchd domain target, `gui/<uid>/<label>`.
    ///   - launchctl: Runs `launchctl`.
    /// - Throws: `Failure.loginItem`.
    static func registerHere(
        service: any LoginItemService = AppServiceAgent(), target: String = LlamaCppAgent.service,
        launchctl: ([String]) -> (status: Int32, output: String) = LlamaCppAgent.launchctl
    ) throws {
        switch service.status {
        case .enabled:
            if launchctl(["kickstart", "-k", target]).status == 0 { return }
        case .notRegistered, .notFound:
            if launchctl(["print", target]).status == 0 { _ = launchctl(["bootout", target]) }
        default:
            break
        }
        do {
            try service.register()
        } catch {
            throw LlamaCppAgent.Failure.loginItem(error.localizedDescription)
        }
    }

    /// Unregisters the main bundle's agent from `SMAppService`, when registered. When `SMAppService` reports none,
    /// a job of the label that launchd still holds is removed with `launchctl bootout`: on 2026-10-30, after
    /// `wisp update`, `SMAppService` said the app's agent was not found while launchd kept its job (type Submitted,
    /// managed by `com.apple.xpc.ServiceManagement`), and unregistering did nothing.
    ///
    /// - Parameters:
    ///   - service: The agent's `SMAppService`.
    ///   - target: The launchd domain target, `gui/<uid>/<label>`.
    ///   - launchctl: Runs `launchctl`.
    /// - Returns: What was done beyond `SMAppService`, to say, or nil.
    /// - Throws: `Failure.loginItem`, or `Failure.launchctl` when the job could not be removed.
    static func unregisterHere(
        service: any LoginItemService = AppServiceAgent(), target: String = LlamaCppAgent.service,
        launchctl: ([String]) -> (status: Int32, output: String) = LlamaCppAgent.launchctl
    ) throws -> String? {
        guard service.status != .notRegistered, service.status != .notFound else {
            guard launchctl(["print", target]).status == 0 else { return nil }
            let arguments = ["bootout", target]
            let result = launchctl(arguments)
            guard result.status == 0 else {
                throw LlamaCppAgent.Failure.launchctl(
                    arguments: arguments, status: result.status, output: result.output)
            }
            return "Login Items lists no agent, but launchd still held \(target); removed it (launchctl bootout)"
        }
        do {
            try service.unregister()
        } catch {
            throw LlamaCppAgent.Failure.loginItem(error.localizedDescription)
        }
        return nil
    }

    /// The agent's status by name: `SMAppService`'s (`name(of:)`), or `held-by-launchd` when it reports none and
    /// launchd holds a job of the label, `held-by-file PATH` when that job is a LaunchAgent file another install
    /// wrote, or `refused-by-launchd` when it is registered and launchd refused to start
    /// it (`LlamaCppAgent.refusedByLaunchd(_:)`).
    ///
    /// - Parameters:
    ///   - service: The agent's `SMAppService`.
    ///   - target: The launchd domain target, `gui/<uid>/<label>`.
    ///   - launchctl: Runs `launchctl`.
    /// - Returns: The name, for `state(named:)`.
    static func status(
        service: any LoginItemService, target: String, launchctl: ([String]) -> (status: Int32, output: String)
    ) -> String {
        let status = service.status
        switch status {
        case .enabled:
            let printed = launchctl(["print", target])
            return printed.status == 0 && LlamaCppAgent.refusedByLaunchd(printed.output)
                ? "refused-by-launchd" : name(of: status)
        case .notRegistered, .notFound:
            let printed = launchctl(["print", target])
            guard printed.status == 0 else { return name(of: status) }
            if case .file(let path) = LlamaCppAgent.holder(printed.output) { return "held-by-file \(path)" }
            return "held-by-launchd"
        default:
            return name(of: status)
        }
    }

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
        case "held-by-launchd": .orphaned
        case "refused-by-launchd": .refusedByLaunchd
        case let held where held.hasPrefix("held-by-file /"):
            .registeredElsewhere(.file(String(held.dropFirst("held-by-file ".count))))
        case "not-found":
            .unknown(
                "SMAppService finds no agent file \(LlamaCppAgent.plistName) in Wisp.app; after an update, "
                    + "\(LlamaCppAgent.repairCommand) registers the app with Launch Services and the agent again")
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
        try loginItem(verb, source: AppInstall.source(of: PackageLayout.current), service: AppServiceAgent())
    }

    /// `loginItem(_:)` for a given install and `SMAppService`, so tests use a fake.
    ///
    /// - Parameters:
    ///   - verb: `register`, `unregister`, or `status`.
    ///   - source: Where the running `wisp` came from.
    ///   - service: The agent's `SMAppService`.
    ///   - target: The launchd domain target, `gui/<uid>/<label>`.
    ///   - launchctl: Runs `launchctl`.
    /// - Returns: What to print.
    /// - Throws: `Failure`, or `Failure.refused` for another verb or outside the app.
    static func loginItem(
        _ verb: String, source: AppInstall.Source, service: any LoginItemService,
        target: String = LlamaCppAgent.service,
        launchctl: ([String]) -> (status: Int32, output: String) = LlamaCppAgent.launchctl
    ) throws -> String {
        guard case .app = source else {
            throw Failure.refused("wisp llamacpp agent is for Wisp.app's own wisp")
        }
        var said: [String] = []
        switch verb {
        case "register":
            try LoginItemAgent.registerHere(service: service, target: target, launchctl: launchctl)
        case "unregister":
            if let note = try LoginItemAgent.unregisterHere(service: service, target: target, launchctl: launchctl) {
                said.append(note)
            }
        case "status": break
        default: throw Failure.refused("no verb \(verb); register, unregister, status, or repair")
        }
        return (said + [LoginItemAgent.status(service: service, target: target, launchctl: launchctl)])
            .joined(separator: "\n")
    }
}
