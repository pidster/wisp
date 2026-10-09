import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The Ollama model without a server: selection parsing, transcript mapping, request bodies, chunk
/// decoding, and the failure when nothing listens.
@Suite struct OllamaModelTests {
    @Test func selectionParsesAndRoundTrips() throws {
        #expect(try ModelSelection(parsing: "ollama:qwen3-coder") == .ollama("qwen3-coder"))
        #expect(try ModelSelection(parsing: " ollama:qwen3-coder:latest ") == .ollama("qwen3-coder:latest"))
        #expect(ModelSelection.ollama("x").description == "ollama:x")
        #expect(ModelSelection.ollama("x") == .local(backend: "ollama", name: "x"))
        #expect(ModelSelection.ollama("x").backend == "ollama")
        #expect(!ModelSelection.ollama("x").leavesDevice)
        #expect(try ModelSelection(parsing: "CoreAI:/models/q") == .local(backend: "coreai", name: "/models/q"))
        #expect(throws: ModelSelection.Failure.unknownModel("bad scheme:x")) {
            try ModelSelection(parsing: "bad scheme:x")
        }
        #expect(throws: ModelSelection.Failure.self) { try ModelSelection.local(backend: "nope", name: "m").resolve() }
        do {
            _ = try ModelSelection.local(backend: "nope", name: "m").resolve()
        } catch ModelSelection.Failure.unknownBackend(let scheme, let registered) {
            #expect(scheme == "nope" && registered.contains("ollama"))
        }
        #expect(throws: ModelSelection.Failure.unknownModel("ollama:")) { try ModelSelection(parsing: "ollama:") }
        #expect(throws: ModelSelection.Failure.unknownModel("ollama:a b")) { try ModelSelection(parsing: "ollama:a b") }
        let encoded = try JSONEncoder().encode(Config(model: .ollama("qwen3-coder")))
        #expect(try JSONDecoder().decode(Config.self, from: encoded).model == .ollama("qwen3-coder"))
    }

    @Test func configCarriesOllamaSettings() throws {
        #expect(Config().resolved.ollama == .default)
        #expect(OllamaSettings.default.baseURL.absoluteString == "http://127.0.0.1:11434")
        let custom = Config(ollama: .init(baseURL: "http://gpu.local:11434", timeoutSeconds: 30, contextLength: 4096))
            .resolved.ollama
        #expect(custom.baseURL.host() == "gpu.local")
        #expect(custom.timeout == .seconds(30))
        #expect(custom.contextLength == 4096)
        #expect(OllamaSettings.default.contextLength == nil)  // sized per model (ADR 0043)
        let json = #"{"ollama":{"contextLength":16384,"models":{"qwen3.8:27b":{"contextLength":12288},"g":{}}}}"#
        let perModel = try JSONDecoder().decode(Config.self, from: Data(json.utf8)).resolved.ollama
        #expect(perModel.modelContextLengths == ["qwen3.8:27b": 12288])
        #expect(perModel.configuredWindow(for: "qwen3.8:27b")?.window == 12288)
        #expect(
            perModel.configuredWindow(for: "g") == .init(window: 16384, reason: "configured as ollama.contextLength"))
        #expect(OllamaSettings.default.configuredWindow(for: "g") == nil)
    }

    @Test func transcriptMapsOntoChatMessages() async throws {
        // The scripted model produces a transcript with every entry kind in 4 ms; map that.
        let session = LanguageModelSession(model: ScriptedModel(), tools: [CurrentDateTool()], instructions: "be brief")
        let reply = try await session.respond(to: "date?").content
        let messages = OllamaModel.Executor.messages(from: session.transcript)
        #expect(messages.map(\.role) == ["system", "user", "assistant", "tool", "assistant"])
        #expect(messages[0].content == "be brief")
        #expect(messages[1].content == "date?")
        #expect(messages[2].tool_calls?.first?.function.name == "current_date")
        #expect(messages[2].tool_calls?.first?.function.arguments == .object(["timeZone": "Asia/Tokyo"]))
        #expect(messages[3].tool_name == "current_date")
        #expect(messages[3].content.hasSuffix("(Asia/Tokyo)"))
        #expect(messages[4].content == reply)
    }

    @Test func requestBodyCarriesToolsAndFormat() throws {
        let definition = Transcript.ToolDefinition(tool: CurrentDateTool())
        let request = LanguageModelExecutorGenerationRequest(
            id: UUID(), transcript: Transcript(), enabledTools: [definition], schema: nil,
            generationOptions: .init(), contextOptions: .init(), metadata: [:])
        let body = OllamaModel.Executor.body(for: request, model: "m", contextLength: 2048)
        #expect(body.model == "m")
        #expect(body.options.num_ctx == 2048)
        #expect(body.stream)
        #expect(body.tools?.count == 1)
        #expect(body.tools?.first?.function.name == "current_date")
        guard case .object(let schema)? = body.tools?.first?.function.parameters else { Issue.record("schema"); return }
        #expect(schema["type"] == "object")
        #expect(body.format == nil)
        let encoded = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        #expect(encoded.contains(#""type":"function""#))
        #expect(encoded.contains(#""options":{"num_ctx":2048}"#))
    }

    @Test func chunksDecode() throws {
        let text = #"{"message":{"role":"assistant","content":"Hi"},"done":false}"#
        let chunk = try JSONDecoder().decode(OllamaModel.Executor.Chunk.self, from: Data(text.utf8))
        #expect(chunk.message?.content == "Hi")
        let call =
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"f","arguments":{"a":1}}}]},"done":true,"eval_count":7}"#
        let decoded = try JSONDecoder().decode(OllamaModel.Executor.Chunk.self, from: Data(call.utf8))
        #expect(decoded.message?.tool_calls?.first?.function.arguments == .object(["a": 1]))
        #expect(decoded.eval_count == 7)
        let tags = #"{"models":[{"name":"q:latest","size":10,"details":{"parameter_size":"30B"}}]}"#
        struct Tags: Decodable { var models: [OllamaModel.Installed] }
        let installed = try JSONDecoder().decode(Tags.self, from: Data(tags.utf8)).models
        #expect(installed == [.init(name: "q:latest", size: 10, parameterSize: "30B")])
        #expect(OllamaModel.matches("q", installed: installed))
        #expect(OllamaModel.matches("q:latest", installed: installed))
        #expect(!OllamaModel.matches("z", installed: installed))
    }

    @Test func nothingListeningIsUnavailable() {
        let config = Config(ollama: .init(baseURL: "http://127.0.0.1:1", timeoutSeconds: 1)).resolved
        #expect(throws: ModelSelection.Failure.self) { try ModelSelection.ollama("x").resolve(config: config) }
        do {
            _ = try ModelSelection.ollama("x").resolve(config: config)
        } catch ModelSelection.Failure.unavailable(let model, let reason) {
            #expect(model == "ollama:x")
            #expect(reason.contains("no Ollama server"))
        } catch {
            Issue.record("wrong failure \(error)")
        }
    }
}
