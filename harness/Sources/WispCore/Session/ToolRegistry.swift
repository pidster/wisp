import FoundationModels

/// The set of tools `wisp` exposes to the model, keyed by name.
public struct ToolRegistry: Sendable {
    /// All tools available in this build, in registration order, each wrapped by `AuditedTool`.
    public let all: [any WispTool]

    /// The built-in tools' names, in registration order; `tools.disabled` may name only these, and a
    /// custom tool may not take one.
    public static let builtInNames = [
        "current_date", "run_command", "read_file", "edit_file", "inspect", "notify", "system_info", "memory",
        "models", "ask",
    ]

    /// Builds the registry with the given limits for command execution and file pages.
    ///
    /// Every tool is wrapped so its calls and results are recorded; without an audit log the wrapper
    /// records to a log that discards everything, so there is one list and one code path. With an
    /// approval gate, `run_command`, `read_file`, and `edit_file` classify and ask before acting. Every tool
    /// bounds its result to the one `budget` (ADR 0050), and what does not fit goes to `store`.
    ///
    /// - Parameters:
    ///   - runner: Limits and policy for `run_command`, whose writable set also confines `edit_file`.
    ///   - reader: Page limits for `read_file`; its page is the budget when one is given.
    ///   - audit: Where tool calls are recorded; nil records nothing.
    ///   - approval: The gate risky tools consult; nil never asks.
    ///   - introspection: What `inspect` shows; the default sees the default home and config.
    ///   - host: The face's effects; `notify` posts through it. Nil gives one with only the process routes
    ///     and a notifier of its own.
    ///   - memory: The conversation's record, which `memory` reads and where its notes wait (`WispThread` passes
    ///     its own). Nil gives one with nothing published, whose `memory` says there is no record: enough for a
    ///     catalogue.
    ///   - models: The conversation's `models` tool, over its actions, gate, and audit session (ADR 0059). Nil gives
    ///     one that answers that models cannot be managed here: enough for a catalogue.
    ///   - ask: The conversation's `ask` tool, over the face's asker and the thread's inquiry state (ADR 0062). Nil
    ///     gives one nobody answers: enough for a catalogue.
    ///   - budget: The conversation's tool-output budget, shared with its agent, which sets the window on it.
    ///   - store: The conversation's output store; nil keeps nothing past the budget, and results say so.
    ///   - condenser: What answers `memory`'s `condense` question over a stored output; nil leaves the verb to
    ///     the exact summary alone.
    ///   - disabled: Built-in tools to leave out (`tools.disabled`).
    ///   - custom: The user's own tools (`tools.custom`), appended after the built-ins; each runs through
    ///     `run_command`'s runner and gate.
    public init(
        runner: CommandRunner.Options = CommandRunner.Options(), reader: FileReader = FileReader(),
        audit: AuditLog? = nil, approval: ApprovalGate? = nil,
        introspection: Introspection = Introspection(home: Home.resolve(), config: Config().resolved),
        host: SessionHost? = nil, memory: MemorySource? = nil, models: ModelsTool? = nil, ask: AskTool? = nil,
        budget: ToolBudget = ToolBudget(), store: OutputStore? = nil, condenser: OutputCondenser? = nil,
        disabled: Set<String> = [],
        custom: [CustomTool.Definition] = []
    ) {
        let audit = audit ?? .disabled(session: "unaudited")
        let ledger = CallLedger()
        let commandRunner = CommandRunner(
            options: runner, audit: audit, approval: approval, budget: budget, store: store)
        var reader = reader
        reader.budget = budget
        let builtIns: [any WispTool] = [
            AuditedTool(CurrentDateTool(), audit: audit, ledger: ledger),
            AuditedTool(RunCommandTool(runner: commandRunner), audit: audit, ledger: ledger),
            AuditedTool(ReadFileTool(reader: reader, approval: approval), audit: audit, ledger: ledger),
            AuditedTool(
                EditFileTool(writer: FileWriter(options: runner), approval: approval, audit: audit), audit: audit,
                ledger: ledger),
            AuditedTool(
                InspectTool(introspection: introspection, budget: budget, store: store), audit: audit, ledger: ledger),
            AuditedTool(
                NotifyTool(
                    host: host ?? SessionHost(approver: DenyingApprover(reason: "no host"), notifier: Notifier()),
                    audit: audit), audit: audit, ledger: ledger),
            AuditedTool(
                SystemInfoTool(runner: commandRunner, budget: budget, store: store), audit: audit, ledger: ledger),
            AuditedTool(
                MemoryTool(
                    source: memory ?? MemorySource(), audit: audit, budget: budget, store: store, condenser: condenser),
                audit: audit, ledger: ledger),
            AuditedTool(models ?? ModelsTool(), audit: audit, ledger: ledger),
            AuditedTool(ask ?? AskTool(), audit: audit, ledger: ledger),
        ]
        // Definitions are validated when the config loads, so building one fails only if the framework
        // rejects its schema; such a tool is left out with a diagnostic rather than failing the session.
        let customs: [any WispTool] = custom.compactMap { definition in
            do {
                return AuditedTool(try CustomTool(definition, runner: commandRunner), audit: audit, ledger: ledger)
            } catch {
                Diagnostics.tools.error("custom tool \(definition.name) left out: \(error)")
                return nil
            }
        }
        all = builtIns.filter { !disabled.contains($0.name) } + customs
    }

    /// The names a conversation given every tool gets: the whole registry, less `memory` unless `memory` is true
    /// (`context.memory`, off by default since [ADR 0057](../../../../docs/decisions/0057-context-defaults-from-checkpoint-2.md)),
    /// less `models` unless `models` is true (`tools.models`, off by default,
    /// [ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)), and less `ask` unless `ask` is true
    /// (`tools.ask`, off by default, [ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md)). All three stay
    /// registered, so a list that names one still selects it.
    ///
    /// - Parameters:
    ///   - memory: Whether `memory` is in the default set.
    ///   - models: Whether `models` is in the default set.
    ///   - ask: Whether `ask` is in the default set.
    /// - Returns: The names, in registration order.
    func defaultNames(memory: Bool, models: Bool = false, ask: Bool = false) -> [String] {
        all.map(\.name).filter {
            (memory || $0 != MemoryTool.toolName) && (models || $0 != ModelsTool.toolName)
                && (ask || $0 != AskTool.toolName)
        }
    }

    /// Tools whose names appear in `names`; unknown names are reported back.
    public func select(_ names: [String]) -> (tools: [any WispTool], unknown: [String]) {
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        var tools: [any WispTool] = []
        var unknown: [String] = []
        for name in names {
            if let tool = byName[name] { tools.append(tool) } else { unknown.append(name) }
        }
        return (tools, unknown)
    }
}
