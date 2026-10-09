import Foundation

/// User configuration read from `Home.configFile`.
///
/// Every field is optional in the file; `resolved` fills in defaults. Unknown
/// keys are ignored so older binaries tolerate newer files.
public struct Config: Codable, Equatable, Sendable {
    /// Text added to wisp's system prompt for every session on this Mac (layer 2 of `Prompting`).
    public var systemPromptExtension: String?
    /// The pre-0.2 name of `systemPromptExtension`; read when the new key is absent, never written.
    public var instructions: String?
    /// Which model sessions run on; nil means `system`.
    public var model: ModelSelection?
    /// Which models are turned off: hidden from `/model` and refused wherever a model is chosen (ADR 0056).
    public var models: ModelsConfig?
    /// Wall-clock limit for `run_command`, in seconds.
    public var commandTimeoutSeconds: Int?
    /// Bytes kept from each of stdout and stderr by `run_command`.
    public var commandMaxOutputBytes: Int?
    /// Live MCP conversation threads kept before eviction.
    public var maxThreads: Int?
    /// The largest tool output an MCP `respond` result carries inline; larger output is a reference.
    public var inlineOutputBytes: Int?
    /// Lines of each tool's output chat shows under its note before folding the rest.
    public var shownOutputLines: Int?
    /// What `run_command` may execute and how it is confined.
    public var commandPolicy: CommandPolicy?
    /// Audit log settings.
    public var audit: AuditConfig?
    /// Risk classification and approval for `run_command`.
    public var approval: ApprovalConfig?
    /// Where a local Ollama serves `ollama:<name>` models.
    public var ollama: OllamaConfig?
    /// Where Core AI bundles for `coreai:<name>` models live.
    public var coreai: CoreAIConfig?
    /// Where MLX model directories for `mlx:<name>` models live, and what each may do.
    public var mlx: MLXConfig?
    /// Notifications from the `notify` tool and `wisp notify`.
    public var notifications: NotificationsConfig?
    /// Which built-in tools to leave out, and the user's own tools.
    public var tools: ToolsConfig?
    /// Choosing a model by input size for the tasks that route.
    public var routing: RoutingConfig?
    /// Facts: whether they are kept, distilled, and composed, and the subject kinds.
    public var facts: FactsConfig?
    /// The assessment of each request: whether it runs, and which tools each request registers.
    public var assessment: AssessmentConfig?
    /// Condensing: the target it condenses to and the headroom it keeps for the next turn.
    public var context: ContextConfig?
    /// `wisp watch`: how long file changes must be quiet before a run starts.
    public var watch: WatchConfig?

    /// The models the operator turned off ([ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md)).
    public struct ModelsConfig: Codable, Equatable, Sendable {
        /// Models hidden from `/model`, Tab, and `/config set model`, and refused by `/model`, `--model`, `model`,
        /// and an MCP caller's `model`, as `--model` spells them; absent or empty, every model is enabled.
        public var disabled: [ModelSelection]?

        /// Creates settings; nil fields take defaults.
        public init(disabled: [ModelSelection]? = nil) {
            self.disabled = disabled
        }
    }

    /// The default model when the file also disables it, which would leave wisp refusing the model it starts on;
    /// nil when the default is enabled.
    public var disabledDefault: ModelSelection? {
        let model = model ?? .default
        return (models?.disabled ?? []).contains(model) ? model : nil
    }

    /// `wisp watch` settings in the file.
    public struct WatchConfig: Codable, Equatable, Sendable {
        /// Seconds without a file change before a run starts; default 1, 0 runs on every change batch.
        public var settle: Double?

        /// Creates settings; nil fields take defaults.
        public init(settle: Double? = nil) {
            self.settle = settle
        }

        /// The range `settle` must be in, in seconds.
        public static let settleRange = 0.0...60.0
        /// What `settle` is when the file does not say.
        public static let defaultSettle = 1.0

