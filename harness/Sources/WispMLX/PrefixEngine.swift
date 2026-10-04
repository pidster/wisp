import Foundation
import FoundationModels
import Synchronization
import WispCore

/// One request as wisp's MLX executor hands it to the runtime: the conversation as chat messages, the tools
/// as the chat template's tool specifications, and whether the model may think
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
struct MLXPrompt: Equatable, Sendable {
    /// The conversation, in order.
    var messages: [ChatMessage]
    /// Each tool as `{"type": "function", "function": {"name", "description", "parameters"}}`.
    var tools: [JSONValue]
    /// Whether the chat template is asked to let the model think (`enable_thinking`); only when the
    /// operator declared `reasoning`.
    var thinking: Bool

    /// Creates a prompt.
    init(messages: [ChatMessage], tools: [JSONValue] = [], thinking: Bool = false) {
        self.messages = messages
        self.tools = tools
        self.thinking = thinking
    }

    /// The prompt for a transcript and the tools enabled for it.
    ///
    /// - Parameters:
    ///   - transcript: What the request carries.
    ///   - tools: The tools the request enables.
    ///   - thinking: Whether the model may think.
    init(transcript: Transcript, tools: [Transcript.ToolDefinition], thinking: Bool) {
        self.init(
            messages: ChatMessage.messages(from: transcript), tools: tools.map(Self.specification),
            thinking: thinking)
    }

    /// The prompt a transcript would be rendered as, with the tools its instructions declare: what
    /// `ResolvedModel.tokenCount(for:)` counts.
    ///
    /// - Parameters:
    ///   - transcript: The transcript.
    ///   - thinking: Whether the model may think.
    /// - Returns: The prompt.
    static func counting(_ transcript: Transcript, thinking: Bool) -> MLXPrompt {
        let tools = transcript.compactMap { entry -> [Transcript.ToolDefinition]? in
            if case .instructions(let instructions) = entry { return instructions.toolDefinitions }
            return nil
        }.flatMap { $0 }
        return MLXPrompt(transcript: transcript, tools: tools, thinking: thinking)
    }

    /// A tool definition as the OpenAI-style specification chat templates take.
    ///
    /// - Parameter definition: The framework's definition.
    /// - Returns: The specification.
    static func specification(_ definition: Transcript.ToolDefinition) -> JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(definition.name), "description": .string(definition.description),
                "parameters": ChatMessage.json(definition.parameters),
            ],
        ]
    }
}

/// What a request asks of the engine beyond the prompt.
struct EngineRequest: Sendable {
    /// The conversation.
    var prompt: MLXPrompt
    /// The JSON Schema the reply must follow, as text, for a guided request; nil for free text and tool calls.
    var schema: String?
    /// The context window: a prompt that does not fit is refused as an overflow.
    var window: Int
    /// The most tokens to generate, when the caller set it.
    var maxTokens: Int?
    /// The sampling temperature, when the caller set it.
    var temperature: Double?
}

/// What generation streams back.
enum EngineEvent: Equatable, Sendable {
    /// Reply text.
    case text(String)
    /// A tool call, with its arguments as an object.
    case toolCall(name: String, arguments: JSONValue)
}

/// One request's token counts, in the shape the executors report usage.
struct EngineUsage: Equatable, Sendable {
    /// Tokens of the rendered prompt.
    var prompt: Int
    /// Of those, tokens taken from the slot's cache rather than processed.
    var reused: Int
    /// Tokens generated.
    var generated: Int
}

/// The MLX model as wisp's executor drives it: exact counts, and generation that reuses a slot's processed
/// prefix. `PrefixEngine` is the implementation; tests drive the executor with it over a fake runtime.
protocol PromptEngine: Sendable {
    /// The prompt's exact length in the model's tokens, rendered with its chat template.
    ///
    /// - Throws: When the tokenizer cannot be loaded or the template cannot render.
    func count(_ prompt: MLXPrompt) async throws -> Int
    /// Generates a reply, streaming it to `emit`, reusing what the slot's cache holds.
    ///
    /// - Throws: `LanguageModelError.contextSizeExceeded` when the prompt does not fit the window; runtime
    ///   failures otherwise.
    func respond(
        _ request: EngineRequest, slot: UUID, emit: @escaping @Sendable (EngineEvent) async -> Void
    ) async throws -> EngineUsage
    /// Forgets a slot's cache, as when its thread ends.
    func release(slot: UUID) async
    /// Whether the weights are loaded, so a new window's sizing counts them as already held; answered without
    /// waiting for a request in progress.
    var isLoaded: Bool { get }
}

