import Foundation
import FoundationModels

/// Lets the model answer questions about this Mac, such as what is using a port, what fills the disk, or
/// which process is busy, through fixed read-only commands wisp chooses and parses. They run under the
/// policy and sandbox but not the approval gate, since the model supplies no command, only a topic and a
/// validated port, process, or folder ([ADR 0034](../../../../docs/decisions/0034-system-info.md)).
public struct SystemInfoTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "system_info"
    /// What the model is told this tool does.
    public let description =
        "Reports on this Mac, read-only: listening ports, disk space, what uses disk in a folder, the user's "
        + "busiest processes, memory, one process, battery, macOS and hardware, network. Use it instead of shell "
        + "commands for these; ps and top cannot run in the sandbox."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// What to report.
        @Guide(description: "What to report.")
        public var topic: SystemTopic
        /// The port for `ports`.
        @Guide(description: "For ports: the port number asked about, such as 8080.")
        public var port: Int?
        /// The process for `process`; empty for other topics. Required rather than optional because the
        /// model left an optional name out of "Is Ollama running?" and then fell back to `ps`.
        @Guide(
            description: "For process: the app or process name from the question, such as Safari, or its id. "
                + "Otherwise empty.")
        public var process: String
        /// The folder for `folderSizes`.
        @Guide(description: "For folderSizes: the folder to measure, such as ~/Library. Default: home.")
        public var path: String?
    }

    private let info: SystemInfo
    /// The bound on a report.
    private let budget: ToolBudget
    /// Where a report past the bound is kept whole; nil keeps nothing.
    private let store: OutputStore?

    /// Bounds.
    public var limits: String {
        "At most \(SystemInfo.maxRows) rows per table and the tool-output budget (\(budget.bytes) bytes now); your "
            + "processes only for ports."
    }
    /// How to ask for it.
    public let examplePrompt = "Use system_info with topic ports and port 8080 to say what is using port 8080."

    /// Creates the tool over a runner.
    ///
    /// - Parameters:
    ///   - runner: Runs the fixed commands under the policy and sandbox; its approval gate, if any, is not
    ///     consulted, and its probes are read whole (up to 1 MiB) in process, not through the output store.
    ///   - budget: The conversation's tool-output budget, which bounds the report.
    ///   - store: The conversation's output store, where a report past the budget is kept.
    public init(runner: CommandRunner, budget: ToolBudget = ToolBudget(), store: OutputStore? = nil) {
        var configured = runner
        configured.approval = nil
        configured.store = nil
        configured.options.maxOutputBytes = 1 << 20
        // du over a large folder takes longer than a typical command; allow half a minute.
        configured.options.timeout = max(configured.options.timeout, .seconds(30))
        let runner = configured
        let probe: SystemInfo.Probe = { line in
            let outcome = try await runner.run(line)
            return (outcome.stdout, outcome.exitStatus, outcome.timedOut)
        }
        self.init(info: SystemInfo(probe: probe), budget: budget, store: store)
    }

    /// Creates the tool over a reporter, for tests.
    init(info: SystemInfo, budget: ToolBudget = ToolBudget(), store: OutputStore? = nil) {
        self.info = info
        self.budget = budget
        self.store = store
    }

    /// Reports the topic.
    ///
    /// - Parameter arguments: Topic, and a target or path where the topic takes one.
    /// - Returns: A short report, or `error: …` saying what was wrong.
    public func call(arguments: Arguments) async -> String {
        do {
            let named = arguments.process.trimmingCharacters(in: .whitespaces)
            let target = arguments.topic == .ports ? arguments.port.map(String.init) : named.isEmpty ? nil : named
            return ToolOutput.fitted(
                try await info.report(arguments.topic, target: target, path: arguments.path), tool: name,
                budget: budget,
                store: store)
        } catch {
            return "error: \(error)"
        }
    }
}
