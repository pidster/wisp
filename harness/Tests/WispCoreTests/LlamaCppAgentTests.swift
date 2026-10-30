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

    // MARK: - From the app itself

    @Test func theAppsOwnAgentRegistersThroughSMAppServiceAndRestartsWhenRegistered() throws {
        let service = FakeLoginItemService(.notRegistered)
        let launchctl = FakeLaunchctl()
        let agent = inBundle(service, launchctl: launchctl)
        #expect(agent.inBundle && agent.means == .loginItem(app: app))
        #expect(
            agent.means.text == "a Login Item of \(app.path) (System Settings > General > Login Items & Extensions)")
        #expect(agent.state() == .notRegistered)
        // Not registered: registered, and launchd is not asked to restart what it does not have.
        try agent.register()
        #expect(service.calls == ["register"] && launchctl.calls.isEmpty && agent.state() == .registered)
        // Registered and known to launchd: restarted, not registered again.
        try agent.register()
        #expect(service.calls == ["register"] && launchctl.calls == [["kickstart", "-k", target]])
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
        #expect(agent.state() == .unknown("Wisp.app carries no agent file com.pidster.wisp.llamacpp.plist"))
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
        #expect(throws: LlamaCppAgent.Failure.refused("no verb restart; register, unregister, or status")) {
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
