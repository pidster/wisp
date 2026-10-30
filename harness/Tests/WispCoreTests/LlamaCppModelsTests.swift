import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// wisp's llama.cpp models folder (ADR 0082, decision 2): `wisp models add` links a GGUF file in, named as
/// llama-server's router names it; `wisp models` lists the links under `llamacpp.server wisp`, a broken one marked;
/// `wisp models uninstall` removes the link and never the file. Every folder and GGUF file is a scratch one.
@Suite(.serialized) struct LlamaCppModelsTests {
    /// The scratch root: GGUF files under `files`, the home under `home`.
    private let root: URL

    init() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(
            path: "wisp-llamacpp-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch.appending(path: "files"), withIntermediateDirectories: true)
        // Real paths, as a link records them: `/private/var/…`, not `/var/…`.
        root = URL(filePath: CommandPolicy.canonical(scratch.path))
    }

    /// A fake GGUF file under `files`: the magic bytes and some padding, or `head` instead of the magic.
    @discardableResult
    private func gguf(_ name: String, head: String = "GGUF", bytes: Int = 100) throws -> URL {
        let file = root.appending(path: "files/\(name)")
        var data = Data(head.utf8)
        data.append(Data(count: bytes - data.count))
        try data.write(to: file)
        return file
    }

    /// A home under the scratch root whose `config.json` holds `json`, the HTTP backends offline.
    private func home(_ json: String) throws -> Home {
        let home = Home(root: root.appending(path: "home"))
        try home.ensure()
        try Data(OfflineBackends.file(json).utf8).write(to: home.configFile)
        return home
    }

    /// The folder for a scratch home.
    private var models: LlamaCppModels { LlamaCppModels(home: Home(root: root.appending(path: "home"))) }

    @Test func theSupportFolderIsApplicationSupportOnlyForThePersonsOwnHome() {
        let own = Home.resolve(environment: [:])
        #expect(own.support.path.hasSuffix("/Library/Application Support/Wisp"))
        #expect(LlamaCppModels(home: own).folder.path.hasSuffix("/Library/Application Support/Wisp/llamacpp/models"))
        let scratch = Home.resolve(environment: [Home.environmentKey: "/tmp/dh"])
        #expect(scratch.support.path == "/tmp/dh/support")
        #expect(Home(root: URL(filePath: "/x")).support.path == "/x/support")
        #expect(Home(root: URL(filePath: "/x"), support: URL(filePath: "/y")).support.path == "/y")
    }

