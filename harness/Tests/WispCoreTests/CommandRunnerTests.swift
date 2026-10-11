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

    @Test func holdsBackTheMiddleOfLongOutputAndKeepsHeadAndTail() async throws {
        // Twelve lines of about 30 bytes against a bound of 256 for the whole result: the first and last lines
        // are shown, the middle is held back, and without a store the note says so.
        let runner = CommandRunner(options: .init(maxOutputBytes: 256))
        let script = "i=1; while [ $i -le 40 ]; do echo \"line $i of a command that prints a lot\"; i=$((i+1)); done"
        let outcome = try await runner.run(script)
        #expect(outcome.truncated && outcome.exitStatus == 0)
        #expect(
            outcome.stdout.hasPrefix("line 1 of a command")
                && outcome.stdout.hasSuffix("line 40 of a command that prints a lot"))
        #expect(outcome.stdout.contains("held back …]"), "\(outcome.stdout)")
        let held = try #require(outcome.held.first)
        #expect(held.stream == "stdout" && held.firstLine > 2 && held.lastLine < 42 && held.bytes > 0)
        #expect(outcome.stored == nil)
        #expect(outcome.rendered.utf8.count <= 256 + CommandRunner.notesAllowance, "\(outcome.rendered.utf8.count)")
        #expect(outcome.rendered.contains("held back: stdout lines \(held.firstLine)–\(held.lastLine)"))
        #expect(outcome.rendered.contains("not kept: this conversation has no output store"))
        #expect(outcome.rendered.hasSuffix("do not run the command again to see it"))
    }

    @Test func rendersCompactly() {
        let outcome = CommandRunner.Outcome(
            exitStatus: 1, stdout: "out", stderr: "err", timedOut: false, truncated: false)
        #expect(outcome.rendered == "exit status: 1\nstdout:\nout\nstderr:\nerr")
        var held = outcome
        held.held = [.init(stream: "stderr", firstLine: 5, lastLine: 9, bytes: 300)]
        held.stored = .init(
            id: "3f9a2c1b", tool: "run_command", bytes: 400, lines: 12, sha256: "x", cut: false, totalBytes: 400)
        held.recallable = true
        let rendered = held.rendered
        #expect(
            rendered.contains(
                "held back: stderr lines 5–9 (300 bytes); the whole output is kept as output 3f9a2c1b (12 lines)"))
        #expect(rendered.contains("memory \"recall output 3f9a2c1b from line 5\" pages it"))
        #expect(rendered.contains("\"condense output 3f9a2c1b: QUESTION\" answers from all of it"))
        held.recallable = false
        #expect(!held.rendered.contains("memory") && held.rendered.hasSuffix("do not run the command again to see it"))
    }

    @Test func lossyBytesDecodeWithReplacement() async throws {
        let outcome = try await CommandRunner().run("printf 'a\\377b'")
        #expect(outcome.stdout == "a\u{FFFD}b")
    }

    @Test func theBufferKeepsHeadAndTailAndCountsWhatItDrops() {
        let buffer = OutputBuffer(keep: 8)
        buffer.append(Data("abc\n".utf8))
        #expect(buffer.contents.whole == Data("abc\n".utf8) && buffer.contents.lines == 1)
        buffer.append(Data("defgh\nij\nklmnop\n".utf8))
        let capture = buffer.contents
        #expect(capture.head == Data("abc\ndefg".utf8) && capture.tail == Data("\nklmnop\n".utf8))
        #expect(capture.total == 20 && capture.dropped == 4 && capture.lines == 4 && capture.whole == nil)
        // Within twice the bound nothing is dropped and the whole is still there.
        let small = OutputBuffer(keep: 8)
        small.append(Data("0123456789ab".utf8))
        #expect(small.contents.whole == Data("0123456789ab".utf8) && small.contents.dropped == 0)
        #expect(small.contents.lines == 1)
    }

    @Test func aCommandPrintingFarMoreThanTheBoundIsSpilledWholeToTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-spill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let store = OutputStore(directory: dir, audit: audit)
        let budget = ToolBudget(window: 8192, memory: true)
        let runner = CommandRunner(audit: audit, budget: budget, store: store)
        // About 1 MiB of stdout and a little stderr, far past the 4 KiB bound and twice its in-memory keep.
        let outcome = try await ToolCallContext.$call.withValue("deadbeef") {
            try await runner.run(
                "i=1; while [ $i -le 20000 ]; do echo \"line $i: fifty bytes of output to spill past\"; i=$((i+1)); done; echo oops >&2; exit 2"
            )
        }
        #expect(outcome.exitStatus == 2 && outcome.truncated)
        let kept = try #require(outcome.stored)
        #expect(kept.id == "deadbeef" && kept.tool == "run_command" && !kept.cut)
        #expect(kept.bytes > 900_000 && kept.lines == 20004, "\(kept)")
        let lines = try #require(store.lines("deadbeef"))
        #expect(
            lines[0] == "exit status: 2" && lines[1] == "stdout:"
                && lines[2] == "line 1: fifty bytes of output to spill past")
        #expect(
            lines[20001] == "line 20000: fifty bytes of output to spill past" && lines[20002] == "stderr:"
                && lines[20003] == "oops")
        let held = try #require(outcome.held.first { $0.stream == "stdout" })
        #expect(lines[held.firstLine - 1].hasPrefix("line \(held.firstLine - 2):"))
        #expect(lines[held.lastLine - 1].hasPrefix("line \(held.lastLine - 2):"))
        #expect(outcome.rendered.utf8.count <= budget.bytes + 64, "\(outcome.rendered.utf8.count)")
        #expect(outcome.rendered.contains("memory \"recall output deadbeef from line \(held.firstLine)\""))
        // The whole output is audited by size and hash, not carried; the spill files are gone.
        let event = try #require(sink.events.first { $0.kind == .outputKept })
        #expect(event.call == "deadbeef" && event.details["lines"] == .int(20004) && event.details["cut"] == false)
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .outputKept)))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["deadbeef", "deadbeef.json"], "\(files)")
    }

    @Test func theCeilingCutsAStoredOutputAndSaysSo() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-ceiling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OutputStore(directory: dir, ceiling: 2048)
        let runner = CommandRunner(options: .init(maxOutputBytes: 300), store: store)
        let outcome = try await runner.run("i=1; while [ $i -le 200 ]; do echo \"line $i of plenty\"; i=$((i+1)); done")
        let kept = try #require(outcome.stored)
        #expect(kept.cut && kept.bytes == 2048 && kept.totalBytes > 2048)
        #expect(outcome.rendered.contains("its first 2 KiB; the rest past that was not kept)"))
    }

    @Test func aCommandSeesNoDescriptorOfWispsOrOfAnotherCommand() async throws {
        // While one command holds its pipes open, another lists its own descriptors: only 0, 1, 2, and the one
        // ls opens on /dev/fd itself. Before close-on-exec it saw the test process's files and the other's pipes.
        let runner = CommandRunner()
        let slow = Task { try await runner.run("sleep 1") }
        try await Task.sleep(for: .milliseconds(100))
        let listed = try await runner.run("ls /dev/fd")
        _ = try await slow.value
        let descriptors = listed.stdout.split(separator: "\n").compactMap { Int($0) }.sorted()
        #expect(Set(descriptors).isSubset(of: [0, 1, 2, 3, 4]), "\(descriptors)")
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
