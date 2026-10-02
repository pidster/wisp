import Foundation
import FoundationModels

/// Checks what a fresh install needs to work, for `wisp doctor`.
public struct Doctor: Sendable {
    /// One check's outcome.
    public struct Finding: Equatable, Sendable {
        /// Short name of the check.
        public var name: String
        /// Whether it passed.
        public var ok: Bool
        /// What was found, or what to do about it.
        public var detail: String

        /// Creates a finding.
        public init(name: String, ok: Bool, detail: String) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    /// How the doctor asks about models, so tests can answer without the framework.
    public struct Probes: Sendable {
        /// Nil when the system model is available, else the reason it is not.
        public var systemModel: @Sendable () -> String?
        /// Nil when the given model resolves under this configuration and home, else the failure text.
        public var configuredModel: @Sendable (ModelSelection, Config.Resolved, Home) -> String?
        /// For a `coreml` classifier: nil when its model prepares, else the failure text.
        public var coremlClassifier: @Sendable (Config.Resolved, Home) -> String?
        /// The context window wisp would use for the given model and how it is known; nil when the model does
        /// not resolve (that is the "configured model" finding's business).
        public var contextWindow: @Sendable (ModelSelection, Config.Resolved, Home) -> ContextWindow?
        /// The process environment, which names the terminal and its app, for the `notify` finding.
        public var environment: @Sendable () -> [String: String]
        /// Whether `/dev/tty` opens for writing, for the `notify` finding; nothing is written.
        public var terminalOpens: @Sendable () -> Bool
        /// Whether `/usr/bin/osascript` can run, for the `notify` finding.
        public var osascriptPresent: @Sendable () -> Bool

