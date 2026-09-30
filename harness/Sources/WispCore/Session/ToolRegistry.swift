import FoundationModels

/// The set of tools `wisp` exposes to the model, keyed by name.
public struct ToolRegistry: Sendable {
    /// All tools available in this build, in registration order, each wrapped by `AuditedTool`.
    public let all: [any WispTool]

    /// The built-in tools' names, in registration order; `tools.disabled` may name only these, and a
    /// custom tool may not take one.
    public static let builtInNames = [
        "current_date", "run_command", "read_file", "edit_file", "inspect", "notify", "system_info", "memory",
    ]

    /// Builds the registry with the given limits for command execution and file pages.
    ///
    /// Every tool is wrapped so its calls and results are recorded; without an audit log the wrapper
    /// records to a log that discards everything, so there is one list and one code path. With an
    /// approval gate, `run_command`, `read_file`, and `edit_file` classify and ask before acting.
    ///
    /// - Parameters:
    ///   - runner: Limits and policy for `run_command`, whose writable set also confines `edit_file`.
    ///   - reader: Page limits for `read_file`.
    ///   - audit: Where tool calls are recorded; nil records nothing.
    ///   - approval: The gate risky tools consult; nil never asks.
    ///   - introspection: What `inspect` shows; the default sees the default home and config.
    ///   - host: The face's effects; `notify` posts through it. Nil gives one with only the process routes
    ///     and a notifier of its own.
    ///   - memory: The conversation's record, which `memory` reads and where its notes wait (`WispThread` passes
    ///     its own). Nil gives one with nothing published, whose `memory` says there is no record: enough for a
    ///     catalogue.
    ///   - disabled: Built-in tools to leave out (`tools.disabled`).
    ///   - custom: The user's own tools (`tools.custom`), appended after the built-ins; each runs through
    ///     `run_command`'s runner and gate.
    public init(
        runner: CommandRunner.Options = CommandRunner.Options(), reader: FileReader = FileReader(),
        audit: AuditLog? = nil, approval: ApprovalGate? = nil,
        introspection: Introspection = Introspection(home: Home.resolve(), config: Config().resolved),
        host: SessionHost? = nil, memory: MemorySource? = nil, disabled: Set<String> = [],
        custom: [CustomTool.Definition] = []
    ) {
        let audit = audit ?? .disabled(session: "unaudited")
        let commandRunner = CommandRunner(options: runner, audit: audit, approval: approval)
        let builtIns: [any WispTool] = [
            AuditedTool(CurrentDateTool(), audit: audit),
            AuditedTool(RunCommandTool(runner: commandRunner), audit: audit),
            AuditedTool(ReadFileTool(reader: reader, approval: approval), audit: audit),
            AuditedTool(
                EditFileTool(writer: FileWriter(options: runner), approval: approval, audit: audit), audit: audit),
            AuditedTool(InspectTool(introspection: introspection), audit: audit),
            AuditedTool(
                NotifyTool(
                    host: host ?? SessionHost(approver: DenyingApprover(reason: "no host"), notifier: Notifier()),
                    audit: audit), audit: audit),
            AuditedTool(SystemInfoTool(runner: commandRunner), audit: audit),
            AuditedTool(MemoryTool(source: memory ?? MemorySource(), audit: audit), audit: audit),
        ]
        // Definitions are validated when the config loads, so building one fails only if the framework
        // rejects its schema; such a tool is left out with a diagnostic rather than failing the session.
        let customs: [any WispTool] = custom.compactMap { definition in
            do {
                return AuditedTool(try CustomTool(definition, runner: commandRunner), audit: audit)
            } catch {
                Diagnostics.tools.error("custom tool \(definition.name) left out: \(error)")
                return nil
            }
        }
        all = builtIns.filter { !disabled.contains($0.name) } + customs
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
