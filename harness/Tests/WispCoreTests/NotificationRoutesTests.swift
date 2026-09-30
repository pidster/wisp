import Foundation
import Synchronization
import Testing

@testable import WispCore

/// ADR 0044's notification routes: which one each face takes in each environment, the bytes written to a
/// terminal, and what the audit records. The terminal is always an injected writer; nothing here writes to
/// the real terminal or runs `osascript`.
@Suite struct NotificationRoutesTests {
    /// Records what reached the terminal and `osascript`.
    final class Effects: Sendable {
        let written = Mutex<[[UInt8]]>([])
        let scripts = Mutex<[[String]]>([])
        let sent = Mutex<[Notifier.Message]>([])
        let terminalFailure: String?
        let status: Int32
        let appStatus: Int32

        init(terminalFailure: String? = nil, status: Int32 = 0, appStatus: Int32 = 0) {
            self.terminalFailure = terminalFailure
            self.status = status
            self.appStatus = appStatus
        }

        var write: TerminalNotification.Writer {
            { bytes in
                self.written.withLock { $0.append(bytes) }
                return self.terminalFailure
            }
        }
        var run: Notifier.Runner {
            { arguments in
                self.scripts.withLock { $0.append(arguments) }
                return arguments.contains("tell application id (item 5 of argv)") ? self.appStatus : self.status
            }
        }
        var frontEnd: NotificationRoutes.FrontEnd {
            .init(declared: { true }, send: { message in self.sent.withLock { $0.append(message) } })
        }
        var writes: Int { written.withLock { $0.count } }
        var runs: Int { scripts.withLock { $0.count } }
    }

