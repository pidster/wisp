import Foundation
import Testing

@testable import WispCore

/// The model registry's rules and its file (ADR 0092, stage 1): what a listing records, what a pull, an add, or the
/// configuration registers, what forgetting removes, and how the file is read and written.
@Suite struct ModelRegistryTests {
    /// Ollama's model as a runtime lists it.
    private static func granite(bytes: Int = 5_350_000_000) -> InstalledModel {
        InstalledModel(
            selection: .local(backend: "ollama", name: "granite4.2:8b"), detail: "8B 5.35 GB", parameters: "8B",
            bytes: bytes, format: "granite Q4_K_M")
    }

    /// A scratch file, removed by the test.
    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "models.json")
    }

    @Test func aListingRecordsWhatItServedAndWhen() throws {
        var registry = ModelRegistry()
        let apple = InstalledModel(selection: .system, detail: "")
        let first = registry.merge(served: [Self.granite(), apple], day: "2026-11-28")
        #expect(first)
        let record = try #require(registry.record("ollama:granite4.2:8b"))
        #expect(record.origin == .seen && record.firstSeen == "2026-11-28" && record.lastSeen == "2026-11-28")
        #expect(record.detail == "8B 5.35 GB" && record.parameters == "8B" && record.format == "granite Q4_K_M")
        #expect(record.scheme == "ollama" && registry.models.count == 1, "Apple's models are never recorded")
        let same = registry.merge(served: [Self.granite()], day: "2026-11-28")
        #expect(!same, "the same listing changes nothing")
        let next = registry.merge(served: [Self.granite(bytes: 1)], day: "2026-11-29")
        #expect(next)
        let later = try #require(registry.record("ollama:granite4.2:8b"))
        #expect(later.firstSeen == "2026-11-28" && later.lastSeen == "2026-11-29" && later.bytes == 1)
    }

    @Test func aModelARuntimeStopsListingIsKeptUntilForgotten() {
        var registry = ModelRegistry()
        let qwen = InstalledModel(selection: .local(backend: "ollama", name: "qwen3.8:27b"), detail: "27B")
        registry.merge(served: [Self.granite(), qwen], day: "2026-11-28")
        let without = registry.merge(served: [Self.granite()], day: "2026-11-28")
        #expect(!without)
        #expect(registry.record("ollama:qwen3.8:27b")?.lastSeen == "2026-11-28")
        #expect(registry.records(of: "ollama").map(\.model) == ["ollama:granite4.2:8b", "ollama:qwen3.8:27b"])
        let forgotten = registry.forget(.local(backend: "ollama", name: "qwen3.8:27b"))
        let again = registry.forget(.local(backend: "ollama", name: "qwen3.8:27b"))
        let apple = registry.forget(.system)
        #expect(forgotten && !again && !apple)
        #expect(registry.models.map(\.model) == ["ollama:granite4.2:8b"])
    }

    @Test func aPullOrAnAddSaysMoreThanSeeingButNothingReplacesAnEarlierDay() throws {
        var registry = ModelRegistry()
        let mlx = ModelSelection.local(backend: "mlx", name: "Qwen3-4B-4bit")
        let pull = registry.register(mlx, origin: .pulled, day: "2026-11-20")
        #expect(pull)
        let pulled = try #require(registry.record("mlx:Qwen3-4B-4bit"))
        #expect(pulled.origin == .pulled && pulled.firstSeen == "2026-11-20" && pulled.lastSeen == nil)
        let configured = registry.register(mlx, origin: .configured, day: "2026-11-28")
        #expect(!configured, "a pulled model stays pulled")
        registry.merge(served: [Self.granite()], day: "2026-11-21")
        let add = registry.register(.local(backend: "ollama", name: "granite4.2:8b"), origin: .added, day: "2026-11-28")
        #expect(add)
        let added = try #require(registry.record("ollama:granite4.2:8b"))
        #expect(added.origin == .added && added.firstSeen == "2026-11-21")
        let apple = registry.register(.privateCloud, origin: .configured, day: "2026-11-28")
        #expect(!apple)
        #expect(registry.models.map(\.model) == ["mlx:Qwen3-4B-4bit", "ollama:granite4.2:8b"], "ordered by name")
    }

    @Test func theFileIsWrittenOnlyWhenSomethingChangesAndReadBack() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ModelRegistry.Store(url: url)
        #expect(store.load() == ModelRegistry())
        try store.update { $0.merge(served: [Self.granite()], day: "2026-11-28") }
        #expect(store.load().record("ollama:granite4.2:8b")?.lastSeen == "2026-11-28")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: url.path)
        try store.update { $0.merge(served: [Self.granite()], day: "2026-11-28") }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(after == earlier, "an unchanged registry is not written")
    }

    @Test func anUnreadableFileIsAnEmptyRegistryThatTheNextChangeReplaces() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: url)
        let store = ModelRegistry.Store(url: url)
        #expect(store.load().models.isEmpty)
        let registry = try store.update { $0.register(.local(backend: "mlx", name: "x"), origin: .pulled, day: "d") }
        #expect(registry.models.count == 1 && store.load() == registry)
    }

    @Test func theDayIsWrittenAsADate() {
        #expect(ModelRegistry.day(Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15")
        #expect(Home(root: URL(filePath: "/h")).modelRegistryFile.path == "/h/models.json")
    }
}