        /// Checks the field's range.
        ///
        /// - Throws: `DecodingError.dataCorrupted` naming the problem.
        public func validate() throws {
            if let settle, !Self.settleRange.contains(settle) {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "watch: settle must be between 0 and 60"))
            }
        }
    }

    /// Condensing settings in the file (phase 5 of the
    /// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)), and whether a
    /// conversation given every tool gets `memory` ([ADR 0057](../../../../docs/decisions/0057-context-defaults-from-checkpoint-2.md)).
    public struct ContextConfig: Codable, Equatable, Sendable {
        /// The share of the window a condensation brings the context down to; default 0.6, from 0.1 to 0.8.
        public var target: Double?
        /// How many of the latest turns the next turn's headroom averages; default 8, 0 for none, 1 for the last
        /// turn alone.
        public var headroomTurns: Int?
        /// Whether `memory` is among the tools a conversation given every tool gets; default false, since context
        /// checkpoint 2 scored fewer answers with it on all three models it measured. A tool list that names
        /// `memory` (`--tool memory`, an MCP caller's `tools`) gets it either way.
        public var memory: Bool?

        /// Creates settings; nil fields take defaults.
        public init(target: Double? = nil, headroomTurns: Int? = nil, memory: Bool? = nil) {
            self.target = target
            self.headroomTurns = headroomTurns
            self.memory = memory
        }

        /// The range `target` must be in: above 0.8 a condensation would leave too little below the 0.85 budget
        /// for the next turn, and below 0.1 it would leave nothing but the instructions.
        public static let targetRange = 0.1...0.8
        /// The range `headroomTurns` must be in.
        public static let headroomRange = 0...64

        /// Checks both fields' ranges.
        ///
        /// - Throws: `DecodingError.dataCorrupted` naming the problem.
        public func validate() throws {
            func fail(_ message: String) -> DecodingError {
                .dataCorrupted(.init(codingPath: [], debugDescription: "context: \(message)"))
            }
            if let target, !Self.targetRange.contains(target) { throw fail("target must be between 0.1 and 0.8") }
            if let headroomTurns, !Self.headroomRange.contains(headroomTurns) {
                throw fail("headroomTurns must be between 0 and 64")
            }
        }
    }

    /// Assessment settings in the file (phase 4d of the
    /// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), decision D12). Off by
    /// default until the eval decides, since it adds a model call to many requests.
    public struct AssessmentConfig: Codable, Equatable, Sendable {
        /// Whether each request is assessed; default false.
        public var enabled: Bool?
        /// Which tools each request registers when it is: `request` (the default), `task`, or `all`.
        public var tools: AssessmentSettings.ToolSets?
        /// When an inferred task may change: only when a request states one (`restated`, the default since ADR
        /// 0057), or on `any` request the rules leave to the model.
        public var taskChanges: AssessmentSettings.TaskChanges?

        /// Creates settings; nil fields take defaults.
        public init(
            enabled: Bool? = nil, tools: AssessmentSettings.ToolSets? = nil,
            taskChanges: AssessmentSettings.TaskChanges? = nil
        ) {
            self.enabled = enabled
            self.tools = tools
            self.taskChanges = taskChanges
        }
    }

    /// Fact settings in the file ([layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md),
    /// decisions D1 and D2).
    public struct FactsConfig: Codable, Equatable, Sendable {
        /// Whether conversations keep facts at all; default true.
        public var enabled: Bool?
        /// Whether turns leaving the active view are distilled into facts by the conversation's model; default
        /// true.
        public var distil: Bool?
        /// The share of the context window facts may take in a request; default 0.1.
        public var share: Double?
        /// Whether the turns condensing drops are summarised in the earlier block by the conversation's model;
        /// default true.
        public var summary: Bool?
        /// The share of the context window the running summary may take, on top of `share`; default 0.05.
        public var summaryShare: Double?
        /// Kinds to add, or changes to the kinds of the same name.
        public var kinds: [KindChange]?
        /// Command prefixes whose exit status is a `tests` fact; replaces wisp's list when set.
        public var testCommands: [String]?

        /// One configured kind: every field but `name` optional, so a change sets only what it names.
        public struct KindChange: Codable, Equatable, Sendable {
            /// The kind's name.
            public var name: String
            /// Its temporal class.
            public var temporalClass: TemporalClass?
            /// Its normaliser's name.
            public var normaliser: String?
            /// What it is, for the distiller.
            public var description: String?
            /// Whether the distiller may record facts of it.
            public var distil: Bool?

            /// The JSON keys.
            enum CodingKeys: String, CodingKey {
                case name
                case temporalClass = "class"
                case normaliser
                case description
                case distil
            }

            /// Creates a change.
            public init(
                name: String, temporalClass: TemporalClass? = nil, normaliser: String? = nil,
                description: String? = nil, distil: Bool? = nil
            ) {
                self.name = name
                self.temporalClass = temporalClass
                self.normaliser = normaliser
                self.description = description
                self.distil = distil
            }
        }

        /// Creates settings; nil fields take defaults.
        public init(
            enabled: Bool? = nil, distil: Bool? = nil, share: Double? = nil, kinds: [KindChange]? = nil,
            testCommands: [String]? = nil, summary: Bool? = nil, summaryShare: Double? = nil
        ) {
            self.summary = summary
            self.summaryShare = summaryShare
            self.enabled = enabled
            self.distil = distil
            self.share = share
            self.kinds = kinds
            self.testCommands = testCommands
        }

        /// Checks that every kind has a name and a known normaliser, and both shares are between 0 and 0.5.
        ///
        /// - Throws: `DecodingError.dataCorrupted` naming the problem.
        public func validate() throws {
            func fail(_ message: String) -> DecodingError {
                .dataCorrupted(.init(codingPath: [], debugDescription: "facts: \(message)"))
            }
            for kind in kinds ?? [] {
                guard !kind.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("a kind has no name") }
                if let normaliser = kind.normaliser, FactNormalisers.named(normaliser) == nil {
                    throw fail(
                        "kind \(kind.name): unknown normaliser \(normaliser); use one of "
                            + FactNormalisers.names.joined(separator: ", "))
                }
            }
            if let share, !(0...0.5).contains(share) { throw fail("share must be between 0 and 0.5") }
            if let summaryShare, !(0...0.5).contains(summaryShare) {
                throw fail("summaryShare must be between 0 and 0.5")
            }
        }
    }

    /// Routing settings in the file.
    public struct RoutingConfig: Codable, Equatable, Sendable {
        /// Models from least to most capable; empty or absent turns routing off.
        public var ladder: [ModelSelection]?
        /// The model for a task's model pass when the caller names none, by task (`secrets`); a task
        /// left out keeps wisp's measured default (`ModelRouting.taskDefaults`).
        public var tasks: [String: ModelSelection]?

        /// Creates settings.
        public init(ladder: [ModelSelection]? = nil, tasks: [String: ModelSelection]? = nil) {
            self.ladder = ladder
            self.tasks = tasks
        }
    }

    /// Tool settings in the file.
    public struct ToolsConfig: Codable, Equatable, Sendable {
        /// Built-in tools not to register at all.
        public var disabled: [String]?
        /// The user's own command-template tools ([ADR 0036](../../../../docs/decisions/0036-custom-tools.md)).
        public var custom: [CustomTool.Definition]?

        /// Creates settings.
        public init(disabled: [String]? = nil, custom: [CustomTool.Definition]? = nil) {
            self.disabled = disabled
            self.custom = custom
        }

        /// Checks that every disabled name is a built-in tool and every custom tool is valid and unique.
        ///
        /// - Throws: `CustomTool.Failure`.
        public func validate() throws {
            if let unknown = (disabled ?? []).first(where: { !ToolRegistry.builtInNames.contains($0) }) {
                throw CustomTool.Failure.invalid(
                    tool: unknown,
                    reason: "tools.disabled names no built-in tool; the built-ins are "
                        + ToolRegistry.builtInNames.joined(separator: ", "))
            }
            try CustomTool.validate(custom ?? [], reserved: Set(ToolRegistry.builtInNames))
        }
    }

    /// Notification settings in the file.
    public struct NotificationsConfig: Codable, Equatable, Sendable {
        /// Whether notifications are posted at all; default true.
        public var enabled: Bool?
        /// At most this many in any minute; default 5.
        public var perMinute: Int?
        /// Whether to post through the terminal app by bundle identifier (ADR 0044's third route); default
        /// false until a probe shows the banner attributed to the app.
        public var viaTerminalApp: Bool?

        /// Creates settings; nil fields take defaults.
        public init(enabled: Bool? = nil, perMinute: Int? = nil, viaTerminalApp: Bool? = nil) {
            self.enabled = enabled
            self.perMinute = perMinute
            self.viaTerminalApp = viaTerminalApp
        }
    }

    /// MLX settings in the file.
    public struct MLXConfig: Codable, Equatable, Sendable {
        /// Directory holding one model directory per subdirectory; default `<home>/models/mlx`.
        public var modelsDirectory: String?
        /// Per model, what the operator declares it can do; an undeclared model is text only.
        public var models: [String: MLXModelConfig]?
        /// The context window for every MLX model; nil sizes each from its `config.json` and the Mac's memory
        /// ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
        public var contextLength: Int?
        /// What runs MLX models: `wisp`, wisp's own executor (the default), or `bridge`, mlx-swift-lm's.
        public var executor: MLXExecutorChoice?
        /// Whether a model whose chat template takes `enable_thinking` is asked to think; unset asks a model the
        /// operator declared `reasoning` for, and leaves every other to its template's default, as an unset
        /// `ollama.think` leaves a model to Ollama's (ADR 0053; ADR 0052, refined 2026-10-06).
        public var think: Bool?

        /// Creates settings; nil takes the defaults.
        public init(
            modelsDirectory: String? = nil, models: [String: MLXModelConfig]? = nil, contextLength: Int? = nil,
            executor: MLXExecutorChoice? = nil, think: Bool? = nil
        ) {
            self.modelsDirectory = modelsDirectory
            self.models = models
            self.contextLength = contextLength
            self.executor = executor
            self.think = think
        }
    }

    /// One MLX model's declaration.
    public struct MLXModelConfig: Codable, Equatable, Sendable {
        /// `toolCalling`, `guidedGeneration`, `reasoning`, `vision`; only what has been verified, by the operator
        /// or by wisp's own check (`wisp models check`, ADR 0056 refined 2026-10-04).
        public var capabilities: [String]?
        /// wisp's last check of the model's capabilities; nil when wisp has not checked it, so every capability
        /// listed is the operator's own declaration.
        public var verified: CapabilityCheck?

        /// Creates a declaration.
        public init(capabilities: [String]? = nil, verified: CapabilityCheck? = nil) {
            self.capabilities = capabilities
            self.verified = verified
        }
    }

    /// What wisp's check of a model's capabilities found, as `config.json` keeps it beside the capabilities it
    /// recorded (ADR 0056, refined 2026-10-04). A capability in `capabilities` that is not in `passed` was declared
    /// by the person.
    public struct CapabilityCheck: Codable, Equatable, Sendable {
        /// The day of the check, `YYYY-MM-DD`.
        public var date: String
        /// The capabilities whose check passed, as `config.json` spells them.
        public var passed: [String]
        /// The capabilities whose check failed.
        public var failed: [String]

        /// Creates a record.
        public init(date: String, passed: [String], failed: [String]) {
            self.date = date
            self.passed = passed
            self.failed = failed
        }
    }

    /// Core AI settings in the file.
    public struct CoreAIConfig: Codable, Equatable, Sendable {
        /// Directory holding one exported bundle per subdirectory; default `<home>/models/coreai`.
        public var modelsDirectory: String?

        /// Creates settings; nil takes the default.
        public init(modelsDirectory: String? = nil) {
            self.modelsDirectory = modelsDirectory
        }
    }

    /// Ollama settings in the file.
    public struct OllamaConfig: Codable, Equatable, Sendable {
        /// The server's base URL; default `http://127.0.0.1:11434`.
        public var baseURL: String?
        /// Seconds allowed for one generation request; default 120.
        public var timeoutSeconds: Int?
        /// Context window asked of the server (`num_ctx`) and condensed against; default 8192.
        public var contextLength: Int?
        /// Whether a model that can think is asked to: `true`, `false`, or a level (`OllamaThink`); unset leaves it
        /// to Ollama and the model (ADR 0053).
        public var think: OllamaThink?

        /// Creates settings; nil fields take defaults.
        public init(
            baseURL: String? = nil, timeoutSeconds: Int? = nil, contextLength: Int? = nil, think: OllamaThink? = nil
        ) {
            self.baseURL = baseURL
            self.timeoutSeconds = timeoutSeconds
            self.contextLength = contextLength
            self.think = think
        }
    }

    /// Approval settings in the file.
    public struct ApprovalConfig: Codable, Equatable, Sendable {
        /// Ask at this level and above: `safe`, `moderate`, `dangerous`, or `never`.
        public var threshold: ApprovalThreshold?
        /// Which classifier runs beside the rules: `rules`, `system-model`, or `coreml` (default).
        public var classifier: RiskClassifierChoice?
        /// The pre-0.2 switch: `false` means `classifier: rules`. Read only when `classifier` is absent.
        public var useModel: Bool?
        /// For `coreml`: the `.mlmodel` or `.mlmodelc` path, absolute, `~`, or under `<home>/models/coreml`.
        public var coremlModel: String?
        /// For `coreml`: below this top-label probability the verdict is raised to at least `moderate`; default 0.6.
        public var coremlMinimumConfidence: Double?
        /// Seconds to wait for an approval answer before treating silence as a denial; 0 waits forever.
        public var timeoutSeconds: Int?
        /// Days a persisted (project or always) approval lasts.
        public var persistDays: Int?
        /// Under `wisp mcp`, whether a waiting command is also filed for `wisp approvals` and `wisp-tui`, with a
        /// notification (ADR 0046); default true.
        public var outOfBand: Bool?

        /// Creates settings; nil fields take defaults.
        public init(
            threshold: ApprovalThreshold? = nil, classifier: RiskClassifierChoice? = nil, useModel: Bool? = nil,
            coremlModel: String? = nil, coremlMinimumConfidence: Double? = nil, timeoutSeconds: Int? = nil,
            persistDays: Int? = nil, outOfBand: Bool? = nil
        ) {
            self.outOfBand = outOfBand
            self.threshold = threshold
            self.classifier = classifier
            self.useModel = useModel
            self.coremlModel = coremlModel
            self.coremlMinimumConfidence = coremlMinimumConfidence
            self.timeoutSeconds = timeoutSeconds
            self.persistDays = persistDays
        }
    }

    /// Audit log settings in the file.
    public struct AuditConfig: Codable, Equatable, Sendable {
        /// Whether to write the audit log at all.
        public var enabled: Bool?
        /// Rotate when the file would exceed this size.
        public var maxFileBytes: Int?
        /// Rotated files to keep.
        public var keepFiles: Int?

        /// Creates settings; nil fields take defaults.
        public init(enabled: Bool? = nil, maxFileBytes: Int? = nil, keepFiles: Int? = nil) {
            self.enabled = enabled
            self.maxFileBytes = maxFileBytes
            self.keepFiles = keepFiles
        }
    }

    /// Creates a config; nil fields take defaults at resolution.
    public init(
        systemPromptExtension: String? = nil, instructions: String? = nil, model: ModelSelection? = nil,
        commandTimeoutSeconds: Int? = nil,
        commandMaxOutputBytes: Int? = nil, maxThreads: Int? = nil, commandPolicy: CommandPolicy? = nil,
        audit: AuditConfig? = nil, approval: ApprovalConfig? = nil, ollama: OllamaConfig? = nil,
        coreai: CoreAIConfig? = nil, mlx: MLXConfig? = nil, notifications: NotificationsConfig? = nil,
        tools: ToolsConfig? = nil, routing: RoutingConfig? = nil, inlineOutputBytes: Int? = nil,
        shownOutputLines: Int? = nil, facts: FactsConfig? = nil, context: ContextConfig? = nil,
        watch: WatchConfig? = nil, models: ModelsConfig? = nil
    ) {
        self.models = models
        self.watch = watch
        self.context = context
        self.facts = facts
        self.inlineOutputBytes = inlineOutputBytes
        self.shownOutputLines = shownOutputLines
        self.tools = tools
        self.routing = routing
        self.systemPromptExtension = systemPromptExtension
        self.instructions = instructions
        self.model = model
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.commandMaxOutputBytes = commandMaxOutputBytes
        self.maxThreads = maxThreads
        self.commandPolicy = commandPolicy
        self.audit = audit
        self.approval = approval
        self.ollama = ollama
        self.coreai = coreai
        self.mlx = mlx
        self.notifications = notifications
    }

    /// Reads the file at `url`, or returns an empty config if it does not exist.
    ///
    /// - Throws: `DecodingError` for malformed JSON or an unknown `approval.threshold`,
    ///   `CommandPolicy.Failure` for a bad pattern, or file-system errors other than "missing".
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        try config.commandPolicy?.validate()
        try config.tools?.validate()
        try config.facts?.validate()
        try config.context?.validate()
        try config.watch?.validate()
        if let model = config.disabledDefault { throw ModelSelection.Failure.defaultDisabled(model: model.description) }
        return config
    }

    /// Writes this config as pretty-printed JSON.
    ///
    /// - Throws: File-system errors.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The effective values with defaults applied.
    public var resolved: Resolved {
        Resolved(
            systemPromptExtension: systemPromptExtension ?? instructions,
            model: model ?? .default,
            disabledModels: models?.disabled ?? [],
            runner: CommandRunner.Options(
                timeout: .seconds(commandTimeoutSeconds ?? 60),
                maxOutputBytes: commandMaxOutputBytes ?? 4096,
                policy: commandPolicy ?? .default
            ),
            maxThreads: maxThreads ?? 32,
            inlineOutputBytes: max(0, inlineOutputBytes ?? 1024),
            shownOutputLines: max(0, shownOutputLines ?? 20),
            auditEnabled: audit?.enabled ?? true,
            auditLimits: FileAuditSink.Limits(
                maxFileBytes: audit?.maxFileBytes ?? 10 * 1024 * 1024, keepFiles: audit?.keepFiles ?? 5),
            approvalThreshold: approval?.threshold ?? .default,
            // The pre-0.2 switch still means what it meant: `true` the on-device model, `false` the rules.
            approvalClassifier: approval?.classifier
                ?? approval?.useModel.map { $0 ? .systemModel : .rules } ?? .default,
            coremlModel: approval?.coremlModel, coremlMinimumConfidence: approval?.coremlMinimumConfidence ?? 0.6,
            approvalTimeout: (approval?.timeoutSeconds ?? 600) == 0 ? nil : .seconds(approval?.timeoutSeconds ?? 600),
            approvalLifetime: .seconds((approval?.persistDays ?? 30) * 24 * 3600),
            approvalOutOfBand: approval?.outOfBand ?? true,
            ollama: OllamaSettings(
                baseURL: ollama?.baseURL.flatMap(URL.init(string:)) ?? OllamaSettings.default.baseURL,
                timeout: .seconds(ollama?.timeoutSeconds ?? 120),
                contextLength: ollama?.contextLength ?? OllamaSettings.default.contextLength, think: ollama?.think),
            coreaiModelsDirectory: coreai?.modelsDirectory,
            mlxModelsDirectory: mlx?.modelsDirectory,
            mlxModels: (mlx?.models ?? [:]).mapValues { $0.capabilities ?? [] },
            mlxVerified: (mlx?.models ?? [:]).compactMapValues(\.verified),
            mlxContextLength: mlx?.contextLength, mlxExecutor: mlx?.executor ?? .wisp, mlxThink: mlx?.think,
            notificationsEnabled: notifications?.enabled ?? true,
            notificationsPerMinute: max(1, notifications?.perMinute ?? 5),
            notificationsViaTerminalApp: notifications?.viaTerminalApp ?? true,
            disabledTools: Set(tools?.disabled ?? []), customTools: tools?.custom ?? [],
            routingLadder: routing?.ladder ?? [],
            taskModels: ModelRouting.taskDefaults.merging(routing?.tasks ?? [:]) { _, configured in configured },
            factsEnabled: facts?.enabled ?? true, factsDistil: facts?.distil ?? true,
            factsShare: min(0.5, max(0, facts?.share ?? 0.1)), factsSummary: facts?.summary ?? true,
            summaryShare: min(0.5, max(0, facts?.summaryShare ?? 0.05)),
            subjectKinds: SubjectKinds.defaults.applying(facts),
            assessmentEnabled: assessment?.enabled ?? false, assessmentTools: assessment?.tools ?? .request,
            assessmentTaskChanges: assessment?.taskChanges ?? AssessmentSettings.TaskChanges.default,
            contextTarget: ContextTarget(
                share: context?.target ?? ContextTarget.default.share,
                headroomTurns: context?.headroomTurns ?? ContextTarget.default.headroomTurns),
            contextMemory: context?.memory ?? false,
            watchSettle: watch?.settle ?? WatchConfig.defaultSettle
        )
    }

    /// Configuration with every default filled in.
    public struct Resolved: Equatable, Sendable {
        /// The operator's addition to wisp's system prompt, if any.
        public var systemPromptExtension: String?
        /// Which model sessions run on.
        public var model: ModelSelection
        /// The models the operator turned off, in the file's order (ADR 0056).
        public var disabledModels: [ModelSelection] = []
        /// Limits for `run_command`.
        public var runner: CommandRunner.Options
        /// Live MCP threads kept before eviction.
        public var maxThreads: Int
        /// The largest tool output an MCP `respond` result carries inline, in bytes.
        public var inlineOutputBytes: Int
        /// Lines of each tool's output chat shows under its note before folding the rest; 0 shows the note
        /// alone.
        public var shownOutputLines: Int = 20
        /// Whether the audit log is written.
        public var auditEnabled: Bool
        /// Rotation limits for the audit file.
        public var auditLimits: FileAuditSink.Limits
        /// From which level a human is asked.
        public var approvalThreshold: ApprovalThreshold
        /// Which classifier runs beside the rules.
        public var approvalClassifier: RiskClassifierChoice
        /// For `coreml`: the model path as configured.
        public var coremlModel: String?
        /// For `coreml`: the confidence below which a verdict is raised to at least `moderate`.
        public var coremlMinimumConfidence: Double

        /// Whether the on-device model classifies alongside the rules.
        public var approvalUsesModel: Bool { approvalClassifier == .systemModel }
        /// How long an approval request may go unanswered before it counts as a denial; nil waits forever.
        public var approvalTimeout: Duration?
        /// How long a persisted approval lasts.
        public var approvalLifetime: Duration
        /// Under `wisp mcp`, whether a waiting command is also filed for another face to answer.
        public var approvalOutOfBand: Bool = true
        /// Where Ollama is for `ollama:<name>` models.
        public var ollama: OllamaSettings
        /// Where Core AI bundles live, as configured; nil means `<home>/models/coreai`.
        public var coreaiModelsDirectory: String?
        /// Where MLX model directories live, as configured; nil means `<home>/models/mlx`.
        public var mlxModelsDirectory: String?
        /// Declared capability names per MLX model name.
        public var mlxModels: [String: [String]]
        /// wisp's last capability check per MLX model name, for the models it has checked.
        public var mlxVerified: [String: CapabilityCheck] = [:]
        /// The context window for every MLX model, when configured; nil sizes each from memory (ADR 0052).
        public var mlxContextLength: Int?
        /// What runs MLX models.
        public var mlxExecutor: MLXExecutorChoice = .wisp
        /// `mlx.think`: whether a model whose template takes `enable_thinking` is asked to think; nil asks one declared
        /// `reasoning` and leaves the others to the template's default.
        public var mlxThink: Bool?
        /// Whether notifications are posted.
        public var notificationsEnabled: Bool = true
        /// At most this many notifications a minute.
        public var notificationsPerMinute: Int = 5
        /// Whether a notification may be sent to the terminal app by bundle identifier.
        public var notificationsViaTerminalApp: Bool = false
        /// Built-in tools not registered.
        public var disabledTools: Set<String> = []
        /// The user's own tools, validated.
        public var customTools: [CustomTool.Definition] = []
        /// Models to route among by input size, least capable first; empty means no routing.
        public var routingLadder: [ModelSelection] = []
        /// The model for each task's model pass when the caller names none: wisp's measured defaults,
        /// overridden by `routing.tasks`.
        public var taskModels: [String: ModelSelection] = ModelRouting.taskDefaults
        /// Whether conversations keep facts.
        public var factsEnabled = true
        /// Whether turns leaving the active view are distilled into facts.
        public var factsDistil = true
        /// The share of the context window facts may take in a request.
        public var factsShare = 0.1
        /// Whether the turns condensing drops are summarised in the earlier block.
        public var factsSummary = true
        /// The share of the context window the running summary may take.
        public var summaryShare = 0.05
        /// The subject kinds and test commands in force.
        public var subjectKinds = SubjectKinds.defaults
        /// Whether each request is assessed (phase 4d); off by default.
        public var assessmentEnabled = false
        /// Which tools each assessed request registers.
        public var assessmentTools = AssessmentSettings.ToolSets.request
        /// When an assessed request may change an inferred task.
        public var assessmentTaskChanges = AssessmentSettings.TaskChanges.default
        /// What condensing aims for: the target share of the window and the next turn's headroom.
        public var contextTarget = ContextTarget.default
        /// Whether a conversation given every tool gets `memory` (`context.memory`); off by default (ADR 0057).
        public var contextMemory = false
        /// Seconds file changes must be quiet before `wisp watch` runs; 0 runs on every batch.
        public var watchSettle = WatchConfig.defaultSettle
    }
}

/// What runs `mlx:` models ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
public enum MLXExecutorChoice: String, Codable, CaseIterable, Sendable {
    /// wisp's own executor: the window enforced, exact token counts, usage reported, and the processed
    /// prefix reused across a thread's requests. Text, tool calls, and schema replies; no images.
    case wisp
    /// mlx-swift-lm's `MLXLanguageModel` bridge, as before 0.19.0: every request processed from the start,
    /// no usage reported to wisp, images accepted when `vision` is declared.
    case bridge
}
