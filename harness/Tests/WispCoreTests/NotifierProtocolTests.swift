import Testing

@testable import WispNotifierKit

/// The command line between wisp and Wisp Notifier.app (ADR 0070).
@Suite struct NotifierProtocolTests {
    /// Every command survives being written as arguments and read back.
    @Test func everyCommandRoundTrips() {
        let full = NotifierProtocol.Request(
            id: "n-1", title: "Build", subtitle: "wisp", body: "done", sound: true, activate: "com.mitchellh.ghostty")
        let bare = NotifierProtocol.Request(id: "n-2", title: "", body: "done")
        for command in [NotifierProtocol.Command.status, .ask, .post(full), .post(bare)] {
            #expect(NotifierProtocol.parse(NotifierProtocol.arguments(command)) == .command(command))
        }
    }

    /// A value is the argument after its option whatever it holds, so text that looks like an option stays text.
    @Test func aValueThatLooksLikeAnOptionIsStillAValue() {
        let request = NotifierProtocol.Request(id: "n", title: "--sound", body: "--activate")
        #expect(NotifierProtocol.parse(NotifierProtocol.arguments(.post(request))) == .command(.post(request)))
    }

    /// No arguments is a launch for a click; anything not understood says why.
    @Test func readsALaunchAndRefusesWhatItDoesNotKnow() {
        #expect(NotifierProtocol.parse([]) == .launched)
        let refusals: [([String], String)] = [
            (["--status", "x"], "--status takes nothing"), (["--ask", "x"], "--ask takes nothing"),
            (["--show"], "unknown command --show"), (["--post", "--id", "n"], "--post needs --body"),
            (["--post", "--body", "b"], "--post needs --id"), (["--post", "--id"], "--id needs a value"),
            (["--post", "--id", "a", "--id", "b", "--body", "x"], "--id given twice"),
            (["--post", "--id", "a", "--body", "x", "--colour", "red"], "unknown option --colour"),
        ]
        for (arguments, reason) in refusals {
            #expect(NotifierProtocol.parse(arguments) == .invalid(reason), "\(arguments)")
        }
    }

    /// Only an allowed permission posts.
    @Test func onlyAnAllowedPermissionPosts() {
        #expect(NotifierProtocol.Permission.authorized.allowsPosting)
        #expect(NotifierProtocol.Permission.provisional.allowsPosting)
        for refused in [NotifierProtocol.Permission.notDetermined, .denied, .unknown] {
            #expect(!refused.allowsPosting)
        }
        #expect(NotifierProtocol.Permission(rawValue: "not-determined") == .notDetermined)
    }
}
