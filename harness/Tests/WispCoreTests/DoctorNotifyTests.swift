import Foundation
import Testing
import WispNotifierKit

@testable import WispCore

/// The doctor's `notify` finding: the route a notification would take here, and why (ADR 0044).
@Suite struct DoctorNotifyTests {
    private func finding(
        _ environment: [String: String], tty: Bool = true, osascript: Bool = true, config: Config = Config(),
        helper: NotifierHelper = .none
    ) -> Doctor.Finding {
        doctor(environment, tty: tty, osascript: osascript, config: config, helper: helper).notifyRoute()
    }

    private func doctor(
        _ environment: [String: String] = [:], tty: Bool = true, osascript: Bool = true, config: Config = Config(),
        helper: NotifierHelper = .none
    ) -> Doctor {
        let probes = Doctor.Probes(
            systemModel: { nil }, configuredModel: { _, _, _ in nil }, environment: { environment },
            terminalOpens: { tty }, osascriptPresent: { osascript }, helper: helper)
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-dn-\(UUID().uuidString)"))
        return Doctor(home: home, config: config.resolved, probes: probes)
    }

    private let app = URL(fileURLWithPath: "/opt/homebrew/Cellar/wisp/0.30.0/libexec/Wisp Notifier.app")

    private func helper(_ permission: NotifierProtocol.Permission?) -> NotifierHelper {
        let app = app
        return NotifierHelper(locate: { app }, permission: { _ in permission })
    }

    @Test func namesTheRouteAndWhy() {
        let ghostty = finding(["TERM_PROGRAM": "ghostty"])
        #expect(
            ghostty
                == .init(
                    name: "notify", ok: true,
                    detail: "terminal: Ghostty posts OSC 9 notifications; helper: no Wisp Notifier.app beside wisp"))
        #expect(
            finding(["TERM_PROGRAM": "Apple_Terminal"], config: Config(notifications: .init(viaTerminalApp: false)))
                .detail
                == "osascript: banners come from Script Editor; helper: no Wisp Notifier.app beside wisp; "
                + "terminal: Terminal.app has no notification sequence; app: off (notifications.viaTerminalApp)")
        #expect(
            finding(["TERM_PROGRAM": "ghostty"], tty: false).detail.hasPrefix(
                "osascript: banners come from Script Editor; helper: no Wisp Notifier.app beside wisp; "
                    + "terminal: no terminal (/dev/tty does not open)"))
        let app = finding(["TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "com.apple.Terminal"])
        #expect(app.ok && app.detail.hasPrefix("app: posted as com.apple.Terminal"))
    }

    @Test func notOkOnlyWhenOnAndNoRouteCanWork() {
        let none = finding(["TERM_PROGRAM": "Apple_Terminal"], osascript: false)
        #expect(!none.ok && none.detail.hasPrefix("no route can post a notification"))
        let off = finding([:], osascript: false, config: Config(notifications: .init(enabled: false)))
        #expect(off == .init(name: "notify", ok: true, detail: "off (notifications.enabled)"))
    }

    /// An allowed helper is the route; one not yet allowed is passed over for the terminal.
    @Test func theHelperIsTheRouteOnceAllowed() {
        #expect(
            finding(["TERM_PROGRAM": "ghostty"], helper: helper(.authorized)).detail
                == "helper: Wisp Notifier.app posts as Wisp")
        #expect(
            finding(["TERM_PROGRAM": "ghostty"], helper: helper(.notDetermined)).detail
                == "terminal: Ghostty posts OSC 9 notifications; helper: not yet allowed (the notifier finding says why)"
        )
    }

    /// The notifier finding: off, missing, or the permission in words with what to do; never a failure.
    @Test func theNotifierSaysWhereItIsAndWhetherItIsAllowed() {
        let path = app.path
        let cases: [(Doctor, String)] = [
            (
                doctor(config: Config(notifications: .init(enabled: false))),
                "notifications are off (notifications.enabled)"
            ),
            (
                doctor(config: Config(notifications: .init(viaHelper: false))),
                "off (notifications.viaHelper); the other routes post"
            ),
            (doctor(), "no Wisp Notifier.app beside wisp; the other routes post (a Homebrew install has it)"),
            (doctor(helper: helper(nil)), "\(path) could not be run; the other routes post"),
            (doctor(helper: helper(.authorized)), "\(path): allowed; banners come from Wisp"),
            (doctor(helper: helper(.provisional)), "\(path): allowed; banners come from Wisp"),
            (
                doctor(helper: helper(.denied)),
                "\(path): notifications for Wisp are off; turn them on in System Settings, Notifications, Wisp"
            ),
            (
                doctor(helper: helper(.notDetermined)),
                "\(path): not yet allowed; the next notification asks, or wisp notify --route helper \"test\" asks now"
            ),
            (
                doctor(helper: helper(.unknown)),
                "\(path): the permission is one this wisp does not know; the other routes post"
            ),
        ]
        for (doctor, detail) in cases {
            #expect(doctor.notifier() == .init(name: "notifier", ok: true, detail: detail))
        }
    }
}
