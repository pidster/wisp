import Foundation

extension LlamaCppAgent {
    /// Why the agent is registered again from scratch.
    public enum Mend: String, Equatable, Sendable {
        /// `wisp update` has just replaced `Wisp.app`.
        case update
        /// The person ran `wisp llamacpp agent repair`.
        case repair
    }

    /// Registers the app with Launch Services again and, when there is an agent (`State.isPresent`), unregisters it
    /// and registers it again, so launchd runs the app as it now is. On 2026-10-30, after `wisp update` replaced
    /// `Wisp.app` (and after a trial app of the same bundle identifier had been registered and deleted), launchd
    /// refused to start the app's agent (exit 78, `EX_CONFIG`), and `SMAppService` then reported it not found while
    /// launchd kept its job; `lsregister -f` on the app, unregistering, and registering mended it. The cause is not
    /// proven: a record in Launch Services of a copy since deleted or replaced is the leading guess.
    ///
    /// Each step is said before it is done and recorded as `llamacpp.agent` with `trigger` `update` or `repair`
    /// (action `launch services`, `unregister`, or `register`). After an update a failure is a warning: the update is
    /// done, and the warning names `wisp llamacpp agent repair`.
    ///
    /// - Parameters:
    ///   - reason: An update or the person's repair.
    ///   - app: The app to register with Launch Services, or nil (an agent that is not a Login Item).
    ///   - control: The agent's control; after an update, one that asks the new app's own `wisp`.
    ///   - launchServices: Registers an app with Launch Services (`launchServices(_:)`); a fake in tests.
    ///   - audit: Where actions are recorded.
    ///   - source: Who asked (`cli`).
    ///   - say: Says a line to the person.
    /// - Returns: False when a step failed, which was said.
    @discardableResult
    static func mend(
        _ reason: Mend, app: URL?, control: any LlamaCppAgentControl,
        launchServices: (URL) -> (status: Int32, output: String), audit: AuditLog?, source: String,
        say: (String) -> Void
    ) -> Bool {
        let means = control.means
        func record(_ action: String, _ outcome: String, _ why: String?) {
            audit?.record(
                .llamaCppAgent,
                details: [
                    "action": .string(action), "means": .string(means.kind), "trigger": .string(reason.rawValue),
                    "outcome": .string(outcome), "reason": why.map { .string($0) } ?? .null,
                    "source": .string(source),
                ])
        }
        let level = reason == .update ? "warning" : "error"
        let afterwards = reason == .update ? "; the update is done, and \(repairCommand) tries again" : ""
        var ok = true
        if let app {
            say("registering \(app.path) with Launch Services again, so macOS knows the app as it now is")
            let result = launchServices(app)
            if result.status == 0 {
                record("launch services", "done", nil)
            } else {
                let why =
                    "lsregister -f failed (status \(result.status))"
                    + (result.output.isEmpty ? "" : ": \(result.output)")
                record("launch services", "failed", why)
                say("\(level): \(why)\(afterwards)")
                ok = false
            }
        }
        switch means {
        case .manual(let why), .refused(let why):
            if reason == .repair { say("wisp registers no LaunchAgent here (\(why)); nothing else to repair") }
            return ok
        case .loginItem, .launchAgent:
            break
        }
        let state = control.state()
        guard state.isPresent else {
            if reason == .repair {
                say(
                    "wisp's llama.cpp server's LaunchAgent is \(state.text), so there is nothing to register again; "
                        + "wisp config set llamacpp.server wisp registers it")
            }
            return ok
        }
        say(
            "registering wisp's llama.cpp server again as \(means.text): unregistering it, then registering it, so "
                + "launchd runs the app as it now is; the server stops and starts again")
        let steps: [(String, () throws -> Void)] = [
            ("unregister", { try control.unregister() }), ("register", { try control.register() }),
        ]
        for (action, body) in steps {
            do {
                try body()
                record(action, "done", nil)
            } catch {
                record(action, "failed", "\(error)")
                say("\(level): \(error)\(afterwards)")
                return false
            }
        }
        if control.state() == .requiresApproval {
            say("it waits for your approval: turn on Wisp in System Settings > General > Login Items & Extensions")
        }
        return ok
    }

    /// What `wisp update` does once it has replaced `app`: registers the app with Launch Services again and, when the
    /// router's Login Item is registered or launchd holds its job, registers it again through the new app's own
    /// `wisp` (`mend(_:app:control:launchServices:audit:source:say:)`). Nothing it does fails the update.
    ///
    /// - Parameters:
    ///   - app: The app just replaced.
    ///   - home: wisp's home; a home other than the person's registers no agent, and only Launch Services is asked.
    ///   - audit: Where actions are recorded.
    ///   - say: Says a line to the person.
    /// - Returns: False when a step failed, which was said as a warning.
    @discardableResult
    public static func afterUpdate(app: URL, home: Home, audit: AuditLog?, say: (String) -> Void) -> Bool {
        let means = means(
            home: home, environment: ProcessInfo.processInfo.environment, source: .app(app),
            executable: ExecutablePath.current, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let control: any LlamaCppAgentControl =
            if case .loginItem(let app) = means { LoginItemAgent(app: app, delegates: true) } else {
                UnregisteredAgent(means: means)
            }
        return mend(
            .update, app: app, control: control, launchServices: launchServices, audit: audit, source: "cli", say: say)
    }

    /// `wisp llamacpp agent repair`: registers `Wisp.app` with Launch Services again, when the agent is its Login
    /// Item, then unregisters the agent, removing a job launchd still holds, and registers it again
    /// (`mend(_:app:control:launchServices:audit:source:say:)`).
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - audit: Where actions are recorded.
    ///   - say: Says a line to the person.
    /// - Returns: False when a step failed, which was said.
    public static func repair(home: Home, audit: AuditLog?, say: (String) -> Void) -> Bool {
        let control = control(home: home)
        let app: URL? = if case .loginItem(let app) = control.means { app } else { nil }
        return mend(
            .repair, app: app, control: control, launchServices: launchServices, audit: audit, source: "cli", say: say)
    }
}
