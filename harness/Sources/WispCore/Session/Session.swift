import Foundation
import FoundationModels

/// Everything an entry point needs before it creates an `Agent`, built the same way for
/// `respond`, `chat`, and `mcp` so their behaviour and audit records cannot drift.
///
/// A session owns what every conversation shares: the resolved config, the audit log, the
/// approval store, the "this session" approvals, and the risk classifier. A face adds its own
/// approver when it opens a conversation, because how a human is asked is the one thing that
/// differs between the terminal and an MCP client.
public struct Session: Sendable {
    /// What the entry point asked for, from flags and arguments.
    public struct Request: Sendable, Equatable {
        /// Which face this is, recorded in the audit log and on standing approvals.
        public var entryPoint: EntryPoint
        /// The conversation's own instructions (layer 3 of `Prompting`); nil means none.
        public var instructions: String?
        /// Model override; nil takes `config.json`'s.
        public var model: ModelSelection?
        /// Which tools to enable.
        public var tools: ToolSelection
        /// Disable the command policy and sandbox.
        public var unsafe: Bool
        /// Approve risky commands without asking.
        public var autoApprove: Bool
        /// Transcript being resumed, for the audit record.
        public var resume: String?
        /// The sessions the resumed transcript's store refers to (`ThreadRecord.Snapshot.sessions`),
        /// recorded on `session.start` as `carriedFrom`; empty when nothing was linked.
        public var carriedFrom: [String]

        /// Creates a request.
        public init(
            entryPoint: EntryPoint, instructions: String? = nil, model: ModelSelection? = nil,
            tools: ToolSelection = .all,
            unsafe: Bool = false, autoApprove: Bool = false, resume: String? = nil, carriedFrom: [String] = []
        ) {
            self.entryPoint = entryPoint
            self.instructions = instructions
            self.model = model
            self.tools = tools
            self.unsafe = unsafe
            self.autoApprove = autoApprove
            self.resume = resume
            self.carriedFrom = carriedFrom
        }
    }

    /// The behaviour a session constructs from its configuration, injectable so tests never
    /// touch the model or the file system.
    public struct Dependencies: Sendable {
        /// Builds the risk classifier the configuration calls for; `home` locates a model under it.
        public var makeClassifier: @Sendable (Config.Resolved, Home) -> any RiskClassifier
        /// Builds the audit sink; called only when the audit log is enabled.
        public var makeSink: @Sendable (Home, Config.Resolved) throws -> any AuditSink
        /// Runs `osascript` for the notifier's app and `osascript` routes.
        public var notify: Notifier.Runner

        /// Creates dependencies.
        public init(
            makeClassifier: @escaping @Sendable (Config.Resolved, Home) -> any RiskClassifier,
            makeSink: @escaping @Sendable (Home, Config.Resolved) throws -> any AuditSink,
            notify: @escaping Notifier.Runner = Notifier.osascript
        ) {
            self.makeClassifier = makeClassifier
            self.makeSink = makeSink
            self.notify = notify
        }

        /// The real thing: the classifier `approval.classifier` names beside the rules (the rules alone, the
        /// on-device model, or a Core ML version), and the audit file under the home directory, which is
        /// created on demand.
        public static let live = Dependencies(
            makeClassifier: { config, home in
                switch config.approvalClassifier {
                case .rules: RuleRiskClassifier.standard
                case .systemModel: CompositeRiskClassifier([RuleRiskClassifier.standard, ModelRiskClassifier()])
                case .coreml:
                    CompositeRiskClassifier([
                        RuleRiskClassifier.standard,
                        CoreMLRiskClassifier(
                            url: Session.coremlModelURL(config: config, home: home),
                            minimumConfidence: config.coremlMinimumConfidence),
                    ])
                }
            },
            makeSink: { home, config in
                try home.ensure()
                return try FileAuditSink(url: home.auditFile, limits: config.auditLimits)
            })

        /// Rules-only classification and the given sink, for tests: no model, no audit file, and notifications
        /// that report success without posting anything.
        public static func testing(sink: any AuditSink = MemoryAuditSink()) -> Dependencies {
            Dependencies(
                makeClassifier: { _, _ in RuleRiskClassifier.standard }, makeSink: { _, _ in sink }, notify: { _ in 0 })
        }
    }

