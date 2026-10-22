import Foundation
import Synchronization
import Testing
import WispNotifierKit

@testable import WispCore

/// The helper as wisp runs it: its executable spawned with `NotifierProtocol`'s command line, its answers read, and
/// each bundle registered once. The executable is a shell script standing in for `WispNotifier` in a temporary
/// bundle, and the registrar only counts, so nothing here touches LaunchServices or posts a notification.
@Suite struct NotifierHelperRunTests {
    /// A temporary bundle whose executable answers from files beside it and records each call.
    struct Stand: Sendable {
        let root: URL
        let app: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "wisp-helper-\(UUID().uuidString)")
            app = root.appending(path: "Wisp Notifier.app")
            let executable = NotifierHelper.executable(in: app)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
                #!/bin/sh
                root="$(cd "$(dirname "$0")/../../.." && pwd)"
                printf '%s\\n' "$*" >> "$root/calls"
                case "$1" in
                --status) cat "$root/permission" ;;
                --ask) cat "$root/answer" ;;
                --post) exit "$(cat "$root/post")" ;;
                *) exit 64 ;;
                esac
                """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        func answer(permission: String = "authorized", ask: String = "authorized", post: Int32 = 0) throws {
            try permission.write(to: root.appending(path: "permission"), atomically: true, encoding: .utf8)
            try ask.write(to: root.appending(path: "answer"), atomically: true, encoding: .utf8)
            try "\(post)".write(to: root.appending(path: "post"), atomically: true, encoding: .utf8)
        }

        var calls: [String] {
            ((try? String(contentsOf: root.appending(path: "calls"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Counts registrations.
    final class Registrar: Sendable {
        let apps = Mutex<[String]>([])
        var register: @Sendable (URL) -> Void { { app in self.apps.withLock { $0.append(app.lastPathComponent) } } }
    }

    private func helper(_ stand: Stand, _ registrar: Registrar = Registrar()) -> NotifierHelper {
        let app = stand.app
        return NotifierHelper.running(locate: { app }, register: registrar.register)
    }

    /// The permission is read in the helper's words, registering the bundle once however often it is run.
    @Test func readsThePermissionAndRegistersOnce() throws {
        let stand = try Stand()
        defer { stand.remove() }
        let registrar = Registrar()
        let helper = helper(stand, registrar)
        try stand.answer(permission: "not-determined")
        #expect(helper.permission(stand.app) == .notDetermined)
        try stand.answer(permission: "authorized")
        #expect(helper.permission(stand.app) == .authorized)
        try stand.answer(permission: "sideways")
        #expect(helper.permission(stand.app) == .unknown)
        try stand.answer(permission: "")
        #expect(helper.permission(stand.app) == nil)
        #expect(registrar.apps.withLock { $0 } == ["Wisp Notifier.app"])
        #expect(stand.calls == ["--status", "--status", "--status", "--status"])
    }

    /// A post passes the request on the command line and reads the exit status.
    @Test func postsAndReadsTheOutcome() throws {
        let stand = try Stand()
        defer { stand.remove() }
        let helper = helper(stand)
        let request = NotifierProtocol.Request(
            id: "wisp-1", title: "Build", body: "done", activate: "com.apple.Terminal")
        try stand.answer(post: 0)
        #expect(helper.post(stand.app, request) == nil)
        #expect(stand.calls == [NotifierProtocol.arguments(.post(request)).joined(separator: " ")])
        try stand.answer(permission: "denied", post: 3)
        #expect(helper.post(stand.app, request) == "notifications for Wisp are not allowed")
        try stand.answer(post: 1)
        #expect(helper.post(stand.app, request) == "Wisp Notifier.app exited with status 1")
    }

    /// Asked and waited for, the answer is read; asked without waiting, the prompt is started once a process.
    @Test func asksNowAndLaterOnce() async throws {
        let stand = try Stand()
        defer { stand.remove() }
        let helper = helper(stand)
        try stand.answer(ask: "denied")
        #expect(helper.askNow(stand.app) == .denied)
        helper.askLater(stand.app)
        helper.askLater(stand.app)
        for _ in 0..<100 where stand.calls.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(stand.calls == ["--ask", "--ask"])
    }

    /// A bundle whose executable cannot start is reported, not thrown.
    @Test func aBundleThatCannotRunIsSaidSo() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "wisp-none-\(UUID().uuidString).app")
        let helper = NotifierHelper.running(locate: { missing }, register: { _ in })
        #expect(helper.permission(missing) == nil && helper.askNow(missing) == nil)
        #expect(helper.post(missing, .init(id: "n", title: "", body: "b")) == "Wisp Notifier.app could not be run")
    }
}
