import Darwin
import Foundation
import Synchronization

/// Runs a shell command with a timeout, bounded output capture, and a `CommandPolicy`.
///
/// The policy's patterns are checked before launch and its sandbox, when
/// enabled, wraps the shell in `sandbox-exec`. The command is spawned in its
/// own process group so a timeout can stop the whole tree. Output is captured
/// separately for stdout and stderr, then truncated to the last
/// `maxOutputBytes` of each so that a chatty command cannot exhaust the
/// model's small context window.
public struct CommandRunner: Sendable {
    /// Limits applied to every command this runner executes.
    public struct Options: Sendable, Equatable {
        /// Root of the sandbox's writable set. Fixed at the launch directory by default and never taken
        /// from a per-command working directory, so a caller cannot widen the sandbox by choosing where
        /// to run.
        public var writableRoot: String
        /// Wall-clock limit after which the command's process group is sent SIGTERM, then SIGKILL.
        public var timeout: Duration
        /// Maximum bytes kept from each of stdout and stderr; earlier output is discarded.
        public var maxOutputBytes: Int
        /// What may run and how it is confined.
        public var policy: CommandPolicy

        /// Creates options. Defaults are a 60-second timeout, 4 KiB per stream, the default policy, and
        /// the current directory as the writable root.
        public init(
            writableRoot: String? = nil, timeout: Duration = .seconds(60), maxOutputBytes: Int = 4096,
            policy: CommandPolicy = .default
        ) {
            self.writableRoot = writableRoot ?? FileManager.default.currentDirectoryPath
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.policy = policy
        }
    }

    /// What a finished command produced.
    public struct Outcome: Sendable, Equatable {
        /// The process exit status, or the terminating signal negated if it was killed.
        public var exitStatus: Int32
        /// Captured standard output, possibly truncated to its tail.
        public var stdout: String
        /// Captured standard error, possibly truncated to its tail.
        public var stderr: String
        /// Whether the command hit the timeout and was killed.
        public var timedOut: Bool
        /// Whether either stream lost leading bytes to the output limit.
        public var truncated: Bool
        /// For a confined command that failed with `Operation not permitted`, whether the sandbox refused it
        /// (ADR 0054); nil otherwise.
        public var sandboxRefusal: SandboxRefusal? = nil
        /// What the model is told of `sandboxRefusal` (`SandboxRefusal.note(roots:)`); nil when there is none.
        public var sandboxNote: String? = nil

        /// A compact, model-facing rendering of the outcome, with the sandbox's note after the output.
        public var rendered: String {
            var lines = ["exit status: \(exitStatus)"]
            if timedOut { lines.append("timed out: the command was killed") }
            if truncated { lines.append("output truncated: only the tail of each stream is shown") }
            if !stdout.isEmpty { lines.append("stdout:\n\(stdout)") }
            if !stderr.isEmpty { lines.append("stderr:\n\(stderr)") }
            if let sandboxNote { lines.append(sandboxNote) }
            return lines.joined(separator: "\n")
        }
    }

    /// Reasons a command could not be started or was refused.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The requested working directory does not exist or is not a directory.
        case invalidWorkingDirectory(String)
        /// The shell could not be launched.
        case launchFailed(String)
        /// The policy's patterns rejected the command.
        case denied(String)
        /// The command needed approval and did not get it.
        case disapproved(String)

