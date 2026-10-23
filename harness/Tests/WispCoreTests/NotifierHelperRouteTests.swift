import Foundation
import Synchronization
import Testing
import WispNotifierKit

@testable import WispCore

/// ADR 0070's helper route: first in every face once the person allows it, asking without waiting when not yet asked,
/// and passing a notification on, with the reason, whenever it cannot post. The helper is a fake; nothing here runs
/// a bundle.
@Suite struct NotifierHelperRouteTests {
    /// What the fake helper was asked to do, and how it answers.
    final class Fake: Sendable {
        let permission: NotifierProtocol.Permission?
        let answer: NotifierProtocol.Permission?
        let failure: String?
        let asked = Mutex<[String]>([])
        let posted = Mutex<[NotifierProtocol.Request]>([])

        init(
            permission: NotifierProtocol.Permission?, answer: NotifierProtocol.Permission? = nil,
            failure: String? = nil
        ) {
            self.permission = permission
            self.answer = answer
            self.failure = failure
        }

        var helper: NotifierHelper {
            NotifierHelper(
                locate: { URL(fileURLWithPath: "/opt/homebrew/Cellar/wisp/0.30.0/libexec/Wisp Notifier.app") },
                permission: { _ in self.permission },
                askLater: { _ in self.asked.withLock { $0.append("later") } },
                askNow: { _ in
                    self.asked.withLock { $0.append("now") }
                    return self.answer
                },
                post: { _, request in
                    self.posted.withLock { $0.append(request) }
                    return self.failure
                })
        }
        var asks: [String] { asked.withLock { $0 } }
        var posts: [NotifierProtocol.Request] { posted.withLock { $0 } }
    }

    private let ghostty = ["TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty"]
    private let message = Notifier.Message(title: "Build", body: "The tests pass.", subtitle: "wisp", sound: true)

    private func deliver(
        _ fake: Fake, face: NotificationRoutes.Face = .terminal, viaHelper: Bool = true,
        only: NotificationRoute? = nil, osascript: Int32 = 0
    ) -> (Notifier.Outcome, skipped: [String]) {
        NotificationRoutes(
            face: face, viaHelper: viaHelper, helper: fake.helper, only: only, environment: ghostty,
            writeTerminal: { _ in nil }
        ).deliver(message, run: { _ in osascript })
    }

    /// Allowed, the helper posts first in every face, carrying the message and the terminal to bring forward.
    @Test func anAllowedHelperPostsFirstInEveryFace() throws {
        let frontEnd = NotificationRoutes.FrontEnd(declared: { true }, send: { _ in })
        for face in [NotificationRoutes.Face.terminal, .frontEnd(frontEnd), .mcp, .headless] {
            let fake = Fake(permission: .authorized)
            let (outcome, skipped) = deliver(fake, face: face)
            #expect(outcome == .posted(.helper) && skipped.isEmpty)
            let request = try #require(fake.posts.first)
            #expect(request.title == "Build" && request.body == "The tests pass." && request.subtitle == "wisp")
            #expect(request.sound && request.activate == "com.mitchellh.ghostty" && request.id.hasPrefix("wisp-"))
        }
    }

    /// Not yet asked, wisp starts asking and this notification goes by the next route, so none waits on the prompt.
    @Test func notYetAskedAsksAndPassesTheNotificationOn() {
        let fake = Fake(permission: .notDetermined)
        let (outcome, skipped) = deliver(fake)
        #expect(outcome == .posted(.terminal))
        #expect(fake.asks == ["later"] && fake.posts.isEmpty)
        #expect(skipped.first?.hasPrefix("helper: asking the person to allow Wisp's notifications") == true)
    }

    /// Refused, off, missing, or failing, the helper passes the notification on and says why.
    @Test func whateverStopsTheHelperTheNextRoutePosts() {
        let denied = deliver(Fake(permission: .denied))
        #expect(denied.0 == .posted(.terminal))
        #expect(denied.skipped.first?.hasPrefix("helper: notifications for Wisp are denied") == true)
        let off = deliver(Fake(permission: .authorized), viaHelper: false)
        #expect(off.0 == .posted(.terminal) && off.skipped.first == "helper: off (notifications.viaHelper)")
        let unrunnable = deliver(Fake(permission: nil))
        #expect(unrunnable.skipped.first == "helper: Wisp Notifier.app could not be run")
        let failing = deliver(Fake(permission: .authorized, failure: "Wisp Notifier.app exited with status 1"))
        #expect(failing.0 == .posted(.terminal))
        #expect(failing.skipped.first == "helper: Wisp Notifier.app exited with status 1")
        let missing = NotificationRoutes(
            face: .terminal, viaHelper: true, helper: .none, environment: ghostty, writeTerminal: { _ in nil }
        ).deliver(message, run: { _ in 0 })
        #expect(missing.skipped.first == "helper: no Wisp Notifier.app beside wisp")
    }

    /// `--route helper` asks and waits, even with the setting off, so an operator can allow it on purpose; refused,
    /// nothing else is tried.
    @Test func theHelperAloneAsksAndWaits() {
        let allowed = Fake(permission: .notDetermined, answer: .authorized)
        #expect(deliver(allowed, viaHelper: false, only: .helper).0 == .posted(.helper))
        #expect(allowed.asks == ["now"] && allowed.posts.count == 1)
        let refused = Fake(permission: .notDetermined, answer: .denied)
        let (outcome, _) = deliver(refused, only: .helper)
        #expect(refused.posts.isEmpty)
        guard case .refused(let reason) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(reason.contains("notifications for Wisp are denied"))
    }

    /// The bundle is found beside `wisp` only when it holds the helper's executable.
    @Test func theBundleIsFoundBesideWisp() {
        let wisp = URL(fileURLWithPath: "/opt/homebrew/Cellar/wisp/0.30.0/libexec/wisp")
        let app = "/opt/homebrew/Cellar/wisp/0.30.0/libexec/Wisp Notifier.app"
        #expect(NotifierHelper.bundle(besides: wisp) { $0 == app + "/Contents/MacOS/WispNotifier" }?.path == app)
        #expect(NotifierHelper.bundle(besides: wisp) { _ in false } == nil)
    }

    /// The bundle the package declares wins over one beside `wisp`, and the search is the fallback when the declared
    /// one is missing (ADR 0072).
    @Test func theDeclaredBundleComesFirst() {
        let wisp = URL(fileURLWithPath: "/Applications/Wisp.app/Contents/MacOS/wisp")
        let declared = URL(fileURLWithPath: "/Applications/Wisp.app/Contents/Helpers/Wisp Notifier.app")
        let beside = "/Applications/Wisp.app/Contents/MacOS/Wisp Notifier.app"
        let both: Set = [declared.path + "/Contents/MacOS/WispNotifier", beside + "/Contents/MacOS/WispNotifier"]
        #expect(NotifierHelper.bundle(besides: wisp, declared: declared, exists: both.contains) == declared)
        let onlyBeside: Set = [beside + "/Contents/MacOS/WispNotifier"]
        #expect(NotifierHelper.bundle(besides: wisp, declared: declared, exists: onlyBeside.contains)?.path == beside)
    }
}
