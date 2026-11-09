import CryptoKit
import Foundation
import Testing
import WispCore

@testable import WispCoreAI

/// Checking a Core AI bundle's weights against the hash exported beside them, on small files standing in for them.
@Suite struct BundleIntegrityTests {
    /// A scratch home and a bundle directory with an `.aimodel` in it.
    private func scratch() throws -> (home: Home, bundle: URL, model: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-integrity-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        let bundle = home.models.appending(path: "coreai/b")
        let model = bundle.appending(path: "b.aimodel")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appending(path: "metadata.json"))
        return (home, bundle, model)
    }

    /// Writes weights and the hash Core AI's exporter writes beside them: their SHA-256 as 32 raw bytes.
    private func write(_ weights: Data, hashOf hashed: Data? = nil, in model: URL) throws {
        try weights.write(to: model.appending(path: "main.mlirb"))
        try Data(SHA256.hash(data: hashed ?? weights)).write(to: model.appending(path: "main.hash"))
    }

    @Test func matchingWeightsAreHashedOnceThenRemembered() throws {
        let (home, bundle, model) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let weights = Data((0..<100_000).map { UInt8($0 % 251) })
        try write(weights, in: model)
        let records = CoreAIBackend.integrityRecords(home: home)
        let path = model.appending(path: "main.mlirb").resolvingSymlinksInPath().path

        #expect(try BundleIntegrity.check(bundle: bundle, records: records) == .verified([path]))
        #expect(BundleIntegrity.load(records)[path]?.bytes == Int64(weights.count))
        #expect(try BundleIntegrity.check(bundle: bundle, records: records) == .remembered)
    }

    @Test func truncatedWeightsAreRefusedWithBothHashes() throws {
        let (home, bundle, model) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let whole = Data(repeating: 7, count: 50_000)
        try write(whole.prefix(1_000), hashOf: whole, in: model)
        let records = CoreAIBackend.integrityRecords(home: home)
        do {
            _ = try BundleIntegrity.check(bundle: bundle, records: records)
            Issue.record("truncated weights passed")
        } catch let mismatch as BundleIntegrity.Mismatch {
            #expect(mismatch.expected == SHA256.hash(data: whole).map { String(format: "%02x", $0) }.joined())
            #expect(mismatch.bytes == 1_000)
            #expect(mismatch.description.contains("truncated or corrupt"))
            #expect(mismatch.description.contains("main.mlirb"))
        }
        #expect(BundleIntegrity.load(records).isEmpty)
    }

    @Test func weightsChangedSinceTheyMatchedAreHashedAgain() throws {
        let (home, bundle, model) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let records = CoreAIBackend.integrityRecords(home: home)
        let whole = Data(repeating: 1, count: 4_096)
        try write(whole, in: model)
        _ = try BundleIntegrity.check(bundle: bundle, records: records)
        // Cut short after it matched, as an interrupted re-download would leave it; the hash file is unchanged.
        try whole.prefix(100).write(to: model.appending(path: "main.mlirb"))
        #expect(throws: BundleIntegrity.Mismatch.self) { try BundleIntegrity.check(bundle: bundle, records: records) }
    }

    @Test func aBundleWithoutAHashIsNotChecked() throws {
        let (home, bundle, model) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try Data(repeating: 0, count: 10).write(to: model.appending(path: "main.mlirb"))
        #expect(
            try BundleIntegrity.check(bundle: bundle, records: CoreAIBackend.integrityRecords(home: home)) == .unchecked
        )
    }

    @Test func resolutionRefusesABundleWhoseWeightsDoNotMatch() throws {
        ModelBackends.register(CoreAIBackend())
        let (home, _, model) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try write(Data(repeating: 2, count: 10), hashOf: Data(repeating: 3, count: 10), in: model)
        do {
            _ = try CoreAIBackend().resolve("b", config: Config().resolved, home: home)
            Issue.record("resolved a bundle whose weights do not match")
        } catch ModelSelection.Failure.unavailable(let name, let reason) {
            #expect(name == "coreai:b")
            #expect(reason.contains("does not match the SHA-256 beside it"))
        }
    }

    @Test func aLinkedBundleIsCheckedAtItsRealDirectory() throws {
        ModelBackends.register(CoreAIBackend())
        let (home, bundle, model) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try write(Data(repeating: 4, count: 10), hashOf: Data(repeating: 5, count: 10), in: model)
        let link = home.models.appending(path: "coreai/linked")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: bundle.path)
        do {
            _ = try CoreAIBackend().resolve("linked", config: Config().resolved, home: home)
            Issue.record("resolved a linked bundle whose weights do not match")
        } catch ModelSelection.Failure.unavailable(_, let reason) {
            #expect(reason.contains(bundle.resolvingSymlinksInPath().path))
        }
    }
}