        /// Human-readable explanation suitable for printing to stderr.
        public var description: String {
            switch self {
            case .invalidWorkingDirectory(let path): "working directory does not exist: \(path)"
            case .launchFailed(let reason): "could not launch /bin/sh: \(reason)"
            case .denied(let reason): "command denied by policy: \(reason)"
            case .disapproved(let reason): "command not approved: \(reason)"
            }
        }
    }

    /// Who chose a command, which decides whether the approval gate is consulted (ADR 0049).
    public enum Origin: String, Sendable, Equatable {
        /// The model, through `run_command` or a tool built on it: the gate classifies the command and asks the
        /// person when it is risky.
        case model
        /// The person, who typed it in chat after `!`: typing it is the approval, so the gate is not consulted.
        /// The policy's lists, the sandbox, the bounds, and the audit apply as for the model.
        case person
    }

    /// Limits applied to every command.
    public var options: Options
    /// Where policy decisions and outcomes are recorded, if anywhere.
    public var audit: AuditLog?
    /// Classifies commands and asks for approval when they are risky; nil never asks.
    public var approval: ApprovalGate?

    /// Creates a runner with the given limits.
    public init(options: Options = Options(), audit: AuditLog? = nil, approval: ApprovalGate? = nil) {
        self.options = options
        self.audit = audit
        self.approval = approval
    }

    /// True when this process is already inside a Seatbelt sandbox whose profile differs from ours.
    ///
    /// Seatbelt lets a process re-apply an identical profile but refuses a different one, so the probe
    /// applies a profile no outer sandbox would use. Decided once per process from a fixed command whose
    /// output nobody else controls; a user command can never influence it.
    public static let isNestedSandbox: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", "(version 1) (allow default) (deny file-write* (subpath \"/nonexistent/wisp-nesting-probe\"))",
            "/usr/bin/true",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return true }
        process.waitUntilExit()
        return process.terminationStatus != 0
    }()

    /// Runs `command` through `/bin/sh -c` and waits for it to finish or time out.
    ///
    /// - Parameters:
    ///   - command: A POSIX shell command line.
    ///   - directory: Where to run it; nil means the process's current directory. Changes where the
    ///     command runs, never what it may write (see `Options.writableRoot`).
    ///   - origin: Who chose it. A command the person typed (`.person`) skips the approval gate, its classifier
    ///     and its question, and is marked as theirs in the audit; everything else is the same.
    /// - Returns: The exit status and bounded output.
    /// - Throws: `Failure` if the policy rejects the command or it cannot be started.
    public func run(_ command: String, in directory: String? = nil, origin: Origin = .model) async throws -> Outcome {
        let workingDirectory = try Self.existingDirectory(directory)
        try await admit(command, in: workingDirectory, gate: origin == .person ? nil : approval, origin: origin)
        decide(.allowed, command: command, in: workingDirectory, origin: origin)
        return try await execute(command, in: workingDirectory, origin: origin)
    }

    /// Whether commands run under Seatbelt here: the policy's sandbox is on and wisp is not already inside
    /// another sandbox, whose refusal of a nested profile makes commands run under that one instead.
    public var confines: Bool { sandboxed }

    /// The canonical directories commands may write under, as the sandbox's profile names them.
    public var writableRoots: [String] {
        options.policy.writableRoots(
            writableRoot: options.writableRoot, temporaryDirectory: FileManager.default.temporaryDirectory.path,
            userCacheDirectory: Self.userCacheDirectory, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Whether the sandbox refused `outcome`'s command (ADR 0054): checked against the writable roots where its
    /// error output names a path, a guess where it names none; nil when it ran unconfined, succeeded, or reported
    /// no `Operation not permitted`.
    ///
    /// - Parameters:
    ///   - outcome: What the command produced.
    ///   - directory: Where it ran, for a relative path.
    /// - Returns: The verdict, or nil.
    func sandboxRefusal(_ outcome: Outcome, in directory: String) -> SandboxRefusal? {
        SandboxRefusal.check(
            stderr: outcome.stderr, exitStatus: outcome.exitStatus, sandboxed: sandboxed, roots: writableRoots,
            directory: directory)
    }

    /// One command line cleared for repeated runs: the gate was consulted once, when it was authorised,
    /// and is not consulted again. Every run still checks the policy, runs under the sandbox, and records
    /// its `policy.decision` and `command.outcome`. Only the exact line and directory it was authorised
    /// for can run, so the clearance cannot be reused for anything else.
    public struct Authorized: Sendable {
        /// The command line.
        public let command: String
        /// Where it runs.
        public let workingDirectory: String
        /// The runner, without its gate.
        let runner: CommandRunner

        /// Runs the command once more.
        ///
        /// - Returns: The exit status and bounded output.
        /// - Throws: `Failure` if the policy now rejects it or it cannot be started.
        public func run() async throws -> Outcome {
            try await runner.run(command, in: workingDirectory)
        }
    }

    /// Checks `command` against the policy and clears it through the approval gate once (classifying it
    /// and asking when it is risky), for a caller that will run the same line repeatedly: `wisp watch`.
    ///
    /// - Parameters:
    ///   - command: A POSIX shell command line.
    ///   - directory: Where it will run; nil means the process's current directory.
    /// - Returns: The authorised command, to run as often as needed.
    /// - Throws: `Failure` if the policy rejects it, the gate refuses it, or the directory does not exist.
    public func authorize(_ command: String, in directory: String? = nil) async throws -> Authorized {
        let workingDirectory = try Self.existingDirectory(directory)
        try await admit(command, in: workingDirectory, gate: approval)
        var cleared = self
        cleared.approval = nil
        return Authorized(command: command, workingDirectory: workingDirectory, runner: cleared)
    }

    /// `directory`, or the current directory, when it is an existing directory.
    ///
    /// - Throws: `Failure.invalidWorkingDirectory` otherwise.
    private static func existingDirectory(_ directory: String?) throws -> String {
        let workingDirectory = directory ?? FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw Failure.invalidWorkingDirectory(workingDirectory) }
        return workingDirectory
    }

    /// Whether commands run under Seatbelt here.
    private var sandboxed: Bool { options.policy.sandbox.enabled && !Self.isNestedSandbox }

    /// Records a `policy.decision`, marked as the person's when they typed the command.
    private func decide(
        _ verdict: AuditEvent.Details.PolicyVerdict, reason: String? = nil, command: String,
        in workingDirectory: String, origin: Origin = .model
    ) {
        audit?.record(
            .policyDecision,
            details: AuditEvent.Details.policyDecision(
                command: command, workingDirectory: workingDirectory, verdict: verdict, reason: reason,
                sandbox: sandboxed, network: options.policy.sandbox.allowNetwork,
                nested: options.policy.sandbox.enabled && Self.isNestedSandbox, origin: origin))
    }

    /// Checks the policy for the line and each simple command in it, then clears the line through `gate`;
    /// records the denial or refusal when there is one.
    ///
    /// - Throws: `Failure.denied` or `Failure.disapproved`.
    private func admit(
        _ command: String, in workingDirectory: String, gate: ApprovalGate?, origin: Origin = .model
    ) async throws {
        let parts = CommandSplitter.split(command)
        let verdicts = ([command] + parts.map(\.text)).map(options.policy.check)
        if let denial = verdicts.first(where: { if case .denied = $0 { true } else { false } }),
            case .denied(let reason) = denial
        {
            decide(.denied, reason: reason, command: command, in: workingDirectory, origin: origin)
            Diagnostics.policy.info("denied: \(reason): \(command)")
            throw Failure.denied(reason)
        }
        do {
            try await gate?.clear(parts: parts, line: command, workingDirectory: workingDirectory)
        } catch ApprovalGate.Failure.refused(let reason) {
            decide(.disapproved, reason: reason, command: command, in: workingDirectory)
            throw Failure.disapproved(reason)
        }
    }

    /// Launches an admitted command and records its outcome, marked as the person's when they typed it.
    private func execute(
        _ command: String, in workingDirectory: String, origin: Origin = .model
    ) async throws
        -> Outcome
    {
        let started = Date()
        var outcome = try await launch(command, in: workingDirectory, sandboxed: sandboxed)
        if let refusal = sandboxRefusal(outcome, in: workingDirectory) {
            outcome.sandboxRefusal = refusal
            outcome.sandboxNote = refusal.note(roots: writableRoots)
        }
        audit?.record(
            .commandOutcome,
            details: AuditEvent.Details.commandOutcome(
                command: command, outcome: outcome, seconds: Date().timeIntervalSince(started), origin: origin))
        Diagnostics.policy.debug("exit \(outcome.exitStatus) after \(Date().timeIntervalSince(started))s: \(command)")
        return outcome
    }

    /// The per-user cache directory (`getconf DARWIN_USER_CACHE_DIR`), or nil if the system has none.
    static var userCacheDirectory: String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(length) - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Spawns `/bin/sh -c command` in its own process group, under `sandbox-exec` when `sandboxed`,
    /// and captures its outcome. Exactly one launch per call.
    private func launch(_ command: String, in workingDirectory: String, sandboxed: Bool) async throws -> Outcome {
        var argv = ["/bin/sh", "-c", command]
        if sandboxed {
            let profile = options.policy.seatbeltProfile(
                writableRoot: options.writableRoot,
                temporaryDirectory: FileManager.default.temporaryDirectory.path,
                userCacheDirectory: Self.userCacheDirectory,
                home: FileManager.default.homeDirectoryForCurrentUser.path
            )
            argv = ["/usr/bin/sandbox-exec", "-p", profile] + argv
        }
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let pid = try Spawn.spawn(argv, workingDirectory: workingDirectory, stdout: stdoutBuffer, stderr: stderrBuffer)

        let timedOut = Mutex(false)
        let timeout = options.timeout
        let watchdog = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            timedOut.withLock { $0 = true }
            kill(-pid, SIGTERM)
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            kill(-pid, SIGKILL)
        }
        let status = await Spawn.wait(for: pid)
        watchdog.cancel()
        // The group is dead, so writers close and EOF arrives; a descendant that escaped the group
        // could hold the pipe, so the drain is bounded rather than blocking.
        await stdoutBuffer.drain(deadline: .seconds(1))
        await stderrBuffer.drain(deadline: .seconds(1))

        let out = Self.tail(stdoutBuffer.contents, maxBytes: options.maxOutputBytes)
        let err = Self.tail(stderrBuffer.contents, maxBytes: options.maxOutputBytes)
        return Outcome(
            exitStatus: status,
            stdout: out.text,
            stderr: err.text,
            timedOut: timedOut.withLock { $0 },
            truncated: out.truncated || err.truncated
        )
    }

    /// Keeps at most `maxBytes` from the end of `data`, decoded as UTF-8 with replacement.
    static func tail(_ data: Data, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard data.count > maxBytes else { return (String(decoding: data, as: UTF8.self), false) }
        return (String(decoding: data.suffix(maxBytes), as: UTF8.self), true)
    }
}

