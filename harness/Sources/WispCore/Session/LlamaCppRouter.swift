import Darwin
import Foundation

/// wisp's own llama.cpp server: one `llama-server` router over the models wisp knows, on `127.0.0.1`, with a key
/// wisp generates ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decisions 1, 6,
/// and 7). `wisp llamacpp serve`, which the LaunchAgent runs (`LlamaCppAgent`), reads the configuration, checks the
/// approved binary, makes sure of the key, and replaces itself with `llama-server` (`prepare`), so launchd supervises
/// the server itself.
public enum LlamaCppRouter {
    /// The memory and port settings of the router, `llamacpp.server*` in `config.json` (decision 7), with defaults
    /// applied.
    public struct Settings: Equatable, Sendable {
        /// The port on `127.0.0.1` it listens on (`llamacpp.serverPort`).
        public var port: Int
        /// The tokens of context each model is loaded with (`llamacpp.serverContextLength`, `--ctx-size`).
        public var contextLength: Int
        /// The requests a model answers at once (`llamacpp.serverSlots`, `--parallel`).
        public var slots: Int
        /// The models kept loaded at once (`llamacpp.serverModelsLoaded`, `--models-max`).
        public var modelsLoaded: Int
        /// Seconds without a request before a loaded model sleeps (`llamacpp.serverIdleSeconds`,
        /// `--sleep-idle-seconds`); 0 never sleeps.
        public var idleSeconds: Int

        /// Creates settings; each omitted takes its default.
        public init(
            port: Int = Settings.defaultPort, contextLength: Int = 65_536, slots: Int = 1, modelsLoaded: Int = 2,
            idleSeconds: Int = 600
        ) {
            self.port = port
            self.contextLength = contextLength
            self.slots = slots
            self.modelsLoaded = modelsLoaded
            self.idleSeconds = idleSeconds
        }

        /// The defaults: a 65,536-token context, 1 slot, 2 models loaded, sleep after 600 s idle, port 8933.
        public static let defaults = Settings()

        /// The default port: not 8080, which `llamacpp.server off` connects to for a `llama-server` the person
        /// starts, nor 9931, llama-server's own default and Llama.app's, nor Ollama's 11434 or LM Studio's 1234; not
        /// assigned in `/etc/services` on macOS 27.
        public static let defaultPort = 8933

        /// The ports a setting may name: none below 1024, which are the system's.
        public static let portRange = 1024...65_535
        /// The slots a setting may name.
        public static let slotsRange = 1...64
        /// The models a setting may keep loaded; no "unlimited", which llama.cpp's 0 would be, since every loaded
        /// model holds its memory.
        public static let modelsLoadedRange = 1...16
        /// The idle seconds a setting may name; 0 never sleeps.
        public static let idleSecondsRange = 0...86_400

        /// The settings in a `llamacpp` section, defaults for those it does not set.
        ///
        /// - Parameter section: The section, if any.
        /// - Returns: The settings.
        static func resolve(_ section: Config.OpenAICompatibleConfig?) -> Settings {
            let d = Settings.defaults
            return Settings(
                port: section?.serverPort ?? d.port, contextLength: section?.serverContextLength ?? d.contextLength,
                slots: section?.serverSlots ?? d.slots, modelsLoaded: section?.serverModelsLoaded ?? d.modelsLoaded,
                idleSeconds: section?.serverIdleSeconds ?? d.idleSeconds)
        }

        /// `http://127.0.0.1:<port>`, where wisp asks the router.
        public var baseURL: URL {
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = port
            return components.url ?? URL(filePath: "/")
        }

        /// The settings in a line, as `wisp doctor` and the start's message give them.
        public var summary: String {
            let idle = idleSeconds == 0 ? "never sleeps" : "sleeps after \(idleSeconds) s idle"
            return "context \(contextLength.formatted()) tokens, \(slots) slot\(slots == 1 ? "" : "s"), up to "
                + "\(modelsLoaded) model\(modelsLoaded == 1 ? "" : "s") loaded, \(idle), port \(port)"
        }
    }

    /// The 9B Bonsai's resident memory at the default settings, measured on 2026-10-30 (docs/measurements.md), for
    /// `wisp config`'s words on the context length.
    static let measuredDefaultMemory = "about 5 GB"

