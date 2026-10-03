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
}
