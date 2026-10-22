import AppKit
import UserNotifications
import WispNotifierKit

// Wisp Notifier.app's executable: posts one notification for wisp through UserNotifications, so banners come from
// "Wisp" with its icon, and brings the terminal wisp ran in forward when one is clicked
// (docs/decisions/0070-a-notification-helper.md). The command line is `NotifierProtocol`'s; nothing here decides
// whether to post: wisp asks only when the person has allowed it.

/// Brings the app named in a clicked banner forward, and lets banners show while this helper runs.
final class Responder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// The key a request's `activate` travels under in the notification's user info.
    static let activateKey = "activate"

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let bundle = response.notification.request.content.userInfo[Self.activateKey] as? String,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else { return }
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// The permission in the protocol's words.
func permission(_ center: UNUserNotificationCenter) async -> NotifierProtocol.Permission {
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .authorized: .authorized
    case .provisional: .provisional
    @unknown default: .unknown
    }
}

/// Posts `request`; in a function of its own so the asynchronous `add` is the one chosen.
func post(_ request: UNNotificationRequest, on center: UNUserNotificationCenter) async throws {
    try await center.add(request)
}

/// Writes `text` and a newline to standard error.
func complain(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let center = UNUserNotificationCenter.current()
let responder = Responder()
center.delegate = responder

switch NotifierProtocol.parse(Array(CommandLine.arguments.dropFirst())) {
case .invalid(let reason):
    complain("WispNotifier: \(reason)")
    exit(NotifierProtocol.Exit.usage.rawValue)
case .launched:
    // A click on a banner launched the helper: the delegate hears it within moments and brings the terminal forward.
    try? await Task.sleep(for: .seconds(5))
    exit(NotifierProtocol.Exit.done.rawValue)
case .command(.status):
    print(await permission(center).rawValue)
    exit(NotifierProtocol.Exit.done.rawValue)
case .command(.ask):
    // The first request can fail while the prompt is still on screen; the answer is read again afterwards.
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    let answer = await permission(center)
    print(answer.rawValue)
    exit(answer.allowsPosting ? NotifierProtocol.Exit.done.rawValue : NotifierProtocol.Exit.notAllowed.rawValue)
case .command(.post(let request)):
    let allowed = await permission(center)
    guard allowed.allowsPosting else {
        print(allowed.rawValue)
        exit(NotifierProtocol.Exit.notAllowed.rawValue)
    }
    let content = UNMutableNotificationContent()
    content.title = request.title
    if let subtitle = request.subtitle { content.subtitle = subtitle }
    content.body = request.body
    if request.sound { content.sound = .default }
    if let activate = request.activate { content.userInfo = [Responder.activateKey: activate] }
    do {
        try await post(UNNotificationRequest(identifier: request.id, content: content, trigger: nil), on: center)
        exit(NotifierProtocol.Exit.done.rawValue)
    } catch {
        complain("WispNotifier: \(error.localizedDescription)")
        exit(NotifierProtocol.Exit.failed.rawValue)
    }
}
