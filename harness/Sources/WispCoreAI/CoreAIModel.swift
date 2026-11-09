import Foundation
import FoundationModels
import Synchronization
import WispCore

/// A Core AI bundle run by wisp's own executor ([ADR 0088](../../../docs/decisions/0088-core-ai-through-wisps-executor.md)):
/// the framework keeps the tool loop, streaming, transcript, and guided generation's typing; the executor maps
/// each request onto the bundle's chat template, refuses a prompt that does not fit the window, reads thinking and
/// tool calls from the generated text itself, and reports usage as the MLX and Ollama executors do.
struct CoreAIModel: LanguageModel, UsageReporting {
    /// The last request's input tokens, written by the executor; a class so the value survives copies.
    final class UsageRecord: Sendable {
        /// The count, or nil before any request.
        let inputTokens = Mutex<Int?>(nil)
    }

    /// The engine for the bundle.
    let engine: CoreAIEngine
    /// The context window the bundle was exported for.
    let window: Int
    /// What the bundle's chat template supports.
    let capabilities: LanguageModelCapabilities
    /// How the chat template lays out a reply.
    let replyFormat: ReplyFormat
    /// The last request's usage.
    let usage = UsageRecord()

    /// Creates a model over an engine.
    ///
    /// - Parameters:
    ///   - engine: The engine for the bundle.
    ///   - window: The context window.
    ///   - capabilities: What the chat template supports.
    ///   - replyFormat: How the chat template lays out a reply.
    init(
        engine: CoreAIEngine, window: Int, capabilities: [LanguageModelCapabilities.Capability],
        replyFormat: ReplyFormat
    ) {
        self.engine = engine
        self.window = window
        self.capabilities = LanguageModelCapabilities(capabilities)
        self.replyFormat = replyFormat
    }

    /// Input tokens of the last request; nil before the first.
    var lastInputTokens: Int? { usage.inputTokens.withLock { $0 } }

    /// Nothing to configure: the model carries its engine.
    var executorConfiguration: Int { 0 }

    /// The exact tokens a transcript renders to, with the tools its instructions declare, at the template's own
    /// thinking default.
    ///
    /// - Parameter transcript: The transcript.
    /// - Returns: Its length in the model's tokens.
    /// - Throws: When the tokenizer cannot be loaded or the template cannot render.
    func tokenCount(for transcript: Transcript) async throws -> Int {
        let tools = transcript.compactMap { entry -> [Transcript.ToolDefinition]? in
            if case .instructions(let instructions) = entry { return instructions.toolDefinitions }
            return nil
        }.flatMap { $0 }
        return try await engine.count(CoreAIPrompt(transcript: transcript, tools: tools))
    }

    /// The thinking of one request, as the engine's event callback sees it: a `ThinkingStretch` behind a lock,
    /// since the callback is `@Sendable`.
    final class Thoughts: Sendable {
        /// The stretch.
        private let stretch: Mutex<ThinkingStretch>

        /// Creates one reporting to the turn's observer, if any.
        init(observer: ReasoningObserver? = ReasoningObserver.current) {
            stretch = Mutex(ThinkingStretch(observer: observer))
        }

        /// Adds a chunk of thinking, one token.
        func think(_ text: String) { stretch.withLock { $0.think(text) } }

        /// Ends the stretch under way, if any.
        func end() { stretch.withLock { $0.end() } }

        /// Tokens of thinking in the request.
        var tokens: Int { stretch.withLock { $0.tokens } }
    }

    /// Hands each request to the engine and streams its reply into the framework's channel.
    struct Executor: LanguageModelExecutor {
        /// The model type this executor serves.
        typealias Model = CoreAIModel

        /// Required by the protocol; nothing to configure.
        init(configuration: Int) throws {}

        /// What one request asks of the engine.
        struct Request: Sendable {
            /// The prompt.
            var prompt: CoreAIPrompt
            /// The request's own limit on the reply, when it sets one.
            var maxTokens: Int?
            /// The sampling temperature, when set.
            var temperature: Double?
            /// The reply's JSON Schema, as text, when one is asked for.
            var schema: String?
            /// The offered tools' parameter schemas by name.
            var tools: [String: JSONValue]
        }