        /// Probes that ask the framework.
        public static let live = Probes(
            systemModel: {
                if case .unavailable(let reason) = SystemLanguageModel.default.availability {
                    return ModelSelection.explain(reason)
                }
                return nil
            },
            configuredModel: { model, config, home in
                do {
                    _ = try model.resolve(config: config, home: home)
                    return nil
                } catch {
                    return "\(error)"
                }
            },
            coremlClassifier: { config, home in
                do {
                    _ = try CoreMLRiskClassifier.prepare(Session.coremlModelURL(config: config, home: home))
                    return nil
                } catch {
                    return "\(error)"
                }
            },
            contextWindow: { model, config, home in
                // The same resolution the "configured model" check does, so an Ollama model costs the same
                // bounded `/api/show` calls and no more.
                guard let resolved = try? model.resolve(config: config, home: home) else { return nil }
                return ContextWindow(size: resolved.contextSize, note: resolved.contextNote)
            },
            environment: { ProcessInfo.processInfo.environment }, terminalOpens: TerminalNotification.ttyOpens,
            osascriptPresent: { FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript") })

        /// Creates probes.
        public init(
            systemModel: @escaping @Sendable () -> String?,
            configuredModel: @escaping @Sendable (ModelSelection, Config.Resolved, Home) -> String?,
            coremlClassifier: @escaping @Sendable (Config.Resolved, Home) -> String? = { _, _ in nil },
            contextWindow: @escaping @Sendable (ModelSelection, Config.Resolved, Home) -> ContextWindow? = { _, _, _ in
                nil
            },
            environment: @escaping @Sendable () -> [String: String] = { [:] },
            terminalOpens: @escaping @Sendable () -> Bool = { false },
            osascriptPresent: @escaping @Sendable () -> Bool = { true }
        ) {
            self.systemModel = systemModel
            self.configuredModel = configuredModel
            self.coremlClassifier = coremlClassifier
            self.contextWindow = contextWindow
            self.environment = environment
            self.terminalOpens = terminalOpens
            self.osascriptPresent = osascriptPresent
        }
    }

    /// What a resolved model says about its context window.
    public struct ContextWindow: Equatable, Sendable {
        /// The window in tokens; nil when only an overflow error will tell.
        public var size: Int?
        /// Why the window is `size`, when the backend chose it (ADR 0043); nil when it is the model's own.
        public var note: String?

        /// Creates a reading.
        public init(size: Int?, note: String? = nil) {
            self.size = size
            self.note = note
        }
    }

    /// Where wisp keeps its state.
    public var home: Home
    /// The configured model, checked in addition to the system model.
    public var model: ModelSelection
    /// The configuration local backends read their settings from.
    public var resolvedConfig: Config.Resolved
    let probes: Probes

    /// Creates a doctor for `home` and the configured `model`.
    public init(
        home: Home, model: ModelSelection = .default, config: Config.Resolved = Config().resolved,
        probes: Probes = .live
    ) {
        self.home = home
        self.model = model
        resolvedConfig = config
        self.probes = probes
    }

    /// Runs every check. Never throws: problems are findings.
    public func run() -> [Finding] {
        var findings = [
            macOSVersion(), modelAvailability(), sandboxExec(), config(), settingsInRange(), factsStore(),
            subjectKinds(), savedTranscripts(), notifyRoute(), homeWritable(), pendingApprovals(),
        ]
        // The window follows the model checks, so it can say "not checked" when they failed.
        let modelProblem = model == .system ? probes.systemModel() : nil
        var configuredProblem: String?
        if model != .system {
            let finding = configuredModel()
            configuredProblem = finding.ok ? nil : finding.detail
            findings.insert(finding, at: 2)
        }
        findings.insert(contextWindow(unavailable: configuredProblem ?? modelProblem), at: model == .system ? 2 : 3)
        if resolvedConfig.approvalClassifier == .coreml { findings.insert(classifier(), at: 2) }
        return findings
    }

    private func classifier() -> Finding {
        if let problem = probes.coremlClassifier(resolvedConfig, home) {
            return Finding(name: "classifier", ok: false, detail: problem)
        }
        return Finding(
            name: "classifier", ok: true,
            detail:
                "coreml model \(resolvedConfig.coremlModel ?? ClassifierStore.reference(ClassifierStore.defaultVersion()) + " (shipped)") prepares"
        )
    }

    private func configuredModel() -> Finding {
        if let problem = probes.configuredModel(model, resolvedConfig, home) {
            return Finding(name: "configured model", ok: false, detail: problem)
        }
        return Finding(name: "configured model", ok: true, detail: "\(model) available")
    }

    /// True when every finding passed.
    public static func allPassed(_ findings: [Finding]) -> Bool {
        findings.allSatisfy(\.ok)
    }

    /// Renders findings one per line with a pass or fail mark.
    public static func render(_ findings: [Finding]) -> String {
        findings.map { "\($0.ok ? "ok  " : "FAIL") \($0.name): \($0.detail)" }.joined(separator: "\n")
    }

    private func macOSVersion() -> Finding {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return Finding(
            name: "macOS", ok: version.majorVersion >= 27,
            detail: version.majorVersion >= 27 ? text : "\(text); wisp needs macOS 27 or later")
    }

    private func modelAvailability() -> Finding {
        if let problem = probes.systemModel() {
            return Finding(name: "model", ok: false, detail: problem)
        }
        return Finding(name: "model", ok: true, detail: "on-device model available")
    }

    private func sandboxExec() -> Finding {
        let path = "/usr/bin/sandbox-exec"
        let present = FileManager.default.isExecutableFile(atPath: path)
        return Finding(
            name: "sandbox", ok: present,
            detail: present ? "\(path) present" : "\(path) missing; run_command cannot be sandboxed")
    }

    private func config() -> Finding {
        let file = home.configFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Finding(name: "config", ok: true, detail: "no \(file.path); defaults apply")
        }
        do {
            _ = try Config.load(from: file)
            return Finding(name: "config", ok: true, detail: "\(file.path) parses")
        } catch {
            return Finding(name: "config", ok: false, detail: "\(file.path): \(error)")
        }
    }

    private func homeWritable() -> Finding {
        do {
            try home.ensure()
            let probe = home.root.appending(path: ".doctor-\(UUID().uuidString)")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return Finding(name: "home", ok: true, detail: "\(home.root.path) writable")
        } catch {
            return Finding(name: "home", ok: false, detail: "\(home.root.path) not writable: \(error)")
        }
    }
}
