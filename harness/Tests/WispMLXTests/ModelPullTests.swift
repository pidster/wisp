import CryptoKit
import Foundation
import Synchronization
import Testing
import WispCore

@testable import WispMLX

/// A Hugging Face that serves one repository from memory at one revision, and can fail a file once, to
/// interrupt a pull.
final class FakeHub: ModelPull.Transport {
    static let revision = "0123456789abcdef0123456789abcdef01234567"

    let files: [String: Data]
    let failing = Mutex<Set<String>>([])
    let requested = Mutex<[String]>([])
    let listingStatus: Int
    let withOids: Bool

    init(files: [String: Data], listingStatus: Int = 200, withOids: Bool = true) {
        self.files = files
        self.listingStatus = listingStatus
        self.withOids = withOids
    }

    /// The git blob id of `data`, as the listing's `oid` gives it.
    static func gitBlobID(_ data: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-256 of `data` as hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The model information: the commit `main` is at.
    var information: Data {
        (try? JSONEncoder().encode(JSONValue.object(["id": "mlx-community/q", "sha": .string(Self.revision)])))
            ?? Data()
    }

    /// The tree listing: every file with its git blob id, and LFS digests for the weights.
    var listing: Data {
        let entries: [JSONValue] =
            files.keys.sorted().map { path in
                let data = files[path] ?? Data()
                var entry: [String: JSONValue] = ["type": "file", "path": .string(path), "size": .int(data.count)]
                if withOids { entry["oid"] = .string(Self.gitBlobID(data)) }
                if path.hasSuffix(".safetensors") {
                    entry["lfs"] = ["oid": .string(Self.sha256(data)), "size": .int(data.count), "pointerSize": 134]
                }
                return .object(entry)
            } + [["type": "directory", "path": "images", "size": 0]]
        return (try? JSONEncoder().encode(JSONValue.array(entries))) ?? Data()
    }

    func data(from url: URL) async throws -> (Data, Int) {
        requested.withLock { $0.append(url.path) }
        guard listingStatus == 200 else { return (Data(), listingStatus) }
        return (url.path.hasSuffix("/revision/main") ? information : listing, 200)
    }

    func download(from url: URL) async throws -> (URL, Int) {
        requested.withLock { $0.append(url.path) }
        let name = url.lastPathComponent
        if failing.withLock({ $0.remove(name) }) != nil { throw URLError(.networkConnectionLost) }
        guard let data = files[name] else { return (try temporary(Data()), 404) }
        return (try temporary(data), 200)
    }

    private func temporary(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-hub-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}

/// `wisp models pull` without the network and without the real cache: naming, the cache's root, the listing,
/// the plan against what the cache holds, the checked fetch into `huggingface_hub`'s layout, reuse, resuming,
/// and the link from the models directory (ADR 0052, refined 2026-10-04).
@Suite struct ModelPullTests {
    static let repository: [String: Data] = [
        "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
        "model.safetensors": Data(repeating: 7, count: 4096),
        "tokenizer.json": Data("{}".utf8),
        "tokenizer_config.json": Data(#"{"a":1}"#.utf8),
        "README.md": Data("# readme".utf8),
        ".gitattributes": Data("*".utf8),
    ]
    static let wantedFiles = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
    static let hubURL = URL(string: "https://hub.test")!

    /// A temporary place with a cache root and a models directory, neither of them created.
    struct Place {
        let root: URL
        var cache: HubCache { HubCache(root: root.appending(path: "hub", directoryHint: .isDirectory)) }
        var models: URL { root.appending(path: "models", directoryHint: .isDirectory) }
        var folder: URL { cache.folder(of: "mlx-community/q") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "wisp-pull-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func pull(_ hub: FakeHub) -> ModelPull { ModelPull(hub: ModelPullTests.hubURL, transport: hub, cache: cache) }

        /// The blob of a repository file.
        func blob(_ path: String) -> URL {
            let data = ModelPullTests.repository[path] ?? Data()
            let id = path.hasSuffix(".safetensors") ? FakeHub.sha256(data) : FakeHub.gitBlobID(data)
            return cache.blob(id, of: "mlx-community/q")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Pulls the repository into the place's cache and links it.
    @discardableResult
    private func pulled(_ place: Place, hub: FakeHub = FakeHub(files: repository)) async throws -> ModelPull.Plan {
        let pull = place.pull(hub)
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        _ = try await pull.fetch(plan, available: 1 << 40)
        _ = try pull.link(plan)
        return plan
    }

    @Test func onlyMLXCommunityRepositoriesAreFetched() throws {
        #expect(
            try ModelPull.repository("mlx-community/Qwen3-1.7B-4bit") == (
                "mlx-community/Qwen3-1.7B-4bit", "Qwen3-1.7B-4bit"
            ))
        #expect(try ModelPull.repository("mlx:mlx-community/q").name == "q")
        for refused in [
            "someone/model", "mlx-community", "mlx-community/", "mlx-community/a/b", "mlx-community/..",
            "mlx-community/a b", "https://huggingface.co/mlx-community/q",
        ] {
            #expect(throws: ModelPull.Failure.notAllowed(refused), "\(refused)") { try ModelPull.repository(refused) }
        }
    }

    @Test func onlyTheFilesAModelDirectoryNeedsAreWanted() {
        for wanted in [
            "config.json", "model-00001-of-00002.safetensors", "tokenizer.model", "chat_template.jinja",
            "merges.txt",
        ] {
            #expect(ModelPull.wanted(wanted), "\(wanted)")
        }
        for unwanted in ["README.md", ".gitattributes", "images/x.json", "model.gguf", "weights.bin"] {
            #expect(!ModelPull.wanted(unwanted), "\(unwanted)")
        }
    }

    @Test func theCacheRootFollowsHuggingFaceHubsVariables() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        func root(_ environment: [String: String]) -> String {
            HubCache.resolve(environment: environment, home: home).root.path
        }
        let all = [
            "HF_HUB_CACHE": "/a", "HUGGINGFACE_HUB_CACHE": "/b", "HF_HOME": "/c", "XDG_CACHE_HOME": "/d",
        ]
        #expect(root(all) == "/a")
        #expect(root(all.filter { $0.key != "HF_HUB_CACHE" }) == "/b")
        #expect(root(["HF_HOME": "/c", "XDG_CACHE_HOME": "/d"]) == "/c/hub")
        #expect(root(["XDG_CACHE_HOME": "/d"]) == "/d/huggingface/hub")
        #expect(root([:]) == "/Users/someone/.cache/huggingface/hub")
        #expect(root(["HF_HUB_CACHE": "~/hf"]) == "/Users/someone/hf")
        #expect(root(["HF_HUB_CACHE": "", "HF_HOME": "~/h"]) == "/Users/someone/h/hub")
        #expect(HubCache.folderName(of: "mlx-community/Qwen3-1.7B-4bit") == "models--mlx-community--Qwen3-1.7B-4bit")
    }

    @Test func thePlanListsTheRevisionsWantedFilesAndWritesNothing() async throws {
        let place = try Place()
        defer { place.remove() }
        let hub = FakeHub(files: Self.repository)
        let plan = try await place.pull(hub).plan("mlx-community/q", into: place.models)
        #expect(plan.files.map(\.path) == Self.wantedFiles)
        #expect(plan.revision == FakeHub.revision && plan.reused.isEmpty && plan.link == .absent)
        #expect(plan.bytes == plan.files.reduce(0) { $0 + $1.size } && plan.remaining == plan.bytes)
        #expect(plan.files.first { $0.path == "model.safetensors" }?.blob.count == 64)
        #expect(plan.files.first { $0.path == "config.json" }?.blob.count == 40)
        #expect(
            plan.snapshot == place.folder.appending(path: "snapshots/\(FakeHub.revision)", directoryHint: .isDirectory))
        #expect(
            hub.requested.withLock { $0 } == [
                "/api/models/mlx-community/q/revision/main", "/api/models/mlx-community/q/tree/\(FakeHub.revision)",
            ])
        #expect(!FileManager.default.fileExists(atPath: place.cache.root.path))
        #expect(!FileManager.default.fileExists(atPath: place.models.path))
    }

    @Test func aRepositoryThatIsNotAModelOrIsMissingIsRefused() async throws {
        let place = try Place()
        defer { place.remove() }
        await #expect(throws: ModelPull.Failure.notAModel("mlx-community/q")) {
            try await place.pull(FakeHub(files: ["config.json": Data("{}".utf8)])).plan(
                "mlx-community/q", into: place.models)
        }
        await #expect(
            throws: ModelPull.Failure.http(
                status: 404, url: "https://hub.test/api/models/mlx-community/q/revision/main")
        ) {
            try await place.pull(FakeHub(files: [:], listingStatus: 404)).plan("mlx-community/q", into: place.models)
        }
        await #expect(throws: ModelPull.Failure.self) {
            try await place.pull(FakeHub(files: Self.repository, withOids: false)).plan(
                "mlx-community/q", into: place.models)
        }
        #expect(throws: ModelPull.Failure.self) { try ModelPull.revision(fromInfo: Data(#"{"sha":"main"}"#.utf8)) }
    }

    @Test func somethingElseAtTheLinksPathIsRefusedBeforeAnyRequest() async throws {
        let place = try Place()
        defer { place.remove() }
        try FileManager.default.createDirectory(at: place.models, withIntermediateDirectories: true)
        let path = place.models.appending(path: "q")
        try Data("x".utf8).write(to: path)
        let hub = FakeHub(files: Self.repository)
        await #expect(throws: ModelPull.Failure.exists(path.path)) {
            try await place.pull(hub).plan("mlx-community/q", into: place.models)
        }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: place.root.path)
        await #expect(throws: ModelPull.Failure.exists(path.path)) {
            try await place.pull(hub).plan("mlx-community/q", into: place.models)
        }
        #expect(hub.requested.withLock { $0.isEmpty })
    }

    @Test func aFreshPullFillsTheCacheInHuggingFacesLayoutAndLinksIt() async throws {
        let place = try Place()
        defer { place.remove() }
        let hub = FakeHub(files: Self.repository)
        let pull = place.pull(hub)
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        var announced: [String] = []
        let fetched = try await pull.fetch(plan, available: 1 << 40) { file, _ in announced.append(file.path) }
        #expect(fetched == plan.bytes && announced == Self.wantedFiles)
        #expect(
            hub.requested.withLock { $0 }.dropFirst(2).allSatisfy {
                $0.hasPrefix("/mlx-community/q/resolve/\(FakeHub.revision)/")
            })
        let fileManager = FileManager.default
        for path in Self.wantedFiles {
            let blob = place.blob(path)
            #expect(try Data(contentsOf: blob) == Self.repository[path], "\(path)")
            let entry = plan.snapshot.appending(path: path).path
            #expect(try fileManager.destinationOfSymbolicLink(atPath: entry) == "../../blobs/\(blob.lastPathComponent)")
        }
        let blobs = try fileManager.contentsOfDirectory(atPath: place.folder.appending(path: "blobs").path)
        #expect(blobs.count == 4 && !blobs.contains { $0.hasSuffix(".incomplete") })
        #expect(try String(contentsOf: place.folder.appending(path: "refs/main"), encoding: .utf8) == FakeHub.revision)
        #expect(place.cache.mainRevision(of: "mlx-community/q") == FakeHub.revision)
        // Nothing is linked from the models directory until `link`, and the listing names the snapshot meanwhile.
        #expect(place.cache.unlinked(in: place.models) == ["mlx-community/q"])
        #expect(try pull.link(plan) == .created)
        #expect(try pull.link(plan) == .unchanged)
        let link = place.models.appending(path: "q")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == plan.snapshot.path)
        #expect(place.cache.unlinked(in: place.models).isEmpty)
        // The link is an MLX model the backend lists and sizes, through the snapshot's links.
        #expect(MLXBackend.models(in: place.models).map(\.lastPathComponent) == ["q"])
        #expect(MLXBackend.weightBytes(in: link) == 4096)
        // A models directory that is itself a link is listed too.
        let linkedModels = place.root.appending(path: "linked-models")
        try fileManager.createSymbolicLink(atPath: linkedModels.path, withDestinationPath: place.models.path)
        #expect(MLXBackend.models(in: linkedModels).map(\.lastPathComponent) == ["q"])
    }

    @Test func aCompleteSnapshotFetchesNothingAndIsOnlyLinked() async throws {
        let place = try Place()
        defer { place.remove() }
        try await pulled(place)
        try FileManager.default.removeItem(at: place.models.appending(path: "q"))
        let hub = FakeHub(files: Self.repository)
        let pull = place.pull(hub)
        var checked: [String] = []
        let plan = try await pull.plan("mlx-community/q", into: place.models) { checked.append($0.path) }
        #expect(plan.reused == Self.wantedFiles && plan.missing.isEmpty && plan.remaining == 0)
        #expect(checked == ["model.safetensors"])
        // No room is needed when nothing is fetched.
        #expect(try await pull.fetch(plan, available: 0) == 0)
        #expect(hub.requested.withLock { $0 }.count == 2)
        #expect(try pull.link(plan) == .created)
        #expect(MLXBackend.models(in: place.models).map(\.lastPathComponent) == ["q"])
    }

    @Test func aPartialSnapshotFetchesOnlyWhatIsMissingAndAnInterruptedOneResumes() async throws {
        let place = try Place()
        defer { place.remove() }
        let hub = FakeHub(files: Self.repository)
        hub.failing.withLock { $0 = ["tokenizer.json"] }
        let pull = place.pull(hub)
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        await #expect(throws: ModelPull.Failure.self) { _ = try await pull.fetch(plan, available: 1 << 40) }
        #expect(!HubCache.occupied(place.models.appending(path: "q")))
        let resumed = try await pull.plan("mlx-community/q", into: place.models)
        #expect(resumed.reused == ["config.json", "model.safetensors"])
        #expect(resumed.missing.map(\.path) == ["tokenizer.json", "tokenizer_config.json"])
        hub.requested.withLock { $0 = [] }
        #expect(try await pull.fetch(resumed, available: 1 << 40) == resumed.remaining)
        #expect(
            hub.requested.withLock { $0 } == [
                "/mlx-community/q/resolve/\(FakeHub.revision)/tokenizer.json",
                "/mlx-community/q/resolve/\(FakeHub.revision)/tokenizer_config.json",
            ])
        #expect(try pull.link(resumed) == .created)
        // A blob that went missing later is fetched again on its own.
        try FileManager.default.removeItem(at: place.blob("tokenizer_config.json"))
        let again = try await pull.plan("mlx-community/q", into: place.models)
        #expect(again.missing.map(\.path) == ["tokenizer_config.json"] && again.link == .current)
    }

    @Test func aCorruptBlobIsFetchedAgain() async throws {
        let place = try Place()
        defer { place.remove() }
        try await pulled(place)
        // The right size with the wrong content, and the wrong size.
        try Data(repeating: 8, count: 4096).write(to: place.blob("model.safetensors"))
        try Data("{}{}".utf8).write(to: place.blob("tokenizer.json"))
        let hub = FakeHub(files: Self.repository)
        let pull = place.pull(hub)
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        #expect(plan.missing.map(\.path) == ["model.safetensors", "tokenizer.json"])
        _ = try await pull.fetch(plan, available: 1 << 40)
        #expect(try Data(contentsOf: place.blob("model.safetensors")) == Self.repository["model.safetensors"])
        #expect(try Data(contentsOf: place.blob("tokenizer.json")) == Self.repository["tokenizer.json"])
    }

    @Test func anIncompleteBlobIsStartedAgain() async throws {
        let place = try Place()
        defer { place.remove() }
        let blob = place.blob("model.safetensors")
        let incomplete = blob.deletingLastPathComponent().appending(path: blob.lastPathComponent + ".incomplete")
        try FileManager.default.createDirectory(
            at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: incomplete)
        let pull = place.pull(FakeHub(files: Self.repository))
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        #expect(plan.missing.map(\.path).contains("model.safetensors"))
        _ = try await pull.fetch(plan, available: 1 << 40)
        #expect(try Data(contentsOf: blob) == Self.repository["model.safetensors"])
        #expect(!HubCache.occupied(incomplete))
    }

    @Test func aBlobAnotherProgramIsFetchingIsRefused() async throws {
        let place = try Place()
        defer { place.remove() }
        let pull = place.pull(FakeHub(files: Self.repository))
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        let lock = place.cache.lock(place.blob("config.json").lastPathComponent, of: "mlx-community/q")
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDWR | O_CREAT, 0o644)
        defer { _ = close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: ModelPull.Failure.busy(lock.path)) {
            _ = try await pull.fetch(plan, available: 1 << 40)
        }
    }

    @Test func aRealDirectoryIsKeptUnlessThePersonAgreesAndALinkToAnotherSnapshotIsRepointed() async throws {
        let place = try Place()
        defer { place.remove() }
        let fileManager = FileManager.default
        let destination = place.models.appending(path: "q")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: destination.appending(path: "config.json"))
        let pull = place.pull(FakeHub(files: Self.repository))
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        #expect(plan.link == .directory)
        _ = try await pull.fetch(plan, available: 1 << 40)
        #expect(try pull.link(plan) == .keptDirectory)
        #expect(
            try fileManager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(fileManager.fileExists(atPath: destination.appending(path: "config.json").path))
        // Not replaced while the snapshot lacks a file, even with the person's yes.
        let blob = place.blob("tokenizer.json")
        let aside = place.root.appending(path: "aside")
        try fileManager.moveItem(at: blob, to: aside)
        var discarded: [URL] = []
        #expect(throws: ModelPull.Failure.self) {
            _ = try pull.link(plan, replacingDirectory: true) { discarded.append($0) }
        }
        #expect(discarded.isEmpty)
        try fileManager.moveItem(at: aside, to: blob)
        #expect(
            try pull.link(plan, replacingDirectory: true) {
                discarded.append($0)
                try fileManager.removeItem(at: $0)
            } == .replacedDirectory)
        #expect(discarded == [destination])
        #expect(try fileManager.destinationOfSymbolicLink(atPath: destination.path) == plan.snapshot.path)
        // A link to another snapshot of the model is pointed at this one.
        try fileManager.removeItem(at: destination)
        let older = place.folder.appending(path: "snapshots/" + String(repeating: "f", count: 40))
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: older.path)
        let replanned = try await pull.plan("mlx-community/q", into: place.models)
        #expect(replanned.link == .stale(older.path) && replanned.missing.isEmpty)
        #expect(try pull.link(replanned) == .replacedLink)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: destination.path) == plan.snapshot.path)
    }

    @Test func theCachesUnlinkedModelsAreTheCompleteOnesNothingNames() async throws {
        let place = try Place()
        defer { place.remove() }
        let pull = place.pull(FakeHub(files: Self.repository))
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        _ = try await pull.fetch(plan, available: 1 << 40)
        #expect(place.cache.unlinked(in: place.models) == ["mlx-community/q"])
        // Another organisation's model is not listed.
        let other = place.cache.folder(of: "someone/q")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // A dangling entry makes the snapshot incomplete.
        try FileManager.default.removeItem(at: place.blob("tokenizer.json"))
        #expect(place.cache.unlinked(in: place.models).isEmpty)
        _ = try await pull.fetch(try await pull.plan("mlx-community/q", into: place.models), available: 1 << 40)
        // A sharded model needs every shard its index names.
        let index = plan.snapshot.appending(path: "model.safetensors.index.json")
        try Data(#"{"weight_map":{"a":"model.safetensors","b":"model-2.safetensors"}}"#.utf8).write(to: index)
        #expect(!HubCache.looksComplete(plan.snapshot))
        try Data(#"{"weight_map":{"a":"model.safetensors"}}"#.utf8).write(to: index)
        #expect(HubCache.looksComplete(plan.snapshot))
        // Anything at the name in the models directory counts as linked.
        try FileManager.default.createDirectory(
            at: place.models.appending(path: "q"), withIntermediateDirectories: true)
        #expect(place.cache.unlinked(in: place.models).isEmpty)
    }

    @Test func enablingACachedModelLinksItFromTheSnapshotWithoutTheHub() async throws {
        let place = try Place()
        defer { place.remove() }
        let pull = place.pull(FakeHub(files: Self.repository))
        _ = try await pull.fetch(try await pull.plan("mlx-community/q", into: place.models), available: 1 << 40)
        // Listed as cached and not linked, with its format and weights from the snapshot.
        let cached = MLXBackend.cached(in: place.cache, modelsDirectory: place.models)
        #expect(cached.map(\.selection) == [.local(backend: "mlx", name: "q")])
        #expect(cached.first?.location == .hubCacheNotLinked && cached.first?.format == "qwen3")
        #expect(cached.first?.bytes == 4096)
        // Linked from the snapshot alone: a hub that answers nothing is never asked.
        let offline = ModelPull(
            hub: Self.hubURL, transport: FakeHub(files: [:], listingStatus: 500), cache: place.cache)
        let plan = try offline.cachedPlan("mlx-community/q", into: place.models)
        #expect(plan.missing.isEmpty && plan.link == .absent)
        #expect(plan.files.map(\.path) == Self.wantedFiles)
        let config = Config(mlx: .init(modelsDirectory: place.models.path)).resolved
        let home = Home(root: place.root)
        let backend = MLXBackend(cache: place.cache)
        let link = try backend.link("q", config: config, home: home)
        #expect(link.outcome == "created" && link.files == 4 && link.repository == "mlx-community/q")
        #expect(link.snapshot == plan.snapshot.path && link.destination == place.models.appending(path: "q").path)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: place.models.appending(path: "q").path)
                == plan.snapshot.path)
        #expect(MLXBackend.cached(in: place.cache, modelsDirectory: place.models).isEmpty)
        // Once linked it is installed, and lives in the Hugging Face cache.
        let installed = try await backend.installed(config: config, home: home)
        #expect(installed.first?.location == .hubCache && installed.first?.bytes == 4096)
        #expect(try backend.link("q", config: config, home: home).outcome == "unchanged")
        // Nothing complete in the cache: refused, with how to fetch it.
        #expect(throws: ModelPull.Failure.notCached("mlx-community/other")) {
            try offline.cachedPlan("mlx-community/other", into: place.models)
        }
        #expect("\(ModelPull.Failure.notCached("mlx-community/x"))".contains("wisp models pull mlx-community/x"))
    }

    @Test func aFileThatIsNotWhatTheListingSaidIsRejected() async throws {
        let place = try Place()
        defer { place.remove() }
        let url = place.root.appending(path: "weights")
        try Data(repeating: 1, count: 10).write(to: url)
        #expect(throws: ModelPull.Failure.mismatch(file: "w", detail: "10 bytes, expected 11")) {
            try ModelPull.check(url, against: .init(path: "w", size: 11))
        }
        #expect(throws: ModelPull.Failure.self) {
            try ModelPull.check(url, against: .init(path: "w", size: 10, sha256: String(repeating: "0", count: 64)))
        }
        let digest = FakeHub.sha256(Data(repeating: 1, count: 10))
        #expect(throws: Never.self) { try ModelPull.check(url, against: .init(path: "w", size: 10, sha256: digest)) }
    }

    @Test func aFetchTheDiskCannotHoldIsRefusedBeforeAnyDownload() async throws {
        let place = try Place()
        defer { place.remove() }
        let hub = FakeHub(files: Self.repository)
        let pull = place.pull(hub)
        let plan = try await pull.plan("mlx-community/q", into: place.models)
        hub.requested.withLock { $0 = [] }
        await #expect(throws: ModelPull.Failure.noRoom(needed: plan.remaining + ModelPull.margin, available: 100)) {
            try await pull.fetch(plan, available: 100)
        }
        #expect(hub.requested.withLock { $0.isEmpty })
        #expect("\(ModelPull.Failure.noRoom(needed: 2 << 30, available: 1 << 30))".contains("GB"))
    }
}
