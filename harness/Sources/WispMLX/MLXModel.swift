import Foundation
import FoundationModels
import Synchronization
import WispCore

/// An MLX model run by wisp's own executor ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)):
/// the framework keeps the tool loop, streaming, transcript, and guided generation's typing; the executor
/// maps each request onto the model's chat template, refuses a prompt that does not fit the window, reuses the
/// processed prefix of the thread's last request, and reports usage as Ollama's executor does.
///
/// Each resolved model has a slot of its own in the engine, so each thread keeps its own processed prefix;
/// the engine, one per model directory, holds the weights once for all of them.
struct MLXModel: LanguageModel, UsageReporting {
    /// Holds a slot's identity and gives the slot back to the engine when the last copy of the model goes.
    final class Slot: Sendable {
        /// The slot's identity in the engine's pool.
        let id = UUID()
        /// The engine that keeps it.
        let engine: any PromptEngine

        /// Creates a slot in `engine`.
        init(engine: any PromptEngine) { self.engine = engine }

        deinit {
            let engine = engine
            let id = id
            Task { await engine.release(slot: id) }
        }
    }

    /// The last request's input tokens, written by the executor; a class so the value survives copies.
    final class UsageRecord: Sendable {
        /// The count, or nil before any request.
        let inputTokens = Mutex<Int?>(nil)
    }

    /// The engine for the model's directory.
    let engine: any PromptEngine
    /// The context window: a prompt that does not fit is refused as an overflow.
    let window: Int
    /// What the operator declared.
    let capabilities: LanguageModelCapabilities
    /// This model's slot.
    let slot: Slot
    /// The last request's usage.
    let usage = UsageRecord()

    /// Creates a model over an engine.
    ///
    /// - Parameters:
    ///   - engine: The engine for the model's directory.
    ///   - window: The context window.
    ///   - capabilities: What the operator declared.
    init(engine: any PromptEngine, window: Int, capabilities: [LanguageModelCapabilities.Capability]) {
        self.engine = engine
        self.window = window
        self.capabilities = LanguageModelCapabilities(capabilities)
        slot = Slot(engine: engine)
    }

    /// Whether the chat template is asked to let the model think.
    var thinking: Bool { capabilities.contains(.reasoning) }

    /// Input tokens of the last request; nil before the first.
    var lastInputTokens: Int? { usage.inputTokens.withLock { $0 } }

    /// Nothing to configure: the model carries its engine.
    var executorConfiguration: Int { 0 }

    /// The exact tokens a transcript renders to, with the tools its instructions declare.
    ///
    /// - Parameter transcript: The transcript.
    /// - Returns: Its length in the model's tokens.
    /// - Throws: When the tokenizer cannot be loaded.
    func tokenCount(for transcript: Transcript) async throws -> Int {
        try await engine.count(MLXPrompt.counting(transcript, thinking: thinking))
    }

    /// Hands each request to the engine and streams its reply into the framework's channel.
    struct Executor: LanguageModelExecutor {
        /// The model type this executor serves.
        typealias Model = MLXModel

        /// Required by the protocol; nothing to configure.
        init(configuration: Int) throws {}

        /// The JSON Schema text for a guided request.
        ///
        /// - Parameter schema: The framework's schema.
        /// - Returns: Its JSON, as text.
        static func schemaText(_ schema: GenerationSchema) -> String {
            guard let data = try? JSONEncoder().encode(ChatMessage.json(schema)) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }

        /// Generates through the engine, then reports usage: input as the rendered prompt with the reused
        /// prefix as cached tokens, output as the tokens generated.
        ///
        /// - Throws: `LanguageModelError.contextSizeExceeded` when the prompt does not fit; runtime failures.
        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest, model: MLXModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let schemas = Dictionary(
                request.enabledToolDefinitions.map { ($0.name, ChatMessage.json($0.parameters)) },
                uniquingKeysWith: { first, _ in first })
            let engineRequest = EngineRequest(
                prompt: MLXPrompt(
                    transcript: request.transcript, tools: request.enabledToolDefinitions, thinking: model.thinking),
                schema: request.schema.map(Self.schemaText), window: model.window,
                maxTokens: request.generationOptions.maximumResponseTokens,
                temperature: request.generationOptions.temperature)
            let prefix = request.id.uuidString.lowercased()
            let usage = try await model.engine.respond(engineRequest, slot: model.slot.id) { event in
                switch event {
                case .text(let text):
                    guard !text.isEmpty else { return }
                    await channel.send(.response(action: .appendText(text, tokenCount: 1)))
                case .toolCall(let name, let arguments):
                    let completed = schemas[name].map { ChatMessage.completed(arguments, schema: $0) } ?? arguments
                    let encoded = (try? JSONEncoder().encode(completed)) ?? Data("{}".utf8)
                    await channel.send(
                        .toolCalls(
                            action: .toolCall(
                                id: "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", name: name,
                                action: .appendArguments(String(decoding: encoded, as: UTF8.self), tokenCount: 1))))
                }
            }
            model.usage.inputTokens.withLock { $0 = usage.prompt }
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: usage.prompt, cachedTokenCount: usage.reused),
                        output: .init(totalTokenCount: usage.generated, reasoningTokenCount: 0))))
        }
    }
}
