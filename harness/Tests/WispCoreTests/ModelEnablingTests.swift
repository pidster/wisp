import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A backend under `enabling:` with a model that resolves (`up`), one that is never there (`down`), and a cached
/// model (`cached`) that is listed until linked, and resolves once it is.
private struct EnablingBackend: ModelBackend {
    let scheme = "enabling"
    /// Whether `cached` has been linked, shared by every copy.
    let linked: LinkedFlag

    final class LinkedFlag: Sendable {
        let value = Mutex(false)
    }

    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let selection = ModelSelection.local(backend: scheme, name: name)
        guard name == "up" || (name == "cached" && linked.value.withLock { $0 }) else {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: "no such server.")
        }
        return ResolvedModel(selection: selection, custom: ScriptedModel(steps: [.say("from \(name)")]))
    }

    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        [InstalledModel(selection: .local(backend: scheme, name: "up"), detail: "")]
    }

    func unlinked(config: Config.Resolved, home: Home) -> [InstalledModel] {
        linked.value.withLock { $0 }
            ? [] : [.init(selection: .local(backend: scheme, name: "cached"), detail: "", location: .hubCacheNotLinked)]
    }

    func link(_ name: String, config: Config.Resolved, home: Home) throws -> ModelLink {
        linked.value.withLock { $0 = true }
        return ModelLink(
            selection: .local(backend: scheme, name: name), repository: "mlx-community/\(name)",
            snapshot: "/cache/snap",
            destination: "/models/\(name)", files: 3, bytes: 300, outcome: "created")
    }

    func settings(in config: Config.Resolved, home: Home) -> JSONValue { [:] }
}

@Suite(.serialized) struct ModelEnablingTests {
    private static let flag = EnablingBackend.LinkedFlag()
    private let up = ModelSelection.local(backend: "enabling", name: "up")
    private let down = ModelSelection.local(backend: "enabling", name: "down")

    init() {
        Self.flag.value.withLock { $0 = false }
        ModelBackends.register(EnablingBackend(linked: Self.flag))
    }

    /// A scratch home with `config` as its file, removed by the caller.
    private func home(_ config: String? = nil) throws -> Home {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-enabling-\(UUID())"))
        try home.ensure()
        // Every HTTP backend offline, so listing and checking models never reach a server on this Mac.
        try Data(OfflineBackends.file(config).utf8).write(to: home.configFile)
        return home
    }

    /// A session of `entryPoint` over `home`, recording to `sink`.
    private func session(
        _ home: Home, sink: MemoryAuditSink = MemoryAuditSink(), entryPoint: EntryPoint = .chat,
        model: ModelSelection? = nil
    ) throws -> Session {
        try Session.begin(.init(entryPoint: entryPoint, model: model), home: home, dependencies: .testing(sink: sink))
    }

    /// The decoded `config.json` of `home`.
    private func file(_ home: Home) throws -> Config { try Config.load(from: home.configFile) }