    /// The settings that change how the router runs, so changing one restarts it when it runs.
    public static let restartingSettings = [
        "llamacpp.serverPort", "llamacpp.serverContextLength", "llamacpp.serverSlots", "llamacpp.serverModelsLoaded",
        "llamacpp.serverIdleSeconds",
    ]

    /// Why `wisp llamacpp serve` would not start the router.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `llamacpp.server` is not `wisp`.
        case notWisp(LlamaCppServer)
        /// The approved binary's check refused it.
        case binary(LlamaCppServerBinary.Refusal)
        /// The key file or the models folder could not be made.
        case files(String)

        /// The failure as said to the person, and written to the server's log.
        public var description: String {
            switch self {
            case .notWisp(let server):
                "llamacpp.server is \(server.rawValue), not wisp, so wisp starts no llama.cpp server; "
                    + "wisp config set llamacpp.server wisp chooses wisp's own"
            case .binary(let refusal): "wisp will not start llama-server: \(refusal)"
            case .files(let reason): "wisp's llama.cpp server cannot start: \(reason)"
            }
        }
    }

    /// What to run: the approved file, and its arguments without the program's name.
    public struct Launch: Equatable, Sendable {
        /// The approved `llama-server`, its real path.
        public var executable: URL
        /// The arguments after the program's name.
        public var arguments: [String]
        /// The router's settings.
        public var settings: Settings
    }

    /// The arguments `llama-server` is started with: a router over `models` (decision 1), listening on `127.0.0.1`
    /// only, with keys read from `keyFile` rather than the command line and without llama.cpp's web UI, since wisp
    /// needs only the API (decision 6), and the memory settings (decision 7). `--no-ui` is llama-server 0.7.0's name;
    /// it calls `--no-webui` deprecated, and the router passes the setting on to each model's process (probed
    /// 2026-10-30). A 0 for idle seconds leaves out `--sleep-idle-seconds`, so the server never sleeps.
    ///
    /// - Parameters:
    ///   - settings: The router's settings.
    ///   - models: The folder of links (`LlamaCppModels.folder`).
    ///   - keyFile: The key file.
    /// - Returns: The arguments after the program's name.
    public static func arguments(_ settings: Settings, models: URL, keyFile: URL) -> [String] {
        var arguments = [
            "--models-dir", models.path, "--models-max", "\(settings.modelsLoaded)", "--ctx-size",
            "\(settings.contextLength)", "--parallel", "\(settings.slots)",
        ]
        if settings.idleSeconds > 0 { arguments += ["--sleep-idle-seconds", "\(settings.idleSeconds)"] }
        arguments += [
            "--no-ui", "--host", "127.0.0.1", "--port", "\(settings.port)", "--api-key-file", keyFile.path,
        ]
        return arguments
    }

    /// The environment `llama-server` is started with: this one without llama.cpp's own `LLAMA_ARG_*` and other
    /// `LLAMA_*` variables, which would set what the arguments do not (another host, a key, the web UI's options).
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: `NAME=value` strings.
    public static func environment(_ environment: [String: String]) -> [String] {
        environment.filter { !$0.key.hasPrefix("LLAMA_") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// Checks everything the start needs and records it: the setting is `wisp`; the approved binary passes its check
    /// (`LlamaCppServerBinary.verify`, which records a refusal as `llamacpp.server.refused`); the key file exists,
    /// made once; the models folder exists. Records `llamacpp.server.start`, with the arguments, which name the key
    /// file and never hold the key. The caller replaces its process with the launch.
    ///
    /// - Parameters:
    ///   - config: The `llamacpp` settings.
    ///   - home: wisp's home, whose support folder holds the approval, the key, and the models.
    ///   - audit: Where the start or the refusal is recorded.
    /// - Returns: What to run.
    /// - Throws: `Failure`.
    public static func prepare(
        _ config: OpenAICompatibleSettings, home: Home, audit: AuditLog?
    ) throws -> Launch {
        func refused(_ failure: Failure) -> Failure {
            audit?.record(
                .llamaCppServerStart,
                details: [
                    "outcome": .string("refused"), "reason": .string(failure.description), "executable": .null,
                    "sha256": .null, "arguments": .null, "port": .int(config.router.port),
                ])
            return failure
        }
        guard config.server == .wisp else { throw refused(.notWisp(config.server)) }
        let approved: LlamaCppServerBinary.Approved
        do {
            approved = try LlamaCppServerBinary(home: home).verify(config.serverPath, audit: audit, source: "serve")
        } catch let refusal as LlamaCppServerBinary.Refusal {
            throw refused(.binary(refusal))
        }
        let keyFile = KeyFile(home: home)
        let models = LlamaCppModels(home: home).folder
        do {
            try keyFile.ensure()
            try FileManager.default.createDirectory(
                at: models, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch let failure as KeyFile.Failure {
            throw refused(.files(failure.description))
        } catch {
            throw refused(.files("\(models.path) cannot be made: \(error.localizedDescription)"))
        }
        let arguments = arguments(config.router, models: models, keyFile: keyFile.file)
        audit?.record(
            .llamaCppServerStart,
            details: [
                "outcome": .string("started"), "reason": .null, "executable": .string(approved.executable.path),
                "sha256": .string(approved.sha256), "arguments": .array(arguments.map { .string($0) }),
                "port": .int(config.router.port),
            ])
        return Launch(executable: approved.executable, arguments: arguments, settings: config.router)
    }

    /// The server's log: `llamacpp.log` in wisp's logs folder (`~/Library/Logs/Wisp`), where `wisp llamacpp serve`
    /// sends its own output and `llama-server`'s.
    ///
    /// - Parameter home: wisp's home.
    /// - Returns: The log file.
    public static func log(home: Home) -> URL {
        home.libraryLogs.appending(path: "llamacpp.log")
    }

    /// The size past which the log is moved aside to `llamacpp.log.1` when the server starts.
    public static let logLimit = 8 << 20

    /// Opens the server's log for appending, owner only, after moving a log past `logLimit` aside, replacing any
    /// earlier one.
    ///
    /// - Parameter file: The log.
    /// - Returns: The open descriptor.
    /// - Throws: `Failure.files` when the folder or the file cannot be made.
    public static func openLog(_ file: URL) throws -> Int32 {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.files("its log folder cannot be made: \(error.localizedDescription)")
        }
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > logLimit {
            let old = URL(filePath: file.path + ".1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: file, to: old)
        }
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw Failure.files("\(file.path) cannot be opened: \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    /// The key wisp's router is started with (decision 6): random, made once and reused, in
    /// `<support>/llamacpp/api-key`, the folder owner only (0700) and the file readable by the owner only (0600).
    /// Never logged or shown: not in the audit, the doctor, the configuration's views, or an error.
    public struct KeyFile: Equatable, Sendable {
        /// Why the key file could not be made.
        public enum Failure: Error, CustomStringConvertible, Equatable {
            /// The folder or the file could not be made or written; the reason, never the key.
            case unwritable(path: String, reason: String)

            /// The failure as said to the person.
            public var description: String {
                switch self {
                case .unwritable(let path, let reason): "the key file \(path) cannot be made: \(reason)"
                }
            }
        }

        /// The file.
        public let file: URL

        /// The key file in `home`'s support folder.
        public init(home: Home) {
            file = home.support.appending(path: "llamacpp/api-key")
        }

        /// The bytes of randomness in a key: 32, written as 64 hex digits.
        static let bytes = 32

        /// A new key: `bytes` from the system's cryptographically secure generator, as lower-case hex.
        ///
        /// - Returns: The key.
        static func generate() -> String {
            var generator = SystemRandomNumberGenerator()
            return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
                .joined()
        }

        /// Whether `text` is a key wisp would have written: 64 hex digits.
        ///
        /// - Parameter text: The file's first line.
        /// - Returns: True for a key.
        static func isKey(_ text: String) -> Bool {
            text.count == bytes * 2 && text.allSatisfy(\.isHexDigit)
        }

        /// The key, or nil when the file is missing or holds none.
        ///
        /// - Returns: The key.
        public func read() -> String? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
            return line.flatMap { Self.isKey($0) ? $0 : nil }
        }

        /// Makes the key file when it is missing or holds no key, and keeps one already there: the folder 0700, the
        /// file created 0600 (never readable by another user, even for a moment) and put back to 0600 when it is
        /// not.
        ///
        /// - Throws: `Failure.unwritable`.
        public func ensure() throws {
            let manager = FileManager.default
            let folder = file.deletingLastPathComponent()
            do {
                try manager.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            } catch {
                throw Failure.unwritable(path: file.path, reason: error.localizedDescription)
            }
            if read() != nil {
                do {
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } catch {
                    throw Failure.unwritable(path: file.path, reason: error.localizedDescription)
                }
                return
            }
            // Missing, or holding no key: written whole to a new file made 0600, then moved into place.
            let fresh = folder.appending(path: ".api-key-\(UUID().uuidString)")
            let descriptor = open(fresh.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw Failure.unwritable(path: file.path, reason: String(cString: strerror(errno)))
            }
            let text = Array((Self.generate() + "\n").utf8)
            let written = text.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
            guard written == text.count, rename(fresh.path, file.path) == 0 else {
                let reason = String(cString: strerror(errno))
                unlink(fresh.path)
                throw Failure.unwritable(path: file.path, reason: reason)
            }
        }
    }

    /// What `wisp`'s router failing to answer means, in plain words, with the fix: the binary refused, the agent not
    /// registered, waiting for approval, held by launchd alone, or refused by launchd, no agent for this home, not
    /// started yet, or registered and silent.
    ///
    /// - Parameters:
    ///   - binary: The approved binary's check.
    ///   - agent: The LaunchAgent's state.
    ///   - keyExists: Whether the key file holds a key, which the first start makes.
    ///   - settings: The router's settings.
    ///   - log: The server's log.
    ///   - detail: What the connection said, when it was tried.
    /// - Returns: The explanation.
    public static func diagnosis(
        binary: Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal>, agent: LlamaCppAgent.State,
        keyExists: Bool, settings: Settings, log: URL, detail: String?
    ) -> String {
        let at = "\(settings.baseURL.absoluteString)\(detail.map { " (\($0))" } ?? "")"
        if case .failure(let refusal) = binary {
            return "wisp's llama.cpp server does not answer at \(at): wisp will not start its llama-server: \(refusal)"
        }
        switch agent {
        case .notRegistered:
            return "wisp's llama.cpp server does not answer at \(at): its LaunchAgent is not registered; "
                + "wisp config set llamacpp.server wisp registers and starts it"
        case .requiresApproval:
            return "wisp's llama.cpp server does not answer at \(at): its Login Item waits for your approval in "
                + "System Settings > General > Login Items & Extensions; turn on Wisp there"
        case .orphaned:
            return "wisp's llama.cpp server does not answer at \(at): its Login Item is not registered, but launchd "
                + "still holds its job; \(LlamaCppAgent.repairCommand) removes the job and registers the agent again"
        case .refusedByLaunchd:
            return "wisp's llama.cpp server does not answer at \(at): launchd refused to start its LaunchAgent (last "
                + "exit code 78, EX_CONFIG), as after an update on 2026-10-30, and nothing reached its log; "
                + "\(LlamaCppAgent.repairCommand) registers Wisp.app with Launch Services and the agent again"
        case .manual(let reason):
            return "wisp's llama.cpp server does not answer at \(at): wisp registers no LaunchAgent here (\(reason)); "
                + "start it yourself with wisp llamacpp serve"
        case .unknown(let reason):
            return "wisp's llama.cpp server does not answer at \(at), and its LaunchAgent's state cannot be read "
                + "(\(reason)); its log is \(log.path)"
        case .registered:
            guard keyExists else {
                return "wisp's llama.cpp server has not started yet: its LaunchAgent is registered, and no start has "
                    + "made its key; its log, \(log.path), says why; wisp config set llamacpp.server wisp starts it "
                    + "again"
            }
            return "wisp's llama.cpp server does not answer at \(at): its LaunchAgent is registered and the server is "
                + "not running, or still starting; its log, \(log.path), says why; wisp config set llamacpp.server "
                + "wisp starts it again"
        }
    }

    /// What to do when wisp's router stops answering mid-request, where the reason is not looked for: `wisp doctor`
    /// says it.
    ///
    /// - Parameter settings: The router's settings.
    /// - Returns: The hint.
    static func unansweredHint(_ settings: Settings) -> String {
        "wisp's llama.cpp server on port \(settings.port) did not answer; wisp doctor says why (its llama-server's "
            + "approval, its LaunchAgent, and its log, llamacpp.log in ~/Library/Logs/Wisp)"
    }
}
