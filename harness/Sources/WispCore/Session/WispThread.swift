import Foundation
import FoundationModels

/// One thread's tools and approval gate, built the same way for every face of wisp.
public struct WispThread: Sendable {
    /// The gate every tool in this conversation consults.
    public let gate: ApprovalGate
    /// The tools the model may use.
    public let tools: [any Tool]
    /// The log the conversation's turns and tool calls are recorded to.
    public let audit: AuditLog
    /// The same events, kept briefly so each turn's `Receipt` can be built for the caller.
    public let receipts: ReceiptCollector
    /// The same events again, as they happen, for a caller that wants progress while a call runs.
    public let relay: EventRelay
    /// The three layers the agent starts with; `Prompting.rendered` is what the model sees.
    public let prompting: Prompting
    /// The model the agent runs on.
    public let model: ModelSelection
    /// The effective configuration, which local backends read their settings from.
    let config: Config.Resolved
    /// wisp's home, for backends that keep assets under it.
    let home: Home
    /// The models the operator turned off, which the thread refuses to open on (ADR 0056).
    let disabled: DisabledModels
    /// The capabilities the session's checks recorded since it began, applied to `config` when a model resolves.
    let declared: DeclaredModels
    /// Where the agent records its turns: the session's store.
    let stats: CallStats
    /// The conversation's tool events, which the agent links its store's tool entries to.
    let toolEvents: ToolEventTrail
    /// The facts the agent keeps, from the session's; nil when `facts.enabled` is false.
    let facts: FactSettings?
    /// What the thread's `memory` tool reads and writes, which its agent publishes; nil when the thread has no
    /// `memory`. A thread has it when it was given every tool, or a list that names it: an explicit list is exactly
    /// that list, so MCP's `tools: ["run_command"]` stays `run_command` alone.
    let memory: MemorySource?
    /// Whether an assessment may infer the task (decision D6): in chat; over MCP the caller's `task` is the task.
    let infersTask: Bool
    /// The runner `run_command` uses, with this thread's audit and gate; the agent runs the person's typed
    /// commands through it (ADR 0049).
    let runner: CommandRunner

    /// Builds the gate and the tool registry for one thread of `session`, over the face's `host`: the gate
    /// asks its approver, and `notify` posts through it.
    ///
    /// - Throws: `Session.Failure.unknownTools` for names not in the registry.
    static func setUp(
        session: Session, audit: AuditLog, host: SessionHost, prompting: Prompting, toolNames: [String],
        model: ModelSelection, observer: (any AuditSink)? = nil
    ) throws -> WispThread {
        let receipts = ReceiptCollector()
        let relay = EventRelay()
        let toolEvents = ToolEventTrail()
        var audit = audit.alsoRecording(to: receipts).alsoRecording(to: relay).alsoRecording(to: toolEvents)
        if let observer { audit = audit.alsoRecording(to: observer) }
        let gate = ApprovalGate(
            classifier: session.classifier, approver: session.request.autoApprove ? AutoApprover() : host.approver,
            threshold: session.config.approvalThreshold, audit: audit, store: session.store,
            source: session.entryPoint, sessionApprovals: session.sessionApprovals)
        let memory = MemorySource()
        let registry = ToolRegistry(
            runner: session.config.runner, audit: audit, approval: gate,
            introspection: session.introspection(for: audit, tools: toolNames, model: model),
            host: host, memory: memory, disabled: session.config.disabledTools, custom: session.config.customTools)
        let selection = registry.select(toolNames)
        guard selection.unknown.isEmpty else { throw Session.Failure.unknownTools(selection.unknown) }
        return WispThread(
            gate: gate, tools: selection.tools.map { $0 }, audit: audit, receipts: receipts, relay: relay,
            prompting: prompting,
            model: model, config: session.config, home: session.home, disabled: session.disabledModels,
            declared: session.declaredModels,
            stats: session.stats, toolEvents: toolEvents,
            facts: session.config.factsEnabled
                ? FactSettings(
                    kinds: session.config.subjectKinds, session: session.sessionFacts,
                    permanent: session.permanentFacts, distils: session.config.factsDistil,
                    proposals: session.factProposals)
                : nil,
            memory: selection.tools.contains { $0.name == MemoryTool.toolName } ? memory : nil,
            infersTask: session.entryPoint == .chat,
            runner: CommandRunner(options: session.config.runner, audit: audit, approval: gate))
    }

