import Foundation
import ServiceManagement
import Synchronization
import Testing

@testable import WispCore

/// wisp's llama.cpp server's LaunchAgent as `Wisp.app`'s Login Item (ADR 0082, decision 4), and the controls that
/// register nothing or fail: driven through a fake `SMAppService`, a fake `launchctl`, and a fake app `wisp`. Nothing
/// here reaches launchd, `SMAppService`, or `~/Library/LaunchAgents`; every file is under the temporary folder.
@Suite(.serialized) struct LlamaCppAgentTests {
    /// The scratch root, real path.
    private let root: URL
    /// The app the Login Item belongs to; never created, as nothing reads it.
    private let app: URL
    /// The launchd domain target the fakes are given.
    private let target = "gui/501/com.pidster.wisp.llamacpp"

    init() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "wisp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        root = URL(filePath: CommandPolicy.canonical(scratch.path))
        app = root.appending(path: "Applications/Wisp.app")
    }

    /// A Login Item control whose main bundle is the app, so it calls `service` itself, and which fails the test if it
    /// asks the app's `wisp` anything.
    private func inBundle(_ service: FakeLoginItemService, launchctl: FakeLaunchctl) -> LoginItemAgent {
        LoginItemAgent(
            app: app, mainBundle: app, service: service, target: target, launchctl: { launchctl.run($0) },
            run: { program, arguments in
                Issue.record("asked the app's wisp: \(program) \(arguments)")
                return (1, "")
            })
    }

    /// The calls that change something: all but `launchctl print`.
    private func changes(_ launchctl: FakeLaunchctl) -> [[String]] { launchctl.calls.filter { $0.first != "print" } }

    // MARK: - From the app itself

    @Test func theAppsOwnAgentRegistersThroughSMAppServiceAndRestartsWhenRegistered() throws {
        let service = FakeLoginItemService(.notRegistered)
        let launchctl = FakeLaunchctl()
        let agent = inBundle(service, launchctl: launchctl)
        #expect(agent.inBundle && agent.means == .loginItem(app: app))
        #expect(
            agent.means.text == "a Login Item of \(app.path) (System Settings > General > Login Items & Extensions)")
        #expect(agent.state() == .notRegistered)
        // Not registered: registered, and launchd is only asked whether it holds a job, not to restart one.
        try agent.register()
        #expect(service.calls == ["register"] && changes(launchctl).isEmpty && agent.state() == .registered)
        // Registered and known to launchd: restarted, not registered again.
        try agent.register()
        #expect(service.calls == ["register"] && changes(launchctl) == [["kickstart", "-k", target]])
        // Unregistered once; asked again with nothing registered, `SMAppService` is not asked.
        try agent.unregister()
        try agent.unregister()
        #expect(service.calls == ["register", "unregister"] && agent.state() == .notRegistered)
        try agent.restart()
        #expect(launchctl.calls.last == ["kickstart", "-k", target])
    }

    @Test func anEnabledAgentLaunchdDoesNotKnowIsRegisteredAgain() throws {
        // As on 2026-10-30: Background Items said enabled, and the kickstart found no service.
        let service = FakeLoginItemService(.enabled)
        let launchctl = FakeLaunchctl(failing: 113, output: "Could not find service")
        let agent = inBundle(service, launchctl: launchctl)
        try agent.register()
        #expect(launchctl.calls == [["kickstart", "-k", target]] && service.calls == ["register"])
        #expect {
            try agent.restart()
        } throws: { error in
            "\(error)" == "launchctl kickstart -k \(target) failed (status 113): Could not find service"
        }
    }

    @Test func aRefusalBySMAppServiceIsSaidAsTheLoginItems() {
        let service = FakeLoginItemService(.requiresApproval, refusing: "Operation not permitted")
        let agent = inBundle(service, launchctl: FakeLaunchctl())
        #expect(agent.state() == .requiresApproval)
        #expect(throws: LlamaCppAgent.Failure.loginItem("Operation not permitted")) { try agent.register() }
        #expect(throws: LlamaCppAgent.Failure.loginItem("Operation not permitted")) { try agent.unregister() }
        #expect(
            "\(LlamaCppAgent.Failure.loginItem("Operation not permitted"))"
                == "the Login Item could not be changed: Operation not permitted")
        // An app without the agent's file.
        service.set(.notFound)
        #expect(
            agent.state()
                == .unknown(
                    "SMAppService finds no agent file com.pidster.wisp.llamacpp.plist in Wisp.app; after an update, "
                        + "wisp llamacpp agent repair registers the app with Launch Services and the agent again"))
        #expect(service.calls == ["register", "unregister"])
    }

    @Test func registeringALoginItemThatWaitsForApprovalSaysWhereToAllowIt() {
        let service = FakeLoginItemService(.notRegistered, becoming: .requiresApproval)
        let agent = inBundle(service, launchctl: FakeLaunchctl())
        let sink = MemoryAuditSink()
        var said: [String] = []
        let ok = LlamaCppAgent.follow(
            .server, server: .wisp, control: agent, audit: AuditLog(session: "s", sink: sink), source: "cli",
            say: { said.append($0) })
        #expect(ok && service.calls == ["register"])
        #expect(said.first?.contains("as a Login Item of \(app.path)") == true, "\(said)")
        #expect(
            said.last
                == "it waits for your approval: turn on Wisp in System Settings > General > Login Items & Extensions")
        let recorded = sink.events.filter { $0.kind == .llamaCppAgent }
        #expect(recorded.count == 1 && recorded.first?.details["means"] == "login item")
    }

    // MARK: - Through a link, by the app's own wisp

    @Test func startedThroughALinkTheAppsOwnWispIsAsked() throws {
        let wisp = FakeAppWisp([
            "status": (0, "requires-approval\n"), "register": (0, "registered\n"), "unregister": (1, "not allowed"),
        ])
        let service = FakeLoginItemService(.enabled)
        let launchctl = FakeLaunchctl()
        let agent = LoginItemAgent(
            app: app, mainBundle: root.appending(path: "bin"), service: service, target: target,
            launchctl: { launchctl.run($0) }, run: { wisp.run($0, $1) })
        #expect(!agent.inBundle)
        #expect(agent.state() == .requiresApproval)
        try agent.register()
        #expect(throws: LlamaCppAgent.Failure.loginItem("not allowed")) { try agent.unregister() }
        let program = app.appending(path: "Contents/MacOS/wisp").path
        #expect(
            wisp.calls == [
                [program, "llamacpp", "agent", "status"], [program, "llamacpp", "agent", "register"],
                [program, "llamacpp", "agent", "unregister"],
            ])
        // Neither `SMAppService` nor launchd was asked here.
        #expect(service.calls.isEmpty && launchctl.calls.isEmpty)
        // A status it cannot give, or one it does not know, is unknown, with its reason.
        let failing = LoginItemAgent(
            app: app, mainBundle: root, service: service, target: target, launchctl: { launchctl.run($0) },
            run: { _, _ in (1, "no such file") })
        #expect(failing.state() == .unknown("the Login Item could not be changed: no such file"))
        #expect(LoginItemAgent.state(named: "frozen\n") == .unknown("frozen"))
    }

    @Test func theAppsOwnWispAnswersEachVerbAndRefusesOutsideTheApp() throws {
        let service = FakeLoginItemService(.notRegistered)
        let launchctl = FakeLaunchctl()
        func run(_ verb: String, source: AppInstall.Source = .app(app)) throws -> String {
            try LlamaCppAgent.loginItem(
                verb, source: source, service: service, target: target, launchctl: { launchctl.run($0) })
        }
        #expect(try run("status") == "not-registered")
        #expect(try run("register") == "registered")
        #expect(try run("unregister") == "not-registered")
        #expect(service.calls == ["register", "unregister"])
        #expect(throws: LlamaCppAgent.Failure.refused("no verb restart; register, unregister, status, or repair")) {
            try run("restart")
        }
        #expect(throws: LlamaCppAgent.Failure.refused("wisp llamacpp agent is for Wisp.app's own wisp")) {
            try run("status", source: .homebrew)
        }
        // The test binary is no app: refused before `SMAppService` is asked.
        #expect(throws: LlamaCppAgent.Failure.refused("wisp llamacpp agent is for Wisp.app's own wisp")) {
            try LlamaCppAgent.loginItem("status")
        }
        #expect(
            [SMAppService.Status.enabled, .requiresApproval, .notRegistered, .notFound].map(LoginItemAgent.name(of:))
                == ["registered", "requires-approval", "not-registered", "not-found"])
    }

    // MARK: - A job launchd holds, and launchd's refusal (2026-10-30)

    @Test func aJobLaunchdStillHoldsIsSeenAndRemovedWhenUnregistering() throws {
        // As after the update on 2026-10-30: `SMAppService` said not found, and launchd kept the job.
        let service = FakeLoginItemService(.notFound)
        let launchctl = FakeLaunchctl(loaded: true)
        let agent = inBundle(service, launchctl: launchctl)
        #expect(agent.state() == .orphaned && agent.state().isPresent)
        #expect(agent.state().text.contains("launchd still holds its job; wisp llamacpp agent repair"))
        try agent.unregister()
        #expect(changes(launchctl) == [["bootout", target]] && service.calls.isEmpty)
        // Gone from launchd too: the state is `SMAppService`'s again, and unregistering asks nothing more.
        #expect(agent.state() == LoginItemAgent.state(named: "not-found"))
        try agent.unregister()
        #expect(changes(launchctl) == [["bootout", target]])
        // The app's own wisp says what it removed, then the status.
        let held = FakeLaunchctl(loaded: true)
        let said = try LlamaCppAgent.loginItem(
            "unregister", source: .app(app), service: FakeLoginItemService(.notRegistered), target: target,
            launchctl: { held.run($0) })
        #expect(
            said == "Login Items lists no agent, but launchd still held \(target); removed it (launchctl bootout)\n"
                + "not-registered")
        #expect(
            try LlamaCppAgent.loginItem(
                "status", source: .app(app), service: FakeLoginItemService(.notRegistered), target: target,
                launchctl: { FakeLaunchctl(loaded: true).run($0) }) == "held-by-launchd")
    }

    @Test func aJobThatCannotBeRemovedIsSaid() {
        let service = FakeLoginItemService(.notRegistered)
        let agent = inBundle(service, launchctl: FakeLaunchctl())
        let failing = LoginItemAgent(
            app: app, mainBundle: app, service: service, target: target,
            launchctl: { $0.first == "bootout" ? (5, "Boot-out failed: 5: Input/output error") : (0, "") },
            run: agent.run)
        #expect(
            throws: LlamaCppAgent.Failure.launchctl(
                arguments: ["bootout", target], status: 5, output: "Boot-out failed: 5: Input/output error")
        ) { try failing.unregister() }
    }

    @Test func registeringRemovesAJobLaunchdHoldsFirst() throws {
        let service = FakeLoginItemService(.notRegistered)
        let launchctl = FakeLaunchctl(loaded: true)
        try inBundle(service, launchctl: launchctl).register()
        #expect(launchctl.calls == [["print", target], ["bootout", target]] && service.calls == ["register"])
    }

    @Test func launchdsRefusalToStartTheAgentIsRead() throws {
        // `launchctl print` as on 2026-10-30, trimmed.
        let refused =
            "gui/501/com.pidster.wisp.llamacpp = {\n\tactive count = 0\n\tstate = spawn scheduled\n"
            + "\tlast exit code = 78: EX_CONFIG\n}"
        #expect(LlamaCppAgent.refusedByLaunchd(refused))
        #expect(!LlamaCppAgent.refusedByLaunchd(refused.replacing("spawn scheduled", with: "running")))
        #expect(!LlamaCppAgent.refusedByLaunchd(refused.replacing("78: EX_CONFIG", with: "(never exited)")))
        #expect(!LlamaCppAgent.refusedByLaunchd(refused.replacing("78: EX_CONFIG", with: "780")))
        #expect(LlamaCppAgent.refusedByLaunchd("last exit code = 78"))
        let agent = inBundle(FakeLoginItemService(.enabled), launchctl: FakeLaunchctl(loaded: true, printed: refused))
        #expect(agent.state() == .refusedByLaunchd && agent.state().isPresent)
        #expect(agent.state().text.contains("(last exit code 78, EX_CONFIG); wisp llamacpp agent repair"))
        #expect(
            try LlamaCppAgent.loginItem(
                "status", source: .app(app), service: FakeLoginItemService(.enabled), target: target,
                launchctl: { FakeLaunchctl(loaded: true, printed: refused).run($0) }) == "refused-by-launchd")
        // A file agent launchd refused reads the same.
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LaunchAgentFile(
            program: URL(filePath: "/w/wisp"), file: root.appending(path: "LaunchAgents/\(LlamaCppAgent.plistName)"),
            service: target, launchctl: { FakeLaunchctl(loaded: true, printed: refused).run($0) })
        try file.register()
        #expect(file.state() == .refusedByLaunchd)
    }

    @Test func turningTheServerOffRemovesAJobLaunchdHolds() {
        let agent = FakeAgent(state: .orphaned, means: .loginItem(app: app))
        var said: [String] = []
        let ok = LlamaCppAgent.follow(.server, server: .off, control: agent, audit: nil, source: "cli") {
            said.append($0)
        }
        #expect(ok && agent.calls == ["unregister"])
        #expect(said.first?.contains(", and the job launchd still holds for it; launchd stops the server") == true)
    }

    // MARK: - After an update, and repair

    /// Runs `mend` with a fake Launch Services answering `status`, and returns what was said, recorded, and asked.
    private func mend(
        _ reason: LlamaCppAgent.Mend, app: URL?, control: any LlamaCppAgentControl, lsregister: Int32 = 0
    ) -> (ok: Bool, said: [String], recorded: [AuditEvent], registered: [URL]) {
        let sink = MemoryAuditSink()
        var asked: [URL] = []
        var said: [String] = []
        let ok = LlamaCppAgent.mend(
            reason, app: app, control: control,
            launchServices: { app in
                asked.append(app)
                return (lsregister, lsregister == 0 ? "" : "spawn failed")
            }, audit: AuditLog(session: "s", sink: sink), source: "cli", say: { said.append($0) })
        return (ok, said, sink.events.filter { $0.kind == .llamaCppAgent }, asked)
    }

    @Test func anUpdateRegistersTheAppWithLaunchServicesAndARegisteredAgentAgain() {
        let agent = FakeAgent(state: .registered, means: .loginItem(app: app))
        let result = mend(.update, app: app, control: agent)
        #expect(result.ok && result.registered == [app] && agent.calls == ["unregister", "register"])
        #expect(
            result.said.first
                == "registering \(app.path) with Launch Services again, so macOS knows the app as it now is")
        #expect(result.said.last?.hasPrefix("registering wisp's llama.cpp server again as a Login Item of") == true)
        #expect(result.recorded.map { $0.details["action"] } == ["launch services", "unregister", "register"])
        #expect(result.recorded.allSatisfy { $0.details["trigger"] == "update" && $0.details["outcome"] == "done" })
        // No agent: only Launch Services is asked.
        let none = FakeAgent(state: .notRegistered, means: .loginItem(app: app))
        let quiet = mend(.update, app: app, control: none)
        #expect(quiet.ok && none.calls.isEmpty && quiet.said.count == 1 && quiet.recorded.count == 1)
    }

    @Test func aFailureAfterAnUpdateIsAWarningThatNamesRepair() {
        let none = FakeAgent(state: .notRegistered, means: .loginItem(app: app))
        let unregistered = mend(.update, app: app, control: none, lsregister: 1)
        #expect(!unregistered.ok && none.calls.isEmpty)
        #expect(
            unregistered.said.last
                == "warning: lsregister -f failed (status 1): spawn failed; the update is done, and wisp llamacpp agent "
                + "repair tries again")
        #expect(unregistered.recorded.first?.details["outcome"] == "failed")
        let refusing = FakeAgent(
            state: .refusedByLaunchd, means: .loginItem(app: app), failure: .loginItem("Operation not permitted"))
        let failed = mend(.update, app: app, control: refusing)
        #expect(!failed.ok && refusing.calls == ["unregister"])
        #expect(
            failed.said.last
                == "warning: the Login Item could not be changed: Operation not permitted; the update is done, and "
                + "wisp llamacpp agent repair tries again")
        #expect(failed.recorded.map { $0.details["outcome"] } == ["done", "failed"])
    }

    @Test func afterAnUpdateTheNewAppsOwnWispIsAsked() throws {
        let wisp = FakeAppWisp(["status": (0, "held-by-launchd\n"), "unregister": (0, ""), "register": (0, "")])
        let agent = LoginItemAgent(
            app: app, mainBundle: app, service: FakeLoginItemService(.enabled), target: target,
            launchctl: { _ in (0, "") }, run: { wisp.run($0, $1) }, delegates: true)
        #expect(!agent.inBundle)
        let result = mend(.update, app: app, control: agent)
        #expect(result.ok)
        #expect(wisp.calls.map { $0.last } == ["status", "unregister", "register", "status"])
    }

    @Test func repairRegistersAgainAndSaysWhenThereIsNothingToRepair() {
        // An agent waiting for approval stays waiting, and is said so.
        let service = FakeLoginItemService(.requiresApproval, becoming: .requiresApproval)
        let waiting = mend(.repair, app: app, control: inBundle(service, launchctl: FakeLaunchctl()))
        #expect(waiting.ok && service.calls == ["unregister", "register"])
        #expect(waiting.said.last?.hasPrefix("it waits for your approval") == true)
        // Not registered: nothing to register again.
        let none = FakeAgent(state: .notRegistered)
        let idle = mend(.repair, app: nil, control: none)
        #expect(idle.ok && none.calls.isEmpty && idle.registered.isEmpty)
        #expect(
            idle.said == [
                "wisp's llama.cpp server's LaunchAgent is not registered, so there is nothing to register again; wisp "
                    + "config set llamacpp.server wisp registers it"
            ])
        // A failure in repair is an error.
        let failing = FakeAgent(state: .registered, failure: .file("x"))
        #expect(
            mend(.repair, app: nil, control: failing).said.last
                == "error: the LaunchAgent's file could not be changed: x")
        // A scratch home registers nothing, and asks Launch Services nothing.
        var said: [String] = []
        #expect(LlamaCppAgent.repair(home: Home(root: root.appending(path: "home")), audit: nil) { said.append($0) })
        #expect(said.count == 1 && said[0].hasPrefix("wisp registers no LaunchAgent here ("), "\(said)")
    }

    // MARK: - Nothing registered, and a file that cannot be written

    @Test func whereNothingIsRegisteredRegisteringAndRestartingAreRefused() throws {
        let manual = UnregisteredAgent(means: .manual("WISP_LLAMACPP_AGENT is off"))
        #expect(manual.state() == .manual("WISP_LLAMACPP_AGENT is off"))
        #expect(throws: LlamaCppAgent.Failure.refused("none (WISP_LLAMACPP_AGENT is off)")) { try manual.register() }
        #expect(throws: LlamaCppAgent.Failure.refused("none (WISP_LLAMACPP_AGENT is off)")) { try manual.restart() }
        try manual.unregister()
        let refused = UnregisteredAgent(means: .refused("on the disk image"))
        #expect(refused.state() == .manual("on the disk image"))
        #expect(
            "\(LlamaCppAgent.Failure.refused(refused.means.text))"
                == "wisp cannot register its llama.cpp server here: none (on the disk image)")
        // A scratch home gets a control that registers nothing.
        let control = LlamaCppAgent.control(home: Home(root: root.appending(path: "home")))
        if case .manual = control.state() {} else { Issue.record("a scratch home registers: \(control.state())") }
    }

    @Test func aLaunchAgentFileThatCannotBeWrittenOrRemovedIsSaid() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        // The folder for the file is a file.
        let blocked = root.appending(path: "LaunchAgents")
        try Data("x".utf8).write(to: blocked)
        let launchctl = FakeLaunchctl()
        let unwritable = LaunchAgentFile(
            program: URL(filePath: "/w/wisp"), file: blocked.appending(path: LlamaCppAgent.plistName),
            service: target, launchctl: { launchctl.run($0) })
        #expect {
            try unwritable.register()
        } throws: { error in
            guard case .file(let reason) = error as? LlamaCppAgent.Failure else { return false }
            return reason.hasPrefix(unwritable.file.path) && "\(error)".hasPrefix("the LaunchAgent's file could not")
        }
        // Loading was not tried: only the earlier agent was unloaded.
        #expect(launchctl.calls == [["bootout", target]])
        // A file in a folder it cannot be removed from.
        let folder = root.appending(path: "Locked")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let locked = LaunchAgentFile(
            program: URL(filePath: "/w/wisp"), file: folder.appending(path: LlamaCppAgent.plistName),
            service: target, launchctl: { launchctl.run($0) })
        try locked.register()
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect {
            try locked.unregister()
        } throws: { error in
            guard case .file(let reason) = error as? LlamaCppAgent.Failure else { return false }
            return reason.hasPrefix(locked.file.path)
        }
        #expect(manager.fileExists(atPath: locked.file.path))
    }
}

