import Foundation
import Synchronization
import Testing

@testable import WispCore

/// wisp's own llama.cpp server (ADR 0082, decisions 1, 4, 6, and 7): the settings it runs with and their ranges, the
/// arguments and environment it starts with, the key file, the checks before a start, what its failing to answer is
/// said as, and its LaunchAgent, driven through a fake control and a fake `launchctl`. Nothing here starts a server or
/// reaches launchd: every home is a scratch one, which registers nothing.
@Suite(.serialized) struct LlamaCppRouterTests {
    /// The scratch root, real path.
    private let root: URL

    init() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "wisp-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        root = URL(filePath: CommandPolicy.canonical(scratch.path))
    }

    /// A scratch home with `json` as its `config.json`.
    private func home(_ json: String = "{}") throws -> Home {
        let home = Home(root: root.appending(path: "home"))
        try home.ensure()
        try Data(json.utf8).write(to: home.configFile)
        return home
    }

    /// A fake executable with Mach-O magic, approved as `llamacpp.serverPath` in `home`.
    private func approvedBinary(in home: Home) throws -> URL {
        let file = root.appending(path: "llama-server")
        try (Data([0xCF, 0xFA, 0xED, 0xFE]) + Data("server".utf8)).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        _ = try LlamaCppServerBinary(home: home).change(
            file.path, configFile: home.configFile, workingDirectory: root, audit: nil, source: "cli")
        return file
    }

    /// The POSIX permissions of `url`.
    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
    }

    // MARK: - Settings

    @Test func theSettingsDefaultAsTheOperatorChose() {
        let settings = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        #expect(settings.router == LlamaCppRouter.Settings.defaults)
        #expect(settings.router.contextLength == 65_536 && settings.router.slots == 1)
        #expect(settings.router.modelsLoaded == 2 && settings.router.idleSeconds == 600 && settings.router.port == 8933)
        #expect(settings.baseURL.absoluteString == "http://127.0.0.1:8933")
        #expect(
            settings.router.summary
                == "context 65,536 tokens, 1 slot, up to 2 models loaded, sleeps after 600 s idle, port 8933")
        // A port neither off's 8080 nor Llama.app's 9931.
        #expect(![8080, LlamaCppServer.llamaAppPort].contains(LlamaCppRouter.Settings.defaultPort))
        for path in LlamaCppRouter.restartingSettings {
            #expect(ConfigSettings.setting(path) != nil, "\(path)")
            #expect(ConfigSettings.defaultValue(path) != nil, "\(path)")
        }
        #expect(ConfigSettings.defaultValue("llamacpp.serverContextLength") == .int(65_536))
        #expect(ConfigSettings.defaultValue("llamacpp.serverPort") == .int(8933))
    }

    @Test func underWispTheBaseURLIsTheServersPortWhateverBaseURLSays() {
        let config = Config(
            llamacpp: .init(baseURL: "http://127.0.0.1:7000", apiKey: "from-file", server: .wisp, serverPort: 9100))
        let settings = config.resolved.llamacpp
        #expect(settings.baseURL.absoluteString == "http://127.0.0.1:9100")
        // No key from config.json, nor from the environment: only wisp's key file.
        #expect(settings.apiKey == nil && settings.apiKeyState == "unset")
        let fromEnvironment = OpenAICompatibleSettings.resolve(
            config.llamacpp, dialect: .llamaCpp, environment: ["WISP_LLAMACPP_API_KEY": "env"])
        #expect(fromEnvironment.apiKey == nil)
        // Under off the explicit URL and the keys stand as before.
        let off = OpenAICompatibleSettings.resolve(
            .init(baseURL: "http://127.0.0.1:7000", apiKey: "from-file", serverPort: 9100), dialect: .llamaCpp,
            environment: ["WISP_LLAMACPP_API_KEY": "env"])
        #expect(off.baseURL.absoluteString == "http://127.0.0.1:7000" && off.apiKey == "env")
        #expect(settings.startHint(for: .llamaCpp).contains("wisp doctor says why"))
    }

    @Test func eachSettingIsCheckedForItsRange() throws {
        for (path, bad, good) in [
            ("llamacpp.serverPort", "80", "9100"), ("llamacpp.serverContextLength", "100", "32768"),
            ("llamacpp.serverSlots", "0", "2"), ("llamacpp.serverModelsLoaded", "0", "1"),
            ("llamacpp.serverIdleSeconds", "-1", "0"),
        ] {
            #expect(throws: ConfigEdit.Failure.self, "\(path)") { try ConfigEdit.set(path, to: bad, in: nil) }
            #expect(try ConfigEdit.set(path, to: good, in: nil).new == .int(Int(good) ?? 0), "\(path)")
        }
        // Written by hand, out of range, the file does not load, and names the setting.
        let file = root.appending(path: "config.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"llamacpp":{"serverSlots":99}}"#.utf8).write(to: file)
        #expect {
            try Config.load(from: file)
        } throws: { error in
            "\(error)".contains("serverSlots must be between 1 and 64")
        }
        // LM Studio has no server of wisp's.
        try Data(#"{"lmstudio":{"serverPort":9100}}"#.utf8).write(to: file)
        #expect {
            try Config.load(from: file)
        } throws: { error in
            "\(error)".contains("lmstudio: serverPort is not taken")
        }
    }

    // MARK: - Starting

    @Test func theArgumentsAreARouterOnLoopbackWithAKeyFile() {
        let models = URL(filePath: "/s/llamacpp/models")
        let key = URL(filePath: "/s/llamacpp/api-key")
        #expect(
            LlamaCppRouter.arguments(.defaults, models: models, keyFile: key) == [
                "--models-dir", "/s/llamacpp/models", "--models-max", "2", "--ctx-size", "65536", "--parallel", "1",
                "--sleep-idle-seconds", "600", "--no-ui", "--host", "127.0.0.1", "--port", "8933", "--api-key-file",
                "/s/llamacpp/api-key",
            ])
        let never = LlamaCppRouter.arguments(
            .init(port: 9000, contextLength: 4096, slots: 2, modelsLoaded: 1, idleSeconds: 0), models: models,
            keyFile: key)
        #expect(!never.contains("--sleep-idle-seconds"))
        #expect(never.contains("4096") && never.contains("9000"))
    }

    @Test func llamaCppsOwnVariablesAreLeftOut() {
        #expect(
            LlamaCppRouter.environment(["HOME": "/u", "LLAMA_ARG_HOST": "0.0.0.0", "LLAMA_CACHE": "/c", "PATH": "/b"])
                == ["HOME=/u", "PATH=/b"])
    }

    @Test func theKeyFileIsMadeOnceOwnerOnlyAndReused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let keys = LlamaCppRouter.KeyFile(home: home)
        #expect(keys.read() == nil)
        try keys.ensure()
        let key = try #require(keys.read())
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit))
        #expect(mode(keys.file) == 0o600 && mode(keys.file.deletingLastPathComponent()) == 0o700)
        try keys.ensure()
        #expect(keys.read() == key)
        // Opened up by hand, it is closed again; a file holding no key is replaced.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keys.file.path)
        try keys.ensure()
        #expect(mode(keys.file) == 0o600 && keys.read() == key)
        try Data("not a key\n".utf8).write(to: keys.file)
        try keys.ensure()
        #expect(keys.read() != nil && keys.read() != key && mode(keys.file) == 0o600)
        // Two keys differ.
        #expect(LlamaCppRouter.KeyFile.generate() != LlamaCppRouter.KeyFile.generate())
    }

    @Test func aStartIsRefusedUnlessTheSettingIsWispAndTheBinaryApproved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        #expect(throws: LlamaCppRouter.Failure.notWisp(.off)) {
            try LlamaCppRouter.prepare(Config().resolved.llamacpp, home: home, audit: audit)
        }
        let unapproved = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        #expect(throws: LlamaCppRouter.Failure.binary(.notSet)) {
            try LlamaCppRouter.prepare(unapproved, home: home, audit: audit)
        }
        #expect(sink.events.map(\.kind) == [.llamaCppServerStart, .llamaCppServerRefused, .llamaCppServerStart])
        #expect(sink.events.allSatisfy { $0.kind != .llamaCppServerStart || $0.details["outcome"] == "refused" })
        #expect(LlamaCppRouter.KeyFile(home: home).read() == nil)
    }

    @Test func anApprovedStartMakesTheKeyAndTheFolderAndRecordsTheArgumentsWithoutTheKey() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let file = try approvedBinary(in: home)
        let sink = MemoryAuditSink()
        let settings = Config(llamacpp: .init(server: .wisp, serverPath: file.path, serverPort: 9200)).resolved.llamacpp
        let launch = try LlamaCppRouter.prepare(settings, home: home, audit: AuditLog(session: "s", sink: sink))
        let keys = LlamaCppRouter.KeyFile(home: home)
        let key = try #require(keys.read())
        #expect(launch.executable.path == file.path)
        #expect(
            launch.arguments
                == LlamaCppRouter.arguments(
                    settings.router, models: LlamaCppModels(home: home).folder, keyFile: keys.file))
        #expect(FileManager.default.fileExists(atPath: LlamaCppModels(home: home).folder.path))
        let start = try #require(sink.events.last)
        #expect(start.kind == .llamaCppServerStart && start.details["outcome"] == "started")
        #expect(start.details["port"] == .int(9200) && start.details["executable"] == .string(file.path))
        let recorded = String(decoding: try JSONEncoder().encode(sink.events), as: UTF8.self)
        #expect(!recorded.contains(key))
        // The key reaches a session through its settings, and is never shown.
        let loaded = try Session.loadConfig(home: try self.home(#"{"llamacpp":{"server":"wisp"}}"#))
        #expect(loaded.llamacpp.apiKey == key && loaded.llamacpp.apiKeyState == "set (wisp's key file)")
        #expect(!loaded.llamacpp.description.contains(key) && !"\(loaded.llamacpp)".contains(key))
    }

    @Test func theLogIsMovedAsideWhenLarge() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let log = LlamaCppRouter.log(home: home)
        #expect(log.path.hasSuffix("/logs/llamacpp.log"))
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: LlamaCppRouter.logLimit + 1).write(to: log)
        let descriptor = try LlamaCppRouter.openLog(log)
        close(descriptor)
        #expect(mode(log) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) == 0)
        #expect(FileManager.default.fileExists(atPath: log.path + ".1"))
    }

    // MARK: - What not answering means

    @Test func notAnsweringIsSaidWithItsFix() throws {
        let settings = LlamaCppRouter.Settings.defaults
        let log = URL(filePath: "/L/llamacpp.log")
        let approval = LlamaCppServerBinary.Approval(path: "/b", resolved: "/b", sha256: "ab", approved: Date())
        let approved: Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal> = .success(
            .init(executable: URL(filePath: "/b"), sha256: "ab", approval: approval))
        func said(
            _ agent: LlamaCppAgent.State, key: Bool = true,
            binary: Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal> = approved
        ) -> String {
            LlamaCppRouter.diagnosis(
                binary: binary, agent: agent, keyExists: key, settings: settings, log: log, detail: "refused")
        }
        #expect(
            said(.registered, binary: .failure(.notSet)).contains(
                "wisp will not start its llama-server: no llama-server"))
        #expect(
            said(.notRegistered).contains("its LaunchAgent is not registered; wisp config set llamacpp.server wisp"))
        #expect(said(.requiresApproval).contains("Login Items & Extensions"))
        #expect(
            said(.manual("a scratch home")).contains("(a scratch home); start it yourself with wisp llamacpp serve"))
        #expect(said(.registered, key: false).contains("has not started yet"))
        let silent = said(.registered)
        #expect(silent.contains("http://127.0.0.1:8933 (refused)") && silent.contains("/L/llamacpp.log"))
    }

    @Test func theBackendSaysWhyTheServerDidNotServe() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let settings = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        let agent = FakeAgent(state: .notRegistered)
        let unreachable = OpenAICompatibleBackend.routerReason(
            .unreachable(.llamaCpp, settings.baseURL, "refused", hint: ""), settings: settings, home: home,
            agent: agent)
        #expect(unreachable.contains("no llama-server is approved"))
        _ = try approvedBinary(in: home)
        var approved = settings
        approved.serverPath = root.appending(path: "llama-server").path
        let unregistered = OpenAICompatibleBackend.routerReason(
            .unusable(.llamaCpp, "x"), settings: approved, home: home, agent: agent)
        #expect(unregistered.contains("its LaunchAgent is not registered"), "\(unregistered)")
        let refused = OpenAICompatibleBackend.routerReason(
            .refused(.llamaCpp, settings.baseURL, status: 401, keySet: true), settings: approved, home: home,
            agent: agent)
        #expect(refused.contains("refused the key in wisp's key file"))
    }

    @Test func noRequestIsMadeBeforeTheKeyExists() async {
        let settings = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        await #expect(throws: OpenAICompatibleModel.Failure.unusable(.llamaCpp, OpenAICompatibleModel.noKey)) {
            try await OpenAICompatibleModel.served(by: .llamaCpp, at: settings)
        }
    }

    @Test func aRouterListingCarriesEachModelsStatus() throws {
        // As llama-server 0.7.0's router answered on 2026-10-30, shortened.
        let json =
            #"{"data":[{"id":"Bonsai-2B","object":"model","status":{"value":"unloaded","args":[]}},"#
            + #"{"id":"Bonsai-9B","object":"model","status":{"value":"loaded"}}],"object":"list"}"#
        let served = try Catalogs.llamaServer(
            try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        #expect(served.map(\.status) == ["unloaded", "loaded"] && served.allSatisfy(\.routed))
    }

    @Test func theDoctorReportsWispsServer() throws {
        let settings = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        let approval = LlamaCppServerBinary.Approval(path: "/b", resolved: "/r", sha256: "abcdef", approved: Date())
        var router = Doctor.RouterState(
            binary: .success(.init(executable: URL(filePath: "/r"), sha256: "abcdef", approval: approval)),
            agent: .registered, means: .manual("x"), keyExists: true, log: URL(filePath: "/L/llamacpp.log"))
        let answering = try #require(
            Doctor.llamaCppServer(
                settings, installed: nil,
                answer: .routed([.init(name: "Bonsai-9B", status: "loaded"), .init(name: "Bonsai-2B", status: nil)]),
                router: router))
        #expect(answering.ok, "\(answering.detail)")
        #expect(answering.detail.contains("llama-server /b approved and unchanged"))
        #expect(answering.detail.contains("LaunchAgent: registered"))
        #expect(answering.detail.contains("serving Bonsai-9B (loaded), Bonsai-2B (status not said)"))
        #expect(
            answering.detail.contains("settings: context 65,536 tokens") && answering.detail.contains("/L/llamacpp.log")
        )
        router.agent = .notRegistered
        let stopped = try #require(
            Doctor.llamaCppServer(settings, installed: nil, answer: .failed("refused"), router: router))
        #expect(!stopped.ok && stopped.detail.contains("its LaunchAgent is not registered"))
    }

    @Test func aStartIsRefusedWhenItsFilesCannotBeMade() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let home = try home()
        let file = try approvedBinary(in: home)
        let settings = Config(llamacpp: .init(server: .wisp, serverPath: file.path)).resolved.llamacpp
        let sink = MemoryAuditSink()
        func reason() -> String? {
            do {
                _ = try LlamaCppRouter.prepare(settings, home: home, audit: AuditLog(session: "s", sink: sink))
                return nil
            } catch let LlamaCppRouter.Failure.files(reason) {
                return reason
            } catch {
                return "another error: \(error)"
            }
        }
        // The models folder's place is taken by a file.
        let models = URL(filePath: LlamaCppModels(home: home).folder.path, directoryHint: .notDirectory)
        try Data("x".utf8).write(to: models)
        let noFolder = try #require(reason())
        #expect(noFolder.hasPrefix("\(models.path) cannot be made: "), "\(noFolder)")
        let refusal = try #require(sink.events.last)
        #expect(refusal.kind == .llamaCppServerStart && refusal.details["outcome"] == "refused")
        #expect(refusal.details["reason"] == .string("wisp's llama.cpp server cannot start: \(noFolder)"))
        try manager.removeItem(at: models)
        // The key file's place is taken by a folder: the new key cannot be moved into it, and nothing is left behind.
        let keys = LlamaCppRouter.KeyFile(home: home)
        try manager.removeItem(at: keys.file)
        try manager.createDirectory(at: keys.file.appending(path: "held"), withIntermediateDirectories: true)
        let noKey = try #require(reason())
        #expect(noKey.hasPrefix("the key file \(keys.file.path) cannot be made: "), "\(noKey)")
        let left = try manager.contentsOfDirectory(atPath: keys.file.deletingLastPathComponent().path)
        #expect(!left.contains { $0.hasPrefix(".api-key-") }, "\(left)")
        // The key file's folder cannot be made: its support folder is a file.
        let blocked = root.appending(path: "support-file")
        try Data("x".utf8).write(to: blocked)
        let elsewhere = LlamaCppRouter.KeyFile(home: Home(root: root.appending(path: "other"), support: blocked))
        #expect {
            try elsewhere.ensure()
        } throws: { error in
            guard case .unwritable(let path, _) = error as? LlamaCppRouter.KeyFile.Failure else { return false }
            return path == elsewhere.file.path
        }
    }

    @Test func aLogThatCannotBeOpenedIsSaid() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Its folder's place is taken by a file.
        let blocked = root.appending(path: "logs-file")
        try Data("x".utf8).write(to: blocked)
        #expect {
            _ = try LlamaCppRouter.openLog(blocked.appending(path: "llamacpp.log"))
        } throws: { error in
            guard case .files(let reason) = error as? LlamaCppRouter.Failure else { return false }
            return reason.hasPrefix("its log folder cannot be made: ")
        }
        // The log's place is taken by a folder.
        let folder = root.appending(path: "logs/llamacpp.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect {
            _ = try LlamaCppRouter.openLog(folder)
        } throws: { error in
            "\(error)" == "wisp's llama.cpp server cannot start: \(folder.path) cannot be opened: Is a directory"
        }
    }

    @Test func anAgentWhoseStateCannotBeReadPointsAtTheLog() {
        let said = LlamaCppRouter.diagnosis(
            binary: .failure(.notSet), agent: .unknown("x"), keyExists: true, settings: .defaults,
            log: URL(filePath: "/L/llamacpp.log"), detail: nil)
        #expect(said.hasPrefix("wisp's llama.cpp server does not answer at http://127.0.0.1:8933: wisp will not start"))
        let unknown = LlamaCppRouter.diagnosis(
            binary: .success(
                .init(
                    executable: URL(filePath: "/b"), sha256: "ab",
                    approval: .init(path: "/b", resolved: "/b", sha256: "ab", approved: Date()))),
            agent: .unknown("launchctl timed out"), keyExists: true, settings: .defaults,
            log: URL(filePath: "/L/llamacpp.log"), detail: "refused")
        #expect(
            unknown
                == "wisp's llama.cpp server does not answer at http://127.0.0.1:8933 (refused), and its LaunchAgent's "
                + "state cannot be read (launchctl timed out); its log is /L/llamacpp.log")
    }

    @Test func theDoctorAsksWispsServerOnlyUnderWispAndNotBeforeItsKey() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let agent = FakeAgent(state: .requiresApproval)
        let off = await Doctor.askWispServer(Config().resolved.llamacpp, home: home, agent: agent)
        #expect(off.answer == nil && off.router == nil)
        let settings = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        let asked = await Doctor.askWispServer(settings, home: home, agent: agent)
        #expect(asked.answer == .failed("no key yet"))
        let router = try #require(asked.router)
        #expect(router.binary == .failure(.notSet) && router.agent == .requiresApproval && !router.keyExists)
        #expect(router.means == agent.means && router.log == LlamaCppRouter.log(home: home))
        // The finding says what waits, and fails.
        let finding = try #require(
            Doctor.llamaCppServer(settings, installed: nil, answer: asked.answer, router: router))
        #expect(!finding.ok && finding.detail.contains("LaunchAgent: waiting for your approval in Login Items"))
    }

    @Test func theDoctorCountsWhatAServerLists() throws {
        let wisp = Config(llamacpp: .init(server: .wisp)).resolved.llamacpp
        let router = Doctor.RouterState(
            binary: .success(
                .init(
                    executable: URL(filePath: "/r"), sha256: "abcdef",
                    approval: .init(path: "/b", resolved: "/r", sha256: "abcdef", approved: Date()))),
            agent: .manual("WISP_LLAMACPP_AGENT is off"), means: .manual("off"), keyExists: true,
            log: URL(filePath: "/L/llamacpp.log"))
        let listed = try #require(Doctor.llamaCppServer(wisp, installed: nil, answer: .listed(1), router: router))
        #expect(
            listed.ok && listed.detail.contains("it answers at http://127.0.0.1:8933 with wisp's key, listing 1 model;")
        )
        let unread = try #require(Doctor.llamaCppServer(wisp, installed: nil, answer: nil, router: nil))
        #expect(!unread.ok && unread.detail == "llamacpp.server wisp: its state was not read")
        // Llama.app's router: counted, but only a plain listing passes without Llama.app installed.
        let app = Config(llamacpp: .init(baseURL: "http://127.0.0.1:8080", server: .llamaApp)).resolved.llamacpp
        let routed = try #require(
            Doctor.llamaCppServer(
                app, installed: nil, answer: .routed([.init(name: "a", status: nil), .init(name: "b", status: nil)])))
        #expect(routed.detail.contains("its server at http://127.0.0.1:8080 answers, listing 2 models"))
        #expect(routed.detail.contains("Llama.app's server has no API key"))
    }

    // MARK: - The LaunchAgent

    @Test func howTheAgentIsRegisteredDependsOnTheInstallAndTheHome() {
        let person = Home.resolve(environment: [:])
        #expect(person.isPersons && !Home(root: root).isPersons)
        let user = URL(filePath: "/Users/p")
        let app = URL(filePath: "/Applications/Wisp.app")
        func means(
            _ home: Home, _ source: AppInstall.Source, environment: [String: String] = [:]
        ) -> LlamaCppAgent.Means {
            LlamaCppAgent.means(
                home: home, environment: environment, source: source,
                executable: URL(filePath: "/opt/homebrew/Cellar/wisp/0.33.0/libexec/wisp"), userHome: user)
        }
        #expect(means(person, .app(app)) == .loginItem(app: app))
        if case .manual = means(Home(root: root), .app(app)) {} else { Issue.record("a scratch home registers") }
        if case .manual = means(person, .app(app), environment: ["WISP_LLAMACPP_AGENT": "off"]) {
        } else {
            Issue.record("off registers")
        }
        if case .refused = means(person, .diskImage(app)) {} else { Issue.record("the disk image registers") }
        #expect(
            means(person, .homebrew)
                == .launchAgent(
                    program: URL(filePath: "/opt/homebrew/opt/wisp/libexec/wisp"),
                    file: URL(filePath: "/Users/p/Library/LaunchAgents/com.pidster.wisp.llamacpp.plist")))
        #expect(
            LlamaCppAgent.stableProgram(URL(filePath: "/build/.build/debug/wisp")).path == "/build/.build/debug/wisp")
    }

    @Test func theAgentsFileRunsTheHiddenSubcommandAndRestartsOnlyAfterACrash() throws {
        let data = try LlamaCppAgent.plist(program: URL(filePath: "/opt/homebrew/opt/wisp/libexec/wisp"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.pidster.wisp.llamacpp")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/homebrew/opt/wisp/libexec/wisp", "llamacpp", "serve"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plist["ThrottleInterval"] as? Int == 30)
    }

    @Test func aFileAgentIsWrittenAndLoadedThroughLaunchctl() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeLaunchctl()
        let file = root.appending(path: "LaunchAgents/com.pidster.wisp.llamacpp.plist")
        let agent = LaunchAgentFile(
            program: URL(filePath: "/w/wisp"), file: file, service: "gui/501/com.pidster.wisp.llamacpp",
            launchctl: { fake.run($0) })
        #expect(agent.state() == .notRegistered)
        try agent.register()
        #expect(FileManager.default.fileExists(atPath: file.path) && agent.state() == .registered)
        try agent.restart()
        try agent.unregister()
        #expect(!FileManager.default.fileExists(atPath: file.path) && agent.state() == .notRegistered)
        #expect(
            fake.calls == [
                ["bootout", "gui/501/com.pidster.wisp.llamacpp"],
                ["bootstrap", "gui/501", file.path], ["print", "gui/501/com.pidster.wisp.llamacpp"],
                ["kickstart", "-k", "gui/501/com.pidster.wisp.llamacpp"],
                ["bootout", "gui/501/com.pidster.wisp.llamacpp"],
            ])
        let failing = LaunchAgentFile(
            program: URL(filePath: "/w/wisp"), file: file, service: "gui/501/com.pidster.wisp.llamacpp",
            launchctl: { _ in (5, "Input/output error") })
        #expect {
            try failing.register()
        } throws: { error in
            "\(error)" == "launchctl bootstrap gui/501 \(file.path) failed (status 5): Input/output error"
        }
    }

    @Test func changesRegisterUnregisterOrRestartTheAgent() {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        func run(
            _ trigger: LlamaCppAgent.Trigger, _ server: LlamaCppServer, _ agent: FakeAgent
        ) -> (ok: Bool, said: [String]) {
            var said: [String] = []
            let ok = LlamaCppAgent.follow(
                trigger, server: server, control: agent, audit: audit, source: "cli", say: { said.append($0) })
            return (ok, said)
        }
        let off = FakeAgent(state: .notRegistered)
        let on = run(.server, .wisp, off)
        #expect(on.ok && off.calls == ["register"] && on.said.first?.hasPrefix("registering") == true)
        let registered = FakeAgent(state: .registered)
        #expect(run(.server, .off, registered).said.first?.hasPrefix("unregistering") == true)
        #expect(registered.calls == ["unregister"])
        let none = FakeAgent(state: .notRegistered)
        #expect(run(.server, .llamaApp, none).said.isEmpty && none.calls.isEmpty)
        let setting = FakeAgent(state: .registered)
        #expect(run(.setting("llamacpp.serverSlots"), .wisp, setting).said.first?.contains("serverSlots") == true)
        #expect(run(.models("llamacpp:q"), .wisp, setting).ok && setting.calls == ["restart", "restart"])
        // Under another server, or not registered, a setting restarts nothing.
        let idle = FakeAgent(state: .notRegistered)
        _ = run(.setting("llamacpp.serverPort"), .wisp, idle)
        _ = run(.setting("llamacpp.serverPort"), .off, setting)
        #expect(idle.calls.isEmpty && setting.calls.count == 2)
        let uninstalled = FakeAgent(state: .requiresApproval)
        _ = run(.uninstall, .wisp, uninstalled)
        #expect(uninstalled.calls == ["unregister"])
        // No agent here: said, and nothing done.
        let manual = FakeAgent(state: .manual("a scratch home"), means: .manual("a scratch home"))
        let skipped = run(.server, .wisp, manual)
        #expect(skipped.ok && manual.calls.isEmpty && skipped.said.first?.contains("wisp llamacpp serve") == true)
        let refused = FakeAgent(state: .notRegistered, means: .refused("on the disk image"))
        #expect(!run(.server, .wisp, refused).ok && refused.calls.isEmpty)
        // A failure is said and recorded.
        let failing = FakeAgent(state: .notRegistered, failure: .loginItem("not allowed"))
        let failed = run(.server, .wisp, failing)
        #expect(!failed.ok && failed.said.last == "error: the Login Item could not be changed: not allowed")
        let actions = sink.events.filter { $0.kind == .llamaCppAgent }
        #expect(actions.map { $0.details["action"] ?? .null }.contains("register"))
        #expect(actions.last?.details["outcome"] == "failed" && actions.last?.details["trigger"] == "llamacpp.server")
    }

    @Test func onlyThePersonTurnsTheServerOnOrChangesIt() {
        let policy = CommandPolicy()
        for command in [
            "wisp config set llamacpp.server wisp", "wisp config unset llamacpp.server",
            "wisp config set llamacpp.serverPort 9000", "wisp 'config' set llamacpp.serverContextLength 4096",
        ] {
            #expect(policy.check(command) != .allowed, "\(command)")
        }
        #expect(policy.check("wisp config get llamacpp.server") == .allowed)
    }
}