    @Test func aDisabledModelIsRefusedWhereverItIsChosen() throws {
        let home = try home(#"{"models":{"disabled":["enabling:up"]}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(try file(home).models?.disabled == [up])
        #expect(Config(models: .init(disabled: [up])).resolved.disabledModels == [up])
        // --model, at the start of a session.
        #expect(throws: ModelSelection.Failure.disabled(model: "enabling:up")) { try session(home, model: up) }
        // /model and an MCP caller's model, when the conversation opens on it.
        let session = try session(home)
        let thread = try session.thread(id: "t", approver: DenyingApprover(reason: "x"), model: up)
        #expect(throws: ModelSelection.Failure.disabled(model: "enabling:up")) { try thread.openAgent() }
        #expect(throws: ModelSelection.Failure.disabled(model: "enabling:up")) {
            try session.openAgent(approver: DenyingApprover(reason: "x"), model: up)
        }
        #expect("\(ModelSelection.Failure.disabled(model: "x:y"))".contains("wisp models enable x:y"))
        // The file's own default: refused when the file loads.
        try Data(#"{"model":"enabling:up","models":{"disabled":["enabling:up"]}}"#.utf8).write(to: home.configFile)
        do {
            _ = try Session.loadConfig(home: home)
            Issue.record("a file disabling its default loaded")
        } catch let failure as Session.Failure {
            #expect("\(failure)".contains("enabling:up is the default model, so it cannot be disabled"))
        }
        // `system` is the default when the file names none.
        #expect(Config(models: .init(disabled: [.system])).disabledDefault == .system)
        #expect(Config(model: up, models: .init(disabled: [.system])).disabledDefault == nil)
    }

    @Test func configSetRefusesADisabledDefaultEitherWayRound() throws {
        let disabling = #"{"models":{"disabled":["enabling:up"]}}"#
        #expect(throws: ConfigEdit.Failure.refused(.disabled(model: "enabling:up"))) {
            try ConfigEdit.set("model", to: "enabling:up", in: Data(disabling.utf8))
        }
        #expect(throws: ConfigEdit.Failure.refused(.defaultDisabled(model: "system"))) {
            try ConfigEdit.set("models.disabled", to: "system", in: nil)
        }
        let outcome = try ConfigEdit.set("models.disabled", to: "enabling:up, private-cloud", in: nil)
        #expect(outcome.new == ["enabling:up", "private-cloud"])
        #expect(ConfigSettings.setting("models.disabled")?.kind == .models)
        #expect(ConfigSettings.defaultValue("models.disabled") == .array([]))
    }

    @Test func enablingAndDisablingWritesTheFileAuditsAndHoldsInTheSessionAtOnce() throws {
        let home = try home(#"{"ollama":{"baseURL":"http://127.0.0.1:9"}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        let lines = try session.setModels(enable: [], disable: ["enabling:up", "private-cloud"], source: "chat")
        #expect(
            lines == [
                "disabled enabling:up: hidden from /model and refused until enabled",
                "disabled private-cloud: hidden from /model and refused until enabled",
            ])
        #expect(try file(home).models?.disabled == [up, .privateCloud])
        #expect(try file(home).ollama?.baseURL == "http://127.0.0.1:9")  // the rest of the file is kept
        let change = try #require(sink.events.last { $0.kind == .configChange })
        #expect(change.details["path"] == "models.disabled" && change.details["source"] == "chat")
        #expect(change.details["old"] == .null && change.details["new"] == ["enabling:up", "private-cloud"])
        // This session refuses it now, without a restart.
        #expect(session.disabledModels.contains(up))
        #expect(throws: ModelSelection.Failure.disabled(model: "enabling:up")) {
            try session.openAgent(approver: DenyingApprover(reason: "x"), model: up)
        }
        // Again: nothing to write. Then on: the last one taken out removes the setting.
        #expect(
            try session.setModels(enable: [], disable: ["enabling:up"], source: "cli") == ["enabling:up is disabled"])
        #expect(sink.events.filter { $0.kind == .configChange }.count == 1)
        #expect(
            try session.setModels(enable: ["enabling:up", "private-cloud"], disable: [], source: "cli") == [
                "enabled enabling:up", "enabled private-cloud",
            ])
        #expect(try file(home).models == nil)
        #expect(!session.disabledModels.contains(up))
        _ = try session.openAgent(approver: DenyingApprover(reason: "x"), model: up)
        #expect(
            try session.setModels(enable: ["enabling:up"], disable: [], source: "cli") == ["enabling:up is enabled"])
        // The default cannot be disabled, and nothing changes when it is asked for with others.
        #expect(throws: ModelSelection.Failure.defaultDisabled(model: "system")) {
            try session.setModels(enable: [], disable: ["enabling:up", "system"], source: "cli")
        }
        #expect(try file(home).models == nil && !session.disabledModels.contains(up))
        #expect(throws: ModelSelection.Failure.self) {
            try session.setModels(enable: ["gpt"], disable: [], source: "cli")
        }
    }

    @Test func enablingACachedModelLinksItWithoutADownload() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        let cached = ModelSelection.local(backend: "enabling", name: "cached")
        let before = await ModelListing.entries(config: session.config, home: home, tools: [])
        #expect(before.entries.first { $0.selection == cached }?.linked == false)
        let lines = try session.setModels(enable: ["enabling:cached"], disable: [], source: "chat")
        #expect(
            lines == [
                "linked enabling:cached: /models/cached → /cache/snap in the Hugging Face cache; nothing was downloaded",
                "enabling:cached is enabled",
            ])
        let pull = try #require(sink.events.last { $0.kind == .modelPull })
        #expect(pull.details["outcome"] == "linked" && pull.details["fetched"] == 0 && pull.details["reused"] == 3)
        #expect(pull.details["link"] == "created" && pull.details["repository"] == "mlx-community/cached")
        #expect(!sink.events.contains { $0.kind == .configChange })  // it was not disabled, only not linked
        let after = await ModelListing.entries(config: session.config, home: home, tools: [])
        #expect(after.entries.first { $0.selection == cached } == nil)  // not installed by this fake, nor cached
        _ = try session.openAgent(approver: DenyingApprover(reason: "x"), model: cached)
    }

    @Test func chatFallsBackToSystemWhenItsConfiguredModelIsUnavailable() throws {
        let home = try home(#"{"model":"enabling:down"}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        let system = { (selection: ModelSelection) in
            ResolvedModel(selection: selection, custom: ScriptedModel(steps: [.say("from system")]))
        }
        let host = session.host(approver: DenyingApprover(reason: "x"))
        let (agent, fallback) = try session.openChatAgent(host: host, resolveFallback: system)
        #expect(agent.model.selection == .system)
        #expect(fallback == ModelFallback(model: down, reason: "no such server.", fallback: .system))
        #expect(
            fallback?.message
                == "enabling:down is unavailable (no such server); using system. /model enabling:down once it is available"
        )
        #expect(
            ModelFallback(model: .ollama("granite4.1:8b"), reason: "no Ollama server at http://x").message
                == "ollama:granite4.1:8b is unavailable (no Ollama server at http://x); using system. "
                + "/model ollama:granite4.1:8b once Ollama is running")
        let event = try #require(sink.events.first { $0.kind == .modelFallback })
        #expect(event.details == ["model": "enabling:down", "reason": "no such server.", "fallback": "system"])
        #expect(sink.events.last { $0.kind == .modelResolved }?.details["model"] == "system")
        #expect(Set(event.details.keys) == AuditEvent.fields(for: .modelFallback))
        // respond's path, and an MCP thread's, never fall back: the configured model's failure, as it was.
        #expect(throws: ModelSelection.Failure.unavailable(model: "enabling:down", reason: "no such server.")) {
            try session.openAgent(host: host)
        }
        let thread = try session.thread(id: "t", host: host)
        #expect(throws: ModelSelection.Failure.self) { try thread.openAgent() }
        #expect(sink.events.filter { $0.kind == .modelFallback }.count == 1)
    }

    @Test func chatFailsAsBeforeWhenTheModelWasNamedOrNothingCanServe() throws {
        let home = try home(#"{"model":"enabling:down"}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let system = { (selection: ModelSelection) in
            ResolvedModel(selection: selection, custom: ScriptedModel(steps: [.say("from system")]))
        }
        // --model names it: the person asked for that model.
        let named = try session(home, model: down)
        #expect(throws: ModelSelection.Failure.unavailable(model: "enabling:down", reason: "no such server.")) {
            try named.openChatAgent(host: named.host(approver: DenyingApprover(reason: "x")), resolveFallback: system)
        }
        // system is unavailable too: the configured model's failure.
        let session = try session(home)
        let host = session.host(approver: DenyingApprover(reason: "x"))
        #expect(throws: ModelSelection.Failure.unavailable(model: "enabling:down", reason: "no such server.")) {
            try session.openChatAgent(host: host) { _ in
                throw ModelSelection.Failure.unavailable(model: "system", reason: "not ready")
            }
        }
        // system is disabled: no fallback either.
        try Data(#"{"model":"enabling:down","models":{"disabled":["system"]}}"#.utf8).write(to: home.configFile)
        let refusing = try self.session(home)
        #expect(throws: ModelSelection.Failure.self) {
            try refusing.openChatAgent(
                host: refusing.host(approver: DenyingApprover(reason: "x")), resolveFallback: system)
        }
        // A missing capability is not unavailability: no fallback.
        #expect(
            ModelFallback.after(
                .unsupportedCapability(model: "m", capability: "tool calling", declaredBy: .runtime, hint: ""),
                configured: down, named: false) == nil)
        #expect(ModelFallback.after(.unknownBackend("x", registered: []), configured: down, named: false) != nil)
        #expect(
            ModelFallback.after(.unavailable(model: "system", reason: "r"), configured: .system, named: false) == nil)
        // The configured model is there: no fallback.
        try Data(#"{"model":"enabling:up"}"#.utf8).write(to: home.configFile)
        let fine = try self.session(home)
        let (agent, fallback) = try fine.openChatAgent(host: fine.host(approver: DenyingApprover(reason: "x")))
        #expect(agent.model.selection == up && fallback == nil)
    }

    @Test func theProtocolCarriesAChoiceWithToggles() throws {
        let choice = ChatChoice(
            title: "Models", options: [.init(value: "a", cells: ["a", "x"], on: true), .init(value: "b", on: false)],
            current: "a", columns: [.init(heading: "MODEL"), .init(heading: "SIZE", drop: 6)])
        let fields = ChatProtocol.choice(id: "c", choice)
        #expect(fields["toggles"] == true)
        #expect(fields["columns"] == [["heading": "MODEL", "drop": 0], ["heading": "SIZE", "drop": 6]])
        #expect(fields["options"]?.arrayValue?.first?.objectValue?["cells"] == ["a", "x"])
        #expect(fields["options"]?.arrayValue?.first?.objectValue?["on"] == true)
        // A plain choice has none of it.
        let plain = ChatProtocol.choice(id: "p", ChatChoice(title: "t", options: [.init(value: "a")]))
        #expect(plain["toggles"] == nil && plain["columns"] == nil)
        #expect(plain["options"]?.arrayValue?.first?.objectValue?["on"] == nil)
        // The answer is the values left on; a single value or none is not one.
        let answer = ChatProtocol.Inbound(line: #"{"type":"choose","id":"c","values":["a","b"]}"#)
        guard case .answer(let id, let decision) = answer else {
            Issue.record("not an answer")
            return
        }
        #expect(id == "c" && ChatChoice.values(answer: decision) == ["a", "b"])
        let none = ChatProtocol.Inbound(line: #"{"type":"choose","id":"c","values":[]}"#)
        if case .answer(_, let decision) = none { #expect(ChatChoice.values(answer: decision) == []) }
        #expect(ChatChoice.values(answer: "a") == nil && ChatChoice.values(answer: nil) == nil)
    }

    @Test func aDisabledModelIsRefusedUnderEverySpellingOfIt() throws {
        // Ollama: a name without a tag is `:latest`; a registry's port is no tag.
        let ollama = DisabledModels([.ollama("granite4.1"), .ollama("host:5000/team/m")])
        #expect(ollama.contains(.ollama("granite4.1:latest")) && ollama.contains(.ollama("granite4.1")))
        #expect(!ollama.contains(.ollama("granite4.1:8b")))
        #expect(ollama.contains(.ollama("host:5000/team/m:latest")))
        #expect(DisabledModels([.ollama("hf.co/org/m:latest")]).contains(.ollama("hf.co/org/m")))
        // llama.cpp: a model listed by its file's path is also named by the file's name without `.gguf`.
        let path = ModelSelection.local(backend: "llamacpp", name: "/models/Qwen3-8B-Q4_K_M.gguf")
        let short = ModelSelection.local(backend: "llamacpp", name: "Qwen3-8B-Q4_K_M")
        #expect(DisabledModels([path]).contains(short) && DisabledModels([short]).contains(path))
        // A path name of a backend this build does not register, by its real path: `~` and links resolved.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "m"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(
            at: dir.appending(path: "link"), withDestinationURL: dir.appending(path: "m"))
        let real = ModelSelection.local(backend: "unregistered", name: dir.appending(path: "m").path)
        let linked = ModelSelection.local(backend: "unregistered", name: dir.appending(path: "link").path)
        #expect(DisabledModels([real]).contains(linked))
        let tilde = ModelSelection.local(backend: "unregistered", name: "~/wisp-alias-model")
        let expanded = ModelSelection.local(
            backend: "unregistered",
            name: FileManager.default.homeDirectoryForCurrentUser.appending(path: "wisp-alias-model").path)
        #expect(DisabledModels([tilde]).contains(expanded))
    }

    @Test func everyEntryRefusesAnAliasAndEnablingOneSpellingEnablesTheModel() throws {
        let home = try home(#"{"models":{"disabled":["ollama:granite4.1"]}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let tagged = ModelSelection.ollama("granite4.1:latest")
        // --model, at the start of a session, and the thread an MCP caller or /model opens.
        #expect(throws: ModelSelection.Failure.disabled(model: "ollama:granite4.1:latest")) {
            try session(home, model: tagged)
        }
        let session = try session(home)
        let thread = try session.thread(id: "t", approver: DenyingApprover(reason: "x"), model: tagged)
        #expect(throws: ModelSelection.Failure.disabled(model: "ollama:granite4.1:latest")) { try thread.openAgent() }
        // Enabling it under the other spelling takes it out of the file.
        let lines = try session.setModels(enable: ["ollama:granite4.1:latest"], disable: [], source: "chat")
        #expect(lines == ["enabled ollama:granite4.1:latest"])
        #expect(try file(home).models?.disabled == nil)
        #expect(!session.disabledModels.contains(tagged))
        // Disabling one spelling and then the other keeps one entry; enabling the first spelling removes it.
        try session.setDisabled(.ollama("granite4.1"), true, source: "chat")
        try session.setDisabled(tagged, true, source: "chat")
        #expect(try file(home).models?.disabled == [tagged])
        try session.setDisabled(.ollama("granite4.1"), false, source: "chat")
        #expect(try file(home).models?.disabled == nil)
        // The default under another spelling cannot be disabled, by setModels or setDisabled, nor by the file.
        try Data(OfflineBackends.file(#"{"model":"ollama:granite4.1"}"#).utf8).write(to: home.configFile)
        #expect(throws: ModelSelection.Failure.defaultDisabled(model: "ollama:granite4.1:latest")) {
            try session.setModels(enable: [], disable: ["ollama:granite4.1:latest"], source: "chat")
        }
        #expect(throws: ModelSelection.Failure.defaultDisabled(model: "ollama:granite4.1:latest")) {
            try session.setDisabled(tagged, true, source: "chat")
        }
        try Data(#"{"model":"ollama:granite4.1","models":{"disabled":["ollama:granite4.1:latest"]}}"#.utf8).write(
            to: home.configFile)
        #expect(throws: ModelSelection.Failure.defaultDisabled(model: "ollama:granite4.1")) {
            try Config.load(from: home.configFile)
        }
        #expect(
            Config(model: .ollama("granite4.1"), models: .init(disabled: [tagged])).disabledDefault
                == .ollama("granite4.1"))
    }
}
