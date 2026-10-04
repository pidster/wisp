import Foundation
import FoundationModels
import Testing
import WispCore

@testable import WispCoreAI

/// The Core AI backend without a model: name resolution, the missing-asset error, listing, settings.
@Suite struct CoreAIBackendTests {
    init() { ModelBackends.register(CoreAIBackend()) }

    private func scratch() throws -> (home: Home, models: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-coreai-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        let models = home.models.appending(path: "coreai")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        return (home, models)
    }

    @Test func namesResolveToBundleDirectories() throws {
        let (home, models) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let config = Config().resolved
        #expect(CoreAIBackend.modelsDirectory(config: config, home: home).path == models.path)
        #expect(CoreAIBackend.bundleURL(for: "q", config: config, home: home).path == models.appending(path: "q").path)
        #expect(CoreAIBackend.bundleURL(for: "/opt/m", config: config, home: home).path == "/opt/m")
        let custom = Config(coreai: .init(modelsDirectory: "/opt/bundles")).resolved
        #expect(CoreAIBackend.bundleURL(for: "q", config: custom, home: home).path == "/opt/bundles/q")
        #expect(CoreAIBackend().settings(in: custom, home: home) == ["modelsDirectory": "/opt/bundles"])
    }

    @Test func aMissingBundleIsUnavailableWithWhereToLookAndHowToExport() throws {
        let (home, models) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try FileManager.default.createDirectory(
            at: models.appending(path: "present"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: models.appending(path: "present/metadata.json"))
        let config = Config().resolved
        do {
            _ = try ModelSelection.local(backend: "coreai", name: "absent").resolve(config: config, home: home)
            Issue.record("resolved a missing bundle")
        } catch ModelSelection.Failure.unavailable(let model, let reason) {
            #expect(model == "coreai:absent")
            #expect(reason.contains("no Core AI bundle at \(models.path)/absent"))
            #expect(reason.contains("bundles under \(models.path): present"))
            #expect(reason.contains("uv run coreai.llm.export"))
        }
        // A bundle whose metadata is present but whose asset is not fails through the bridge, typed.
        do {
            _ = try CoreAIBackend().resolve("present", config: config, home: home)
            Issue.record("resolved an empty bundle")
        } catch ModelSelection.Failure.unavailable(let model, let reason) {
            #expect(model == "coreai:present")
            #expect(!reason.isEmpty)
        }
    }

    @Test func theWindowIsTheOneTheBundleWasExportedFor() throws {
        let (home, models) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        func bundle(_ metadata: String) throws -> URL {
            let url = models.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(metadata.utf8).write(to: url.appending(path: "metadata.json"))
            return url
        }
        let current = try bundle(#"{"metadata_version":"0.2","kind":"llm","language":{"max_context_length":8192}}"#)
        #expect(
            CoreAIBackend.contextWindow(in: current)
                == .init(window: 8192, reason: "declared by the bundle (metadata.json language.max_context_length)"))
        let legacy = try bundle(#"{"name":"q","max_context_length":4096}"#)
        #expect(CoreAIBackend.contextWindow(in: legacy)?.window == 4096)
        #expect(CoreAIBackend.contextWindow(in: legacy)?.reason.hasSuffix("(metadata.json max_context_length)") == true)
        #expect(CoreAIBackend.contextWindow(in: try bundle(#"{"kind":"llm","language":{}}"#)) == nil)
        #expect(CoreAIBackend.contextWindow(in: try bundle("not json")) == nil)
        #expect(CoreAIBackend.contextWindow(in: models.appending(path: "absent")) == nil)
    }

    @Test func listsBundlesWithTheirMetadata() async throws {
        let (home, models) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let bundle = models.appending(path: "qwen3_0_6b")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(
            #"{"kind":"llm","compression":"4bit","source":{"hf_model_id":"Qwen/Qwen3-0.6B"},"language":{"max_context_length":8192}}"#
                .utf8
        ).write(to: bundle.appending(path: "metadata.json"))
        try Data(repeating: 0, count: 2048).write(to: bundle.appending(path: "weights.aimodel"))
        try FileManager.default.createDirectory(
            at: models.appending(path: "not-a-bundle"), withIntermediateDirectories: true)
        let installed = try await CoreAIBackend().installed(config: Config().resolved, home: home)
        #expect(installed.map(\.selection) == [.local(backend: "coreai", name: "qwen3_0_6b")])
        #expect(installed.first?.detail.hasPrefix("llm 4bit Qwen/Qwen3-0.6B") == true)
        #expect(installed.first?.detail.contains("KB") == true)
        #expect(installed.first?.detail.hasSuffix("8,192-token window") == true)
        #expect(
            try await CoreAIBackend().installed(
                config: Config().resolved, home: Home(root: URL(filePath: "/nonexistent"))
            ).isEmpty)
    }
}

/// Runs a real exported bundle. Needs `WISP_COREAI_TESTS=1` and `WISP_COREAI_MODEL` set to a bundle
/// directory; never in the gate. See docs/backends.md for the export.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_COREAI_TESTS"] == "1"))
struct CoreAILiveTests {
    static let bundle = ProcessInfo.processInfo.environment["WISP_COREAI_MODEL"] ?? ""

    @Test func textConversationAndDeclaredCapabilities() async throws {
        ModelBackends.register(CoreAIBackend())
        let resolved = try ModelSelection.local(backend: "coreai", name: Self.bundle).resolve()
        print("COREAI capabilities: \(resolved.capabilityNames) source \(resolved.capabilitySource)")
        #expect(resolved.asset == Self.bundle)
        let agent = Agent(instructions: "Answer with one word.", tools: [], model: resolved)
        let started = ContinuousClock.now
        let reply = try await agent.respond(to: "What colour is the sky on a clear day?")
        print("COREAI text: \(reply.text.prefix(200)) in \(ContinuousClock.now - started)")
        #expect(!reply.text.isEmpty)
        if resolved.capabilities.contains(.toolCalling) {
            let withTools = Agent(
                instructions: "Use the current_date tool, then answer with the date only.", tools: [CurrentDateTool()],
                model: resolved)
            // A 0.6B model does not always finish its turn; report what happened either way.
            var outcomes: [String] = []
            for attempt in 1...3 {
                let fresh = Agent(
                    instructions: "Use the current_date tool, then answer with the date only.",
                    tools: [CurrentDateTool()], model: resolved)
                do {
                    let dated = try await fresh.respond(to: "What is today's date in Asia/Tokyo?")
                    let kinds = fresh.transcript.map { entry -> String in
                        if case .toolCalls = entry { return "toolCalls" }
                        if case .toolOutput = entry { return "toolOutput" }
                        if case .reasoning = entry { return "reasoning" }
                        return "other"
                    }
                    outcomes.append(kinds.contains("toolOutput") ? "tool loop ran" : "no tool call")
                    print("COREAI tools attempt \(attempt): \(dated.text.prefix(60)) transcript \(kinds)")
                } catch {
                    outcomes.append("error: \(error)")
                    print("COREAI tools attempt \(attempt): error \(error)")
                }
            }
            // Reported, not asserted: with the pinned bridge a 0.6B model completes the loop only some of
            // the time (3 of 6 probe attempts on 2026-09-20); declared support is eligibility, not proof.
            print("COREAI tool loop outcomes: \(outcomes)")
            _ = withTools
        }
    }
}