    /// Resolves the model, refuses a request its declared capabilities cannot serve, records
    /// `model.resolved`, and creates the agent that runs this conversation.
    ///
    /// - Parameters:
    ///   - transcript: A saved conversation to resume, or nil to start from the instructions.
    ///   - links: The store links saved with `transcript`, if any.
    ///   - store: The store of an agent being replaced, which the new agent continues; takes precedence over
    ///     `transcript`.
    ///   - override: A model other than the conversation's, as routing by input size chooses one.
    /// - Returns: The agent, recording to this conversation's audit log and advancing its turn clock.
    /// - Throws: `ModelSelection.Failure` if the model is disabled, cannot be used, or lacks a needed capability.
    public func openAgent(
        transcript: Transcript? = nil, links: ThreadRecord.Snapshot? = nil, store: ThreadRecord? = nil,
        model override: ModelSelection? = nil
    ) throws -> Agent {
        try disabled.check(override ?? model)
        return try openAgent(
            on: try (override ?? model).resolve(config: declared.applied(to: config), home: home),
            transcript: transcript, links: links,
            store: store)
    }

    /// Creates the agent that runs this conversation on an already resolved model: refuses a request its
    /// declared capabilities cannot serve, records `model.resolved`, and sets the agent's stats and archive.
    /// Tests pass a scripted model here to drive the same path the faces take.
    ///
    /// - Parameters:
    ///   - resolved: The model.
    ///   - transcript: A saved conversation to resume, or nil to start from the instructions.
    ///   - links: The store links saved with `transcript`, if any.
    ///   - store: The store of an agent being replaced; takes precedence over `transcript`.
    /// - Returns: The agent, recording to this conversation's audit log and advancing its turn clock.
    /// - Throws: `ModelSelection.Failure` if the model lacks a needed capability.
    func openAgent(
        on resolved: ResolvedModel, transcript: Transcript? = nil, links: ThreadRecord.Snapshot? = nil,
        store: ThreadRecord? = nil
    ) throws -> Agent {
        try resolved.check(tools: tools)
        audit.record(
            .modelResolved,
            details: AuditEvent.Details.modelResolved(
                model: resolved.selection, backend: resolved.selection.backend, asset: resolved.asset,
                capabilities: resolved.capabilityNames, capabilitySource: resolved.capabilitySource,
                tools: tools.map(\.name), contextSize: resolved.contextSize, contextNote: resolved.contextNote))
        let agent =
            if let store {
                Agent(store: store, tools: tools, model: resolved, audit: audit)
            } else if let transcript {
                Agent(transcript: transcript, tools: tools, model: resolved, audit: audit, links: links)
            } else {
                Agent(
                    instructions: prompting.rendered(toolsAvailable: !tools.isEmpty, memory: memory != nil),
                    tools: tools, model: resolved, audit: audit)
            }
        agent.stats = stats
        agent.toolEvents = toolEvents
        agent.commandRunner = runner
        agent.contextPolicy = .target(config.contextTarget)
        agent.factsShare = config.factsShare
        agent.summarises = config.factsSummary
        agent.summaryShare = config.summaryShare
        agent.facts = facts
        agent.memory = memory
        if config.assessmentEnabled {
            agent.assessment = AssessmentSettings(
                tools: config.assessmentTools, infersTask: infersTask, taskChanges: config.assessmentTaskChanges)
        }
        if config.auditEnabled { agent.archive = ContextArchive(directory: home.contexts, session: audit.session) }
        return agent
    }
}
