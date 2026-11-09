import Foundation
import FoundationModels
import Synchronization
import WispCore

/// What wisp's Core AI executor needs from a bundle's tokenizer: its chat template, its decoding, and its stop
/// tokens. Loaded alone, without the weights, so counting never loads them.
protocol CoreAITokenizing: Sendable {
    /// The prompt rendered with the chat template, generation prompt included, as tokens.
    ///
    /// - Parameter prompt: The conversation, tools, and template context.
    /// - Returns: The tokens.
    /// - Throws: When the template cannot render the prompt.
    func tokens(for prompt: CoreAIPrompt) throws -> [Int]
    /// Tokens as text, special tokens kept, so the template's tags are seen.
    ///
    /// - Parameter tokens: The tokens.
    /// - Returns: Their text.
    func text(of tokens: [Int]) -> String
    /// The tokens that end a reply: the tokenizer's end of sequence, the extra ones its configuration lists, and
    /// ChatML's end of turn when the template uses it.
    var stopTokens: Set<Int32> { get }
}

/// What wisp's Core AI executor needs from the loaded weights: generation, guided generation, and a shutdown that
/// waits for the engine's own work to end.
protocol CoreAIGenerating: Sendable {
    /// Generates from a prompt, handing each token to `emit` until it answers false, a stop token, or the budget.
    ///
    /// - Parameters:
    ///   - prompt: The prompt's tokens.
    ///   - maxTokens: The most tokens to generate.
    ///   - temperature: The sampling temperature, when set; greedy otherwise.
    ///   - stopTokens: Tokens that end the reply; not handed to `emit`.
    ///   - emit: Receives each token; false stops generation after it.
    /// - Returns: Tokens generated, and tokens of the prompt the engine reused from its cache.
    /// - Throws: Runtime failures and cancellation.
    func generate(
        prompt: [Int], maxTokens: Int, temperature: Double?, stopTokens: Set<Int32>,
        emit: @Sendable (Int32) async -> Bool
    ) async throws -> (generated: Int, reused: Int)
    /// Generates text constrained to a JSON Schema.
    ///
    /// - Parameters:
    ///   - prompt: The prompt's tokens.
    ///   - schema: The schema, as JSON text.
    ///   - maxTokens: The most tokens to generate.
    ///   - temperature: The sampling temperature, when set.
    /// - Returns: The text and the tokens generated.
    /// - Throws: `LanguageModelError.unsupportedCapability` when the engine cannot constrain; runtime failures.
    func guided(
        prompt: [Int], schema: String, maxTokens: Int, temperature: Double?
    ) async throws -> (
        text: String, generated: Int
    )
    /// Cancels any generation still winding down and waits for it, so the engine is idle and its last
    /// reference can go on the caller's task.
    func shutdown() async
}

/// One request to the engine.
struct CoreAIPrompt: Sendable {
    /// The conversation as the chat template takes it.
    var messages: [[String: any Sendable]]
    /// The tools' specifications as the template takes them; nil for none.
    var tools: [[String: any Sendable]]?
    /// The template's extra context, such as `enable_thinking`; nil to leave its defaults.
    var context: [String: any Sendable]?

    /// The prompt for a transcript and the tools a request offers.
    ///
    /// - Parameters:
    ///   - transcript: The conversation.
    ///   - tools: The tools the request offers.
    ///   - thinking: `enable_thinking`, or nil for the template's default.
    init(transcript: Transcript, tools: [Transcript.ToolDefinition], thinking: Bool? = nil) {
        messages = ChatMessage.messages(from: transcript).map(ChatTemplateValues.message)
        self.tools = ChatTemplateValues.tools(tools.map(ChatTemplateValues.specification))
        context = ChatTemplateValues.context(thinking: thinking)
    }

    /// A prompt from its parts, for tests.
    init(messages: [[String: any Sendable]], tools: [[String: any Sendable]]? = nil) {
        self.messages = messages
        self.tools = tools
        context = nil
    }
}

/// What a reply streams as: text, thinking, or a tool call read from a `<tool_call>` frame.
enum CoreAIEvent: Equatable, Sendable {
    /// Reply text.
    case text(String)
    /// Thinking.
    case reasoning(String)
    /// A call to an offered tool.
    case toolCall(name: String, arguments: JSONValue)
}

