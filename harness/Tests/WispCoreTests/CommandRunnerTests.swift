import Foundation
import Synchronization
import Testing

@testable import WispCore

@Suite struct CommandRunnerTests {
    @Test func capturesStdoutAndExitStatus() async throws {
        let outcome = try await CommandRunner().run("printf hello; exit 3")
        #expect(outcome.stdout == "hello")
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.exitStatus == 3)
        #expect(!outcome.timedOut)
        #expect(!outcome.truncated)
    }

    @Test func separatesStderr() async throws {
        let outcome = try await CommandRunner().run("printf err >&2")
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == "err")
    }

    @Test func honoursWorkingDirectory() async throws {
        let outcome = try await CommandRunner().run("pwd", in: "/private/tmp")
        #expect(outcome.stdout.trimmingCharacters(in: .newlines) == "/private/tmp")
    }

    @Test func rejectsMissingWorkingDirectory() async {
        await #expect(throws: CommandRunner.Failure.invalidWorkingDirectory("/nonexistent/dir")) {
            try await CommandRunner().run("true", in: "/nonexistent/dir")
        }
    }

    @Test func killsOnTimeout() async throws {
        let runner = CommandRunner(options: .init(timeout: .milliseconds(200)))
        let outcome = try await runner.run("sleep 30")
        #expect(outcome.timedOut)
        #expect(outcome.exitStatus == -SIGTERM)
    }

    @Test func keepsOnlyTheTailOfLongOutput() async throws {
        let runner = CommandRunner(options: .init(maxOutputBytes: 10))
        let outcome = try await runner.run("printf 0123456789abcdef")
        #expect(outcome.truncated)
        #expect(outcome.stdout == "6789abcdef")
    }

    @Test func rendersCompactly() {
        let outcome = CommandRunner.Outcome(
            exitStatus: 1, stdout: "out", stderr: "err", timedOut: false, truncated: true)
        #expect(
            outcome.rendered
                == "exit status: 1\noutput truncated: only the tail of each stream is shown\nstdout:\nout\nstderr:\nerr"
        )
    }

    @Test func tailDecodesLossily() {
        let data = Data([0x61, 0xFF, 0x62])
        #expect(CommandRunner.tail(data, maxBytes: 10).text == "a\u{FFFD}b")
    }
}

@Suite struct CommandRunnerPolicyTests {
    /// The runner's own once-per-process probe; enforcement cannot be asserted when nested.
    static let nested = CommandRunner.isNestedSandbox

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Counts classifications and rates everything moderate, so the gate asks every time it is consulted.
    final class CountingClassifier: RiskClassifier {
        let count = Mutex(0)
        func classify(command: String, workingDirectory: String) async -> RiskAssessment {
            count.withLock { $0 += 1 }
            return RiskAssessment(level: .moderate, reasons: ["counted"], sources: ["test"])
        }
    }