    /// The link points to the real path, is named after the file, and is made in a folder only the person can open;
    /// the file stays where it is; adding it again changes nothing.
    @Test func addLinksTheFileByItsNameAndAgainChangesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try gguf("Ternary-Bonsai-2-9B-Q2_0.gguf")
        let added = try models.add("files/Ternary-Bonsai-2-9B-Q2_0.gguf", workingDirectory: root)
        #expect(!added.unchanged)
        #expect(added.link.name == "Ternary-Bonsai-2-9B-Q2_0" && added.link.bytes == 100)
        let link = models.folder.appending(path: "Ternary-Bonsai-2-9B-Q2_0.gguf")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)
        let permissions = try FileManager.default.attributesOfItem(atPath: models.folder.path)[.posixPermissions]
        #expect(permissions as? Int == 0o700)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let again = try models.add(file.path, workingDirectory: URL(filePath: "/"))
        #expect(again.unchanged && again.link.name == added.link.name)
        #expect(models.linked().map(\.name) == ["Ternary-Bonsai-2-9B-Q2_0"])
    }

    /// The name comes from the path as given, so a link to a file named otherwise keeps the name the person sees.
    @Test func theNameIsThePathsAsGiven() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = try gguf("blob-0123")
        let named = root.appending(path: "files/Qwen3-8B-Q4_K_M.GGUF")
        try FileManager.default.createSymbolicLink(at: named, withDestinationURL: blob)
        let added = try models.add(named.path, workingDirectory: root)
        #expect(added.link.name == "Qwen3-8B-Q4_K_M" && added.link.target.path == blob.path)
    }

    @Test func addRefusesWhatIsNotAReadableGGUFFileWithAGoodName() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try gguf("plain.bin")
        try gguf("fake.gguf", head: "JUNK")
        try gguf("has space.gguf")
        try gguf(".hidden.gguf")
        try gguf("m.gguf")
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let elsewhere = other.appending(path: "m.gguf")
        try Data("GGUF....".utf8).write(to: elsewhere)
        let files = root.appending(path: "files")

        #expect(throws: LlamaCppModels.Failure.notAFile(files.appending(path: "missing.gguf").path)) {
            try models.add("missing.gguf", workingDirectory: files)
        }
        #expect(throws: LlamaCppModels.Failure.notAFile(files.path)) {
            try models.add(files.path, workingDirectory: root)
        }
        #expect(
            throws: LlamaCppModels.Failure.notGGUF(
                files.appending(path: "plain.bin").path, reason: "its name does not end in .gguf")
        ) {
            try models.add("plain.bin", workingDirectory: files)
        }
        #expect(
            throws: LlamaCppModels.Failure.notGGUF(
                files.appending(path: "fake.gguf").path, reason: "it does not begin with GGUF's magic bytes")
        ) {
            try models.add("fake.gguf", workingDirectory: files)
        }
        #expect(throws: LlamaCppModels.Failure.badName("has space")) {
            try models.add("has space.gguf", workingDirectory: files)
        }
        #expect(throws: LlamaCppModels.Failure.badName(".hidden")) {
            try models.add(".hidden.gguf", workingDirectory: files)
        }
        _ = try models.add("m.gguf", workingDirectory: files)
        #expect(throws: LlamaCppModels.Failure.taken(name: "m", linksTo: files.appending(path: "m.gguf").path)) {
            try models.add(elsewhere.path, workingDirectory: root)
        }
        #expect(models.linked().map(\.name) == ["m"])
        #expect("\(LlamaCppModels.Failure.badName("a b"))".contains("rename the file"))
        #expect("\(LlamaCppModels.Failure.notWispsServer(.llamaApp))".contains("add the model in Llama.app"))
        #expect("\(LlamaCppModels.Failure.notWispsServer(.off))".hasSuffix("set llamacpp.server wisp first"))
    }

    /// A link whose file is gone is listed as broken; uninstalling it, or a whole one, removes the link and never the
    /// file, saying where the file stays.
    @Test func brokenLinksAreMarkedAndRemovalKeepsTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try gguf("kept.gguf")
        let gone = try gguf("gone.gguf")
        _ = try models.add(kept.path, workingDirectory: root)
        _ = try models.add(gone.path, workingDirectory: root)
        try FileManager.default.removeItem(at: gone)
        let links = models.linked()
        #expect(links.map(\.name) == ["gone", "kept"])
        #expect(links.map(\.broken) == [true, false])

        let plan = try models.removal("kept", purgeCache: true)
        #expect(plan.model == "llamacpp:kept" && plan.bytes == 0)
        #expect(plan.steps == [.unlink(models.folder.appending(path: "kept.gguf"), pointsTo: kept)])
        #expect(plan.kept.first == "the GGUF file \(kept.path) stays where it is; wisp never deletes it")
        #expect(plan.kept.last?.hasPrefix("--purge-cache does nothing here") == true)
        try await plan.perform(ollama: .default, report: { _ in })
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(models.link(named: "kept") == nil)

        let broken = try models.removal("gone", purgeCache: false)
        #expect(broken.kept == ["\(gone.path), the file it pointed to, is missing already"])
        #expect(throws: ModelRemoval.Failure.self) { try models.removal("never", purgeCache: false) }
    }

    /// Under `llamacpp.server wisp`, the backend lists the folder rather than a server, resolves only what is linked,
    /// and plans an uninstall as the link; under `off` it lists from the server as before.
    @Test func theBackendReadsTheFolderOnlyUnderWisp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home(#"{"llamacpp":{"server":"wisp"}}"#)
        let file = try gguf("q.gguf")
        let gone = try gguf("gone.gguf")
        _ = try models.add(file.path, workingDirectory: root)
        _ = try models.add(gone.path, workingDirectory: root)
        try FileManager.default.removeItem(at: gone)
        let backend = OpenAICompatibleBackend(.llamaCpp)
        let wisp = try Session.loadConfig(home: home)

        let installed = try await backend.installed(config: wisp, home: home)
        #expect(installed.map(\.selection.description) == ["llamacpp:gone", "llamacpp:q"])
        #expect(installed.map(\.location) == [.brokenLink, .linkedFile])
        #expect(installed.first?.detail == "broken link: \(gone.path) is missing" && installed.last?.bytes == 100)

        #expect(throws: ModelSelection.Failure.self) { try backend.resolve("absent", config: wisp, home: home) }
        #expect(OpenAICompatibleBackend.notServable("absent", home: home)?.contains("wisp models add PATH") == true)
        #expect(OpenAICompatibleBackend.notServable("gone", home: home)?.contains("which is missing") == true)
        #expect(OpenAICompatibleBackend.notServable("q", home: home) == nil)
        // Linked, it gets as far as the server, which is not built yet.
        #expect {
            try backend.resolve("q", config: wisp, home: home)
        } throws: { error in
            "\(error)".contains(LlamaCppServer.notBuilt)
        }
        let plan = try await backend.removal("q", config: wisp, home: home, purgeCache: false)
        #expect(plan.steps.count == 1 && plan.kept.first?.contains("stays where it is") == true)

        let listing = await ModelListing.entries(config: wisp, home: home, tools: [])
        let added = listing.shown(all: false).filter(\.added).map(\.selection.description)
        #expect(added == ["llamacpp:gone", "llamacpp:q"])

        let off = try Session.loadConfig(home: try self.home("{}"))
        await #expect(throws: OpenAICompatibleModel.Failure.self) {
            try await backend.installed(config: off, home: home)
        }
        await #expect(throws: ModelRemoval.Failure.self) {
            try await backend.removal("q", config: off, home: home, purgeCache: false)
        }
    }

    /// `wisp models add` and `/models add` go through `ModelActions.add`: refused under another server's setting and
    /// to the model, each attempt recorded as `model.add`; `uninstall` then removes the link and keeps the file.
    @Test func theActionIsThePersonsAndAudited() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try gguf("q.gguf")
        let sink = MemoryAuditSink()
        let offHome = try home("{}")
        let off = try Session.begin(
            .init(entryPoint: .models, model: .system), home: offHome, dependencies: .testing(sink: sink))
        #expect(throws: LlamaCppModels.Failure.notWispsServer(.off)) {
            try ModelActions(session: off, face: .cli).add(file.path, workingDirectory: root)
        }
        off.end()
        let refused = try #require(sink.events.last { $0.kind == .modelAdd })
        #expect(refused.details["outcome"] == "refused" && refused.details["model"] == .null)

        let home = try home(#"{"llamacpp":{"server":"wisp"}}"#)
        let session = try Session.begin(
            .init(entryPoint: .models, model: .system), home: home, dependencies: .testing(sink: sink))
        defer { session.end() }
        #expect(throws: ModelActions.Failure.self) {
            try ModelActions(session: session, face: .tool).add(file.path, workingDirectory: root)
        }
        let actions = ModelActions(session: session, face: .chat)
        let lines = try actions.add("files/q.gguf", workingDirectory: root)
        #expect(lines.first?.hasPrefix("added llamacpp:q: ") == true)
        let added = try #require(sink.events.last { $0.kind == .modelAdd })
        #expect(
            added.details["outcome"] == "added" && added.details["model"] == "llamacpp:q"
                && added.details["file"] == .string(file.path) && added.details["bytes"] == 100
                && added.details["source"] == "chat")
        #expect(try actions.add(file.path, workingDirectory: root).first?.hasSuffix("nothing changed") == true)
        #expect(sink.events.last { $0.kind == .modelAdd }?.details["outcome"] == "unchanged")

        let shown = Guarded<[String]>([])
        let removed = try await actions.uninstall(
            "llamacpp:q", purgeCache: false, yes: true,
            dialog: .init(interactive: false, show: { line in shown.update { $0.append(line) } }, typed: { _ in nil }))
        #expect(removed)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(models.linked().isEmpty)
        #expect(shown.value.contains("the GGUF file \(file.path) stays where it is; wisp never deletes it"))
        #expect(sink.events.last?.kind == .modelUninstall && sink.events.last?.details["outcome"] == "removed")
    }

    @Test func chatParsesAddAndThePolicyRefusesItToTheModel() {
        #expect(ModelsRequest("add ~/models/a b.gguf") == .add("~/models/a b.gguf"))
        #expect(ModelsRequest("  add   x.gguf ") == .add("x.gguf"))
        #expect(ModelsRequest("add") == .unknown("add"))
        #expect(ModelsRequest.usage.contains("add PATH"))
        let policy = CommandPolicy()
        #expect(policy.check("wisp models add ~/models/x.gguf") != .allowed)
        #expect(policy.check("wisp models list") == .allowed)
        #expect(!ModelActions.Action.add.forModel && ModelActions.Action.add.remembered == nil)
        #expect(ModelLocation.brokenLink.label == "broken link")
    }
}