/// What a request used.
struct CoreAIUsage: Equatable, Sendable {
    /// The rendered prompt's tokens.
    var prompt: Int
    /// Those the engine reused from its cache.
    var reused: Int
    /// The tokens generated.
    var generated: Int
}

/// Turns streamed tokens into text, holding back a token whose bytes do not yet form whole characters, as the
/// bridge does: decode the pending tokens with one token of context and emit what the context's text does not
/// already account for.
struct IncrementalDecoder {
    /// Tokens not yet emitted, after the one kept as context.
    private var pending: [Int] = []
    /// The text of the tokens before `pending`'s new ones.
    private var previous = ""

    /// The text one more token adds; empty while its bytes are incomplete.
    ///
    /// - Parameters:
    ///   - token: The token.
    ///   - decode: Decodes tokens to text.
    /// - Returns: The new text.
    mutating func add(_ token: Int, decode: ([Int]) -> String) -> String {
        pending.append(token)
        let text = decode(pending)
        if text.unicodeScalars.contains("\u{FFFD}") {
            previous = text
            return ""
        }
        let delta = String(text.dropFirst(text.commonPrefix(with: previous).count))
        let last = pending[pending.count - 1]
        pending = [last]
        previous = decode([last])
        return delta
    }
}

/// wisp's Core AI engine for one bundle ([ADR 0088](../../../docs/decisions/0088-core-ai-through-wisps-executor.md)):
/// the tokenizer, loaded alone for counting; the weights, on the first request; and the reply read by wisp's own
/// readings into thinking, text, and tool calls (`ReplyReader`). Core AI keeps one cache per engine and reuses its
/// prefix itself.
///
/// Requests run one at a time, as the GPU serves one and the engine cancels a generation still in flight when
/// another starts; the turn is held across generation's suspension points, which an actor's own isolation does not.
actor CoreAIEngine {
    /// Loads the tokenizer.
    private let loadTokenizer: @Sendable () async throws -> any CoreAITokenizing
    /// Loads the weights.
    private let loadGenerator: @Sendable () async throws -> any CoreAIGenerating
    /// The tokenizer, once loaded.
    private var tokenizer: (any CoreAITokenizing)?
    /// The weights, once loaded; nil again after shutdown.
    private var generator: (any CoreAIGenerating)?
    /// Whether a request holds the engine.
    private var busy = false
    /// Requests waiting for it, in order.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Creates an engine; nothing loads until it is needed.
    ///
    /// - Parameters:
    ///   - loadTokenizer: Loads the tokenizer.
    ///   - loadGenerator: Loads the weights.
    init(
        loadTokenizer: @escaping @Sendable () async throws -> any CoreAITokenizing,
        loadGenerator: @escaping @Sendable () async throws -> any CoreAIGenerating
    ) {
        self.loadTokenizer = loadTokenizer
        self.loadGenerator = loadGenerator
    }

    /// Whether the weights are loaded.
    var isLoaded: Bool { generator != nil }

    /// The tokenizer, loading it on first use.
    ///
    /// - Throws: When it cannot be loaded.
    private func renderer() async throws -> any CoreAITokenizing {
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
    /// - Parameter prompt: The prompt.
    /// - Returns: Its length.
    /// - Throws: When the tokenizer cannot be loaded or the template cannot render.
    func count(_ prompt: CoreAIPrompt) async throws -> Int {
        try await renderer().tokens(for: prompt).count
    }

    /// Renders the prompt, refuses it when it does not fit, then generates under the engine's turn: a schema reply
    /// constrained by the engine, anything else read as it streams by the template's reply format (`ReplyReader`),
    /// stopping once a routed tool message ends, or when the task is cancelled.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - window: The context window; generation stops at it.
    ///   - maxTokens: The request's own limit, when it sets one.
    ///   - temperature: The sampling temperature, when set.
    ///   - schema: A JSON Schema for the reply, as text, when the request asks for one.
    ///   - format: How the template lays out a reply.
    ///   - tools: The offered tools' parameter schemas by name.
    ///   - emit: Receives the reply.
    /// - Returns: What the request used.
    /// - Throws: `LanguageModelError.contextSizeExceeded` when the prompt does not fit; `CancellationError` when the
    ///   task was cancelled; load and runtime failures.
    func respond(
        _ prompt: CoreAIPrompt, window: Int, maxTokens: Int?, temperature: Double?, schema: String?,
        format: ReplyFormat, tools: [String: JSONValue], emit: @escaping @Sendable (CoreAIEvent) async -> Void
    ) async throws -> CoreAIUsage {
        let tokenizer = try await renderer()
        let tokens = try tokenizer.tokens(for: prompt)
        guard tokens.count < window else {
            throw LanguageModelError.contextSizeExceeded(
                .init(
                    contextSize: window, tokenCount: tokens.count,
                    debugDescription: "the prompt is \(tokens.count) tokens; the window is \(window)", metadata: [:]))
        }
        let budget = max(1, min(maxTokens ?? .max, window - tokens.count))
        await acquire()
        defer { relinquish() }
        let generator: any CoreAIGenerating
        if let loaded = self.generator {
            generator = loaded
        } else {
            generator = try await loadGenerator()
            self.generator = generator
        }
        if let schema {
            let reply = try await generator.guided(
                prompt: tokens, schema: schema, maxTokens: budget, temperature: temperature)
            await emit(.text(reply.text))
            return CoreAIUsage(prompt: tokens.count, reused: 0, generated: reply.generated)
        }
        let primed: Bool =
            if case .tagged(let thinking?) = format {
                thinking.promptEndsInside(tokenizer.text(of: Array(tokens.suffix(16))))
            } else {
                false
            }
        let reader = ReplyReader(format: format, primed: primed, tools: tools)
        let decoder = Mutex(IncrementalDecoder())
        let usage = try await generator.generate(
            prompt: tokens, maxTokens: budget, temperature: temperature, stopTokens: tokenizer.stopTokens
        ) { token in
            let delta = decoder.withLock { $0.add(Int(token), decode: tokenizer.text(of:)) }
            for event in reader.feed(delta) { await emit(event) }
            // A turn stopped by the person cancels the request's task (`CoreAIModel.Executor.generate`).
            return !reader.isDone && !Task.isCancelled
        }
        try Task.checkCancellation()
        for event in reader.finish(stopped: usage.generated < budget || reader.isDone) { await emit(event) }
        return CoreAIUsage(prompt: tokens.count, reused: usage.reused, generated: usage.generated)
    }

    /// Waits for the engine's own work to end and lets the weights go, on the caller's task: Core AI's pipelined
    /// engine winds a generation down in a task of its own after the reply ends, and when that task held the
    /// engine's last reference as the process exited, its teardown ran beside `exit()`'s and aborted the process
    /// (seen 2026-10-05 with Muse Glimmer 30B, ADR 0088).
    func shutdown() async {
        await acquire()
        defer { relinquish() }
        await generator?.shutdown()
        generator = nil
    }
}

/// The engines in this process, one per bundle, so every thread on a bundle shares one copy of the weights, and
/// the process can shut them all down before it exits.
enum CoreAIEngines {
    /// The engines by the bundle's real path.
    private final class Registry: Sendable {
        /// The table.
        let engines = Mutex<[String: CoreAIEngine]>([:])
    }

    /// The process's registry.
    private static let registry = Registry()

    /// The engine for a bundle, made on first use.
    ///
    /// - Parameters:
    ///   - bundle: The bundle directory.
    ///   - make: Makes the engine.
    /// - Returns: The engine.
    static func engine(for bundle: URL, make: () -> CoreAIEngine) -> CoreAIEngine {
        registry.engines.withLock { engines in
            let key = bundle.resolvingSymlinksInPath().path
            if let engine = engines[key] { return engine }
            let engine = make()
            engines[key] = engine
            return engine
        }
    }

    /// Shuts every engine down and forgets it, waiting for each.
    static func shutdown() async {
        let engines = registry.engines.withLock { engines in
            defer { engines = [:] }
            return Array(engines.values)
        }
        for engine in engines { await engine.shutdown() }
    }
}
