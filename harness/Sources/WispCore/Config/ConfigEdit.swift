import Foundation

/// The settings a person can change from chat or `wisp config set`, and what each accepts
/// ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)). The rest of `config.json`
/// (policies, custom tools, backend model tables) is edited by hand; an edit here keeps it as it is.
public enum ConfigSettings {
    /// What a setting's value is.
    public enum Kind: Equatable, Sendable {
        /// One of these words.
        case choice([String])
        /// `true` or `false`; `on`, `off`, `yes`, and `no` are read too.
        case flag
        /// A whole number within the range.
        case integer(ClosedRange<Int>)
        /// A number within the range.
        case number(ClosedRange<Double>)
        /// Free text.
        case text
        /// A model, as `--model` spells it.
        case model
        /// Models, least to most capable, as a JSON array or separated by commas or spaces.
        case models
        /// Tool names, as a JSON array or separated by commas or spaces.
        case tools
        /// A Core ML model: `risk@<version>` from the classifier store, a file under
        /// `<home>/models/coreml`, or an absolute or `~` path.
        case coremlModel
    }

    /// One setting.
    public struct Setting: Equatable, Sendable {
        /// Its dotted path in `config.json`, such as `approval.classifier`.
        public var path: String
        /// What it does, in a line.
        public var summary: String
        /// What it accepts.
        public var kind: Kind
    }

    /// Every setting, in the order a list shows them.
    public static let all: [Setting] = [
        Setting(path: "model", summary: "the model new sessions run on", kind: .model),
        Setting(
            path: "models.disabled", summary: "models hidden from /model and refused; wisp models enable|disable",
            kind: .models),
        Setting(
            path: "approval.threshold", summary: "ask before commands rated at this level or above",
            kind: .choice(["safe", "moderate", "dangerous", "never"])),
        Setting(
            path: "approval.classifier", summary: "what judges each command beside the rules",
            kind: .choice(RiskClassifierChoice.allCases.map(\.rawValue))),
        Setting(
            path: "approval.coremlModel", summary: "the Core ML model for classifier coreml", kind: .coremlModel),
        Setting(
            path: "approval.coremlMinimumConfidence", summary: "below this a Core ML verdict asks anyway",
            kind: .number(0...1)),
        Setting(
            path: "approval.timeoutSeconds", summary: "seconds to wait for an approval; 0 waits forever",
            kind: .integer(0...86_400)),
        Setting(
            path: "approval.persistDays", summary: "days a project or always approval lasts", kind: .integer(1...365)),
        Setting(
            path: "approval.outOfBand",
            summary: "under wisp mcp, also ask through wisp approvals and wisp-tui, with a notification", kind: .flag),
        Setting(
            path: "routing.ladder", summary: "models to route to by input size, least capable first", kind: .models),
        Setting(
            path: "routing.tasks.secrets", summary: "the model for the thorough pass of scan and redact",
            kind: .model),
        Setting(
            path: "commandTimeoutSeconds", summary: "seconds a command may run; 0 waits forever",
            kind: .integer(0...86_400)),
        Setting(
            path: "commandMaxOutputBytes", summary: "bytes of output kept from each command",
            kind: .integer(256...1_048_576)),
        Setting(path: "tools.disabled", summary: "built-in tools the model does not get", kind: .tools),
        Setting(
            path: "shownOutputLines", summary: "lines of each tool's output chat shows before folding; 0 for none",
            kind: .integer(0...10_000)),
        Setting(path: "notifications.enabled", summary: "whether wisp posts notifications", kind: .flag),
        Setting(path: "notifications.perMinute", summary: "notifications allowed a minute", kind: .integer(1...60)),
        Setting(
            path: "notifications.viaTerminalApp",
            summary: "whether to post through the terminal app by bundle identifier", kind: .flag),
        Setting(path: "audit.enabled", summary: "whether the audit log is written", kind: .flag),
        Setting(path: "ollama.baseURL", summary: "where Ollama serves", kind: .text),
        Setting(
            path: "ollama.contextLength",
            summary: "the context window asked of every Ollama model; unset sizes each from memory",
            kind: .integer(1024...1_048_576)),
        Setting(
            path: "ollama.think",
            summary:
                "whether a model that can think is asked to: true, false, or a level; unset leaves it to the model",
            kind: .choice(OllamaThink.choices)),
        Setting(
            path: "mlx.contextLength",
            summary: "the context window of every MLX model; unset sizes each from memory",
            kind: .integer(1024...1_048_576)),
        Setting(
            path: "mlx.executor", summary: "what runs MLX models: wisp's executor, or the bridge (no prefix reuse)",
            kind: .choice(MLXExecutorChoice.allCases.map(\.rawValue))),
        Setting(
            path: "mlx.think",
            summary: "whether an MLX model thinks (enable_thinking); unset, declared reasoning or its template's",
            kind: .flag),
        Setting(path: "systemPromptExtension", summary: "text added to wisp's system prompt", kind: .text),
        Setting(
            path: "assessment.enabled",
            summary: "assess each request: its tools, task, and relevant facts (adds a model call)", kind: .flag),
        Setting(
            path: "assessment.tools", summary: "which tools an assessed request registers",
            kind: .choice(AssessmentSettings.ToolSets.allCases.map(\.rawValue))),
        Setting(
            path: "assessment.taskChanges",
            summary: "when an assessed request may change the inferred task: any request, or one that states a task",
            kind: .choice(AssessmentSettings.TaskChanges.allCases.map(\.rawValue))),
        Setting(
            path: "context.target", summary: "the share of the window condensing brings the context down to",
            kind: .number(Config.ContextConfig.targetRange)),
        Setting(
            path: "context.headroomTurns",
            summary: "the latest turns whose average size is kept free for the next turn; 0 for none",
            kind: .integer(Config.ContextConfig.headroomRange)),
        Setting(
            path: "context.memory",
            summary: "give a conversation with every tool the memory tool, to recall what condensing left out",
            kind: .flag),
        Setting(
            path: "watch.settle",
            summary: "seconds file changes must be quiet before wisp watch runs; 0 runs on every change",
            kind: .number(Config.WatchConfig.settleRange)),
    ]

