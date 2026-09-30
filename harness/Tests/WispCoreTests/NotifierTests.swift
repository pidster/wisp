import Foundation
import Synchronization
import Testing

@testable import WispCore

@Suite struct NotifierTests {
    /// A runner that records what it was given and exits with `status`.
    final class Recorder: Sendable {
        let calls = Mutex<[[String]]>([])
        let status: Int32
        init(status: Int32 = 0) { self.status = status }
        var run: Notifier.Runner {
            { arguments in
                self.calls.withLock { $0.append(arguments) }
                return self.status
            }
        }
        var count: Int { calls.withLock { $0.count } }
    }

    @Test func passesEveryValueAsAnArgumentNeverAsScript() {
        let arguments = Notifier.arguments(
            for: .init(
                title: "Build \"done\"", body: "tests pass\"; do shell script \"rm -rf ~\"", subtitle: "x", sound: true)
        )
        // Script lines alternate with -e; the values follow, untouched by the script text.
        #expect(arguments.first == "-e" && arguments[1] == "on run argv")
        #expect(arguments.filter { $0 == "-e" }.count == Notifier.script.count)
        let values = Array(arguments.suffix(4))
        #expect(values == [#"tests pass"; do shell script "rm -rf ~""#, #"Build "done""#, "x", "sound"])
        #expect(!Notifier.script.joined().contains("rm -rf"))
        #expect(Notifier.arguments(for: .init(title: "t", body: "b")).suffix(2) == ["", "quiet"])
    }

    @Test func cleansAndBoundsText() {
        #expect(Notifier.cleaned("  a\nb\tc\u{7}  ", limit: 10) == "a b c")
        #expect(Notifier.cleaned(String(repeating: "x", count: 70), limit: 64).count == 64)
        #expect(Notifier.cleaned(String(repeating: "x", count: 70), limit: 64).hasSuffix("…"))
        #expect(Notifier.cleaned("short", limit: 64) == "short")
    }

    @Test func postsRefusesAndAuditsEachAttempt() {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "n", sink: sink)
        let recorder = Recorder()
        let now = Mutex(Date(timeIntervalSince1970: 1000))
        let notifier = Notifier(perMinute: 2, run: recorder.run, clock: { now.withLock { $0 } })
        #expect(notifier.post(.init(title: "t", body: "one"), source: .model, audit: audit) == .posted(.osascript))
        #expect(notifier.post(.init(title: "t", body: "two"), source: .user, audit: audit) == .posted(.osascript))
        // A third within the minute is refused and never reaches osascript.
        #expect(
            notifier.post(.init(title: "t", body: "three"), source: .model, audit: audit)
                == .refused("at most 2 notifications a minute; try again shortly"))
        #expect(recorder.count == 2)
        // A minute later there is room again.
        now.withLock { $0 = $0.addingTimeInterval(60) }
        #expect(notifier.post(.init(title: "t", body: "four"), source: .model, audit: audit) == .posted(.osascript))
        // An empty message is refused without spending the limit.
        #expect(
            notifier.post(.init(title: "t", body: " \n "), source: .model, audit: audit)
                == .refused("a notification needs a message"))
        let events = sink.events.filter { $0.kind == .notification }
        #expect(events.count == 5)
        #expect(events[0].details["outcome"] == "posted" && events[0].details["source"] == "model")
        #expect(events[0].details["route"] == "osascript" && events[2].details["route"] == nil)
        #expect(events[1].details["source"] == "user")
        #expect(events[2].details["outcome"] == "refused" && events[2].details["reason"] != nil)
        #expect(events[0].summary.hasSuffix("notification session=n: posted from model: t"))
    }

    @Test func offMeansOffAndAFailedRunIsReported() {
        let recorder = Recorder()
        let off = Notifier(enabled: false, run: recorder.run)
        #expect(
            off.post(.init(title: "t", body: "b"), source: .user, audit: nil)
                == .refused("notifications are turned off (notifications.enabled)"))
        #expect(recorder.count == 0)
        let failing = Notifier(run: Recorder(status: 1).run)
        #expect(
            failing.post(.init(title: "t", body: "b"), source: .user, audit: nil)
                == .refused("osascript exited with status 1"))
    }

    @Test func theSpawnerReportsExitStatusFailureToStartAndTimeout() {
        #expect(Notifier.spawner("/usr/bin/true", timeout: 5)([]) == 0)
        #expect(Notifier.spawner("/usr/bin/false", timeout: 5)([]) == 1)
        #expect(Notifier.spawner("/nonexistent/osascript", timeout: 5)([]) == -1)
        #expect(Notifier.spawner("/bin/sleep", timeout: 0.1)(["5"]) == -1)
    }

    @Test func theToolRepliesInTextAndTheConfigResolves() async {
        let recorder = Recorder()
        let tool = NotifyTool(
            host: SessionHost(
                approver: DenyingApprover(reason: "none"), notifier: Notifier(perMinute: 1, run: recorder.run)))
        #expect(
            await tool.call(arguments: .init(title: "Done", message: "Tests pass."))
                == "notification posted via osascript")
        #expect(
            await tool.call(arguments: .init(title: "Done", message: "Again."))
                == "error: notification not shown: at most 1 notifications a minute; try again shortly")
        #expect(recorder.calls.withLock { $0.first?.suffix(4) } == ["Tests pass.", "Done", "", "quiet"])
        #expect(tool.limits.contains("64") && tool.examplePrompt.contains("notify"))
        #expect(ToolRegistry().all.map(\.name).contains("notify"))
        #expect(Config().resolved.notificationsEnabled && Config().resolved.notificationsPerMinute == 5)
        let custom = Config(notifications: .init(enabled: false, perMinute: 0)).resolved
        #expect(!custom.notificationsEnabled && custom.notificationsPerMinute == 1)
    }
}
