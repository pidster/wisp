import Darwin
import Foundation
import Testing

@testable import WispCore

/// wisp's home is never writable by a command or an edit, and nothing a command starts outlives it (the
/// 2026-10-09 review). Writes go only under the temporary directory.
@Suite struct ConfinementTests {
    static let nested = CommandRunner.isNestedSandbox

    /// A scratch root with a fake wisp home inside it, so the home is inside the writable set: the case where
    /// only the profile's own denial keeps it closed.
    private func scratch() throws -> (root: URL, home: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-confine-\(UUID().uuidString)")
        let home = root.appending(path: "fake-wisp-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (root, home)
    }

    @Test func theProfileDeniesWritesToWispsHomeAfterTheAllowRule() throws {
        let (root, home) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = CommandPolicy.default.seatbeltProfile(
            writableRoot: root.path, temporaryDirectory: "/private/tmp", home: "/Users/x", protected: [home.path])
        let deny = "(deny file-write* (subpath \"\(CommandPolicy.canonical(home.path))\"))"
        let lines = profile.split(separator: "\n").map(String.init)
        let allow = try #require(lines.firstIndex { $0.hasPrefix("(allow file-write*") })
        let denied = try #require(lines.firstIndex(of: deny))
        #expect(denied > allow)
        #expect(profile.contains("; note: \(CommandPolicy.canonical(home.path)) is inside the writable set"))
        // A home outside the writable set is denied without a note.
        let apart = CommandPolicy.default.seatbeltProfile(
            writableRoot: root.path, temporaryDirectory: "/private/tmp", home: "/Users/x",
            protected: ["/Users/x/.wisp"])
        #expect(apart.contains("(deny file-write* (subpath \"/Users/x/.wisp\"))") && !apart.contains("; note:"))
        // By default, the runner protects the home wisp resolves.
        #expect(CommandRunner.Options().protectedPaths == [Home.resolve().root.path])
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func aSandboxedCommandCannotWriteWispsHomeButCanWriteBesideIt() async throws {
        let (root, home) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner(options: .init(writableRoot: root.path, protectedPaths: [home.path]))
        let blocked = home.appending(path: "approvals.json").path
        let refused = try await runner.run("echo x > '\(blocked)'", in: root.path)
        #expect(refused.exitStatus != 0)
        #expect(refused.stderr.contains("Operation not permitted"), "\(refused.stderr)")
        #expect(!FileManager.default.fileExists(atPath: blocked))
        let sibling = root.appending(path: "beside.txt").path
        let allowed = try await runner.run("echo y > '\(sibling)'", in: root.path)
        #expect(allowed.exitStatus == 0, "\(allowed.stderr)")
        #expect(FileManager.default.fileExists(atPath: sibling))
    }

    @Test func editFileRefusesWispsHome() throws {
        let (root, home) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(root.path)], protected: [home.path])
        let target = home.appending(path: "config.json").path
        #expect(throws: FileWriter.Failure.protected(target)) { try writer.apply(.write("{}"), to: target) }
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(!writer.permits(home.path) && writer.permits(root.appending(path: "x").path))
        // Even with no confinement (the sandbox off), the home stays closed.
        #expect(!FileWriter(roots: nil, protected: [home.path]).permits(target))
        #expect(FileWriter(roots: nil).protected == [CommandPolicy.canonical(Home.resolve().root.path)])
        #expect("\(FileWriter.Failure.protected(target))".contains("wisp's own home"))
    }

    /// Waits up to two seconds for `pid` to be gone.
    private func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func aChildIgnoringTerminationIsKilledAfterATimeout() async throws {
        let (root, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner(options: .init(writableRoot: root.path, timeout: .seconds(1)))
        // The subshell ignores SIGTERM (and so does its sleep); the leader waits on it and dies at the timeout.
        let outcome = try await runner.run("(trap '' TERM; exec sleep 30) & echo $!; wait", in: root.path)
        let pid = try #require(pid_t(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        #expect(outcome.timedOut)
        #expect(await gone(pid), "pid \(pid) survived the timeout")
    }

    @Test func aBackgroundJobDoesNotOutliveItsCommand() async throws {
        let (root, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // A long timeout: under the gate's load a short one can fire first, and the timeout would kill the job anyway.
        let runner = CommandRunner(options: .init(writableRoot: root.path, timeout: .seconds(120)))
        let outcome = try await runner.run("sleep 30 >/dev/null 2>&1 & echo $!", in: root.path)
        let pid = try #require(pid_t(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        #expect(outcome.exitStatus == 0 && !outcome.timedOut)
        #expect(await gone(pid), "pid \(pid) outlived its command")
    }
}