/// A thread-safe byte accumulator fed by a pipe's readability handler.
final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())
    private let finished = Mutex(false)
    /// The pipe's read end; owned here so its readability handler stays installed.
    private let handle = Mutex<FileHandle?>(nil)

    /// A snapshot of everything captured so far.
    var contents: Data { storage.withLock { $0 } }

    /// Whether the writer has closed the pipe.
    var isFinished: Bool { finished.withLock { $0 } }

    /// Appends bytes; safe to call from the pipe's handler queue and the caller concurrently.
    func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    /// Takes ownership of a pipe's read end and appends every chunk until end of file.
    func capture(_ handle: FileHandle) {
        self.handle.withLock { $0 = handle }
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.withLock { $0 = true }
                try? handle.close()
            } else {
                append(chunk)
            }
        }
    }

    /// Waits for end of file, but no longer than `deadline`.
    func drain(deadline: Duration) async {
        let stop = ContinuousClock.now + deadline
        while !isFinished, ContinuousClock.now < stop {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Minimal `posix_spawn` wrapper: new process group, working directory, stdin from `/dev/null`,
/// stdout and stderr into `OutputBuffer`s.
enum Spawn {
    /// Spawns `argv[0]` with `argv`, returning the child's pid, which is also its process group id.
    ///
    /// - Throws: `CommandRunner.Failure.launchFailed`.
    static func spawn(
        _ argv: [String], workingDirectory: String, stdout: OutputBuffer, stderr: OutputBuffer
    ) throws
        -> pid_t
    {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw CommandRunner.Failure.launchFailed("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for descriptor in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, environ)
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw CommandRunner.Failure.launchFailed("\(argv[0]): \(String(cString: strerror(result)))")
        }
        stdout.capture(FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true))
        stderr.capture(FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true))
        return pid
    }

    /// Waits for `pid` off the cooperative pool and returns its status: the exit code, or the signal negated.
    static func wait(for pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                let signal = status & 0x7f
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : -signal)
            }
        }
    }
}
