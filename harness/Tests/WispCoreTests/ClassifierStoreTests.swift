import Foundation
import Testing

@testable import WispCore

/// The versioned classifier store: a shipped default that never changes, versions trained here that
/// never overwrite, and config references that name one (ADR 0038, amendment).
@Suite struct ClassifierStoreTests {
    private func home() throws -> Home {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Home(root: dir)
    }

    @Test func referencesAndVersionNames() {
        #expect(ClassifierStore.version(of: "risk@0.12.0-local.3") == "0.12.0-local.3")
        #expect(ClassifierStore.version(of: "risk.mlmodel") == nil && ClassifierStore.version(of: "risk@") == nil)
        #expect(ClassifierStore.reference("0.13.0-default") == "risk@0.13.0-default")
        #expect(ClassifierStore.defaultVersion("0.13.0") == "0.13.0-default")
        #expect(ClassifierStore.digest([RiskExample(command: "ls", level: .safe)]).count == 64)
        #expect(
            ClassifierStore.digest([RiskExample(command: "ls", level: .safe)])
                != ClassifierStore.digest([RiskExample(command: "ls", level: .moderate)]))
        #expect("\(ClassifierStore.Failure.notAReference("x"))".contains("risk@<version>"))
    }

    /// A version that could name a directory outside the store is refused everywhere one is taken (the
    /// 2026-10-09 review).
    @Test func versionsThatReachOutsideTheStoreAreRefused() throws {
        for bad in ["../x", "../../etc", "a/b", "/abs", ".hidden", "a..b", "x y", ""] {
            #expect(ClassifierStore.version(of: "risk@\(bad)") == nil, "\(bad)")
            #expect(!ClassifierStore.isValidVersion(bad), "\(bad)")
        }
        #expect(ClassifierStore.isValidVersion("0.21.1-local.2") && ClassifierStore.isValidVersion("0.13.0-default"))
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ClassifierStore(home: home)
        #expect(store.manifest("../../x") == nil)
        #expect(throws: ClassifierStore.Failure.unknownVersion("../x")) { try store.remove("../x", inUse: nil) }
        let manifest = ClassifierStore.Manifest(
            task: "risk", version: "../escape", wispVersion: "0", created: "", examplesSource: "", examples: 0,
            perLevel: [:], examplesDigest: "", parent: nil, measurements: [])
        #expect(throws: ClassifierStore.Failure.invalidVersion("../escape")) {
            try store.add(model: home.root.appending(path: "none.mlmodel"), manifest: manifest)
        }
        #expect(!FileManager.default.fileExists(atPath: home.root.appending(path: "classifiers/escape").path))
        #expect("\(ClassifierStore.Failure.invalidVersion("../x"))".contains("not a classifier version"))
    }

    @Test func trainingAddsVersionsAndNeverReplacesOne() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ClassifierStore(home: home)
        let first = try store.train(RiskExamples.bundled, source: "bundled")
        #expect(first.manifest.version == "\(WispVersion.current)-local.1" && first.manifest.parent == nil)
        let second = try store.train(RiskExamples.bundled, source: "bundled + audit", parent: first.manifest.version)
        #expect(second.manifest.version == "\(WispVersion.current)-local.2")
        #expect(second.manifest.parent == first.manifest.version)
        #expect(store.versions().map(\.version) == [first.manifest.version, second.manifest.version])
        #expect(first.manifest.examplesDigest == ClassifierStore.digest(RiskExamples.bundled))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.model(first.manifest.version).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o444, "the model is read-only")
        #expect(throws: (any Error).self, "a version is never replaced") {
            try store.train(RiskExamples.bundled, source: "again", version: first.manifest.version)
        }
        // A measurement is recorded in the manifest; nothing else changes.
        let report = RiskMeasurement.Report(
            total: 2, correct: 2, over: 0, under: 0, dangerousRatedSafe: [], misses: [], fallbacks: 0,
            p50Milliseconds: 0.05, p95Milliseconds: 0.1, maxMilliseconds: 0.2)
        try store.record(.init(report, examplesSource: "eval.tsv"), for: first.manifest.version)
        let measured = try #require(store.manifest(first.manifest.version))
        #expect(measured.measurements.map(\.correct) == [2] && measured.examples == first.manifest.examples)
        #expect(throws: ClassifierStore.Failure.unknownVersion("nope")) {
            try store.record(.init(report, examplesSource: "x"), for: "nope")
        }
    }

    @Test func heldOutCommandsNeverTrain() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ClassifierStore(home: home)
        let examples = [
            RiskExample(command: "git push origin main", level: .moderate),
            RiskExample(command: "cat notes.txt", level: .safe), RiskExample(command: "ls", level: .safe),
        ]
        #expect(store.withoutHeldOut(examples).removed == 0, "no held-out file, nothing left out")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data("moderate\tgit push origin main\nsafe\tcat other.txt\n".utf8).write(to: store.heldOut)
        let held = store.withoutHeldOut(examples)
        #expect(held.removed == 2 && held.kept.map(\.command) == ["ls"], "exact and family overlaps both go")
        let extra = home.root.appending(path: "more.tsv")
        try Data("safe\tls\n".utf8).write(to: extra)
        #expect(store.withoutHeldOut(examples, also: [extra]).kept.isEmpty)
    }

    @Test func removingSparesTheDefaultAndTheVersionInUse() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ClassifierStore(home: home)
        let trained = try store.train(RiskExamples.bundled, source: "bundled")
        let version = trained.manifest.version
        #expect(throws: ClassifierStore.Failure.protected(version, reason: "approval.coremlModel names it")) {
            try store.remove(version, inUse: version)
        }
        if let installed = try store.installDefault() {
            #expect(throws: ClassifierStore.Failure.self) { try store.remove(installed, inUse: nil) }
        }
        try store.remove(version, inUse: nil)
        #expect(store.manifest(version) == nil)
        #expect(throws: ClassifierStore.Failure.unknownVersion(version)) { try store.remove(version, inUse: nil) }
    }

    @Test func theShippedDefaultIsForThisBuildAndInstallsOnce() throws {
        let shipped = try #require(ShippedClassifier.current, "this build ships a default")
        #expect(shipped.manifest.version == ClassifierStore.defaultVersion())
        #expect(shipped.manifest.examplesDigest == ClassifierStore.digest(RiskExamples.bundled))
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ClassifierStore(home: home)
        #expect(try store.installDefault() == ClassifierStore.defaultVersion())
        #expect(try Data(contentsOf: store.model(ClassifierStore.defaultVersion())) == shipped.model)
        #expect(try store.installDefault() == ClassifierStore.defaultVersion(), "a second install changes nothing")
        #expect(try CoreMLRiskClassifier.prepare(store.model(ClassifierStore.defaultVersion())).contract == "2")
        // The resource round-trips, and anything else is no default.
        let text = try ShippedClassifier.resource(manifest: shipped.manifest, model: shipped.model)
        #expect(ShippedClassifier.decode(text)?.model == shipped.model)
        #expect(ShippedClassifier.decode("{}") == nil)
    }

    @Test func configReferencesResolveInTheStoreAndCoremlWithoutAModelUsesTheDefault() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        var config = Config().resolved
        config.coremlModel = "risk@0.12.0-local.7"
        #expect(
            Session.coremlModelURL(config: config, home: home) == ClassifierStore(home: home).model("0.12.0-local.7"))
        config.coremlModel = nil
        #expect(
            Session.coremlModelURL(config: config, home: home)
                == ClassifierStore(home: home).model(ClassifierStore.defaultVersion()))
        config.coremlModel = "risk.mlmodel"
        #expect(
            Session.coremlModelURL(config: config, home: home)?.path.hasSuffix("models/coreml/risk.mlmodel") == true)
    }
}
