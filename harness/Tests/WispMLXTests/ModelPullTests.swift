import CryptoKit
import Foundation
import Synchronization
import Testing
import WispCore

@testable import WispMLX

/// A Hugging Face that serves one repository from memory and can fail a file once, to interrupt a pull.
final class FakeHub: ModelPull.Transport {
    let files: [String: Data]
    let failing = Mutex<Set<String>>([])
    let requested = Mutex<[String]>([])
    let listingStatus: Int

    init(files: [String: Data], listingStatus: Int = 200) {
        self.files = files
        self.listingStatus = listingStatus
    }

    /// The tree listing: every file, with LFS digests for the weights.
    var listing: Data {
        let entries: [JSONValue] =
            files.keys.sorted().map { path in
                let data = files[path] ?? Data()
                var entry: [String: JSONValue] = ["type": "file", "path": .string(path), "size": .int(data.count)]
                if path.hasSuffix(".safetensors") {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    entry["lfs"] = ["oid": .string(digest), "size": .int(data.count)]
                }
                return .object(entry)
            } + [["type": "directory", "path": "images", "size": 0]]
        return (try? JSONEncoder().encode(JSONValue.array(entries))) ?? Data()
    }

    func data(from url: URL) async throws -> (Data, Int) {
        requested.withLock { $0.append(url.path) }
        return (listingStatus == 200 ? listing : Data(), listingStatus)
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

/// `wisp models pull` without the network: naming, the listing, the plan, the checked fetch, and resuming
/// (ADR 0052).
@Suite struct ModelPullTests {
    static let repository: [String: Data] = [
        "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
        "model.safetensors": Data(repeating: 7, count: 4096),
        "tokenizer.json": Data("{}".utf8),
        "tokenizer_config.json": Data("{}".utf8),
        "README.md": Data("# readme".utf8),
        ".gitattributes": Data("*".utf8),
    ]

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-pull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    @Test func thePlanListsTheWantedFilesAndTheirSize() async throws {
        let models = try directory()
        defer { try? FileManager.default.removeItem(at: models) }
        let hub = FakeHub(files: Self.repository)
        let pull = ModelPull(hub: URL(string: "https://hub.test")!, transport: hub)
        let plan = try await pull.plan("mlx-community/q", into: models)
        #expect(
            plan.files.map(\.path) == ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        #expect(plan.bytes == plan.files.reduce(0) { $0 + $1.size } && plan.remaining == plan.bytes)
        #expect(plan.files.first { $0.path == "model.safetensors" }?.sha256?.count == 64)
        #expect(plan.destination.lastPathComponent == "q" && plan.present.isEmpty)
        #expect(hub.requested.withLock { $0 } == ["/api/models/mlx-community/q/tree/main"])
        // Nothing is fetched by planning.
        #expect(!FileManager.default.fileExists(atPath: plan.partial.path))
    }

    @Test func aRepositoryThatIsNotAModelOrIsMissingIsRefused() async throws {
        let models = try directory()
        defer { try? FileManager.default.removeItem(at: models) }
        let noWeights = ModelPull(
            hub: URL(string: "https://hub.test")!, transport: FakeHub(files: ["config.json": Data("{}".utf8)]))
        await #expect(throws: ModelPull.Failure.notAModel("mlx-community/q")) {
            try await noWeights.plan("mlx-community/q", into: models)
        }
        let missing = ModelPull(
            hub: URL(string: "https://hub.test")!, transport: FakeHub(files: [:], listingStatus: 404))
        await #expect(
            throws: ModelPull.Failure.http(status: 404, url: "https://hub.test/api/models/mlx-community/q/tree/main")
        ) {
            try await missing.plan("mlx-community/q", into: models)
        }
        try FileManager.default.createDirectory(at: models.appending(path: "q"), withIntermediateDirectories: true)
        let present = ModelPull(hub: URL(string: "https://hub.test")!, transport: FakeHub(files: Self.repository))
        await #expect(throws: ModelPull.Failure.exists(models.appending(path: "q").path)) {
            try await present.plan("mlx-community/q", into: models)
        }
    }

    @Test func theFetchChecksEachFileAndResumesAfterAnInterruption() async throws {
        let models = try directory()
        defer { try? FileManager.default.removeItem(at: models) }
        let hub = FakeHub(files: Self.repository)
        hub.failing.withLock { $0 = ["tokenizer.json"] }
        let pull = ModelPull(hub: URL(string: "https://hub.test")!, transport: hub)
        let plan = try await pull.plan("mlx-community/q", into: models)
        var announced: [String] = []
        await #expect(throws: ModelPull.Failure.self) {
            _ = try await pull.fetch(plan, available: 1 << 40) { file, _ in announced.append(file.path) }
        }
        #expect(announced == ["config.json", "model.safetensors", "tokenizer.json"])
        #expect(!FileManager.default.fileExists(atPath: plan.destination.path))
        // The next plan finds what the interrupted pull finished and fetches only the rest.
        let resumed = try await pull.plan("mlx-community/q", into: models)
        #expect(resumed.present == ["config.json", "model.safetensors"])
        #expect(
            resumed.remaining == Self.repository["tokenizer.json"]!.count
                + Self.repository["tokenizer_config.json"]!.count)
        hub.requested.withLock { $0 = [] }
        let fetched = try await pull.fetch(resumed, available: 1 << 40)
        #expect(fetched == resumed.remaining)
        #expect(
            hub.requested.withLock { $0 } == [
                "/mlx-community/q/resolve/main/tokenizer.json", "/mlx-community/q/resolve/main/tokenizer_config.json",
            ])
        let installed = try FileManager.default.contentsOfDirectory(atPath: plan.destination.path).sorted()
        #expect(installed == ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        #expect(
            try Data(contentsOf: plan.destination.appending(path: "model.safetensors"))
                == Self.repository["model.safetensors"])
        #expect(!FileManager.default.fileExists(atPath: plan.partial.path))
        // The directory is now an MLX model the backend lists.
        #expect(MLXBackend.models(in: models).map(\.lastPathComponent) == ["q"])
    }

    @Test func aFileThatIsNotWhatTheListingSaidIsRejected() async throws {
        let models = try directory()
        defer { try? FileManager.default.removeItem(at: models) }
        let url = models.appending(path: "weights")
        try Data(repeating: 1, count: 10).write(to: url)
        #expect(throws: ModelPull.Failure.mismatch(file: "w", detail: "10 bytes, expected 11")) {
            try ModelPull.check(url, against: .init(path: "w", size: 11))
        }
        #expect(throws: ModelPull.Failure.self) {
            try ModelPull.check(url, against: .init(path: "w", size: 10, sha256: String(repeating: "0", count: 64)))
        }
        let digest = SHA256.hash(data: Data(repeating: 1, count: 10)).map { String(format: "%02x", $0) }.joined()
        #expect(throws: Never.self) { try ModelPull.check(url, against: .init(path: "w", size: 10, sha256: digest)) }
    }

    @Test func aFetchTheDiskCannotHoldIsRefusedBeforeAnyRequest() async throws {
        let models = try directory()
        defer { try? FileManager.default.removeItem(at: models) }
        let hub = FakeHub(files: Self.repository)
        let pull = ModelPull(hub: URL(string: "https://hub.test")!, transport: hub)
        let plan = try await pull.plan("mlx-community/q", into: models)
        hub.requested.withLock { $0 = [] }
        await #expect(throws: ModelPull.Failure.noRoom(needed: plan.remaining + ModelPull.margin, available: 100)) {
            try await pull.fetch(plan, available: 100)
        }
        #expect(hub.requested.withLock { $0.isEmpty })
        #expect("\(ModelPull.Failure.noRoom(needed: 2 << 30, available: 1 << 30))".contains("GB"))
    }
}
