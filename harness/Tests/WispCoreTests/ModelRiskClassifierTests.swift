import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The model classifier on a model other than the on-device one, as the local-model comparison measures it
/// (docs/measurements.md): the verdict comes from the given model's structured reply, and a model that fails
/// reports `moderate` with the failure, as the on-device model's path does.
@Suite struct ModelRiskClassifierTests {
    /// A scripted model resolved as a local backend's would be.
    private func model(
        _ steps: [ScriptedModel.Step],
        capabilities: [LanguageModelCapabilities.Capability] = [
            .toolCalling, .guidedGeneration,
        ]
    ) -> (ResolvedModel, ScriptedModel) {
        let scripted = ScriptedModel(steps: steps, capabilities: capabilities)
        return (ResolvedModel(selection: .ollama("scripted"), custom: scripted), scripted)
    }

    @Test func classifiesWithTheGivenModel() async throws {
        let (resolved, scripted) = model([.say(#"{"reason":"deletes the build directory","risk":"dangerous"}"#)])
        let assessment = await ModelRiskClassifier(model: resolved).classify(
            command: "rm -rf build", workingDirectory: "/tmp")
        #expect(assessment.level == .dangerous)
        #expect(assessment.reasons == ["deletes the build directory"])
        #expect(assessment.metadata[RiskAssessment.failureKey] == nil)
        // One fresh session, with the classifier's instructions and the command between the markers.
        let request = try #require(scripted.script.requests.withLock { $0.first })
        let text = "\(request.transcript)"
        #expect(text.contains("<<<COMMAND"))
        #expect(text.contains("rm -rf build"))
    }

    @Test func aReplyThatIsNotAVerdictAsksRatherThanWavesThrough() async {
        let (resolved, _) = model([.say("I think it is fine")])
        let assessment = await ModelRiskClassifier(model: resolved).classify(
            command: "rm -rf build", workingDirectory: "/tmp")
        #expect(assessment.level == .moderate)
        #expect(assessment.metadata[RiskAssessment.failureKey] != nil)
    }
}