    @Test func anAuthorizedCommandIsClassifiedOnceAndStillAuditedOnEveryRun() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let classifier = CountingClassifier()
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "watch", sink: sink)
        let gate = ApprovalGate(
            classifier: classifier, approver: AutoApprover(), threshold: .level(.moderate), audit: audit)
        let runner = CommandRunner(options: .init(writableRoot: dir), audit: audit, approval: gate)
        let authorized = try await runner.authorize("echo hi", in: dir)
        for _ in 0..<3 { #expect(try await authorized.run().stdout == "hi\n") }
        #expect(classifier.count.withLock { $0 } == 1)
        #expect(sink.events.filter { $0.kind == .approvalRequested }.count == 1)
        #expect(sink.events.filter { $0.kind == .policyDecision && $0.details["verdict"] == "allowed" }.count == 3)
        #expect(sink.events.filter { $0.kind == .commandOutcome }.count == 3)
        #expect(authorized.command == "echo hi" && authorized.workingDirectory == dir)
        // The runner it came from still consults the gate for anything it runs.
        _ = try await runner.run("echo again", in: dir)
        #expect(classifier.count.withLock { $0 } == 2)
    }

    @Test func authorizationAppliesThePolicyAndTheGate() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        await #expect(throws: CommandRunner.Failure.denied("command matches deny pattern secret")) {
            try await CommandRunner(options: .init(policy: CommandPolicy(deny: ["secret"]))).authorize("echo secret")
        }
        let refusing = ApprovalGate(
            classifier: CountingClassifier(), approver: DenyingApprover(reason: "no"), threshold: .level(.moderate))
        await #expect(throws: CommandRunner.Failure.self) {
            try await CommandRunner(approval: refusing).authorize("echo hi", in: dir)
        }
        await #expect(throws: CommandRunner.Failure.invalidWorkingDirectory("/nonexistent/x")) {
            try await CommandRunner().authorize("echo hi", in: "/nonexistent/x")
        }
    }

    @Test func deniedPatternNeverLaunches() async {
        await #expect(throws: CommandRunner.Failure.denied("command matches deny pattern secret")) {
            try await CommandRunner(options: .init(policy: CommandPolicy(deny: ["secret"]))).run("echo secret")
        }
    }

    @Test func sandboxAllowsWritesInWorkingDirectoryAndTemp() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let outcome = try await CommandRunner().run(
            "echo hi > here.txt && echo hi > \"$TMPDIR/wisp-sb-probe\" && cat here.txt", in: dir)
        #expect(outcome.exitStatus == 0, "\(outcome.stderr)")
        #expect(outcome.stdout == "hi\n")
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func sandboxBlocksWritesElsewhere() async throws {
        let dir = try scratch()
        // The home directory is outside the writable set (working directory, temp, caches).
        let blocked = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "wisp-sb-blocked-\(UUID().uuidString).txt").path
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: blocked)
        }
        let runner = CommandRunner(options: .init(writableRoot: dir))
        let outcome = try await runner.run("echo x > '\(blocked)'", in: dir)
        #expect(outcome.exitStatus != 0)
        #expect(outcome.stderr.contains("Operation not permitted"))
        #expect(!FileManager.default.fileExists(atPath: blocked))
    }

    @Test(.enabled(if: !nested, "enforcement cannot be asserted inside an outer sandbox"))
    func sandboxCanBlockNetwork() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var options = CommandRunner.Options(writableRoot: dir, timeout: .seconds(10))
        options.policy.sandbox.allowNetwork = false
        // A closed local port: without the sandbox this is "Connection refused"; with network denied the
        // kernel refuses the connect call itself, which is the only outcome that proves enforcement.
        let probe = "/usr/bin/python3 -c \"import socket; socket.socket().connect(('127.0.0.1', 1))\""
        let denied = try await CommandRunner(options: options).run(probe, in: dir)
        #expect(denied.exitStatus != 0)
        #expect(denied.stderr.contains("Operation not permitted"), "\(denied.stderr)")
        options.policy.sandbox.allowNetwork = true
        let allowed = try await CommandRunner(options: options).run(probe, in: dir)
        #expect(allowed.stderr.contains("Connection refused"), "\(allowed.stderr)")
    }

    @Test func unrestrictedRunsPlainShell() async throws {
        let dir = try scratch()
        let other = try scratch()
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: other)
        }
        let runner = CommandRunner(options: .init(policy: .unrestricted))
        let outcome = try await runner.run("echo x > '\(other)/ok.txt'", in: dir)
        #expect(outcome.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: "\(other)/ok.txt"))
    }
}

@Suite struct NestedSandboxTests {
    @Test func nestingIsDecidedByTheProbeNotByCommandOutput() async throws {
        // A command that prints the refusal string and fails must run exactly once, sandboxed.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-nest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let runner = CommandRunner(
            options: .init(writableRoot: dir.path), audit: AuditLog(session: "s", sink: sink))
        let outcome = try await runner.run(
            "echo launched >> launches.txt; echo 'sandbox-exec: sandbox_apply: Operation not permitted' >&2; exit 71",
            in: dir.path)
        #expect(outcome.exitStatus == 71)
        let launches = try String(contentsOf: dir.appending(path: "launches.txt"), encoding: .utf8)
        #expect(launches == "launched\n")
        #expect(sink.events.filter { $0.kind == .policyDecision }.count == 1)
        #expect(
            sink.events.first { $0.kind == .policyDecision }?.details["nested"] == .bool(CommandRunner.isNestedSandbox))
    }
}

@Suite struct ProcessTreeTests {
    @Test func timeoutStopsBackgroundChildrenAndReturnsPromptly() async throws {
        let runner = CommandRunner(options: .init(timeout: .milliseconds(300), policy: .unrestricted))
        let started = ContinuousClock.now
        let outcome = try await runner.run("sleep 30 & sleep 30; echo done")
        let elapsed = ContinuousClock.now - started
        #expect(outcome.timedOut)
        // Loose on purpose: a loaded Mac takes seconds to schedule the teardown, and the failure this
        // catches waits for the background `sleep 30`.
        #expect(elapsed < .seconds(15), "took \(elapsed)")
        #expect(!outcome.stdout.contains("done"))
    }

    @Test(.disabled(if: CommandRunnerPolicyTests.nested, "enforcement cannot be asserted inside an outer sandbox"))
    func modelChosenDirectoryDoesNotWidenTheSandbox() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = FileManager.default.homeDirectoryForCurrentUser.path
        // Runs in the home directory (allowed) but the writable root stays the scratch dir, so the write fails.
        let runner = CommandRunner(options: .init(writableRoot: root.path))
        let blocked = "wisp-root-probe-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: "\(elsewhere)/\(blocked)") }
        let outcome = try await runner.run("pwd; echo x > \(blocked)", in: elsewhere)
        #expect(outcome.stdout.hasPrefix(CommandPolicy.canonical(elsewhere)))
        #expect(outcome.exitStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: "\(elsewhere)/\(blocked)"))
    }
}