/// A flag readable from any thread, for state an actor sets and synchronous code reads.
final class Flag: Sendable {
    /// The value.
    private let value = Mutex(false)

    /// Whether it is set.
    var isSet: Bool { value.withLock { $0 } }

    /// Sets it.
    func set() { value.withLock { $0 = true } }
}

/// The engine of a build without MLX: resolution refuses every `mlx:` model before one is needed, so this
/// only answers that MLX is missing.
struct UnavailableEngine: PromptEngine {
    /// The refusal.
    private var missing: ModelSelection.Failure {
        .unavailable(model: "mlx", reason: "MLX is not compiled in")
    }

    /// Refuses.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable`.
    func count(_ prompt: MLXPrompt) async throws -> Int { throw missing }

    /// Refuses.
    ///
    /// - Throws: `ModelSelection.Failure.unavailable`.
    func respond(
        _ request: EngineRequest, slot: UUID, emit: @escaping @Sendable (EngineEvent) async -> Void
    ) async throws -> EngineUsage { throw missing }

    /// Nothing to forget.
    func release(slot: UUID) async {}

    /// Never loaded.
    var isLoaded: Bool { false }
}

/// Renders a prompt to the model's tokens.
protocol PromptTokenizer: Sendable {
    /// The rendered prompt's tokens.
    ///
    /// - Throws: When the chat template cannot render the prompt.
    func tokens(for prompt: MLXPrompt) throws -> [Int]
}

/// The model in memory: what `PrefixEngine` needs to process a prompt onto a cache and generate. Not
/// `Sendable`: the engine, an actor, owns it, and its async requirements run on the engine's executor.
protocol PromptRuntime {
    /// The runtime's key-value cache.
    associatedtype Cache

    /// A new, empty cache.
    ///
    /// - Throws: When the model cannot make one.
    func makeCache() throws -> Cache
    /// Tokens the cache holds.
    func processed(_ cache: Cache) -> Int
    /// Whether the cache can drop tokens from its end.
    func canTrim(_ cache: Cache) -> Bool
    /// Drops `count` tokens from the end of the cache.
    ///
    /// - Returns: Whether exactly that many were dropped.
    func trim(_ cache: Cache, by count: Int) -> Bool
    /// Processes `suffix` onto `cache` and generates, streaming the reply.
    ///
    /// - Parameters:
    ///   - suffix: The prompt tokens the cache does not hold.
    ///   - cache: The cache, holding the rest of the prompt; it holds the whole prompt and some generated
    ///     tokens afterwards.
    ///   - prompt: The prompt, for its tools.
    ///   - maxTokens: The most tokens to generate.
    ///   - temperature: The sampling temperature, when set.
    ///   - emit: Receives the reply.
    /// - Returns: Tokens generated.
    /// - Throws: Runtime failures and cancellation.
    nonisolated(nonsending) func generate(
        suffix: [Int], cache: Cache, prompt: MLXPrompt, maxTokens: Int, temperature: Double?,
        emit: @escaping @Sendable (EngineEvent) async -> Void
    ) async throws -> Int
    /// Generates a reply that follows a JSON Schema, from the whole prompt on a cache of its own.
    ///
    /// - Parameters:
    ///   - prompt: The prompt tokens.
    ///   - schema: The JSON Schema, as text.
    ///   - maxTokens: The most tokens to generate.
    /// - Returns: The reply and the tokens generated.
    /// - Throws: When the schema cannot be compiled or generation fails.
    nonisolated(nonsending) func guided(
        prompt: [Int], schema: String, maxTokens: Int
    ) async throws -> (
        text: String, generated: Int
    )
}