    /// The setting at `path`, or nil.
    public static func setting(_ path: String) -> Setting? {
        all.first { $0.path == path }
    }

    /// What a setting is when `config.json` does not set it, from `Config().resolved`; nil where the
    /// default is nothing at all (no extension to the system prompt).
    public static func defaultValue(_ path: String) -> JSONValue? {
        let d = Config().resolved
        switch path {
        case "model": return .string(d.model.description)
        case "models.disabled": return .array(d.disabledModels.map { .string($0.description) })
        case "approval.threshold": return .string(d.approvalThreshold.rawValue)
        case "approval.classifier": return .string(d.approvalClassifier.rawValue)
        case "approval.coremlModel": return .string(ClassifierStore.reference(ClassifierStore.defaultVersion()))
        case "approval.coremlMinimumConfidence": return .double(d.coremlMinimumConfidence)
        case "approval.timeoutSeconds": return .int(Int(d.approvalTimeout?.components.seconds ?? 0))
        case "approval.persistDays": return .int(Int(d.approvalLifetime.components.seconds / 86_400))
        case "approval.outOfBand": return .bool(d.approvalOutOfBand)
        case "routing.ladder": return .array(d.routingLadder.map { .string($0.description) })
        case "routing.tasks.secrets": return d.taskModels["secrets"].map { .string($0.description) }
        case "commandTimeoutSeconds": return .int(Int(d.runner.timeout.components.seconds))
        case "commandMaxOutputBytes": return .int(d.runner.maxOutputBytes)
        case "tools.disabled": return .array(d.disabledTools.sorted().map { .string($0) })
        case "shownOutputLines": return .int(d.shownOutputLines)
        case "notifications.enabled": return .bool(d.notificationsEnabled)
        case "notifications.perMinute": return .int(d.notificationsPerMinute)
        case "notifications.viaTerminalApp": return .bool(d.notificationsViaTerminalApp)
        case "audit.enabled": return .bool(d.auditEnabled)
        case "ollama.baseURL": return .string(d.ollama.baseURL.absoluteString)
        case "ollama.contextLength": return d.ollama.contextLength.map { .int($0) } ?? .string("sized per model")
        case "ollama.think": return d.ollama.think.map { .string($0.text) } ?? .string("the model's default")
        case "mlx.contextLength": return d.mlxContextLength.map { .int($0) } ?? .string("sized per model")
        case "mlx.executor": return .string(d.mlxExecutor.rawValue)
        case "mlx.think": return d.mlxThink.map { .bool($0) } ?? .string("declared reasoning, else the template's")
        case "assessment.enabled": return .bool(d.assessmentEnabled)
        case "assessment.tools": return .string(d.assessmentTools.rawValue)
        case "assessment.taskChanges": return .string(d.assessmentTaskChanges.rawValue)
        case "context.target": return .double(d.contextTarget.share)
        case "context.headroomTurns": return .int(d.contextTarget.headroomTurns)
        case "context.memory": return .bool(d.contextMemory)
        case "watch.settle": return .double(d.watchSettle)
        default: return nil
        }
    }
}