    /// Why a session could not be set up.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// What is wrong with `config.json`.
        public enum ConfigProblem: Equatable, Sendable {
            /// The JSON does not decode, including an unknown `approval.threshold` value.
            case invalidJSON(String)
            /// A `run_command` policy pattern does not compile.
            case invalidPolicy(CommandPolicy.Failure)
            /// A `tools` entry is not usable.
            case invalidTool(CustomTool.Failure)
            /// The file exists but cannot be read.
            case unreadable(String)
            /// The models it names do not agree, such as a default it also disables (ADR 0056).
            case invalidModels(ModelSelection.Failure)

            /// Human-readable explanation.
            public var description: String {
                switch self {
                case .invalidJSON(let detail): detail
                case .invalidPolicy(let failure): failure.description
                case .invalidTool(let failure): failure.description
                case .unreadable(let detail): detail
                case .invalidModels(let failure): failure.description
                }
            }
        }

        /// `config.json` exists but cannot be used.
        case malformedConfig(path: String, problem: ConfigProblem)
        /// `--tool` names not in the registry.
        case unknownTools([String])

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .malformedConfig(let path, let problem): "malformed \(path): \(problem.description)"
            case .unknownTools(let names): "unknown tool(s): \(names.joined(separator: ", "))"
            }
        }
    }

    /// What the entry point asked for.
    public let request: Request
    /// Where config, logs, and approvals live.
    public let home: Home
    /// The resolved configuration with overrides applied.
    public let config: Config.Resolved
    /// The session's audit log; `end()` closes it.
    public let audit: AuditLog
    /// Standing approvals shared by every conversation of this session.
    public let store: ApprovalStore
    /// "This session" approvals shared by every conversation of this session.
    public let sessionApprovals: SessionApprovals
    /// Warnings for the face to show the user on stderr, such as `--unsafe` or an off-device model.
    public let notes: [String]
    /// Names of the tools the session's conversations get by default; never empty.
    public let toolNames: [String]
    /// The classifier every conversation's gate uses.
    let classifier: any RiskClassifier
    /// Bounds and rate-limits notifications for every conversation, so the limit covers them all; each
    /// face's `SessionHost` posts through it by its own routes.
    public let notifier: Notifier
    /// The recent model turns and classifier calls of every conversation of this session, for `/stats`.
    public let stats: CallStats
    /// The session's ephemeral facts, shared by every conversation of it (decision D2).
    public let sessionFacts = SharedFacts.session()
    /// The shared store of permanent facts under the home directory, which only the person admits facts to.
    public let permanentFacts: SharedFacts
    /// The permanent facts proposed in every conversation of this session, awaiting the person's decision.
    public let factProposals = FactProposals()
    /// The models turned off, as the configuration had them and as this session's chat has changed them since
    /// (ADR 0056); every conversation of the session refuses them.
    public let disabledModels: DisabledModels
    /// The capabilities this session's checks recorded (ADR 0056, refined 2026-10-04); every conversation of the
    /// session resolves its model with them, so a model a check made usable can be chosen at once.
    public let declaredModels = DeclaredModels()

    /// Which face this session is.
    public var entryPoint: EntryPoint { request.entryPoint }

    /// Read-only views of this session's config, approvals, and audit log, with the session's own status.
    public var introspection: Introspection {
        introspection(for: audit, tools: toolNames, model: config.model)
    }

    /// Views for one thread of this session.
    func introspection(for audit: AuditLog, tools: [String], model: ModelSelection) -> Introspection {
        let sessionApprovals = sessionApprovals
        let entryPoint = entryPoint
        return Introspection(
            home: home, config: config, store: store,
            status: {
                [
                    "session": .string(audit.session), "entryPoint": .string(entryPoint.rawValue),
                    "turn": .int(audit.currentTurn), "model": .string(model.description),
                    "tools": .array(tools.map { .string($0) }),
                    "sessionApprovals": .int(sessionApprovals.count),
                    "auditFile": .string(home.auditFile.path), "version": .string(WispVersion.current),
                ]
            })
    }
    /// The layers of what the model is told, for the session's own conversation.
    public var prompting: Prompting {
        Prompting(systemPromptExtension: config.systemPromptExtension, instructions: request.instructions)
    }

    /// Reads `config.json` under `home`, mapping every failure to `Failure.malformedConfig`.
    ///
    /// - Throws: `Failure.malformedConfig`.
    public static func loadConfig(home: Home) throws -> Config.Resolved {
        do {
            return try Config.load(from: home.configFile).resolved
        } catch let failure as CommandPolicy.Failure {
            throw Failure.malformedConfig(path: home.configFile.path, problem: .invalidPolicy(failure))
        } catch let failure as CustomTool.Failure {
            throw Failure.malformedConfig(path: home.configFile.path, problem: .invalidTool(failure))
        } catch let failure as ModelSelection.Failure {
            throw Failure.malformedConfig(path: home.configFile.path, problem: .invalidModels(failure))
        } catch let error as DecodingError {
            throw Failure.malformedConfig(path: home.configFile.path, problem: .invalidJSON(Self.describe(error)))
        } catch {
            throw Failure.malformedConfig(path: home.configFile.path, problem: .unreadable("\(error)"))
        }
    }

    /// The decoder's own explanation, without the wrapping the framework adds.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context),
            .valueNotFound(_, let context):
            context.codingPath.isEmpty
                ? context.debugDescription
                : "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        @unknown default: "\(error)"
        }
    }

    /// Loads config, applies the request's overrides, opens the audit log and the approval store,
    /// checks the tool selection, and records `session.start`.
    ///
    /// - Parameters:
    ///   - request: Flags and arguments from the entry point.
    ///   - home: Where config, logs, and approvals live.
    ///   - dependencies: What the session builds from its config; tests pass `.testing()`.
    /// - Returns: The ready session; call `end()` when the entry point finishes.
    /// - Throws: `Failure`, `ModelSelection.Failure.disabled` for a `--model` the operator disabled, or whatever
    ///   `dependencies.makeSink` throws.
    public static func begin(_ request: Request, home: Home, dependencies: Dependencies = .live) throws -> Session {
        var config = try loadConfig(home: home)
        var notes: [String] = []
        if let model = request.model {
            if model.isAmong(config.disabledModels, config: config, home: home) {
                throw ModelSelection.Failure.disabled(model: model.description)
            }
            config.model = model
        }
        if request.unsafe {
            config.runner.policy = .unrestricted
            notes.append("warning: --unsafe: run_command policy and sandbox are off")
        }
        if config.model.leavesDevice {
            notes.append(
                "note: model \(config.model) runs on Apple's Private Cloud Compute; prompts and tool output leave this Mac"
            )
        }
        let toolNames = try Self.resolve(request.tools, config: config)
        let permanentFacts = SharedFacts.permanent(home: home)
        if let aside = permanentFacts.setAside {
            notes.append(
                "warning: \(home.factsFile.path) could not be read; it was moved to \(aside.path) and wisp starts with "
                    + "no permanent facts")
        }
        let sessionID = ShortID.make()
        let sink: any AuditSink = config.auditEnabled ? try dependencies.makeSink(home, config) : NullAuditSink()
        let audit = AuditLog(session: sessionID, sink: sink)
        let stats = CallStats()
        let classifier = dependencies.makeClassifier(config, home)
        audit.record(
            .sessionStart,
            details: AuditEvent.Details.sessionStart(
                entryPoint: request.entryPoint,
                prompting: Prompting(
                    systemPromptExtension: config.systemPromptExtension, instructions: request.instructions),
                tools: toolNames, model: config.model, unsafe: request.unsafe, autoApprove: request.autoApprove,
                resume: request.resume, carriedFrom: request.carriedFrom))
        return Session(
            request: request, home: home, config: config, audit: audit,
            store: ApprovalStore(url: home.approvalsFile, lifetime: config.approvalLifetime),
            sessionApprovals: SessionApprovals(), notes: notes, toolNames: toolNames,
            // The rules answer in microseconds; only a configuration with a model classifier is timed, and
            // cached so a command line the session has judged is not judged again.
            classifier: config.approvalClassifier == .rules
                ? classifier
                : CachingRiskClassifier(
                    TimedRiskClassifier(classifier, name: config.approvalClassifier.rawValue, stats: stats)),
            notifier: Notifier(
                enabled: config.notificationsEnabled, perMinute: config.notificationsPerMinute,
                run: dependencies.notify),
            stats: stats, permanentFacts: permanentFacts,
            disabledModels: DisabledModels(config.disabledModels, config: config, home: home))
    }

    /// Where `approval.coremlModel` points: `risk@<version>` in the classifier store, absolute or `~`
    /// as given, anything else under `<home>/models/coreml`. When it is not set, the default this build
    /// ships, installed into the store on first use; nil when there is none.
    public static func coremlModelURL(config: Config.Resolved, home: Home) -> URL? {
        let store = ClassifierStore(home: home)
        guard let configured = config.coremlModel else {
            return (try? store.installDefault()).flatMap { $0 }.map(store.model)
        }
        if let version = ClassifierStore.version(of: configured) {
            if version == ClassifierStore.defaultVersion() { _ = try? store.installDefault() }
            return store.model(version)
        }
        if configured.hasPrefix("/") || configured.hasPrefix("~") {
            return URL(filePath: (configured as NSString).expandingTildeInPath)
        }
        return home.models.appending(path: "coreml").appending(path: configured)
    }

    /// The whole registry for `.all` (without `memory` unless `context.memory` is on), or the names as given once
    /// each is known.
    ///
    /// - Throws: `Failure.unknownTools`.
    private static func resolve(_ selection: ToolSelection, config: Config.Resolved) throws -> [String] {
        let registry = ToolRegistry(
            runner: config.runner, disabled: config.disabledTools, custom: config.customTools)
        let names = selection.resolved(or: registry.defaultNames(memory: config.contextMemory))
        let unknown = registry.select(names).unknown
        guard unknown.isEmpty else { throw Failure.unknownTools(unknown) }
        return names
    }

    /// The host for a face of this session: its approver, the session's notifier, and the face's
    /// notification routes with `notifications.viaTerminalApp` from the config. Every face builds one
    /// (ADR 0044).
    ///
    /// - Parameters:
    ///   - approver: How the face asks a human.
    ///   - face: Which face, for the notification routes; `.headless` has only the process routes.
    ///   - only: A single notification route, for `wisp notify --route`.
    /// - Returns: The host.
    public func host(
        approver: any Approver, face: NotificationRoutes.Face = .headless, only: NotificationRoute? = nil
    ) -> SessionHost {
        SessionHost(
            approver: approver, notifier: notifier,
            notifications: NotificationRoutes(
                face: face, viaTerminalApp: config.notificationsViaTerminalApp, only: only))
    }

    /// The approver for `wisp mcp` (ADR 0046): with `approval.outOfBand` on, a waiting command is filed in the
    /// home's `pending/` channel for `wisp approvals` and `wisp-tui`, announced by a notification through the
    /// MCP face's routes, and asked through `elicitation` too when the client has it, the first answer winning;
    /// with it off, `elicitation` alone, or `fallback` when the client has none.
    ///
    /// - Parameters:
    ///   - elicitation: The client's dialog now, or nil when it has none.
    ///   - fallback: What decides when nothing can ask: a denial that says why.
    ///   - client: The client's name.
    /// - Returns: The approver.
    public func mcpApprover(
        elicitation: @escaping @Sendable () -> OutOfBandApprover.Ask?, fallback: any Approver,
        client: @escaping @Sendable () -> String? = { nil }
    ) -> any Approver {
        guard config.approvalOutOfBand else { return ElicitationOnly(ask: elicitation, fallback: fallback) }
        let host = host(approver: fallback, face: .mcp)
        return OutOfBandApprover(
            channel: PendingApprovals(home: home), timeout: config.approvalTimeout, alongside: elicitation,
            client: client,
            notify: { message, audit in host.notify(message, source: .approval, audit: audit) })
    }

    /// Opens the session's own conversation over a headless host with `approver`; for tests and callers
    /// with no screen of their own.
    func openAgent(
        approver: any Approver, transcript: Transcript? = nil, links: ThreadRecord.Snapshot? = nil,
        store: ThreadRecord? = nil, observer: (any AuditSink)? = nil, model: ModelSelection? = nil
    ) throws -> Agent {
        try openAgent(
            host: host(approver: approver), transcript: transcript, links: links, store: store, observer: observer,
            model: model)
    }

    /// Sets up a further conversation over a headless host with `approver`; for tests.
    func thread(
        id: String, approver: any Approver, instructions: String? = nil, tools: ToolSelection = .all,
        model: ModelSelection? = nil
    ) throws -> WispThread {
        try thread(id: id, host: host(approver: approver), instructions: instructions, tools: tools, model: model)
    }

    /// Opens the session's own conversation: `respond` and `chat` call this once.
    ///
    /// - Parameters:
    ///   - host: The face's effects: how it asks a human (its approver is replaced by `AutoApprover` when the
    ///     request said `--yes`) and how it posts a notification.
    ///   - transcript: A saved conversation to resume, or nil to start fresh.
    ///   - links: The store links saved with `transcript` (`TranscriptStore.Saved.links`), if any.
    ///   - store: The store of an agent being replaced, which the new agent continues; chat's `/model`
    ///     passes it. Takes precedence over `transcript`.
    ///   - observer: A sink that also sees every event of this conversation as it is recorded; chat
    ///     shows tool activity through it.
    ///   - model: A model other than the configured one; chat's `/model` switches this way.
    /// - Returns: The agent over the session's tools, recording to the session's audit log.
    /// - Throws: `ModelSelection.Failure` if the model cannot be used.
    public func openAgent(
        host: SessionHost, transcript: Transcript? = nil, links: ThreadRecord.Snapshot? = nil,
        store: ThreadRecord? = nil, observer: (any AuditSink)? = nil, model: ModelSelection? = nil
    ) throws -> Agent {
        let thread = try WispThread.setUp(
            session: self, audit: audit, host: host, prompting: prompting, toolNames: toolNames,
            model: model ?? config.model, observer: observer)
        return try thread.openAgent(transcript: transcript, links: links, store: store)
    }

    /// Sets up a further conversation with its own audit session, gate, and tools, sharing the
    /// session's store and session approvals, and records its `session.start`. Needs no model;
    /// `WispThread.openAgent` adds the agent. The MCP server calls this per `thread_id`.
    ///
    /// - Parameters:
    ///   - id: The conversation's id; its audit events carry it as the session.
    ///   - host: The face's effects; its approver is replaced by `AutoApprover` when the request said `--yes`.
    ///   - instructions: The thread's own instructions (layer 3); nil takes the session's.
    ///   - tools: Tool selection; `.all` takes the session's.
    ///   - model: Model override; nil takes the session's.
    /// - Returns: The conversation, ready to open.
    /// - Throws: `Failure.unknownTools`.
    public func thread(
        id: String, host: SessionHost, instructions: String? = nil, tools: ToolSelection = .all,
        model: ModelSelection? = nil
    ) throws -> WispThread {
        let audit = self.audit.log(forSession: id)
        var prompting = self.prompting
        if let instructions { prompting.instructions = instructions }
        let thread = try WispThread.setUp(
            session: self, audit: audit, host: host, prompting: prompting,
            toolNames: tools.resolved(or: toolNames), model: model ?? config.model)
        audit.record(
            .sessionStart,
            details: AuditEvent.Details.sessionStart(
                entryPoint: entryPoint.thread, prompting: thread.prompting,
                tools: thread.tools.map(\.name), model: thread.model, unsafe: request.unsafe,
                autoApprove: request.autoApprove, resume: nil, parent: self.audit.session))
        return thread
    }

    /// Records `session.end`.
    public func end() {
        audit.record(.sessionEnd)
    }
}
