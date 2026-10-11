import Foundation
import FoundationModels

/// Lets the model run a shell command on this machine.
///
/// The command passes the `CommandPolicy`, the approval gate, and runs under
/// the Seatbelt sandbox rooted at the harness's launch directory; a
/// model-chosen working directory changes where it runs, never what it may write.
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
    }

    /// Supplies the policy, timeout, and output cap.
    private let runner: CommandRunner

    /// Sandbox, timeout, output cap, and approval, from the runner's live options.
    public var limits: String {
        let seconds = runner.options.timeout.components.seconds
        let confinement =
            runner.options.policy.sandbox.enabled
            ? "in a Seatbelt sandbox rooted at wisp's launch directory; writes elsewhere fail"
            : "with no sandbox (policy.sandbox.enabled is false)"
        let bound =
            runner.options.maxOutputBytes.map { "\($0) bytes (commandMaxOutputBytes)" }
            ?? "the tool-output budget, \(runner.bound) bytes now (an eighth of the model's window, 4 to 64 KiB)"
        return
            "POSIX shell via /bin/sh -c \(confinement). Timeout \(seconds) s. The result is bounded as a whole to "
            + "\(bound): past that the first and last lines are shown, the rest is held back and kept whole in the "
            + "conversation's output store, and the result says how to page, filter, or summarise it. Commands pass "
            + "a deny/allow policy and a risk classifier; moderate and dangerous ones need the user's approval."
    }
    /// How to ask for it.
    public let examplePrompt =
        "Use run_command with working directory /path/to/repo to run exactly: swift test 2>&1 | tail -3 . "
        + "Report the exit status and output verbatim, nothing else."

    /// Creates the tool over a runner that supplies timeout and output limits.
    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    /// Runs the command and returns a compact rendering of its outcome.
    ///
    /// A policy denial or a bad working directory is returned as text rather
    /// than thrown, so the model sees why and can choose another approach
    /// instead of the whole response failing.
    ///
    /// - Parameter arguments: The command and optional working directory.
    /// - Returns: Exit status and bounded stdout/stderr, formatted for the model.
    public func call(arguments: Arguments) async -> String {
        do {
            return try await runner.run(arguments.command, in: arguments.workingDirectory).rendered
        } catch {
            return ToolOutput.error(error)
        }
    }
}