/// `SMAppService` for one agent: a status that registering and unregistering change, every call recorded, and a
/// refusal when given one.
final class FakeLoginItemService: LoginItemService {
    /// The status and the calls so far.
    private let current: Mutex<(status: SMAppService.Status, calls: [String])>
    /// The status registering leaves.
    let becoming: SMAppService.Status
    /// What every call is refused with, if anything.
    let refusal: String?

    /// A service at `status`.
    init(_ status: SMAppService.Status, becoming: SMAppService.Status = .enabled, refusing refusal: String? = nil) {
        current = Mutex((status, []))
        self.becoming = becoming
        self.refusal = refusal
    }

    /// The calls so far.
    var calls: [String] { current.withLock { $0.calls } }

    /// The status.
    var status: SMAppService.Status { current.withLock { $0.status } }

    /// Sets the status.
    func set(_ status: SMAppService.Status) { current.withLock { $0.status = status } }

    /// Records a call, then refuses or moves to `status`.
    private func call(_ name: String, becoming status: SMAppService.Status) throws {
        current.withLock { $0.calls.append(name) }
        if let refusal {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal])
        }
        set(status)
    }

    /// Registers.
    func register() throws { try call("register", becoming: becoming) }
    /// Unregisters.
    func unregister() throws { try call("unregister", becoming: .notRegistered) }
}

/// The app's own `wisp`, answering `wisp llamacpp agent VERB` with a canned status and output, each call recorded.
final class FakeAppWisp: Sendable {
    /// The calls so far, the program first.
    private let log = Mutex<[[String]]>([])
    /// The answer to each verb.
    let replies: [String: (status: Int32, output: String)]

    /// A `wisp` answering `replies`.
    init(_ replies: [String: (status: Int32, output: String)]) { self.replies = replies }

    /// The calls so far.
    var calls: [[String]] { log.withLock { $0 } }

    /// Runs `program` with `arguments`: the answer for the last argument, the verb.
    func run(_ program: String, _ arguments: [String]) -> (status: Int32, output: String) {
        log.withLock { $0.append([program] + arguments) }
        return replies[arguments.last ?? ""] ?? (1, "no answer")
    }
}
