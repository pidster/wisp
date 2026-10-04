import Foundation
import FoundationModels
import Testing
import WispCore

@testable import WispMLX

/// The MLX backend without weights: naming, declared capabilities, listing, settings, and the two
/// refusals (not compiled in, no model directory).
@Suite struct MLXBackendTests {
    init() { ModelBackends.register(MLXBackend()) }

    private func scratch() throws -> (home: Home, models: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-mlx-\(UUID().uuidString)")
        let home = Home(root: root)
        try home.ensure()
        let models = home.models.appending(path: "mlx")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        return (home, models)
    }

    @Test func namesCapabilitiesAndSettings() throws {
        let (home, models) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let config = Config(
            mlx: .init(models: [
                "q": .init(capabilities: ["toolCalling", "reasoning"]), "bad": .init(capabilities: ["magic"]),
            ])
        ).resolved
        #expect(MLXBackend.modelURL(for: "q", config: config, home: home).path == models.appending(path: "q").path)
        #expect(MLXBackend.modelURL(for: "/opt/m", config: config, home: home).path == "/opt/m")
        let declared = try MLXBackend.declaredCapabilities(for: "q", config: config)
        #expect(declared.declared && declared.capabilities == [.toolCalling, .reasoning])
        let undeclared = try MLXBackend.declaredCapabilities(for: "other", config: config)
        #expect(!undeclared.declared && undeclared.capabilities.isEmpty)
        #expect(throws: ModelSelection.Failure.self) { try MLXBackend.declaredCapabilities(for: "bad", config: config) }
        let settings = MLXBackend().settings(in: config, home: home).objectValue
        #expect(settings?["compiledIn"] == .bool(MLXBackend.isCompiledIn))
        #expect(
            settings?["models"]?.objectValue?["q"]?.objectValue?["capabilities"]
                == .array(["toolCalling", "reasoning"]))
        #expect(CapabilityName.allCases.map(\.rawValue) == ["toolCalling", "guidedGeneration", "reasoning", "vision"])
    }

    @Test func listsModelDirectoriesAndRefusesWhatItCannotServe() async throws {
        let (home, models) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let model = models.appending(path: "qwen3-4bit")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3","quantization":{"bits":4,"group_size":64}}"#.utf8).write(
            to: model.appending(path: "config.json"))
        try FileManager.default.createDirectory(at: models.appending(path: "empty"), withIntermediateDirectories: true)
        let config = Config(mlx: .init(models: ["qwen3-4bit": .init(capabilities: ["toolCalling"])])).resolved
        let installed = try await MLXBackend().installed(config: config, home: home)
        #expect(installed.map(\.selection) == [.local(backend: "mlx", name: "qwen3-4bit")])
        #expect(installed.first?.detail.hasPrefix("qwen3 4-bit capabilities: toolCalling") == true)
        do {
            _ = try ModelSelection.local(backend: "mlx", name: "absent").resolve(config: config, home: home)
            Issue.record("resolved a missing model")
        } catch ModelSelection.Failure.unavailable(let name, let reason) {
            #expect(name == "mlx:absent")
            if MLXBackend.isCompiledIn {
                #expect(reason.contains("no MLX model at \(models.path)/absent"))
                #expect(reason.contains("models under \(models.path): qwen3-4bit"))
            } else {
                #expect(reason.contains("--traits MLX"))
            }
        }
    }
}

/// The window of an MLX model, from its `config.json` and its weights' size as ADR 0043 sizes an Ollama
/// model's, or configured (ADR 0052).
@Suite struct MLXWindowTests {
    static let gib = 1 << 30

    private func modelDirectory(config: String?, weights: [Int] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wisp-mlx-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let config { try Data(config.utf8).write(to: directory.appending(path: "config.json")) }
        for (index, size) in weights.enumerated() {
            try Data(count: size).write(to: directory.appending(path: "model-\(index).safetensors"))
        }
        try Data(count: 999).write(to: directory.appending(path: "tokenizer.json"))
        return directory
    }

    static let qwen3 =
        #"{"model_type":"qwen3","max_position_embeddings":40960,"num_hidden_layers":28,"num_attention_heads":16,"#
        + #""num_key_value_heads":8,"head_dim":128,"hidden_size":2048}"#

    @Test func theWindowIsSizedFromTheConfigAndTheWeights() throws {
        let directory = try modelDirectory(config: Self.qwen3, weights: [3000, 2000])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(MLXBackend.weightBytes(in: directory) == 5000)
        let memory = MemoryState(installed: 16 * Self.gib, available: 8 * Self.gib)
        let sized = MLXBackend.window(for: directory, configured: nil, memory: memory, weightsHeld: false)
        let shape = try #require(
            ContextSizing.shape(fromModelConfig: [
                "max_position_embeddings": 40960,
                "num_hidden_layers": 28, "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 128,
            ]))
        #expect(
            sized == ContextSizing.size(shape: shape, weights: 5000, memory: memory, shortfall: MLXBackend.shortfall))
        #expect(sized.window == 28672 && sized.reason.hasPrefix("28,672 of 40,960"), "\(sized.reason)")
        // Weights this process already holds count as available, as Ollama's loaded models do.
        let held = MLXBackend.window(
            for: directory, configured: nil, memory: MemoryState(installed: 16 * Self.gib, available: 0),
            weightsHeld: true)
        #expect(
            held
                == ContextSizing.size(
                    shape: shape, weights: 5000, memory: MemoryState(installed: 16 * Self.gib, available: 0),
                    held: 5000,
                    shortfall: MLXBackend.shortfall))
        let tight = MLXBackend.window(
            for: directory, configured: nil, memory: MemoryState(installed: 2 * Self.gib, available: Self.gib / 2),
            weightsHeld: false)
        #expect(tight.window == ContextSizing.floor && tight.reason.contains("may swap"))
    }

    @Test func aConfiguredWindowWinsAndAMissingShapeFallsBackToTheFloor() throws {
        let directory = try modelDirectory(config: Self.qwen3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = MemoryState(installed: 16 * Self.gib, available: 8 * Self.gib)
        #expect(
            MLXBackend.window(for: directory, configured: 12288, memory: memory, weightsHeld: false)
                == .init(window: 12288, reason: "configured as mlx.contextLength"))
        let bare = try modelDirectory(config: #"{"model_type":"mystery"}"#)
        defer { try? FileManager.default.removeItem(at: bare) }
        let fallback = MLXBackend.window(for: bare, configured: nil, memory: memory, weightsHeld: false)
        #expect(fallback.window == ContextSizing.floor && fallback.reason.contains("the default"))
    }

    @Test func settingsCarryTheWindowAndTheExecutor() {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-mlx-settings"))
        let defaults = MLXBackend().settings(in: Config().resolved, home: home).objectValue
        #expect(defaults?["executor"] == "wisp" && defaults?["contextLength"] == "sized per model (ADR 0052)")
        let set = MLXBackend().settings(
            in: Config(mlx: .init(contextLength: 16384, executor: .bridge)).resolved, home: home
        ).objectValue
        #expect(set?["executor"] == "bridge" && set?["contextLength"] == 16384)
    }
}