/// `launchctl` as far as the file agent uses it: `print` succeeds while loaded, and every call is recorded; or, given
/// a failure, every call fails with it.
final class FakeLaunchctl: Sendable {
    /// The calls, in order, and whether the agent is loaded.
    private let state = Mutex<(calls: [[String]], loaded: Bool)>(([], false))
    /// The status and output every call fails with, if any.
    private let failure: (status: Int32, output: String)?

    /// A `launchctl` that succeeds, or fails every call with `status` and `output`.
    init(failing status: Int32? = nil, output: String = "") {
        failure = status.map { ($0, output) }
    }

    /// The calls so far.
    var calls: [[String]] { state.withLock { $0.calls } }

    /// Runs one call.
    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        state.withLock { state in
            state.calls.append(arguments)
            if let failure { return failure }
            switch arguments.first {
            case "bootstrap": state.loaded = true
            case "bootout": state.loaded = false
            case "print": return (state.loaded ? 0 : 113, "")
            default: break
            }
            return (0, "")
        }
    }
}

/// A LaunchAgent control that records what it is asked, and changes its state as the real ones would.
final class FakeAgent: LlamaCppAgentControl {
    /// The calls, in order.
    private let log = Mutex<[String]>([])
    /// The state now.
    private let current: Mutex<LlamaCppAgent.State>
    /// The means it reports.
    let means: LlamaCppAgent.Means
    /// What every action throws, if anything.
    let failure: LlamaCppAgent.Failure?

    /// A control in `state`.
    init(
        state: LlamaCppAgent.State, means: LlamaCppAgent.Means = .manual("fake"), failure: LlamaCppAgent.Failure? = nil
    ) {
        current = Mutex(state)
        self.means =
            if case .manual("fake") = means {
                .launchAgent(program: URL(filePath: "/w"), file: URL(filePath: "/f"))
            } else { means }
        self.failure = failure
    }

    /// The calls so far.
    var calls: [String] { log.withLock { $0 } }

    /// The state now.
    func state() -> LlamaCppAgent.State { current.withLock { $0 } }

    /// Records a call and throws the failure, if any.
    private func call(_ name: String, becoming state: LlamaCppAgent.State?) throws {
        log.withLock { $0.append(name) }
        if let failure { throw failure }
        if let state { current.withLock { $0 = state } }
    }

    /// Registers.
    func register() throws { try call("register", becoming: .registered) }
    /// Unregisters.
    func unregister() throws { try call("unregister", becoming: .notRegistered) }
    /// Restarts.
    func restart() throws { try call("restart", becoming: nil) }
}
