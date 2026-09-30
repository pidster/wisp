import Foundation
import Testing

@testable import WispCore

/// The doctor's `notify` finding: the route a notification would take here, and why (ADR 0044).
@Suite struct DoctorNotifyTests {
    private func finding(
        _ environment: [String: String], tty: Bool = true, osascript: Bool = true, config: Config = Config()
    ) -> Doctor.Finding {
        let probes = Doctor.Probes(
            systemModel: { nil }, configuredModel: { _, _, _ in nil }, environment: { environment },
            terminalOpens: { tty }, osascriptPresent: { osascript })
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-dn-\(UUID().uuidString)"))
        return Doctor(home: home, config: config.resolved, probes: probes).notifyRoute()
    }

    @Test func namesTheRouteAndWhy() {
        let ghostty = finding(["TERM_PROGRAM": "ghostty"])
        #expect(ghostty == .init(name: "notify", ok: true, detail: "terminal: Ghostty posts OSC 9 notifications"))
        #expect(
            finding(["TERM_PROGRAM": "Apple_Terminal"]).detail
                == "osascript: banners come from Script Editor; terminal: Terminal.app has no notification "
                + "sequence; app: off (notifications.viaTerminalApp)")
        #expect(
            finding(["TERM_PROGRAM": "ghostty"], tty: false).detail.hasPrefix(
                "osascript: banners come from Script Editor; terminal: no terminal (/dev/tty does not open)"))
        let app = finding(
            ["TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "com.apple.Terminal"],
            config: Config(notifications: .init(viaTerminalApp: true)))
        #expect(app.ok && app.detail.hasPrefix("app: posted as com.apple.Terminal"))
    }

    @Test func notOkOnlyWhenOnAndNoRouteCanWork() {
        let none = finding(["TERM_PROGRAM": "Apple_Terminal"], osascript: false)
        #expect(!none.ok && none.detail.hasPrefix("no route can post a notification"))
        let off = finding([:], osascript: false, config: Config(notifications: .init(enabled: false)))
        #expect(off == .init(name: "notify", ok: true, detail: "off (notifications.enabled)"))
    }
}