/// wisp's MLX engine for one model directory: the tokenizer, loaded alone for counting; the weights, loaded on
/// the first request; and a pool of processed prompts, one slot per thread (ADR 0052).
///
/// Requests run one at a time, as the GPU serves one; the lock holds across the suspension points of
/// generation, which an actor's own isolation does not.
actor PrefixEngine<Runtime: PromptRuntime>: PromptEngine {
    /// Loads the tokenizer.
    private let loadTokenizer: @Sendable () async throws -> any PromptTokenizer
    /// Loads the weights.
    private let loadRuntime: @Sendable () async throws -> sending Runtime
    /// The tokenizer, once loaded.
    private var tokenizer: (any PromptTokenizer)?
    /// The weights, once loaded.
    private var runtime: Runtime?
    /// The processed prompts.
    private var pool = PromptCachePool<Runtime.Cache>()
    /// Whether a request holds the engine.
    private var busy = false
    /// Requests waiting for it, in order.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Set once the weights are loaded.
    private let loaded = Flag()

    /// Creates an engine; nothing loads until it is needed.
    ///
    /// - Parameters:
    ///   - loadTokenizer: Loads the tokenizer.
    ///   - loadRuntime: Loads the weights.
    init(
        loadTokenizer: @escaping @Sendable () async throws -> any PromptTokenizer,
        loadRuntime: @escaping @Sendable () async throws -> sending Runtime
    ) {
        self.loadTokenizer = loadTokenizer
        self.loadRuntime = loadRuntime
    }

    /// The tokens each slot's cache holds, for tests.
    var slotTokens: [UUID: [Int]] { pool.slots.mapValues(\.tokens) }

    /// Whether the weights are loaded.
    nonisolated var isLoaded: Bool { loaded.isSet }

    /// The tokenizer, loading it on first use.
    ///
    /// - Throws: When it cannot be loaded.
    private func renderer() async throws -> any PromptTokenizer {
        if let tokenizer { return tokenizer }
        let loaded = try await loadTokenizer()
        tokenizer = loaded
        return loaded
    }

    /// Waits until no other request holds the engine, then holds it.
    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the engine to the next waiting request, or frees it.
    private func relinquish() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// The prompt's tokens.
    ///
    /// - Throws: When the tokenizer cannot be loaded or the template cannot render.
    func count(_ prompt: MLXPrompt) async throws -> Int {
        try await renderer().tokens(for: prompt).count
    }

    /// Forgets a slot.
    func release(slot: UUID) {
        pool.remove(slot)
    }

    /// Renders the prompt, refuses it when it does not fit, then generates under the engine's lock: a schema
    /// reply on a cache of its own, anything else on the slot's cache after reusing its common prefix. The
    /// slot keeps the cache trimmed back to the prompt, so the next request's prefix is compared with exactly
    /// what was rendered; a failed request leaves the slot empty.
    ///
    /// - Throws: `LanguageModelError.contextSizeExceeded`, and runtime failures.
    func respond(
        _ request: EngineRequest, slot: UUID, emit: @escaping @Sendable (EngineEvent) async -> Void
    ) async throws -> EngineUsage {
        let tokens = try await renderer().tokens(for: request.prompt)
        guard tokens.count < request.window else {
            throw LanguageModelError.contextSizeExceeded(
                .init(
                    contextSize: request.window, tokenCount: tokens.count,
                    debugDescription: "the prompt is \(tokens.count) tokens; the window is \(request.window)",
                    metadata: [:]))
        }
        let budget = min(request.maxTokens ?? .max, request.window - tokens.count)
        await acquire()
        defer { relinquish() }
        if runtime == nil {
            runtime = try await loadRuntime()
            loaded.set()
        }
        guard let runtime else { return EngineUsage(prompt: tokens.count, reused: 0, generated: 0) }
        if let schema = request.schema {
            let reply = try await runtime.guided(prompt: tokens, schema: schema, maxTokens: budget)
            await emit(.text(reply.text))
            return EngineUsage(prompt: tokens.count, reused: 0, generated: reply.generated)
        }
        let held = pool.take(slot)
        var plan = PrefixPlan.plan(
            cached: held?.tokens ?? [], prompt: tokens, trimmable: held.map { runtime.canTrim($0.cache) } ?? false)
        let cache: Runtime.Cache
        if let held, !plan.rebuild, plan.trimmed == 0 || runtime.trim(held.cache, by: plan.trimmed),
            runtime.processed(held.cache) == plan.reused
        {
            cache = held.cache
        } else {
            plan = .rebuild
            cache = try runtime.makeCache()
        }
        let generated = try await runtime.generate(
            suffix: Array(tokens[plan.reused...]), cache: cache, prompt: request.prompt, maxTokens: budget,
            temperature: request.temperature, emit: emit)
        let extra = runtime.processed(cache) - tokens.count
        if extra >= 0, extra == 0 || runtime.trim(cache, by: extra) {
            pool.put(slot, tokens: tokens, cache: cache, capacity: request.window)
        }
        return EngineUsage(prompt: tokens.count, reused: plan.reused, generated: generated)
    }
}
