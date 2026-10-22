import Foundation
import WispNotifierKit

/// The doctor's `notify` check: the route a notification would take from this terminal (ADR 0044).
extension Doctor {
    /// The route `wisp notify` and the model's `notify` would take in this environment, and why the earlier
    /// routes would be skipped. Never not ok unless notifications are on and no route can work. Nothing is
    /// posted: the terminal route is judged by whether `/dev/tty` opens, the app route by the setting and
    /// the bundle identifier. `wisp-tui` posts through its own terminal, whatever this says.
    ///
    /// - Returns: The finding, such as `terminal: Ghostty posts OSC 9 notifications`.
    func notifyRoute() -> Finding {
        let name = "notify"
        guard resolvedConfig.notificationsEnabled else {
            return Finding(name: name, ok: true, detail: "off (notifications.enabled)")
        }
        let routes = NotificationRoutes(
            face: .terminal, viaTerminalApp: resolvedConfig.notificationsViaTerminalApp,
            viaHelper: resolvedConfig.notificationsViaHelper, helper: probes.helper, environment: probes.environment(),
            writeTerminal: { _ in nil })
        var skipped: [String] = []
        for step in routes.steps() {
            switch step {
            case .skip(.host, _):
                continue
            case .skip(let route, let reason):
                skipped.append("\(route.rawValue): \(reason)")
            case .attempt(.helper, _):
                guard let app = probes.helper.locate(), let permission = probes.helper.permission(app),
                    permission.allowsPosting
                else {
                    skipped.append("helper: not yet allowed (the notifier finding says why)")
                    continue
                }
                let after = skipped.isEmpty ? "" : "; " + skipped.joined(separator: "; ")
                return Finding(name: name, ok: true, detail: "helper: Wisp Notifier.app posts as Wisp\(after)")
            case .attempt(.terminal, _) where !probes.terminalOpens():
                skipped.append("terminal: no terminal (/dev/tty does not open)")
            case .attempt(.osascript, _) where !probes.osascriptPresent():
                skipped.append("osascript: /usr/bin/osascript cannot run")
            case .attempt(let route, let why):
                let after = skipped.isEmpty ? "" : "; " + skipped.joined(separator: "; ")
                return Finding(name: name, ok: true, detail: "\(route.rawValue): \(why)\(after)")
            }
        }
        return Finding(
            name: name, ok: false,
            detail: "no route can post a notification: " + skipped.joined(separator: "; ")
                + "; turn notifications off with notifications.enabled false, or run wisp in a terminal that posts them"
        )
    }

    /// `Wisp Notifier.app`: whether it is on, where it is, and whether the person has allowed it (ADR 0070). Never a
    /// failure, since the other routes post without it; it says what to do to have banners come from Wisp.
    ///
    /// - Returns: The finding, such as `…/libexec/Wisp Notifier.app: allowed; banners come from Wisp`.
    func notifier() -> Finding {
        let name = "notifier"
        guard resolvedConfig.notificationsEnabled else {
            return Finding(name: name, ok: true, detail: "notifications are off (notifications.enabled)")
        }
        guard resolvedConfig.notificationsViaHelper else {
            return Finding(name: name, ok: true, detail: "off (notifications.viaHelper); the other routes post")
        }
        guard let app = probes.helper.locate() else {
            return Finding(
                name: name, ok: true,
                detail:
                    "no \(NotifierProtocol.bundleName) beside wisp; the other routes post (a Homebrew install has it)")
        }
        let detail: String
        switch probes.helper.permission(app) {
        case nil: detail = "\(app.path) could not be run; the other routes post"
        case .notDetermined?:
            detail =
                "\(app.path): not yet allowed; the next notification asks, or wisp notify --route helper \"test\" asks now"
        case .denied?:
            detail = "\(app.path): notifications for Wisp are off; turn them on in System Settings, Notifications, Wisp"
        case .authorized?, .provisional?: detail = "\(app.path): allowed; banners come from Wisp"
        case .unknown?: detail = "\(app.path): the permission is one this wisp does not know; the other routes post"
        }
        return Finding(name: name, ok: true, detail: detail)
    }
}