/// Runs real weights. Needs `WISP_MLX_TESTS=1`, a build with `--traits MLX`, and `WISP_MLX_MODEL`
/// set to a model directory; never in the gate. Run it with `scripts/check mlx-live <model directory>`,
/// which places `mlx.metallib` beside the test bundle's binary, where MLX looks for it; without that,
/// MLX fails with "Failed to load the default metallib" (ADR 0047).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MLX_TESTS"] == "1" && MLXBackend.isCompiledIn))
struct MLXLiveTests {
    static let directory = ProcessInfo.processInfo.environment["WISP_MLX_MODEL"] ?? ""

    @Test func textConversationThenToolsWhenDeclared() async throws {
        ModelBackends.register(MLXBackend())
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-mlx-live-\(UUID().uuidString)"))
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let text = try ModelSelection.local(backend: "mlx", name: Self.directory).resolve(
            config: Config().resolved, home: home)
        print("MLX undeclared capabilities: \(text.capabilityNames) source \(text.capabilitySource)")
        #expect(text.capabilityNames.isEmpty && text.capabilitySource == .undeclared)
        let agent = Agent(instructions: "Answer with one word.", tools: [], model: text)
        let started = ContinuousClock.now
        let reply = try await agent.respond(to: "What colour is the sky on a clear day?")
        print(
            "MLX text: \(reply.text.replacingOccurrences(of: "\n", with: " ").prefix(120)) in \(ContinuousClock.now - started)"
        )
        #expect(!reply.text.isEmpty)
        let declared = Config(mlx: .init(models: [Self.directory: .init(capabilities: ["toolCalling"])])).resolved
        let withTools = try ModelSelection.local(backend: "mlx", name: Self.directory).resolve(
            config: declared, home: home)
        #expect(withTools.capabilityNames == ["toolCalling"] && withTools.capabilitySource == .configuration)
        var outcomes: [String] = []
        for attempt in 1...3 {
            let fresh = Agent(
                instructions: "Use the current_date tool, then answer with the date only.", tools: [CurrentDateTool()],
                model: withTools)
            do {
                let dated = try await fresh.respond(to: "What is today's date in Asia/Tokyo?")
                let ran = fresh.transcript.contains { if case .toolOutput = $0 { true } else { false } }
                outcomes.append(ran ? "tool loop ran" : "no tool call")
                print(
                    "MLX tools attempt \(attempt): \(dated.text.replacingOccurrences(of: "\n", with: " ").prefix(80))")
            } catch {
                outcomes.append("error: \(error)")
                print("MLX tools attempt \(attempt): error \(error)")
            }
        }
        print("MLX tool loop outcomes: \(outcomes)")
    }

    /// What 0.19.0 adds (ADR 0052): a sized window, exact counts, usage, and the second request of a
    /// conversation reusing the first's processed prompt. Timings are printed, not asserted; 0.20.0 measures.
    @Test func sizedWindowExactCountsUsageAndPrefixReuse() async throws {
        ModelBackends.register(MLXBackend())
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-mlx-live-\(UUID().uuidString)"))
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let resolved = try ModelSelection.local(backend: "mlx", name: Self.directory).resolve(
            config: Config().resolved, home: home)
        print("MLX window: \(resolved.contextSize.map(String.init) ?? "none"), \(resolved.contextNote ?? "")")
        #expect(resolved.contextSize != nil)
        let session = resolved.session(tools: [], instructions: "Answer in one short sentence.")
        let counted = try await resolved.tokenCount(for: session.transcript)
        #expect((counted ?? 0) > 0)
        var started = ContinuousClock.now
        _ = try await session.respond(to: "Name a colour.")
        let first = ContinuousClock.now - started
        let firstInput = resolved.reportedInputTokens() ?? 0
        started = ContinuousClock.now
        _ = try await session.respond(to: "Name another one.")
        let second = ContinuousClock.now - started
        let cached = session.usage.input.cachedTokenCount
        print(
            "MLX counted \(counted ?? 0) tokens before the first request; first request \(firstInput) input tokens in "
                + "\(first); second request \(resolved.reportedInputTokens() ?? 0) input tokens, \(cached) reused, in \(second)"
        )
        // A template may render a past reply differently from the generation prompt that preceded it, so the
        // reuse stops where the two renderings part, possibly a few tokens short of the first prompt.
        #expect(firstInput > 0 && cached > 0)
    }
}