    private let ghostty = ["TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty"]
    private let appleTerminal = ["TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "com.apple.Terminal"]
    private let message = Notifier.Message(title: "Build", body: "The tests pass.")

    private func deliver(
        _ face: NotificationRoutes.Face, _ environment: [String: String], app: Bool = false,
        only: NotificationRoute? = nil, effects: Effects
    ) -> (Notifier.Outcome, skipped: [String]) {
        NotificationRoutes(
            face: face, viaTerminalApp: app, only: only, environment: environment, writeTerminal: effects.write
        ).deliver(message, run: effects.run)
    }

    @Test func terminalsAreNamedByTermProgramThenTerm() {
        #expect(TerminalNotification.terminal(in: ["TERM_PROGRAM": "ghostty"])?.sequence == .osc9)
        #expect(
            TerminalNotification.terminal(in: ["TERM_PROGRAM": "iTerm.app"]) == .init(name: "iTerm2", sequence: .osc9))
        #expect(TerminalNotification.terminal(in: ["TERM_PROGRAM": "WezTerm"])?.sequence == .osc9)
        #expect(TerminalNotification.terminal(in: ["TERM_PROGRAM": "kitty"])?.sequence == .osc99)
        #expect(TerminalNotification.terminal(in: ["TERM": "xterm-kitty"]) == .init(name: "kitty", sequence: .osc99))
        #expect(TerminalNotification.terminal(in: ["TERM": "xterm-ghostty"])?.sequence == .osc9)
        #expect(
            TerminalNotification.terminal(in: ["TERM_PROGRAM": "Apple_Terminal"])
                == .init(name: "Terminal.app", sequence: nil))
        // tmux does not pass the sequence through, whatever terminal it runs in.
        #expect(
            TerminalNotification.terminal(in: ["TERM_PROGRAM": "tmux", "TERM": "xterm-kitty"])
                == .init(name: "tmux", sequence: nil))
        #expect(TerminalNotification.terminal(in: ["TERM": "xterm-256color"]) == nil)
        #expect(TerminalNotification.terminal(in: [:]) == nil)
    }

    @Test func osc9AndOsc99AreWrittenExactly() {
        #expect(
            TerminalNotification.bytes(.osc9, message: message, id: "x")
                == Array("\u{1B}]9;Build: The tests pass.\u{07}".utf8))
        let watch = Notifier.Message(title: "wisp watch", body: "now failing", subtitle: "make test")
        #expect(
            TerminalNotification.bytes(.osc9, message: watch, id: "x")
                == Array("\u{1B}]9;wisp watch — make test: now failing\u{07}".utf8))
        #expect(
            TerminalNotification.bytes(.osc99, message: message, id: "wisp-1")
                == Array(
                    "\u{1B}]99;i=wisp-1:d=0:p=title;Build\u{1B}\\\u{1B}]99;i=wisp-1:p=body;The tests pass.\u{1B}\\".utf8
                ))
    }

    @Test func anInjectedEscapeOrBellNeverReachesTheTerminalRaw() {
        let hostile = Notifier.Message(
            title: "a\u{1B}]9;x\u{07}b", body: "d\u{1B}\\e;f\u{9D}g\u{07}\u{1B}[2J", subtitle: "\u{9C}c")
        // Straight into the sequence, without Notifier's cleaning first: the sequence's own cleaning suffices.
        let osc9 = TerminalNotification.bytes(.osc9, message: hostile, id: "x")
        #expect(osc9 == Array("\u{1B}]9;a ]9,x b — c: d \\e,f g  [2J\u{07}".utf8))
        let osc99 = TerminalNotification.bytes(.osc99, message: hostile, id: "i;d:=")
        #expect(osc9.filter { $0 == 0x1B }.count == 1 && osc9.filter { $0 == 0x07 }.count == 1)
        #expect(osc99.filter { $0 == 0x1B }.count == 4 && !osc99.contains(0x07))
        let text = String(decoding: osc99, as: UTF8.self)
        #expect(!text.contains("\u{9C}") && !text.contains("\u{9D}") && text.contains("i=i,d--:d=0"))
        #expect(TerminalNotification.sanitised(" a;b\tc\u{7F} ") == "a,b c")
        // And through a whole post: Notifier cleans first, the terminal sequence cleans again.
        let effects = Effects()
        let notifier = Notifier(run: effects.run)
        let routes = NotificationRoutes(face: .terminal, environment: ghostty, writeTerminal: effects.write)
        #expect(notifier.post(hostile, source: .model, audit: nil, routes: routes) == .posted(.terminal))
        let written = effects.written.withLock { $0[0] }
        #expect(written.first == 0x1B && written.last == 0x07)
        #expect(written.dropFirst().dropLast().allSatisfy { $0 >= 0x20 && $0 != 0x7F })
    }

    @Test func theTerminalFaceUsesItsTerminalWhenItPostsNotifications() {
        let effects = Effects()
        let (outcome, skipped) = deliver(.terminal, ghostty, effects: effects)
        #expect(outcome == .posted(.terminal))
        #expect(skipped == ["host: no front end"])
        #expect(effects.written.withLock { $0 } == [Array("\u{1B}]9;Build: The tests pass.\u{07}".utf8)])
        #expect(effects.runs == 0)
        let kitty = Effects()
        #expect(deliver(.terminal, ["TERM": "xterm-kitty"], effects: kitty).0 == .posted(.terminal))
        #expect(String(decoding: kitty.written.withLock { $0[0] }, as: UTF8.self).hasPrefix("\u{1B}]99;i=wisp-"))
    }

    @Test func terminalAppFallsToOsascriptWithTheAppRouteOff() {
        let effects = Effects()
        let (outcome, skipped) = deliver(.terminal, appleTerminal, effects: effects)
        #expect(outcome == .posted(.osascript))
        #expect(
            skipped == [
                "host: no front end", "terminal: Terminal.app has no notification sequence",
                "app: off (notifications.viaTerminalApp)",
            ])
        #expect(effects.writes == 0)
        #expect(effects.scripts.withLock { $0 } == [Notifier.arguments(for: message)])
    }

    @Test func theAppRouteSendsToTheBundleWhenOnAndFallsThroughWhenItFails() {
        let effects = Effects()
        #expect(deliver(.terminal, appleTerminal, app: true, effects: effects).0 == .posted(.app))
        #expect(effects.scripts.withLock { $0 } == [Notifier.appArguments(for: message, bundle: "com.apple.Terminal")])
        #expect(Notifier.appArguments(for: message, bundle: "b").last == "b")
        // The identifier is a value in argv, never script text.
        #expect(!Notifier.appScript.joined().contains("com.apple"))
        let failing = Effects(appStatus: 1)
        let (outcome, skipped) = deliver(.terminal, appleTerminal, app: true, effects: failing)
        #expect(outcome == .posted(.osascript))
        #expect(skipped.last == "app: osascript exited with status 1")
        // No bundle identifier: the app route is skipped even when on.
        #expect(
            deliver(.terminal, ["TERM_PROGRAM": "Apple_Terminal"], app: true, effects: Effects()).skipped.last
                == "app: no __CFBundleIdentifier")
    }

    @Test func noTerminalFallsThrough() {
        let effects = Effects(terminalFailure: "no terminal (/dev/tty does not open)")
        let (outcome, skipped) = deliver(.terminal, ghostty, effects: effects)
        #expect(outcome == .posted(.osascript))
        #expect(skipped.contains("terminal: no terminal (/dev/tty does not open)"))
        #expect(effects.writes == 1 && effects.runs == 1)
    }

    @Test func theJSONFaceNeverWritesToTheTerminal() {
        // With a hello declaring notify, the front end posts it.
        let declared = Effects()
        #expect(deliver(.frontEnd(declared.frontEnd), ghostty, effects: declared) == (.posted(.host), []))
        #expect(declared.sent.withLock { $0 } == [message])
        #expect(declared.writes == 0 && declared.runs == 0)
        // Without one, today's behaviour: posted by wisp's process, never through the terminal it does not own.
        let silent = Effects()
        let frontEnd = NotificationRoutes.FrontEnd(declared: { false }, send: { _ in Issue.record("sent") })
        let (outcome, skipped) = deliver(.frontEnd(frontEnd), ghostty, effects: silent)
        #expect(outcome == .posted(.osascript))
        #expect(
            skipped == [
                "host: the front end declared no notify", "terminal: the front end owns the terminal",
                "app: off (notifications.viaTerminalApp)",
            ])
        #expect(silent.writes == 0)
    }

    @Test func mcpLeavesTheClientsTerminalAlone() {
        let effects = Effects()
        let (outcome, skipped) = deliver(.mcp, ghostty, effects: effects)
        #expect(outcome == .posted(.osascript))
        #expect(skipped.prefix(2) == ["host: MCP has no notification", "terminal: the MCP client owns the terminal"])
        #expect(effects.writes == 0)
        #expect(deliver(.mcp, ghostty, app: true, effects: Effects()).0 == .posted(.app))
        #expect(deliver(.headless, ghostty, effects: Effects()).skipped[1] == "terminal: not used by this face")
    }

    @Test func oneRouteOnlyForTheProbe() {
        // The app route is tried when asked for, even with the setting off.
        let effects = Effects()
        #expect(deliver(.terminal, appleTerminal, only: .app, effects: effects) == (.posted(.app), []))
        #expect(effects.runs == 1)
        let refused = deliver(.terminal, appleTerminal, only: .terminal, effects: Effects())
        #expect(refused.0 == .refused("terminal: Terminal.app has no notification sequence"))
        #expect(deliver(.terminal, ghostty, only: .host, effects: Effects()).0 == .refused("host: no front end"))
        let failed = deliver(.terminal, ghostty, only: .osascript, effects: Effects(status: 2))
        #expect(failed.0 == .refused("osascript exited with status 2"))
    }

    @Test func theAuditRecordsTheRouteAndWhyEarlierOnesWereSkipped() {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "n", sink: sink)
        let effects = Effects()
        let notifier = Notifier(run: effects.run)
        let terminal = NotificationRoutes(face: .terminal, environment: ghostty, writeTerminal: effects.write)
        notifier.post(message, source: .user, audit: audit, routes: terminal)
        let apple = NotificationRoutes(face: .terminal, environment: appleTerminal, writeTerminal: effects.write)
        notifier.post(message, source: .model, audit: audit, routes: apple)
        let off = Notifier(enabled: false, run: effects.run)
        off.post(message, source: .model, audit: audit, routes: terminal)
        let events = sink.events.filter { $0.kind == .notification }
        #expect(events[0].details["route"] == "terminal")
        #expect(events[0].details["skipped"] == .array(["host: no front end"]))
        #expect(events[1].details["route"] == "osascript")
        #expect(events[1].details["skipped"]?.arrayValue?.count == 3)
        // Refused before any route: no route and nothing skipped.
        #expect(events[2].details["route"] == nil && events[2].details["skipped"] == nil)
        for event in events { #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .notification))) }
    }

    @Test func theLimitAndBoundsApplyBeforeAnyRoute() {
        let effects = Effects()
        let notifier = Notifier(perMinute: 1, run: effects.run)
        let routes = NotificationRoutes(face: .frontEnd(effects.frontEnd), environment: ghostty)
        let long = Notifier.Message(title: String(repeating: "t", count: 100), body: String(repeating: "b", count: 300))
        #expect(notifier.post(long, source: .model, audit: nil, routes: routes) == .posted(.host))
        #expect(
            notifier.post(message, source: .model, audit: nil, routes: routes)
                == .refused("at most 1 notifications a minute; try again shortly"))
        let sent = effects.sent.withLock { $0 }
        #expect(
            sent.count == 1 && sent[0].title.count == Notifier.titleLimit && sent[0].body.count == Notifier.bodyLimit)
    }

    @Test func theSessionBuildsHostsWithTheSetting() throws {
        let off = try scratchHostSession(config: #"{"notifications":{"viaTerminalApp":false}}"#)
        #expect(!off.host(approver: DenyingApprover(reason: "x"), face: .terminal).notifications.viaTerminalApp)
        let on = try scratchHostSession(config: nil)
        let host = on.host(approver: DenyingApprover(reason: "x"), face: .mcp, only: .app)
        #expect(host.notifications.viaTerminalApp && host.notifications.only == .app)
        #expect(host.notifier === on.notifier)
        #expect(Config().resolved.notificationsViaTerminalApp == true)
        #expect(ConfigSettings.defaultValue("notifications.viaTerminalApp") == .bool(true))
    }

    /// A session over a scratch home with `config` as its `config.json`.
    private func scratchHostSession(config: String?) throws -> Session {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-host-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        if let config { try Data(config.utf8).write(to: home.configFile) }
        return try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing())
    }
}