        /// Runs the engine for one request, until it ends or the turn it belongs to is stopped (`TurnStop`, ADR 0049
        /// amended 2026-10-11), as MLX's executor does: the request's task is cancelled then, which the engine checks
        /// at every token.
        ///
        /// - Parameters:
        ///   - request: The request.
        ///   - model: The model, for its engine, window, and reply format.
        ///   - emit: Where each event goes.
        /// - Returns: The usage.
        /// - Throws: `TurnStop.Failure.stopped` when the turn was stopped; the engine's failures.
        static func generate(
            _ request: Request, on model: CoreAIModel, emit: @escaping @Sendable (CoreAIEvent) async -> Void
        ) async throws -> CoreAIUsage {
            let stop = TurnStop.current
            try stop?.check()
            let engine = model.engine
            let window = model.window
            let format = model.replyFormat
            let run: @Sendable () async throws -> CoreAIUsage = {
                try await engine.respond(
                    request.prompt, window: window, maxTokens: request.maxTokens, temperature: request.temperature,
                    schema: request.schema, format: format, tools: request.tools, emit: emit)
            }
            guard let stop else { return try await run() }
            return try await withThrowingTaskGroup(of: CoreAIUsage?.self) { group in
                group.addTask { try await run() }
                group.addTask {
                    await stop.stopped()
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let usage = first else { throw TurnStop.Failure.stopped }
                return usage
            }
        }

        /// Generates through the engine, then reports usage: input as the rendered prompt with the prefix Core AI
        /// reused as cached tokens, output as the tokens generated, the thinking among them. Thinking goes to the
        /// framework as reasoning and to the turn's observer at its edges (ADR 0053), never into the reply.
        ///
        /// - Throws: `LanguageModelError.contextSizeExceeded` when the prompt does not fit; load and runtime
        ///   failures.
        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest, model: CoreAIModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let schemas = Dictionary(
                request.enabledToolDefinitions.map { ($0.name, ChatMessage.json($0.parameters)) },
                uniquingKeysWith: { first, _ in first })
            let schema = request.schema.flatMap { schema -> String? in
                guard let data = try? JSONEncoder().encode(ChatMessage.json(schema)) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            // What the request's scope asks (a call of wisp's own asks for no thinking), for a template that takes it.
            let thinking = model.thinkSent(RequestThinking.current)?.enabled
            let engineRequest = Request(
                prompt: CoreAIPrompt(
                    transcript: request.transcript, tools: request.enabledToolDefinitions, thinking: thinking),
                maxTokens: request.generationOptions.maximumResponseTokens,
                temperature: request.generationOptions.temperature, schema: schema, tools: schemas)
            let prefix = request.id.uuidString.lowercased()
            let thoughts = Thoughts()
            let emit: @Sendable (CoreAIEvent) async -> Void = { event in
                switch event {
                case .reasoning(let text):
                    guard !text.isEmpty else { return }
                    thoughts.think(text)
                    await channel.send(.reasoning(action: .appendText(text, tokenCount: 1)))
                case .text(let text):
                    guard !text.isEmpty else { return }
                    thoughts.end()
                    await channel.send(.response(action: .appendText(text, tokenCount: 1)))
                case .toolCall(let name, let arguments):
                    thoughts.end()
                    let completed = schemas[name].map { ChatMessage.completed(arguments, schema: $0) } ?? arguments
                    let encoded = (try? JSONEncoder().encode(completed)) ?? Data("{}".utf8)
                    await channel.send(
                        .toolCalls(
                            action: .toolCall(
                                id: "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", name: name,
                                action: .appendArguments(String(decoding: encoded, as: UTF8.self), tokenCount: 1))))
                }
            }
            let usage = try await Self.generate(engineRequest, on: model, emit: emit)
            thoughts.end()
            model.usage.inputTokens.withLock { $0 = usage.prompt }
            // The engine counts every token it generated; the thinking is one a streamed chunk, within that total.
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: usage.prompt, cachedTokenCount: usage.reused),
                        output: .init(
                            totalTokenCount: max(usage.generated, thoughts.tokens),
                            reasoningTokenCount: thoughts.tokens))))
        }
    }
}

extension CoreAIModel: ThinkingControl {
    /// What is asked, as on or off, for a template that marks thinking and takes `enable_thinking`; nothing otherwise,
    /// and nothing when nothing is asked, which leaves the template's own default: there is no `coreai.think`
    /// (ADR 0088).
    ///
    /// - Parameter requested: The thinking asked of the request; nil asks nothing.
    /// - Returns: The value sent, or nil.
    func thinkSent(_ requested: OllamaThink?) -> OllamaThink? {
        guard let requested, case .tagged(let thinking?) = replyFormat, thinking.toggle else { return nil }
        return requested.enabled ? .on : .off
    }
}
