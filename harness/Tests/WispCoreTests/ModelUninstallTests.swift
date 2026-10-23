import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A backend under `gone:` whose models are folders under a scratch root's `models`, with a Hugging Face cache at its
/// `hub`, planned as MLX's are.
private struct GoneBackend: ModelBackend {
    let scheme = "gone"
    /// The scratch root, shared by every copy.
    static let root = Mutex<URL?>(nil)

    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        ResolvedModel(selection: .local(backend: scheme, name: name), custom: ScriptedModel(steps: [.say("hi")]))
    }

    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] { [] }

    func settings(in config: Config.Resolved, home: Home) -> JSONValue { [:] }

    func removal(_ name: String, config: Config.Resolved, home: Home, purgeCache: Bool) async throws -> ModelRemoval {
        let root = try #require(Self.root.withLock { $0 })
        return try ModelRemoval.folder(
            model: "gone:\(name)", entry: root.appending(path: "models/\(name)"),
            cacheRoot: root.appending(path: "hub"),
            purgeCache: purgeCache)
    }
}

/// Answers Ollama's tags and delete at `gone.ollama`, recording each request's method, path, and body.
private final class GoneOllama: URLProtocol {
    /// Requests seen.
    static let seen = Mutex<[(method: String, path: String, body: String)]>([])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "gone.ollama" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let path = request.url?.path() ?? ""
        Self.seen.withLock {
            $0.append((request.httpMethod ?? "", path, String(decoding: body, as: UTF8.self)))
        }
        let reply =
            path == "/api/tags"
            ? #"{"models":[{"name":"old:latest","size":2020000000},{"name":"kept:8b","size":5}]}"# : "{}"
        let status = path == "/api/delete" && String(decoding: body, as: UTF8.self).contains("missing") ? 404 : 200
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `wisp models uninstall` and `/models uninstall` (ADR 0075): each backend's plan, the steps, the typed confirmation,
/// the settings cleared, and the audit; nothing reaches a real runtime or the Bin.
@Suite(.serialized) struct ModelUninstallTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "wisp-uninstall-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appending(path: "models"), withIntermediateDirectories: true)
        GoneBackend.root.withLock { [root] in $0 = root }
        ModelBackends.register(GoneBackend())
    }

    /// A snapshot of `models--org--name` in the scratch cache, its one file a link to a blob of `bytes` bytes, and the
    /// models folder's `name` linked to it.
    @discardableResult
    private func cached(_ name: String, bytes: Int = 1000) throws -> URL {
        let repository = root.appending(path: "hub/models--org--\(name)")
        let snapshot = repository.appending(path: "snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repository.appending(path: "blobs"), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: repository.appending(path: "blobs/b1"))
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appending(path: "model.safetensors").path, withDestinationPath: "../../blobs/b1")
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "models/\(name)").path, withDestinationPath: snapshot.path)
        return repository
    }

    @Test func aLinkIntoTheCacheIsUnlinkedAndTheCacheKeptUnlessPurged() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try cached("q")
        let entry = root.appending(path: "models/q")
        let hub = root.appending(path: "hub")
        let kept = try ModelRemoval.folder(model: "gone:q", entry: entry, cacheRoot: hub, purgeCache: false)
        #expect(kept.steps == [.unlink(entry, pointsTo: repository.appending(path: "snapshots/abc"))])
        #expect(kept.bytes == 0 && kept.kept.first?.contains("--purge-cache removes it too") == true)
        let purged = try ModelRemoval.folder(model: "gone:q", entry: entry, cacheRoot: hub, purgeCache: true)
        #expect(purged.steps.last == .purge(repository) && purged.bytes == 1000 && purged.kept.isEmpty)
        // The blob counts once: the snapshot's link to it is not followed.
        #expect(ModelRemoval.size(of: repository) == 1000 && ModelRemoval.size(of: entry) == 0)
    }

    /// Another tool may keep blobs in a store at the cache's root and link a repository's blobs to it: the plan names
    /// and sizes them, and a purge removes the repository's folder alone, leaving the store and its lists as they were.
    @Test func aPurgeLeavesTheCachesSharedStoreAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = root.appending(path: "hub")
        let store = hub.appending(path: "blobs/2d")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data(count: 5000).write(to: store.appending(path: "weights"))
        try Data("models--org--q/blobs/weights\n".utf8).write(to: store.appending(path: "weights.refs"))
        let repository = try cached("q", bytes: 10)
        try FileManager.default.createSymbolicLink(
            atPath: repository.appending(path: "blobs/weights").path, withDestinationPath: "../../blobs/2d/weights")
        let entry = root.appending(path: "models/q")
        let kept = try ModelRemoval.folder(model: "gone:q", entry: entry, cacheRoot: hub, purgeCache: false)
        #expect(
            kept.kept.first
                == "5 KB of its files are in \(hub.path)/blobs, a store another tool keeps; wisp leaves it to that tool"
        )
        let plan = try ModelRemoval.folder(model: "gone:q", entry: entry, cacheRoot: hub, purgeCache: true)
        #expect(plan.steps.last == .purge(repository) && plan.bytes == 10 && plan.kept.count == 1)
        try await plan.perform(
            ollama: OllamaSettings(baseURL: URL(filePath: "/"), timeout: .seconds(1)), report: { _ in })
        #expect(!FileManager.default.fileExists(atPath: repository.path))
        #expect(FileManager.default.fileExists(atPath: store.appending(path: "weights").path))
        #expect(
            try String(contentsOf: store.appending(path: "weights.refs"), encoding: .utf8)
                == "models--org--q/blobs/weights\n")
    }

    @Test func aRealFolderGoesToTheBinAndNothingThereIsNotInstalled() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "models/bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 300).write(to: folder.appending(path: "weights"))
        let plan = try ModelRemoval.folder(model: "gone:bundle", entry: folder, cacheRoot: nil, purgeCache: true)
        #expect(plan.steps == [.trash(folder)] && plan.bytes == 300)
        #expect(plan.kept == ["--purge-cache does nothing here: the model is a folder, not a link into a cache"])
        let elsewhere = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = root.appending(path: "models/linked")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: elsewhere.path)
        let outside = try ModelRemoval.folder(
            model: "gone:linked", entry: link, cacheRoot: root.appending(path: "hub"), purgeCache: true)
        #expect(
            outside.steps == [.unlink(link, pointsTo: elsewhere)]
                && outside.kept.first?.contains("does nothing") == true)
        #expect(throws: ModelRemoval.Failure.self) {
            try ModelRemoval.folder(
                model: "gone:none", entry: root.appending(path: "models/none"), cacheRoot: nil, purgeCache: false)
        }
    }

    @Test func theStepsAreCarriedOutInOrder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try cached("q")
        let folder = root.appending(path: "models/bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = root.appending(path: "models/q")
        let plan = ModelRemoval(
            model: "gone:q",
            steps: [
                .ollama("old:latest"), .unlink(entry, pointsTo: repository), .trash(folder),
                .purge(repository),
            ],
            bytes: 1)
        let binned = Mutex<[URL]>([])
        let deleted = Mutex<[String]>([])
        var lines: [String] = []
        try await plan.perform(
            ollama: OllamaSettings(baseURL: URL(filePath: "/"), timeout: .seconds(1)), report: { lines.append($0) },
            trash: { url in binned.withLock { $0.append(url) } },
            delete: { name, _ in deleted.withLock { $0.append(name) } })
        #expect(deleted.withLock { $0 } == ["old:latest"] && binned.withLock { $0 } == [folder])
        #expect(
            !FileManager.default.fileExists(atPath: entry.path)
                && !FileManager.default.fileExists(atPath: repository.path))
        #expect(lines.count == 4 && lines[0] == "deleted old:latest from Ollama")
        #expect(ModelRemoval.Step.purge(repository).described.hasSuffix("every revision, removed"))
    }

    /// Ollama's model is found under its tag and deleted through `DELETE /api/delete`; one Ollama does not list is not
    /// installed; llama.cpp's, LM Studio's, and a runtime's own are refused.
    @Test func ollamaDeletesThroughItsAPIAndServersKeepTheirOwn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(URLProtocol.registerClass(GoneOllama.self))
        defer { URLProtocol.unregisterClass(GoneOllama.self) }
        GoneOllama.seen.withLock { $0 = [] }
        var config = Config().resolved
        config.ollama = OllamaSettings(
            baseURL: URL(string: "http://gone.ollama") ?? URL(filePath: "/"), timeout: .seconds(5))
        let home = Home(root: root)
        let plan = try await OllamaBackend().removal("old", config: config, home: home, purgeCache: true)
        #expect(
            plan.model == "ollama:old:latest" && plan.steps == [.ollama("old:latest")] && plan.bytes == 2_020_000_000)
        #expect(plan.kept.first?.contains("Ollama") == true)
        await #expect(throws: ModelRemoval.Failure.self) {
            try await OllamaBackend().removal("absent", config: config, home: home, purgeCache: false)
        }
        try await OllamaModel.delete("old:latest", at: config.ollama)
        let delete = try #require(GoneOllama.seen.withLock { $0 }.last)
        #expect(delete.method == "DELETE" && delete.path == "/api/delete" && delete.body == #"{"model":"old:latest"}"#)
        await #expect(throws: OllamaModel.Failure.self) { try await OllamaModel.delete("missing", at: config.ollama) }
        for dialect in [OpenAICompatibleDialect.llamaCpp, .lmStudio] {
            await #expect(throws: ModelRemoval.Failure.self) {
                try await OpenAICompatibleBackend(dialect).removal("m", config: config, home: home, purgeCache: false)
            }
        }
        let refusal = ModelRemoval.Failure.notWisps(model: "llamacpp:m", reason: "delete the file")
        #expect("\(refusal)" == "llamacpp:m is not wisp's to remove: delete the file")
    }

    /// A scratch home whose `config.json` holds `json`, with every HTTP backend offline.
    private func home(_ json: String) throws -> Home {
        let home = Home(root: root.appending(path: "home"))
        try home.ensure()
        try Data(OfflineBackends.file(json).utf8).write(to: home.configFile)
        return home
    }

    /// The person types the name to go ahead; anything else, or nobody to ask, leaves the model and its settings; the
    /// model's tool is refused; once removed, its settings and disabled entry are cleared and it is all audited.
    @Test func theTypedNameGoesAheadAndEverythingIsAudited() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try cached("q")
        try cached("r")
        let home = try home(
            #"{"model":"gone:q","gone":{"models":{"q":{"think":false}}},"models":{"disabled":["gone:r"]}}"#)
        let sink = MemoryAuditSink()
        let session = try Session.begin(
            .init(entryPoint: .models, model: .system), home: home, dependencies: .testing(sink: sink))
        defer { session.end() }
        let shown = Mutex<[String]>([])
        func dialog(typing: String?, interactive: Bool = true) -> ModelActions.UninstallDialog {
            .init(
                interactive: interactive, show: { line in shown.withLock { $0.append(line) } }, typed: { _ in typing })
        }
        let link = root.appending(path: "models/q")
        let actions = ModelActions(session: session, face: .cli)

        let declined = try await actions.uninstall(
            "gone:q", purgeCache: false, yes: false, dialog: dialog(typing: "no"))
        #expect(!declined)
        #expect(FileManager.default.fileExists(atPath: link.path))
        let plan = shown.withLock { $0 }
        #expect(plan.first == "uninstalling gone:q removes:")
        #expect(plan.contains("  from config.json: gone.models.q"))
        #expect(plan.contains { $0.hasPrefix("warning: gone:q is the default model") })
        #expect(plan.last == "left gone:q as it was")
        #expect(sink.events.last?.kind == .modelUninstall && sink.events.last?.details["outcome"] == "declined")

        await #expect(throws: ModelActions.UninstallFailure.notInteractive("gone:q")) {
            try await actions.uninstall(
                "gone:q", purgeCache: false, yes: false, dialog: dialog(typing: nil, interactive: false))
        }
        await #expect(throws: ModelActions.Failure.self) {
            try await ModelActions(session: session, face: .tool).uninstall(
                "gone:q", purgeCache: false, yes: true, dialog: dialog(typing: nil))
        }
        await #expect(throws: ModelRemoval.Failure.self) {
            try await actions.uninstall("system", purgeCache: false, yes: true, dialog: dialog(typing: nil))
        }

        let removedIt = try await actions.uninstall(
            "gone:q", purgeCache: true, yes: false, dialog: dialog(typing: " gone:q "))
        #expect(removedIt)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "hub/models--org--q").path))
        #expect(!String(decoding: try Data(contentsOf: home.configFile), as: UTF8.self).contains(#""q""#))
        #expect(sink.events.suffix(2).map(\.kind) == [.configChange, .modelUninstall])
        let removed = try #require(sink.events.last)
        #expect(removed.kind == .modelUninstall && removed.details["outcome"] == "removed")
        #expect(
            removed.details["purgeCache"] == true && removed.details["bytes"] == 1000
                && removed.details["source"] == "cli")

        // A disabled model's entry is cleared too; --yes asks nothing.
        shown.withLock { $0 = [] }
        let removedR = try await actions.uninstall("gone:r", purgeCache: false, yes: true, dialog: dialog(typing: nil))
        #expect(removedR)
        #expect(shown.withLock { $0 }.contains("  from config.json: its models.disabled entry"))
        #expect(shown.withLock { $0 }.last == "cleared gone:r from models.disabled")
        #expect(!String(decoding: try Data(contentsOf: home.configFile), as: UTF8.self).contains("disabled"))
        #expect(session.disabledModels.all.isEmpty)

        // A model already gone is not installed.
        await #expect(throws: ModelRemoval.Failure.self) {
            try await actions.uninstall("gone:q", purgeCache: false, yes: true, dialog: dialog(typing: nil))
        }
    }

    /// In chat, the plan is noted and the name typed at the prompt; a wrong name leaves the model, the right one
    /// removes it.
    @Test func chatAsksForTheNameAtThePrompt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try cached("q")
        let home = try home("{}")
        let session = try Session.begin(
            .init(entryPoint: .chat, model: .system), home: home, dependencies: .testing(sink: MemoryAuditSink()))
        defer { session.end() }
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("hi")])))
        let capture = ChatLoopTests.Capture(lines: [
            "/models uninstall gone:q", "keep it", "/models uninstall gone:q --purge-cache", "gone:q", "/quit",
        ])
        var loop = ChatLoop(
            agent: agent,
            context: .init(directory: "/r", approval: "--yes", models: ModelActions(session: session, face: .chat)),
            io: capture.io)
        try await loop.run()
        let noted = capture.noted
        #expect(noted.contains("uninstalling gone:q removes:") && noted.contains("left gone:q as it was"))
        #expect(noted.contains { $0.hasPrefix("removed the link") })
        #expect(noted.contains { $0.hasPrefix("removed ") && $0.contains("models--org--q") })
        #expect(capture.output.contains("Type gone:q to remove it; anything else leaves it"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "models/q").path))
    }

    @Test func chatParsesUninstallAndThePolicyRefusesItToTheModel() {
        #expect(ModelsRequest("uninstall ollama:x") == .uninstall("ollama:x", purgeCache: false))
        #expect(ModelsRequest("uninstall --purge-cache mlx:q") == .uninstall("mlx:q", purgeCache: true))
        #expect(ModelsRequest("uninstall mlx:q --purge-cache") == .uninstall("mlx:q", purgeCache: true))
        #expect(ModelsRequest("uninstall") == .unknown("uninstall"))
        #expect(ModelsRequest("uninstall --purge-cache") == .unknown("uninstall"))
        #expect(ModelsRequest.usage.hasSuffix("uninstall NAME [--purge-cache]"))
        let policy = CommandPolicy()
        #expect(policy.check("wisp models uninstall ollama:x --yes") != .allowed)
        #expect(policy.check("/opt/homebrew/bin/wisp 'models' uninstall x") != .allowed)
        #expect(policy.check("wisp models list") == .allowed)
        #expect(!ModelActions.Action.uninstall.forModel && ModelActions.Action.uninstall.remembered == nil)
        #expect(
            ModelActions.Action.uninstall.changes?.contains("Bin") == true
                && !ModelActions.Action.uninstall.reads.isEmpty)
        #expect("\(ModelActions.UninstallFailure.notInteractive("m"))".hasSuffix("or pass --yes"))
        #expect(ModelRemoval.formatted(2_020_000_000) == "2.02 GB")
    }
}
