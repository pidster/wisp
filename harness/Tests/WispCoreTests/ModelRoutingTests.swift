import Foundation
import Testing

@testable import WispCore

@Suite struct ModelRoutingTests {
    static let task = ChangeDraft.routingTask
    static let big = ModelSelection.ollama("qwen3.8:27b")

    static func measured(_ model: String, _ passed: Int, of total: Int, upTo bytes: Int?) -> WispCore.Measurement {
        WispCore.Measurement(task: task, model: model, passed: passed, total: total, notes: "n", maxInputBytes: bytes)
    }

    static let measurements = [
        measured("system", 10, of: 10, upTo: 1_000), measured("system", 1, of: 2, upTo: 14_000),
        measured("system", 2, of: 2, upTo: 52_000), measured("ollama:qwen3.8:27b", 10, of: 10, upTo: 1_000),
        measured("ollama:qwen3.8:27b", 2, of: 2, upTo: 52_000), measured("ollama:qwen3.8:27b", 5, of: 5, upTo: nil),
    ]

    @Test func aModelIsTrustedUpToItsFirstFailingBand() {
        // The system model's 14 KB band failed, so its passing 52 KB band does not count.
        #expect(ModelRouting.envelope(task: Self.task, model: .system, measurements: Self.measurements) == 1_000)
        #expect(ModelRouting.envelope(task: Self.task, model: Self.big, measurements: Self.measurements) == 52_000)
        let noisy = [Self.measured("system", 7, of: 10, upTo: 1_000), Self.measured("system", 2, of: 2, upTo: 14_000)]
        #expect(ModelRouting.envelope(task: Self.task, model: .system, measurements: noisy) == 0)
        #expect(ModelRouting.envelope(task: "triage", model: .system, measurements: Self.measurements) == 0)
    }

    @Test func theFirstTrustedModelOnTheLadderWins() throws {
        let ladder: [ModelSelection] = [.system, Self.big]
        let small = try #require(
            ModelRouting.choose(task: Self.task, inputBytes: 800, ladder: ladder, measurements: Self.measurements))
        #expect(small.model == .system && small.reason.contains("up to 1000 bytes"), "\(small.reason)")
        let medium = ModelRouting.choose(
            task: Self.task, inputBytes: 9_000, ladder: ladder, measurements: Self.measurements)
        #expect(medium?.model == Self.big && medium?.reason.contains("up to 52000 bytes") == true)
        let huge = ModelRouting.choose(
            task: Self.task, inputBytes: 90_000, ladder: ladder, measurements: Self.measurements)
        #expect(huge?.model == Self.big && huge?.reason.hasPrefix("no model on the ladder is trusted") == true)
        #expect(ModelRouting.choose(task: Self.task, inputBytes: 1, ladder: [], measurements: Self.measurements) == nil)
    }

    @Test func draftsRouteUnlessTheCallerNamedAModelOrTheChoiceCannotOpen() {
        let ladder: [ModelSelection] = [.system, Self.big]
        let opens: (ModelSelection) -> String? = { _ in nil }
        #expect(
            ChangeDraft.route(
                explicit: .system, inputBytes: 90_000, ladder: ladder, measurements: Self.measurements, opens: opens)
                == nil)
        #expect(
            ChangeDraft.route(explicit: nil, inputBytes: 9, ladder: [], measurements: Self.measurements, opens: opens)
                == nil)
        let routed = ChangeDraft.route(
            explicit: nil, inputBytes: 20_000, ladder: ladder, measurements: Self.measurements, opens: opens)
        #expect(routed?.model == Self.big)
        let down = ChangeDraft.route(
            explicit: nil, inputBytes: 20_000, ladder: ladder, measurements: Self.measurements,
            opens: { $0 == Self.big ? "no Ollama server" : nil })
        #expect(down?.model == .system && down?.reason.contains("cannot be opened (no Ollama server)") == true)
    }

    @Test func measurementsOfOneTaskAndModelAtDifferentSizesAreKeptApart() {
        var all: [WispCore.Measurement] = []
        all = Measurements.merge(all, with: Self.measured("system", 1, of: 2, upTo: 1_000))
        all = Measurements.merge(all, with: Self.measured("system", 2, of: 2, upTo: 52_000))
        all = Measurements.merge(all, with: Self.measured("system", 2, of: 2, upTo: 1_000))
        #expect(all.count == 2 && all.contains { $0.maxInputBytes == 1_000 && $0.passed == 2 })
        #expect(Measurements.decode(Measurements.encode(all))?.map(\.maxInputBytes) == [1_000, 52_000])
    }

    @Test func theLadderComesFromTheConfigAndRoutingIsAudited() throws {
        let json = #"{"routing":{"ladder":["system","ollama:qwen3.8:27b"]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.resolved.routingLadder == [.system, Self.big])
        #expect(Config().resolved.routingLadder.isEmpty)
        #expect(Config(routing: .init(ladder: [.system])).resolved.routingLadder == [.system])
        let details = AuditEvent.Details.modelRouted(
            task: Self.task, inputBytes: 5, decision: .init(model: .system, reason: "r"))
        #expect(Set(details.keys) == AuditEvent.fields(for: .modelRouted) && details["model"] == "system")
    }

    @Test func aTaskUsesItsMeasuredDefaultUnlessTheConfigOrTheCallerNamesAModel() throws {
        let defaults = Config().resolved.taskModels
        #expect(defaults == ["secrets": .system])
        let measured = try #require(ModelRouting.forTask("secrets", explicit: nil, models: defaults))
        #expect(measured.model == .system && measured.reason.contains("measured default for secrets"))
        #expect(ModelRouting.forTask("secrets", explicit: Self.big, models: defaults) == nil)
        #expect(ModelRouting.forTask("triage", explicit: nil, models: defaults) == nil)
        let json = #"{"routing":{"tasks":{"secrets":"ollama:qwen3.8:27b"}}}"#
        let configured = try JSONDecoder().decode(Config.self, from: Data(json.utf8)).resolved.taskModels
        let chosen = try #require(ModelRouting.forTask("secrets", explicit: nil, models: configured))
        #expect(chosen.model == Self.big && chosen.reason == "routing.tasks.secrets is ollama:qwen3.8:27b")
        #expect(ConfigSettings.defaultValue("routing.tasks.secrets") == "system")
    }

    @Test func theShippedMeasurementsGiveTheSystemModelNoDraftingEnvelope() {
        // Recorded 2026-09-24: the system model passed 7 of 10 small diffs, below the 80% bar.
        #expect(ModelRouting.envelope(task: Self.task, model: .system, measurements: Measurements.embedded) == 0)
        #expect(ModelRouting.envelope(task: Self.task, model: Self.big, measurements: Measurements.embedded) >= 50_000)
    }
}