/// A change to `config.json`, checked before it is written: the file must still load exactly as it
/// does at start-up ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)).
public enum ConfigEdit {
    /// Why a change was refused. Nothing is written.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No such setting.
        case unknownSetting(String)
        /// The value is not one the setting accepts.
        case invalidValue(path: String, reason: String)
        /// The existing file is not a JSON object.
        case unreadableFile(String)
        /// The edited file would not load.
        case wouldNotLoad(String)
        /// The change would leave the file naming a default it also disables (ADR 0056).
        case refused(ModelSelection.Failure)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unknownSetting(let path):
                "no setting '\(path)'; the settings are: " + ConfigSettings.all.map(\.path).joined(separator: ", ")
            case .invalidValue(let path, let reason): "\(path): \(reason)"
            case .unreadableFile(let detail): "config.json is not a JSON object: \(detail)"
            case .wouldNotLoad(let detail): "the change would leave config.json unloadable: \(detail)"
            case .refused(let failure): failure.description
            }
        }
    }

    /// What a change did.
    public struct Outcome: Equatable, Sendable {
        /// The setting.
        public var path: String
        /// The value before, nil when unset.
        public var old: JSONValue?
        /// The value after, nil when unset.
        public var new: JSONValue?
        /// The file's new contents.
        public var data: Data
        /// A warning when the change weakens approval or the audit, or needs something else set.
        public var warning: String?
    }

    /// The value `text` means for `setting`.
    ///
    /// - Throws: `Failure.invalidValue`.
    public static func value(_ text: String, for setting: ConfigSettings.Setting) throws -> JSONValue {
        let text = text.trimmingCharacters(in: .whitespaces)
        let invalid = { (reason: String) in Failure.invalidValue(path: setting.path, reason: reason) }
        switch setting.kind {
        case .choice(let options):
            guard options.contains(text) else {
                throw invalid("'\(text)' is not one of \(options.joined(separator: ", "))")
            }
            return .string(text)
        case .flag:
            switch text.lowercased() {
            case "true", "on", "yes": return .bool(true)
            case "false", "off", "no": return .bool(false)
            default: throw invalid("'\(text)' is not true or false")
            }
        case .integer(let range):
            guard let number = Int(text), range.contains(number) else {
                throw invalid("'\(text)' is not a whole number from \(range.lowerBound) to \(range.upperBound)")
            }
            return .int(number)
        case .number(let range):
            guard let number = Double(text), range.contains(number) else {
                throw invalid("'\(text)' is not a number from \(range.lowerBound) to \(range.upperBound)")
            }
            return .double(number)
        case .text, .coremlModel:
            guard !text.isEmpty else { throw invalid("give a value, or unset it") }
            return .string(unquoted(text))
        case .model:
            do {
                return .string(try ModelSelection(parsing: text).description)
            } catch {
                throw invalid("\(error)")
            }
        case .models:
            var models: [JSONValue] = []
            for name in list(text) {
                do {
                    models.append(.string(try ModelSelection(parsing: name).description))
                } catch {
                    throw invalid("\(error)")
                }
            }
            return .array(models)
        case .tools:
            let names = list(text)
            let unknown = names.filter { !ToolRegistry.builtInNames.contains($0) }
            guard unknown.isEmpty else {
                throw invalid(
                    "no built-in tool \(unknown.joined(separator: ", ")); the tools are "
                        + ToolRegistry.builtInNames.joined(separator: ", "))
            }
            return .array(names.map { .string($0) })
        }
    }

    /// `text` without one pair of surrounding double quotes.
    static func unquoted(_ text: String) -> String {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") ? String(text.dropFirst().dropLast()) : text
    }

    /// Items of a JSON array of strings, or of text separated by commas or spaces.
    static func list(_ text: String) -> [String] {
        if let decoded = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) { return decoded }
        return text.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    /// Sets `path` to `text` in the file `data` holds (nil for no file).
    ///
    /// - Throws: `Failure`.
    public static func set(_ path: String, to text: String, in data: Data?) throws -> Outcome {
        guard let setting = ConfigSettings.setting(path) else { throw Failure.unknownSetting(path) }
        return try change(path, to: try value(text, for: setting), in: data)
    }

    /// Removes `path` from the file `data` holds, so its default applies.
    ///
    /// - Throws: `Failure`.
    public static func unset(_ path: String, in data: Data?) throws -> Outcome {
        guard ConfigSettings.setting(path) != nil else { throw Failure.unknownSetting(path) }
        return try change(path, to: nil, in: data)
    }

    /// Sets the value at `keys` in the file `data` holds, or removes it when `value` is nil, checked as every change
    /// is: for an entry no `ConfigSettings` row names, whose key may hold a dot, such as an MLX model's declaration
    /// `mlx.models.<name>` that a capability check records (ADR 0056, refined 2026-10-04). The outcome's `path` is
    /// the keys joined by dots.
    ///
    /// - Throws: `Failure`.
    public static func set(keys: [String], to value: JSONValue?, in data: Data?) throws -> Outcome {
        try change(keys, to: value, in: data)
    }

    /// The value at `keys` in the file `data` holds, nil when unset.
    ///
    /// - Throws: `Failure.unreadableFile`.
    public static func current(keys: [String], in data: Data?) throws -> JSONValue? {
        value(at: keys, in: .object(try object(data)))
    }

    /// The value at `path` in the file `data` holds, nil when unset.
    ///
    /// - Throws: `Failure.unreadableFile`.
    public static func current(_ path: String, in data: Data?) throws -> JSONValue? {
        let root = try object(data)
        return value(at: path.split(separator: ".").map(String.init), in: .object(root))
    }

    /// The file's top-level object.
    static func object(_ data: Data?) throws -> [String: JSONValue] {
        guard let data, !data.isEmpty else { return [:] }
        do {
            guard let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
                throw Failure.unreadableFile("the top level is not an object")
            }
            return object
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadableFile("\(error)")
        }
    }

    private static func value(at keys: [String], in root: JSONValue) -> JSONValue? {
        keys.reduce(Optional(root)) { node, key in node?.objectValue?[key] }
    }

    /// `object` with `keys` set to `value`, or removed when nil; an object left empty is removed too.
    private static func setting(
        _ keys: ArraySlice<String>, to value: JSONValue?, in object: [String: JSONValue]
    )
        -> [String: JSONValue]
    {
        guard let key = keys.first else { return object }
        var object = object
        if keys.count == 1 {
            object[key] = value
        } else {
            let child = setting(keys.dropFirst(), to: value, in: object[key]?.objectValue ?? [:])
            object[key] = child.isEmpty ? nil : .object(child)
        }
        return object
    }

    /// The change of the setting at the dotted `path`.
    private static func change(_ path: String, to new: JSONValue?, in data: Data?) throws -> Outcome {
        try change(path.split(separator: ".").map(String.init), to: new, in: data)
    }

    /// `data` with `keys` set to `new` (removed when nil), checked to load as start-up loads it.
    private static func change(_ keys: [String], to new: JSONValue?, in data: Data?) throws -> Outcome {
        let root = try object(data)
        let path = keys.joined(separator: ".")
        let edited = setting(keys[...], to: new, in: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output: Data
        let config: Config
        do {
            output = try encoder.encode(JSONValue.object(edited)) + Data("\n".utf8)
            config = try JSONDecoder().decode(Config.self, from: output)
            try config.commandPolicy?.validate()
            try config.tools?.validate()
        } catch {
            throw Failure.wouldNotLoad("\(error)")
        }
        // Setting the default to a disabled model names the model; disabling the default says what to do first.
        if let model = config.disabledDefault {
            throw Failure.refused(
                path == "model"
                    ? .disabled(model: model.description) : .defaultDisabled(model: model.description))
        }
        return Outcome(
            path: path, old: value(at: keys, in: .object(root)), new: new, data: output,
            warning: warning(path: path, new: new, in: edited))
    }

    /// Words for a change that weakens the gate or the audit, or that needs another setting.
    static func warning(path: String, new: JSONValue?, in edited: [String: JSONValue]) -> String? {
        switch (path, new?.stringValue, new?.boolValue) {
        case ("approval.threshold", "never", _):
            return "commands will run without asking, however risky; the policy and sandbox still apply"
        case ("approval.threshold", "dangerous", _):
            return "only commands rated dangerous will ask; moderate ones, such as git push or npm install, run at once"
        case ("approval.classifier", "rules", _):
            return "only the rules judge commands; anything they do not recognise is rated by them alone"
        case ("approval.classifier", "coreml", _)
        where value(at: ["approval", "coremlModel"], in: .object(edited)) == nil:
            return "no approval.coremlModel is set, so the default shipped with this wisp is used; "
                + "'wisp classifier list' shows the versions you can choose"
        case ("audit.enabled", _, false):
            return "nothing will be recorded in the audit log from the next session on"
        default:
            return nil
        }
    }

    /// Writes an outcome's data to `url`, readable by the owner only, replacing the file whole.
    ///
    /// - Throws: File-system errors.
    public static func write(_ outcome: Outcome, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try outcome.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
