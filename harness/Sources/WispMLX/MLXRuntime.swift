#if MLX
    import Foundation
    import MLX
    import MLXGuidedGeneration
    import MLXHuggingFace
    import MLXLLM
    import MLXLMCommon
    import Tokenizers
    import WispCore

    /// The model's tokenizer with its chat template, loaded without the weights so that counting a prompt
    /// never loads them ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
    struct MLXPromptTokenizer: PromptTokenizer {
        /// mlx-swift-lm's tokenizer, from the model directory's tokenizer files.
        let tokenizer: any MLXLMCommon.Tokenizer

        /// Loads the tokenizer from a model directory.
        ///
        /// - Parameter directory: The model directory.
        /// - Returns: The tokenizer.
        /// - Throws: When the tokenizer files cannot be read.
        static func load(from directory: URL) async throws -> MLXPromptTokenizer {
            MLXPromptTokenizer(tokenizer: try await #huggingFaceTokenizerLoader().load(from: directory))
        }

        /// The prompt rendered with the chat template, generation prompt included, as tokens.
        ///
        /// - Throws: When the template cannot render the prompt.
        func tokens(for prompt: MLXPrompt) throws -> [Int] {
            try tokenizer.applyChatTemplate(
                messages: prompt.messages.map(Self.dictionary),
                tools: prompt.tools.isEmpty
                    ? nil : prompt.tools.compactMap { Self.sendable($0) as? [String: any Sendable] },
                additionalContext: ["enable_thinking": prompt.thinking])
        }

        /// A message as the chat template takes it, in the shape mlx-swift-lm's own message generator writes.
        ///
        /// - Parameter message: The message.
        /// - Returns: Its dictionary.
        static func dictionary(_ message: ChatMessage) -> [String: any Sendable] {
            var dictionary: [String: any Sendable] = ["role": message.role, "content": message.content]
            if !message.toolCalls.isEmpty {
                dictionary["tool_calls"] = message.toolCalls.map { call -> [String: any Sendable] in
                    [
                        "type": "function",
                        "function": ["name": call.name, "arguments": sendable(call.arguments)]
                            as [String: any Sendable],
                    ]
                }
            }
            if let name = message.toolName { dictionary["name"] = name }
            return dictionary
        }

        /// A JSON value as the plain values the template engine reads.
        ///
        /// - Parameter value: The value.
        /// - Returns: A string, number, boolean, array, dictionary, or `NSNull`.
        static func sendable(_ value: WispCore.JSONValue) -> any Sendable {
            switch value {
            case .null: NSNull()
            case .bool(let bool): bool
            case .int(let int): int
            case .double(let double): double
            case .string(let string): string
            case .array(let array): array.map(sendable)
            case .object(let object): object.mapValues(sendable)
            }
        }
    }

    /// The weights in memory, with what generation on a reused cache needs. Owned by `PrefixEngine`.
    struct MLXPromptRuntime: PromptRuntime {
        /// The loaded model, tokenizer, and configuration.
        let context: ModelContext

        /// Loads the weights from a model directory.
        ///
        /// - Parameter directory: The model directory.
        /// - Returns: The runtime.
        /// - Throws: When the weights cannot be loaded.
        static func load(from directory: URL) async throws -> sending MLXPromptRuntime {
            let context = try await loadModel(from: directory, using: #huggingFaceTokenizerLoader())
            return MLXPromptRuntime(context: context)
        }

        /// A new cache for every layer.
        ///
        /// - Throws: When the model cannot make one.
        func makeCache() throws -> [KVCache] {
            try context.model.newCache(parameters: GenerateParameters())
        }

        /// Tokens the cache holds: its first layer's offset.
        func processed(_ cache: [KVCache]) -> Int { cache.first?.offset ?? 0 }

        /// Whether every layer can drop tokens from its end.
        func canTrim(_ cache: [KVCache]) -> Bool { canTrimPromptCache(cache) }

        /// Drops `count` tokens from the end of every layer.
        func trim(_ cache: [KVCache], by count: Int) -> Bool {
            canTrimPromptCache(cache) && trimPromptCache(cache, numTokens: count) == count
        }

        /// Processes the suffix onto the cache and streams the reply; tool calls are parsed in the model's own
        /// format and only for the tools the prompt offers. Waits for the generation task to finish, so the cache
        /// is not in use when this returns.
        ///
        /// - Throws: `CancellationError` when the request is cancelled; runtime failures.
        nonisolated(nonsending) func generate(
            suffix: [Int], cache: [KVCache], prompt: MLXPrompt, maxTokens: Int, temperature: Double?,
            emit: @escaping @Sendable (EngineEvent) async -> Void
        ) async throws -> Int {
            var parameters = GenerateParameters(maxTokens: max(1, maxTokens))
            if let temperature { parameters.temperature = Float(max(0, temperature)) }
            let iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(suffix)), model: context.model, cache: cache, parameters: parameters)
            let tools = prompt.tools.compactMap { MLXPromptTokenizer.sendable($0) as? [String: any Sendable] }
            let (stream, task) = generateTask(
                promptTokenCount: suffix.count, modelConfiguration: context.configuration,
                tokenizer: context.tokenizer, iterator: iterator, tools: tools.isEmpty ? nil : tools,
                toolCallPolicy: parameters.toolCallPolicy)
            var generated = 0
            for await event in stream {
                switch event {
                case .chunk(let text): await emit(.text(text))
                case .toolCall(let call):
                    let data = (try? JSONEncoder().encode(call.function.arguments)) ?? Data("{}".utf8)
                    await emit(
                        .toolCall(
                            name: call.function.name, arguments: ChatMessage.json(String(decoding: data, as: UTF8.self))
                        ))
                case .info(let info): generated = info.generationTokenCount
                case .rejectedToolCall: break
                }
            }
            await task.value
            try Task.checkCancellation()
            return generated
        }

        /// A schema reply through xgrammar, as mlx-swift-lm's bridge makes one: the schema compiled into a
        /// constraint over the model's vocabulary, with its closing and whitespace biases.
        ///
        /// - Throws: When the schema does not compile or generation fails.
        nonisolated(nonsending) func guided(
            prompt: [Int], schema: String, maxTokens: Int
        ) async throws -> (
            text: String, generated: Int
        ) {
            let tokenizer = context.tokenizer
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocabulary.vocab, vocabType: vocabulary.vocabType, eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: tokenizer)
            let budget = max(1, min(maxTokens, 4096))
            let reserve = CompletionReserve.estimate(schemaJSON: schema, tokenizer: tokenizer)
            let (whitespace, whitespaceTokens) = WhitespaceTokenBias.compute(tokenizer: tokenizer)
            var text = ""
            var generated = 0
            do {
                generated = try GuidedGenerationLoop.run(
                    input: LMInput(tokens: MLXArray(prompt)), context: context, constraint: constraint,
                    maxTokens: budget, vocabSize: grammarTokenizer.vocabSize,
                    completionReserve: max(reserve * 3, budget / 4), hardReserve: reserve * 8,
                    closingBias: ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId),
                    whitespaceBias: whitespace, whitespaceTokenIDs: whitespaceTokens
                ) { delta in
                    text += delta
                    return !Task.isCancelled
                }
            } catch GuidedGenerationError.incompleteOutput {
                // The text so far goes back; the framework reports the reply does not match the schema.
            }
            Stream.gpu.synchronize()
            try Task.checkCancellation()
            return (text, generated)
        }
    }

    extension MLXBackend {
        /// The engine for a model directory, over MLX.
        ///
        /// - Parameter directory: The model directory.
        /// - Returns: A new engine; nothing loads until it is used.
        static func makeEngine(for directory: URL) -> any PromptEngine {
            PrefixEngine<MLXPromptRuntime>(
                loadTokenizer: { try await MLXPromptTokenizer.load(from: directory) },
                loadRuntime: { try await MLXPromptRuntime.load(from: directory) })
        }
    }
#endif
