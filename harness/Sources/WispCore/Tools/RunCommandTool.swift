import Foundation
import FoundationModels

/// Lets the model run a shell command on this machine.
///
/// The command passes the `CommandPolicy`, the approval gate, and runs under
/// the Seatbelt sandbox rooted at the harness's launch directory; a
/// model-chosen working directory changes where it runs, never what it may write.
/// It runs under a wall-clock limit: the call's `timeoutSeconds`, else the thread's, else the operator's
/// default, a requested one clamped to `commandMaxTimeoutSeconds`
/// ([ADR 0063](../../../../docs/decisions/0063-command-time-limits.md)); the call's only lengthens the one it would
/// otherwise get ([ADR 0067](../../../../docs/decisions/0067-a-call-may-only-lengthen-its-time-limit.md)). With `outsideSandbox` it asks to run one
/// command without the sandbox, which the person approves for that line, once, every time
/// ([ADR 0064](../../../../docs/decisions/0064-an-approved-run-outside-the-sandbox.md)).
public struct RunCommandTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "run_command"
    /// What the model is told this tool does.
    public let description =
        "Runs a shell command on this Mac and returns its exit status and output. "
        + "Use it to build or test software, list or read files, and inspect the system."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The command line, executed by `/bin/sh -c`.
        @Guide(description: "POSIX shell command line to run with /bin/sh -c.")
        public var command: String
        /// Optional directory to run in; nil means the harness's current directory.
        @Guide(description: "Absolute path of the directory to run in. Omit to use the current directory.")
        public var workingDirectory: String?
        /// Optional wall-clock limit for this call, in seconds; nil, or one shorter than the thread's or the default,
        /// takes that.
        @Guide(description: "Only for a build or test that needs longer than the default, in seconds. Omit otherwise.")
        public var timeoutSeconds: Int?
        /// Whether to ask to run it without the sandbox (ADR 0064); nil or false runs it sandboxed.
        @Guide(
            description:
                "Set true only for a command the sandbox refuses, such as brew upgrade or cargo install; "
                + "the person must approve it.")
        public var outsideSandbox: Bool?
    }

    /// Supplies the policy, timeout, and output cap.
    private let runner: CommandRunner
    /// The thread's own limit, in seconds, from `respond`'s `commandTimeoutSeconds` when it started; nil takes the
    /// operator's default. Read by this tool alone, so it never reaches another thread or another tool.
    private let threadTimeout: Int?

    /// Sandbox, timeout, output cap, and approval, from the runner's live options.
    public var limits: String {
        let confinement =
            runner.options.policy.sandbox.enabled
            ? "in a Seatbelt sandbox rooted at wisp's launch directory; writes elsewhere fail"
            : "with no sandbox (policy.sandbox.enabled is false)"
        let bound =
            runner.options.maxOutputBytes.map { "\($0) bytes (commandMaxOutputBytes)" }
            ?? "the tool-output budget, \(runner.bound) bytes now (an eighth of the model's window, 4 to 64 KiB)"
        return
            "POSIX shell via /bin/sh -c \(confinement). \(timeoutText) The result is bounded as a whole to "
            + "\(bound): past that the first and last lines are shown, the rest is held back and kept whole in the "
            + "conversation's output store, and the result says how to page, filter, or summarise it. Commands pass "
            + "a deny/allow policy and a risk classifier; moderate and dangerous ones need the user's approval."
            + outsideText
    }

    /// The `outsideSandbox` sentence of `limits` (ADR 0064): what asking for it does here, or nothing when the
    /// sandbox is off.
    private var outsideText: String {
        switch runner.outsideSandboxRequest {
        case .asked:
            " outsideSandbox true asks to run one command the sandbox refuses without it; the user approves every such "
                + "run, whatever its risk, and nothing remembers it."
        case .turnedOff: " Running outside the sandbox is turned off here (outsideSandbox is refused)."
        case .unchanged(.nested):
            " wisp runs inside another sandbox, which confines its commands; outsideSandbox changes nothing here."
        case .unchanged(.sandboxOff), .notAsked: ""
        }
    }

    /// The timeout sentence of `limits`: the limit this thread's commands get when they ask for none, and the cap
    /// on a request.
    private var timeoutText: String {
        let fallback = runner.limit(for: .model, requested: .init(seconds: threadTimeout, source: .thread))
        let base = fallback?.seconds.map { "Timeout \($0) s" } ?? "No timeout"
        let whose = fallback?.source == .thread ? " (this thread's)" : ""
        let cap = fallback?.cap ?? 0
        return "\(base)\(whose); timeoutSeconds asks for longer, up to \(cap) s (commandMaxTimeoutSeconds)."
    }

    /// How to ask for it.
    public let examplePrompt =
        "Use run_command with working directory /path/to/repo to run exactly: swift test 2>&1 | tail -3 . "
        + "Report the exit status and output verbatim, nothing else."

    /// Creates the tool over a runner that supplies timeout and output limits.
    ///
    /// - Parameters:
    ///   - runner: The runner, with the operator's default limit and the cap on a request.
    ///   - threadTimeout: The thread's own limit in seconds, at least 1, clamped to the cap when a command runs;
    ///     nil takes the default.
    public init(runner: CommandRunner = CommandRunner(), threadTimeout: Int? = nil) {
        self.runner = runner
        self.threadTimeout = threadTimeout
    }

    /// Runs the command and returns a compact rendering of its outcome.
    ///
    /// A policy denial, a bad working directory, a `timeoutSeconds` below 1, or a refused `outsideSandbox` is
    /// returned as text rather than thrown, so the model sees why and can choose another approach
    /// instead of the whole response failing.
    ///
    /// - Parameter arguments: The command, optional working directory, optional limit, and whether to ask to run it
    ///   outside the sandbox.
    /// - Returns: Exit status and bounded stdout/stderr, formatted for the model.
    public func call(arguments: Arguments) async -> String {
        if let seconds = arguments.timeoutSeconds, seconds < 1 {
            return "error: timeoutSeconds must be at least 1 (it was \(seconds)); omit it for the default"
        }
        let requested: CommandRunner.TimeLimit.Request =
            arguments.timeoutSeconds.map { .init(seconds: $0, source: .call, thread: threadTimeout) }
            ?? .init(seconds: threadTimeout, source: .thread)
        do {
            return try await runner.run(
                arguments.command, in: arguments.workingDirectory, requested: requested,
                outsideSandbox: arguments.outsideSandbox == true
            ).rendered
        } catch {
            return ToolOutput.error(error)
        }
    }
}
