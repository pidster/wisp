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
        /// Wall-clock limit after which the command's process group is sent SIGTERM, then SIGKILL. A command the person
        /// typed (`Origin.person`) has none.
        public var timeout: Duration
        /// Maximum bytes kept from each of stdout and stderr; earlier output is discarded.
        public var maxOutputBytes: Int
        /// What may run and how it is confined.
        public var policy: CommandPolicy
        /// Directories no command may write, even inside the writable set: wisp's own home, where its approvals,
        /// facts, configuration, and pending answers live. `edit_file` refuses them too.
        public var protectedPaths: [String]

        /// Creates options. Defaults are a 60-second timeout, 4 KiB per stream, the default policy, the
        /// current directory as the writable root, and wisp's home (`Home.resolve()`) protected.
        public init(
            writableRoot: String? = nil, timeout: Duration = .seconds(60), maxOutputBytes: Int = 4096,
            policy: CommandPolicy = .default, protectedPaths: [String]? = nil
        ) {
            self.writableRoot = writableRoot ?? FileManager.default.currentDirectoryPath
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.policy = policy
            self.protectedPaths = protectedPaths ?? [Home.resolve().root.path]
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
        /// Whether the person stopped it (`CommandStop`, Ctrl-C in chat) and it was killed.
        public var stopped: Bool = false
        /// For a confined command that failed with `Operation not permitted`, whether the sandbox refused it
        /// (ADR 0054); nil otherwise.
        public var sandboxRefusal: SandboxRefusal? = nil
        /// What the model is told of `sandboxRefusal` (`SandboxRefusal.note(roots:)`); nil when there is none.
        public var sandboxNote: String? = nil

        /// A compact, model-facing rendering of the outcome, with the sandbox's note after the output.
        public var rendered: String {
            var lines = ["exit status: \(exitStatus)"]
            if timedOut { lines.append("timed out: the command was killed") }
            if stopped { lines.append("stopped: the person stopped the command") }
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
        /// The policy's lists, the sandbox, the output bound, and the audit apply as for the model; the timeout does
        /// not, since the person stops it themselves (`CommandStop`, ADR 0049 amended 2026-10-09).
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

    /// Runs `command` through `/bin/sh -c` and waits for it to finish, time out, or be stopped.
    ///
    /// - Parameters:
    ///   - command: A POSIX shell command line.
    ///   - directory: Where to run it; nil means the process's current directory. Changes where the
    ///     command runs, never what it may write (see `Options.writableRoot`).
    ///   - origin: Who chose it. A command the person typed (`.person`) skips the approval gate, its classifier
    ///     and its question, and has no timeout: the person stops it, through `stop` (ADR 0049, amended
    ///     2026-10-09). It is marked as theirs in the audit; everything else is the same.
    ///   - stop: Stops the command when asked: its process group is sent SIGTERM, then SIGKILL after
    ///     `CommandStop.grace`, or SIGKILL at once on a second request; nil cannot be stopped but by the timeout.
    /// - Returns: The exit status and bounded output.
    /// - Throws: `Failure` if the policy rejects the command or it cannot be started.
    public func run(
        _ command: String, in directory: String? = nil, origin: Origin = .model, stop: CommandStop? = nil
    ) async throws -> Outcome {
        let workingDirectory = try Self.existingDirectory(directory)
        try await admit(command, in: workingDirectory, gate: origin == .person ? nil : approval, origin: origin)
        decide(.allowed, command: command, in: workingDirectory, origin: origin)
        return try await execute(command, in: workingDirectory, origin: origin, stop: stop)
    }

    /// The wall-clock limit for a command from `origin`: `Options.timeout` for the model's, none for one the person
    /// typed, who stops it themselves (ADR 0049, amended 2026-10-09).
    ///
    /// - Parameter origin: Who chose the command.
    /// - Returns: The limit, or nil for none.
    func timeout(for origin: Origin) -> Duration? {
        origin == .person ? nil : options.timeout
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
        _ command: String, in workingDirectory: String, origin: Origin = .model, stop: CommandStop? = nil
    ) async throws
        -> Outcome
    {
        let started = Date()
        var outcome = try await launch(
            command, in: workingDirectory, sandboxed: sandboxed, timeout: timeout(for: origin), stop: stop)
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
    ///
    /// - Parameters:
    ///   - command: The command line.
    ///   - workingDirectory: Where it runs.
    ///   - sandboxed: Whether to confine it.
    ///   - timeout: When the watchdog stops it; nil never.
    ///   - stop: Stops it when the person asks; nil cannot.
    /// - Returns: The outcome.
    /// - Throws: `Failure.launchFailed`.
    private func launch(
        _ command: String, in workingDirectory: String, sandboxed: Bool, timeout: Duration?, stop: CommandStop?
    ) async throws -> Outcome {
        var argv = ["/bin/sh", "-c", command]
        if sandboxed {
            let profile = options.policy.seatbeltProfile(
                writableRoot: options.writableRoot,
                temporaryDirectory: FileManager.default.temporaryDirectory.path,
                userCacheDirectory: Self.userCacheDirectory,
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                protected: options.protectedPaths
            )
            if profile.contains("\n; note: ") {
                Diagnostics.policy.info("wisp's home is inside the writable set; the sandbox still denies writes to it")
            }
            argv = ["/usr/bin/sandbox-exec", "-p", profile] + argv
        }
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let pid = try Spawn.spawn(argv, workingDirectory: workingDirectory, stdout: stdoutBuffer, stderr: stderrBuffer)

        let group = ProcessGroup(pid)
        let watchdog = timeout.map { timeout in
            Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                group.end(.timedOut)
                guard (try? await Task.sleep(for: CommandStop.grace)) != nil else { return }
                group.signal(SIGKILL)
            }
        }
        // The person's stop: SIGTERM, then SIGKILL after the grace; a second request kills at once.
        stop?.attach { request in
            switch request {
            case .stop:
                group.end(.stopped)
                Task {
                    try? await Task.sleep(for: CommandStop.grace)
                    group.signal(SIGKILL)
                }
            case .kill:
                group.end(.stopped, signal: SIGKILL)
            }
        }
        let status = await Spawn.wait(for: pid)
        group.reaped()
        stop?.detach()
        watchdog?.cancel()
        // The leader is gone, but a child may live on in its group: one that ignored SIGTERM, or a job the
        // command put in the background. Nothing a command starts outlives it, so the group is killed now.
        await Self.killGroup(pid)
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
            timedOut: group.ending == .timedOut,
            truncated: out.truncated || err.truncated,
            stopped: group.ending == .stopped
        )
    }

    /// Sends SIGKILL to process group `group` until it is empty (`kill` reports `ESRCH`), checking every
    /// 10 ms for up to `deadline`. Called once its leader has been reaped: the kernel keeps the group's id
    /// from reuse while any member lives, so the signal reaches only what the command started.
    ///
    /// - Parameters:
    ///   - group: The process group id, the leader's pid.
    ///   - deadline: How long to keep trying; a member stuck in the kernel can outlast it.
    static func killGroup(_ group: pid_t, deadline: Duration = .seconds(2)) async {
        let stop = ContinuousClock.now + deadline
        while kill(-group, SIGKILL) == 0 || errno == EPERM, ContinuousClock.now < stop {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Keeps at most `maxBytes` from the end of `data`, decoded as UTF-8 with replacement.
    static func tail(_ data: Data, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard data.count > maxBytes else { return (String(decoding: data, as: UTF8.self), false) }
        return (String(decoding: data.suffix(maxBytes), as: UTF8.self), true)
    }
}

/// A command's process group while its leader runs, signalled by the watchdog and the person's stop: once the
/// leader is reaped (`reaped()`) nothing more is sent, so a group id the kernel has freed and reused is never
/// signalled. Records which of the two ended it first.
final class ProcessGroup: Sendable {
    /// What ended a command before it finished on its own.
    enum Ending: Equatable {
        /// The watchdog, at the timeout.
        case timedOut
        /// The person, through `CommandStop`.
        case stopped
    }

    /// The process group id, the leader's pid.
    private let id: pid_t
    /// Whether the leader has been reaped, and what ended it, if anything did.
    private let state = Mutex<(reaped: Bool, ending: Ending?)>((false, nil))

    /// Creates the group led by `id`.
    init(_ id: pid_t) { self.id = id }

    /// What ended the command first, or nil when it finished on its own.
    var ending: Ending? { state.withLock { $0.ending } }

    /// Records `ending` unless something ended the command already, and sends `signal` to the group.
    ///
    /// - Parameters:
    ///   - ending: Why.
    ///   - signal: The signal; SIGTERM by default.
    func end(_ ending: Ending, signal: Int32 = SIGTERM) {
        state.withLock { state in
            guard !state.reaped else { return }
            if state.ending == nil { state.ending = ending }
            kill(-id, signal)
        }
    }

    /// Sends `signal` to the group while its leader has not been reaped.
    func signal(_ signal: Int32) {
        state.withLock { state in
            if !state.reaped { kill(-id, signal) }
        }
    }

    /// The leader has been reaped: nothing more is sent through this (`CommandRunner.killGroup` clears the rest).
    func reaped() {
        state.withLock { $0.reaped = true }
    }
}

/// Stops a running command when the person asks (Ctrl-C in chat, an `interrupt` line from a front end): the first
/// request sends its process group SIGTERM and SIGKILL after `grace`; a later one sends SIGKILL at once. A request
/// made before the command starts takes effect as it starts; one made after it ended does nothing.
public final class CommandStop: Sendable {
    /// What a request asks of the command.
    public enum Request: Sendable, Equatable {
        /// End it: SIGTERM, then SIGKILL after the grace.
        case stop
        /// Kill it now.
        case kill
    }

    /// How long a stopped command has between SIGTERM and SIGKILL.
    public static let grace: Duration = .seconds(2)

    /// The requests so far, and who acts on them while the command runs.
    private let state = Mutex<(requests: Int, handler: (@Sendable (Request) -> Void)?)>((0, nil))

    /// Creates a stop nobody has asked for.
    public init() {}

    /// Whether a stop has been asked for.
    public var requested: Bool { state.withLock { $0.requests > 0 } }

    /// Asks the command to stop: the first request is `.stop`, every later one `.kill`.
    ///
    /// - Returns: What was asked.
    @discardableResult
    public func request() -> Request {
        let (request, handler) = state.withLock { state in
            state.requests += 1
            return (state.requests == 1 ? Request.stop : .kill, state.handler)
        }
        handler?(request)
        return request
    }

    /// Asks the command to die now, whatever was asked before.
    public func kill() {
        let handler = state.withLock { state in
            state.requests = max(state.requests, 2)
            return state.handler
        }
        handler?(.kill)
    }

    /// Sets who acts on requests while the command runs; a request already made is acted on at once.
    ///
    /// - Parameter handler: Signals the command's group.
    func attach(_ handler: @escaping @Sendable (Request) -> Void) {
        let requests = state.withLock { state in
            state.handler = handler
            return state.requests
        }
        if requests > 0 { handler(requests == 1 ? .stop : .kill) }
    }

    /// The command has ended: later requests reach nobody.
    func detach() {
        state.withLock { $0.handler = nil }
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
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        // Chat ignores SIGINT to take Ctrl-C itself (`ChatInterrupt`); an ignored signal is inherited across exec,
        // so the command gets the default back.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

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
