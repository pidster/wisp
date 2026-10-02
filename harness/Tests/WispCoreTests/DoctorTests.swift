import Foundation
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct DoctorTests {
    @Test func rendersAndJudgesFindings() {
        let findings = [
            Doctor.Finding(name: "a", ok: true, detail: "fine"), Doctor.Finding(name: "b", ok: false, detail: "broken"),
        ]
        #expect(Doctor.render(findings) == "ok   a: fine\nFAIL b: broken")
        #expect(!Doctor.allPassed(findings))
        #expect(Doctor.allPassed([findings[0]]))
    }

    @Test func checksConfigAndHomeWithoutTheModel() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = Doctor.Probes(systemModel: { nil }, configuredModel: { _, _, _ in nil })
        let doctor = Doctor(home: Home(root: root), probes: healthy)
        var findings = doctor.run()
        // The default classifier is the shipped Core ML one, so the doctor checks it too.
        #expect(
            findings.map(\.name) == [
                "macOS", "model", "classifier", "context window", "sandbox", "config", "settings", "facts store",
                "subject kinds", "saved transcripts", "notify", "home",
                "pending approvals",
            ])
        let broken = Doctor.Probes(
            systemModel: { "not enabled" }, configuredModel: { model, _, _ in "\(model) is down" })
        let extra = Doctor(home: Home(root: root), model: .privateCloud, probes: broken).run()
        #expect(
            extra.map(\.name) == [
                "macOS", "model", "classifier", "configured model", "context window", "sandbox", "config",
                "settings", "facts store", "subject kinds", "saved transcripts", "notify", "home",
                "pending approvals",
            ])
        #expect(!extra[1].ok && extra[1].detail == "not enabled")
        #expect(!extra[3].ok && extra[3].detail == "private-cloud is down")
        #expect(extra[4].ok && extra[4].detail.contains("not checked"))
        func finding(_ name: String) throws -> Doctor.Finding {
            try #require(findings.first { $0.name == name })
        }
        #expect(try finding("config").ok && finding("config").detail.contains("defaults apply"))
        #expect(try finding("home").ok)
        try Data("{bad".utf8).write(to: Home(root: root).configFile)
        findings = doctor.run()
        #expect(try !finding("config").ok)
        #expect(try finding("sandbox").ok)
        #expect(try finding("settings").detail.contains("not checked"))
    }

    /// A home in a fresh temporary directory, and a doctor over it that asks no model anything.
    private func fixture(
        config: Config.Resolved = Config().resolved, window: Doctor.ContextWindow? = nil,
        model: ModelSelection = .system
    ) throws -> (Home, Doctor, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probes = Doctor.Probes(
            systemModel: { nil }, configuredModel: { _, _, _ in nil }, contextWindow: { _, _, _ in window })
        let home = Home(root: root)
        return (home, Doctor(home: home, model: model, config: config, probes: probes), root)
    }

    @Test func theFactsStoreIsAbsentOkParsedAndOwnerOnly() throws {
        let (home, doctor, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(doctor.factsStore().ok && doctor.factsStore().detail.contains("no permanent facts yet"))
        let facts = SharedFacts.permanent(home: home)
        for name in ["codename", "ticket"] {
            try facts.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .permanent, subject: "entity", name: name), source: .person,
                    value: "v", temporalClass: .permanent, method: .stated, turn: 1))
        }
        let good = doctor.factsStore()
        #expect(
            good.ok && good.detail.contains("2 current permanent facts (entity 2)") && good.detail.contains("mode 600"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.factsFile.path)
        let open = doctor.factsStore()
        #expect(
            !open.ok && open.detail.contains("mode 644") && open.detail.contains("chmod 600 \(home.factsFile.path)"))
        try Data("{nope".utf8).write(to: home.factsFile)
        let broken = doctor.factsStore()
        #expect(!broken.ok && broken.detail.contains("does not parse") && broken.detail.contains("no permanent facts"))
    }

    @Test func subjectKindsNameWhatConfigAddsAndChanges() throws {
        let (_, plain, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shipped = plain.subjectKinds()
        #expect(shipped.ok && !shipped.detail.contains("added by config"))
        var config = Config().resolved
        config.subjectKinds = SubjectKinds.defaults.applying(
            Config.FactsConfig(kinds: [
                .init(name: "vendor", temporalClass: .permanent, normaliser: "trim"),
                .init(name: "task", normaliser: "trim"),
            ]))
        let (_, custom, other) = try fixture(config: config)
        defer { try? FileManager.default.removeItem(at: other) }
        let finding = custom.subjectKinds()
        #expect(finding.ok && finding.detail.contains("added by config: vendor"))
        #expect(finding.detail.contains("changed by config: task"))
        config.subjectKinds = SubjectKinds(
            kinds: [SubjectKind(name: "odd", temporalClass: .dynamic, normaliser: "shout", description: "x")],
            testCommands: [])
        let (_, bad, third) = try fixture(config: config)
        defer { try? FileManager.default.removeItem(at: third) }
        let broken = bad.subjectKinds()
        #expect(!broken.ok && broken.detail.contains("kind odd: unknown normaliser shout"))
    }

    @Test func savedTranscriptsMustHaveAMatchingStoreFile() async throws {
        let (home, doctor, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(doctor.savedTranscripts().ok && doctor.savedTranscripts().detail == "none saved")
        try home.ensure()
        try FileManager.default.createDirectory(at: home.transcripts, withIntermediateDirectories: true)
        let store = TranscriptStore(directory: home.transcripts)
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("hi")]), contextSize: 10_000))
        _ = try await agent.respond(to: "hello")
        try store.save(agent.store, as: "good")
        #expect(doctor.savedTranscripts().ok)
        try store.save(agent.transcript, as: "old")
        let stuck = doctor.savedTranscripts()
        #expect(!stuck.ok && stuck.detail.contains("1 of 2 cannot be resumed: old"))
        #expect(stuck.detail.contains("older wisp") && !stuck.detail.contains("good,"))
        try Data("{}".utf8).write(to: store.linksURL(for: "old"))
        #expect(!doctor.savedTranscripts().ok)
    }

    @Test func numericSettingsMustBeInRangeAndClampsAreNoted() throws {
        let (home, doctor, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(doctor.settingsInRange().ok && doctor.settingsInRange().detail.contains("shownOutputLines 20"))
        try Data(#"{"shownOutputLines": -3, "inlineOutputBytes": 2048}"#.utf8).write(to: home.configFile)
        let clamped = doctor.settingsInRange()
        #expect(clamped.ok && clamped.detail.contains("shownOutputLines -3 is used as 0"))
        try Data(#"{"facts": {"share": 0.9}}"#.utf8).write(to: home.configFile)
        let refused = doctor.settingsInRange()
        #expect(!refused.ok && refused.detail.contains("facts.share 0.9 must be between 0 and 0.5"))
        try Data(#"{"context": {"target": 0.95, "headroomTurns": 100}}"#.utf8).write(to: home.configFile)
        let context = doctor.settingsInRange()
        #expect(!context.ok && context.detail.contains("context.target 0.95 must be between 0.1 and 0.8"))
        #expect(context.detail.contains("context.headroomTurns 100 must be between 0 and 64"))
        try Data(#"{"context": {"target": 0.6}}"#.utf8).write(to: home.configFile)
        #expect(doctor.settingsInRange().ok && doctor.settingsInRange().detail.contains("context.headroomTurns 8"))
        #expect(!doctor.settingsInRange().detail.contains("is used as"))
        // A target near the budget is accepted, and reported as the cap it is used at.
        try Data(#"{"context": {"target": 0.8}}"#.utf8).write(to: home.configFile)
        let capped = doctor.settingsInRange()
        #expect(capped.ok && capped.detail.contains("context.target 0.8 is used as 0.65"), "\(capped.detail)")
    }

    @Test func theContextWindowSaysHowItIsKnown() throws {
        func detail(_ window: Doctor.ContextWindow?, _ model: ModelSelection = .system) throws -> String {
            let (_, doctor, root) = try fixture(window: window, model: model)
            defer { try? FileManager.default.removeItem(at: root) }
            let finding = try #require(doctor.run().first { $0.name == "context window" })
            #expect(finding.ok)
            return finding.detail
        }
        #expect(try detail(.init(size: 8192)) == "8,192 tokens, reported by the framework")
        #expect(try detail(.init(size: nil)).contains("unknown") && detail(.init(size: nil)).contains("8,192"))
        #expect(try detail(nil).contains("not checked"))
        let sized = try detail(
            .init(size: 32768, note: "32,768 of 131,072: 10.2 GiB of an 11.1 GiB budget"), .ollama("x"))
        #expect(sized.contains("32,768 tokens, sized from memory (ADR 0043): 32,768 of 131,072"))
        let configured = try detail(.init(size: 16384, note: "configured as ollama.contextLength"), .ollama("x"))
        #expect(configured == "16,384 tokens, configured (ollama.contextLength)")
        let fallback = try detail(
            .init(size: 8192, note: "8,192, the default: Ollama reported no model shape"), .ollama("x"))
        #expect(fallback.contains("the default, not sized"))
    }
}
