import Darwin
import Foundation
import Synchronization

/// Runs a shell command with a timeout, bounded output capture, and a `CommandPolicy`.
///
/// The policy's patterns are checked before launch and its sandbox, when
/// enabled, wraps the shell in `sandbox-exec`. The command is spawned in its
/// own process group so a timeout can stop the whole tree. Output is captured
/// separately for stdout and stderr into bounded buffers that keep each stream's head and tail in memory,
/// and spill the whole stream to the conversation's output store (`OutputStore`) as it arrives when there is
/// one; the result the model sees fits the tool-output budget as a whole, and what is held back is marked and
/// kept, never dropped ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)).
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
        /// The most bytes of a command's result the model is shown, its notes included, set by the operator
        /// (`commandMaxOutputBytes`); nil, the default, takes the conversation's tool-output budget (`ToolBudget`),
        /// an eighth of the model's window. Whatever the bound, the whole output is kept in the output store when
        /// the conversation has one.
        public var maxOutputBytes: Int?
        /// What may run and how it is confined.
        public var policy: CommandPolicy
        /// Directories no command may write, even inside the writable set: wisp's own home, where its approvals,
        /// facts, configuration, and pending answers live. `edit_file` refuses them too.
        public var protectedPaths: [String]

        /// Creates options. Defaults are a 60-second timeout, the tool-output budget as the bound, the default
        /// policy, the current directory as the writable root, and wisp's home (`Home.resolve()`) protected.
        public init(
            writableRoot: String? = nil, timeout: Duration = .seconds(60), maxOutputBytes: Int? = nil,
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
        /// A run of one stream's lines the model is not shown.
        public struct Held: Sendable, Equatable {
            /// `stdout` or `stderr`.
            public var stream: String
            /// The first line held back, numbered in the stored output (`stored`), from 1.
            public var firstLine: Int
            /// The last line held back.
            public var lastLine: Int
            /// Bytes held back.
            public var bytes: Int

            /// Creates a run.
            public init(stream: String, firstLine: Int, lastLine: Int, bytes: Int) {
                self.stream = stream
                self.firstLine = firstLine
                self.lastLine = lastLine
                self.bytes = bytes
            }
        }

        /// The process exit status, or the terminating signal negated if it was killed.
        public var exitStatus: Int32
        /// Standard output as the model is shown it: whole within the bound, else its first and last lines with a
        /// marker between them naming what is held back (`held`).
        public var stdout: String
        /// Standard error, likewise.
        public var stderr: String
        /// Whether the command hit the timeout and was killed.
        public var timedOut: Bool
        /// Whether either stream has lines held back.
        public var truncated: Bool
        /// Whether the person stopped it (`CommandStop`, Ctrl-C in chat) and it was killed.
        public var stopped: Bool = false
        /// For a confined command that failed with `Operation not permitted`, whether the sandbox refused it
        /// (ADR 0054); nil otherwise.
        public var sandboxRefusal: SandboxRefusal? = nil
        /// What the model is told of `sandboxRefusal` (`SandboxRefusal.note(roots:)`); nil when there is none.
        public var sandboxNote: String? = nil
        /// What each stream holds back, in stream order; empty when the whole output is shown.
        public var held: [Held] = []
        /// The whole output as kept in the conversation's output store (the rendering with nothing held back),
        /// when anything was held back and the conversation has a store; nil otherwise.
        public var stored: OutputStore.Kept? = nil
        /// Whether the conversation has `memory`, so the note on held-back output names the calls that page it.
        public var recallable: Bool = false

        /// Creates an outcome.
        public init(
            exitStatus: Int32, stdout: String, stderr: String, timedOut: Bool, truncated: Bool, stopped: Bool = false,
            sandboxRefusal: SandboxRefusal? = nil, sandboxNote: String? = nil, held: [Held] = [],
            stored: OutputStore.Kept? = nil, recallable: Bool = false
        ) {
            self.exitStatus = exitStatus
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
            self.truncated = truncated
            self.stopped = stopped
            self.sandboxRefusal = sandboxRefusal
            self.sandboxNote = sandboxNote
            self.held = held
            self.stored = stored
            self.recallable = recallable
        }

        /// The lines before the streams: the exit status, and how the command was ended when it did not end on
        /// its own. The same in the result and in the stored output, so the held-back line numbers agree.
        var header: [String] {
            var lines = ["exit status: \(exitStatus)"]
            if timedOut { lines.append("timed out: the command was killed") }
            if stopped { lines.append("stopped: the person stopped the command") }
            return lines
        }

        /// A compact, model-facing rendering of the outcome: the header, each non-empty stream under its frame,
        /// the note on what is held back and where the whole is kept, and the sandbox's note. Within the bound as
        /// a whole, the notes included.
        public var rendered: String {
            var lines = header
            if !stdout.isEmpty { lines.append("stdout:\n\(stdout)") }
            if !stderr.isEmpty { lines.append("stderr:\n\(stderr)") }
            if !held.isEmpty {
                lines.append(
                    ToolOutput.heldNote(
                        held.map {
                            (
                                $0.stream,
                                ToolOutput.HeldBack(firstLine: $0.firstLine, lastLine: $0.lastLine, bytes: $0.bytes)
                            )
                        }, kept: stored, memory: recallable, command: true))
            }
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
    /// The conversation's tool-output budget, the bound on a result when `Options.maxOutputBytes` is nil; nil
    /// gives the budget's floor.
    public var budget: ToolBudget?
    /// Where a command's whole output is kept when more than the bound is printed; nil keeps nothing, and the
    /// result says so.
    public var store: OutputStore?

    /// Creates a runner with the given limits.
    ///
    /// - Parameters:
    ///   - options: The limits.
    ///   - audit: Where decisions and outcomes are recorded.
    ///   - approval: The gate.
    ///   - budget: The conversation's tool-output budget.
    ///   - store: The conversation's output store.
    public init(
        options: Options = Options(), audit: AuditLog? = nil, approval: ApprovalGate? = nil, budget: ToolBudget? = nil,
        store: OutputStore? = nil
    ) {
        self.options = options
        self.audit = audit
        self.approval = approval
        self.budget = budget
        self.store = store
    }

    /// The most bytes a result carries to the model, its notes included: the operator's `maxOutputBytes`, else the
    /// budget now, else the budget's floor.
    public var bound: Int { options.maxOutputBytes ?? budget?.bytes ?? ToolBudget.floor }

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
        // Each stream keeps a head and a tail of the bound in memory, enough to render any share of it, and spills
        // the whole stream to the store the moment memory would drop a byte.
        let bound = self.bound
        let id = ToolCallContext.outputID
        let stdoutBuffer = OutputBuffer(keep: bound, spill: Self.spill(into: store, name: id + ".out"))
        let stderrBuffer = OutputBuffer(keep: bound, spill: Self.spill(into: store, name: id + ".err"))
        let pid = try Spawn.spawn(argv, workingDirectory: workingDirectory, stdout: stdoutBuffer, stderr: stderrBuffer)

        let group = ProcessGroup(pid)
        // The watchdog is a safety bound, so it runs on an `Alarm`, not a `Task.sleep`: blocked cooperative threads
        // must not be able to hold it off (docs/design.md, "Concurrency"). Once the leader is reaped the group sends
        // nothing, so a SIGKILL alarm left pending after the command ends is harmless.
        let watchdog = timeout.map { timeout in
            Alarm(after: timeout) {
                group.end(.timedOut)
                _ = Alarm(after: CommandStop.grace) { group.signal(SIGKILL) }
            }
        }
        // The person's stop: SIGTERM, then SIGKILL after the grace; a second request kills at once.
        stop?.attach { request in
            switch request {
            case .stop:
                group.end(.stopped)
                _ = Alarm(after: CommandStop.grace) { group.signal(SIGKILL) }
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

        return Self.outcome(
            exitStatus: status, timedOut: group.ending == .timedOut, stopped: group.ending == .stopped,
            stdout: stdoutBuffer.contents, stderr: stderrBuffer.contents, bound: bound, store: store, id: id,
            recallable: budget?.memory ?? false)
    }

    /// Room the notes on a result take out of the bound: the header, the frames, and the held-back note.
    static let notesAllowance = 640

    /// What opens a stream's spill file in `store`, named `name`; nil without a store.
    private static func spill(
        into store: OutputStore?, name: String
    ) -> (@Sendable () -> (handle: FileHandle, url: URL)?)? {
        guard let store else { return nil }
        return { store.spill(name) }
    }

    /// The outcome from two captured streams: each shown whole when both fit the bound with the notes, else as
    /// its head and tail within its share of the room, the whole output composed into the store under `id` when
    /// anything is held back.
    ///
    /// The share is proportional to the streams' sizes, and never less than a fifth of the room for a stream
    /// that has something to show, so a long build log does not crowd out a short error. The stored output is the
    /// rendering with nothing held back, so the line numbers the markers give are the stored file's.
    ///
    /// - Parameters:
    ///   - exitStatus: The exit status.
    ///   - timedOut: Whether the watchdog ended it.
    ///   - stopped: Whether the person did.
    ///   - stdout: Standard output as captured.
    ///   - stderr: Standard error as captured.
    ///   - bound: The most bytes the rendering may take.
    ///   - store: Where the whole output is kept; nil keeps nothing.
    ///   - id: The id to keep it under.
    ///   - recallable: Whether the note names `memory`.
    /// - Returns: The outcome.
    static func outcome(
        exitStatus: Int32, timedOut: Bool, stopped: Bool, stdout: OutputBuffer.Capture, stderr: OutputBuffer.Capture,
        bound: Int, store: OutputStore?, id: String, recallable: Bool
    ) -> Outcome {
        var outcome = Outcome(
            exitStatus: exitStatus, stdout: "", stderr: "", timedOut: timedOut, truncated: false, stopped: stopped,
            recallable: recallable)
        let header = outcome.header
        let streams = [("stdout", stdout), ("stderr", stderr)].filter { $0.1.total > 0 }
        let total = streams.reduce(0) { $0 + $1.1.total }
        let whole = streams.allSatisfy { $0.1.whole != nil }
        let plain = header.count + streams.count * 8 + total
        if whole, plain <= bound {
            outcome.stdout = stdout.whole.map { String(decoding: $0, as: UTF8.self) } ?? ""
            outcome.stderr = stderr.whole.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return outcome
        }
        let room = max(256, bound - Self.notesAllowance)
        let floor = room / 5
        var line = header.count
        var held: [Outcome.Held] = []
        var parts: [OutputStore.Part] = [.text(header.joined(separator: "\n") + "\n")]
        for (name, capture) in streams {
            let share = max(floor, room * capture.total / max(1, total))
            let fit: ToolOutput.Fit
            if let data = capture.whole {
                let text = String(decoding: data, as: UTF8.self)
                fit = ToolOutput.fit(head: text, tail: text, within: share, lineOffset: line + 1)
                parts.append(.text("\(name):\n" + text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n")))
            } else {
                fit = ToolOutput.fit(
                    head: String(decoding: capture.head, as: UTF8.self),
                    tail: String(decoding: capture.tail, as: UTF8.self),
                    total: (capture.lines, capture.total), within: share, lineOffset: line + 1)
                parts.append(.text("\(name):\n"))
                if let spilled = capture.spilled { parts.append(.file(spilled, remove: true)) }
                if capture.lastByte != 0x0A { parts.append(.text("\n")) }
            }
            if name == "stdout" { outcome.stdout = fit.shown } else { outcome.stderr = fit.shown }
            if let run = fit.held {
                held.append(
                    Outcome.Held(stream: name, firstLine: run.firstLine, lastLine: run.lastLine, bytes: run.bytes))
            }
            line += 1 + capture.lines
        }
        outcome.held = held
        outcome.truncated = !held.isEmpty
        if !held.isEmpty {
            outcome.stored = store?.compose(parts, id: id, tool: "run_command")
        }
        // A spilled stream that was shown whole after all leaves its file behind; remove it.
        for capture in [stdout, stderr] {
            if held.isEmpty, let spilled = capture.spilled { try? FileManager.default.removeItem(at: spilled) }
        }
        return outcome
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

/// A bounded byte buffer fed by a pipe's readability handler: it keeps the first `keep` bytes and the last `keep`
/// bytes of a stream in memory, counts everything, and, the moment a byte would be dropped from memory, spills
/// the whole stream (what it holds, then every later chunk) to a file through `spill`, so a command that prints
/// far more than the bound costs memory of twice the bound and no more, and nothing is lost when there is a store
/// ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)). Before 0.22.0 it held every
/// byte until the command ended, then kept the tail (the 2026-10-09 review).
final class OutputBuffer: Sendable {
    /// What was captured, as the runner reads it when the command has ended.
    struct Capture: Sendable, Equatable {
        /// The first bytes, up to `keep`.
        var head = Data()
        /// The last bytes, up to `keep`; overlaps `head` while the stream is short.
        var tail = Data()
        /// Bytes seen.
        var total = 0
        /// Newlines seen.
        var newlines = 0
        /// The last byte seen; nil while none.
        var lastByte: UInt8?
        /// The file the whole stream was spilled to; nil while nothing was dropped from memory, or without a spill.
        var spilled: URL?
        /// Bytes dropped from memory (and spilled when there is a spill).
        var dropped = 0

        /// Lines seen: the newlines, and one more for an unterminated last line.
        var lines: Int { newlines + (lastByte == nil || lastByte == 0x0A ? 0 : 1) }

        /// The whole stream, when nothing was dropped from memory; nil otherwise.
        var whole: Data? {
            guard dropped == 0 else { return nil }
            guard total > head.count else { return head }
            return head + tail.suffix(total - head.count)
        }
    }

    /// The bytes kept at each end.
    let keep: Int
    /// Opens the spill file when the first byte would be dropped; nil never spills.
    private let spill: (@Sendable () -> (handle: FileHandle, url: URL)?)?
    /// The capture, the spill file once open, and whether the writer has closed the pipe.
    private let state: Mutex<(capture: Capture, handle: FileHandle?, spillFailed: Bool, finished: Bool)>
    /// The pipe's read end; owned here so its readability handler stays installed.
    private let handle = Mutex<FileHandle?>(nil)

    /// Creates a buffer.
    ///
    /// - Parameters:
    ///   - keep: Bytes kept at each end; the bound.
    ///   - spill: Opens the file the whole stream goes to once memory would drop a byte; nil drops and counts.
    init(keep: Int, spill: (@Sendable () -> (handle: FileHandle, url: URL)?)? = nil) {
        self.keep = max(1, keep)
        self.spill = spill
        state = Mutex((Capture(), nil, false, false))
    }

    /// A snapshot of everything captured so far.
    var contents: Capture { state.withLock { $0.capture } }

    /// Whether the writer has closed the pipe.
    var isFinished: Bool { state.withLock { $0.finished } }

    /// Appends bytes; safe to call from the pipe's handler queue and the caller concurrently.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock { state in
            state.capture.total += data.count
            state.capture.newlines += data.count(where: { $0 == 0x0A })
            state.capture.lastByte = data.last
            var rest = data[...]
            if state.capture.head.count < keep {
                let take = min(keep - state.capture.head.count, rest.count)
                state.capture.head.append(rest.prefix(take))
                rest = rest.dropFirst(take)
            }
            guard !rest.isEmpty else { return }
            if state.handle == nil, !state.spillFailed, state.capture.tail.count + rest.count > keep, let spill {
                // About to drop a byte from memory: from here the whole stream goes to the file, starting with what
                // memory holds.
                if let opened = spill() {
                    state.handle = opened.handle
                    state.capture.spilled = opened.url
                    try? opened.handle.write(contentsOf: state.capture.head)
                    try? opened.handle.write(contentsOf: state.capture.tail)
                } else {
                    state.spillFailed = true
                }
            }
            try? state.handle?.write(contentsOf: rest)
            state.capture.tail.append(rest)
            if state.capture.tail.count > keep {
                let excess = state.capture.tail.count - keep
                state.capture.tail.removeFirst(excess)
                state.capture.dropped += excess
            }
        }
    }

    /// Takes ownership of a pipe's read end and appends every chunk until end of file.
    func capture(_ handle: FileHandle) {
        self.handle.withLock { $0 = handle }
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.withLock { state in
                    state.finished = true
                    try? state.handle?.close()
                    state.handle = nil
                }
                try? handle.close()
            } else {
                append(chunk)
            }
        }
    }

    /// Waits for end of file, but no longer than `deadline`; closes the spill file either way.
    func drain(deadline: Duration) async {
        let stop = ContinuousClock.now + deadline
        while !isFinished, ContinuousClock.now < stop {
            try? await Task.sleep(for: .milliseconds(10))
        }
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }
}

/// Minimal `posix_spawn` wrapper: new process group, working directory, stdin from `/dev/null`,
/// stdout and stderr into `OutputBuffer`s, and no other descriptor of wisp's in the child.
enum Spawn {
    /// Spawns `argv[0]` with `argv`, returning the child's pid, which is also its process group id.
    ///
    /// The child gets exactly three descriptors. Every descriptor wisp holds is closed in the child by
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, so one command never inherits another's pipe, an audit file, or a file
    /// `read_file` has open (the 2026-10-09 review); the pipes' ends are marked close-on-exec as well, so no
    /// other `exec` in this process (a notifier's `osascript`, a probe) inherits them either.
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
        for descriptor in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        // dup2 clears close-on-exec on the new descriptor, so 1 and 2 survive the exec; nothing else does.
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                truncatingIfNeeded: POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                    | POSIX_SPAWN_CLOEXEC_DEFAULT))
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
    ///
    /// The wait blocks a thread in `waitpid` for as long as the command runs, so it gets a serial queue of its own,
    /// which libdispatch backs with a thread of its own: on a global queue, enough running commands would reach
    /// libdispatch's limit on that queue's threads and hold up every other job sent to it.
    static func wait(for pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "wisp.waitpid", qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                let signal = status & 0x7f
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : -signal)
            }
        }
    }
}
