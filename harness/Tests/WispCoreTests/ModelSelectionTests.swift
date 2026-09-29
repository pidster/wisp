import Foundation
import FoundationModels
import Testing

@testable import WispCore

@Suite struct ModelSelectionTests {
    @Test func parsesKnownSpellings() throws {
        #expect(try ModelSelection(parsing: "system") == .system)
        #expect(try ModelSelection(parsing: "") == .system)
        #expect(try ModelSelection(parsing: " private-cloud ") == .privateCloud)
        #expect(try ModelSelection(parsing: "pcc") == .privateCloud)
    }

    @Test func rejectsUnknownSpellings() throws {
        #expect(throws: ModelSelection.Failure.unknownModel("gpt-5")) { try ModelSelection(parsing: "gpt-5") }
        // Any scheme parses; a backend this build lacks fails when the model is resolved.
        #expect(try ModelSelection(parsing: "adapter:x") == .local(backend: "adapter", name: "x"))
        #expect(throws: ModelSelection.Failure.self) { try ModelSelection(parsing: "adapter:x").resolve() }
        #expect(throws: ModelSelection.Failure.unknownModel("adapter:")) { try ModelSelection(parsing: "adapter:") }
    }

    @Test func privateCloudNeedsTheEntitlementBeforeTheFrameworkIsAsked() throws {
        #expect(
            throws: ModelSelection.Failure.unavailable(
                model: "private-cloud", reason: ModelSelection.missingPrivateCloudEntitlement)
        ) { try ModelSelection.privateCloud.resolve(entitlements: .none) }
        // With the entitlement the framework's own availability decides; on an eligible Mac it resolves.
        let granted = Entitlements.granting([Entitlements.privateCloudCompute])
        #expect(granted.has(Entitlements.privateCloudCompute) && !granted.has("other"))
        if case .available = PrivateCloudComputeLanguageModel().availability {
            let resolved = try ModelSelection.privateCloud.resolve(entitlements: granted)
            #expect(resolved.capabilitySource == .framework && resolved.asset == nil)
        }
        // The test binary is ad-hoc signed and holds no entitlements.
        #expect(!Entitlements.process.has(Entitlements.privateCloudCompute))
        #expect(throws: ModelSelection.Failure.self) { try ModelSelection.privateCloud.resolve() }
    }

    @Test func describesAndFlagsDeviceEgress() {
        #expect(ModelSelection.system.description == "system")
        #expect(ModelSelection.privateCloud.description == "private-cloud")
        #expect(!ModelSelection.system.leavesDevice)
        #expect(ModelSelection.privateCloud.leavesDevice)
    }

    @Test func readWindowKeepsAPositiveReadingAndNeverFails() async {
        struct Refused: Error {}
        #expect(await ResolvedModel.readWindow { 32_768 } == 32_768)
        #expect(await ResolvedModel.readWindow { throw Refused() } == nil)
        #expect(await ResolvedModel.readWindow { 0 } == nil)
        // A reading that never comes back, and ignores cancellation, is abandoned at the timeout rather
        // than hanging resolution: a continuation nobody resumes cannot be cancelled.
        let started = ContinuousClock.now
        #expect(
            await ResolvedModel.readWindow(timeout: .milliseconds(50)) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            } == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func configCarriesTheModel() throws {
        #expect(Config().resolved.model == .system)
        #expect(Config(model: .privateCloud).resolved.model == .privateCloud)
        let file = FileManager.default.temporaryDirectory.appending(path: "wisp-model-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"model":"nope"}"#.utf8).write(to: file)
        #expect(throws: DecodingError.self) { try Config.load(from: file) }
        try Config(model: .privateCloud).save(to: file)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"private-cloud\""))
        #expect(try Config.load(from: file).model == .privateCloud)
    }
}
