import Foundation

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
            environment: probes.environment(), writeTerminal: { _ in nil })
        var skipped: [String] = []
        for step in routes.steps() {
            switch step {
            case .skip(.host, _):
                continue
            case .skip(let route, let reason):
                skipped.append("\(route.rawValue): \(reason)")
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
}
