import CoreAILanguageModels
import Foundation
import FoundationModels
import Tokenizers
import WispCore

/// A bundle's tokenizer through swift-transformers, as the bridge loads it, with the stop tokens the bridge would
/// use and the template's own end of turn.
struct CoreAITokenizer: CoreAITokenizing {
    /// The tokenizer.
    let tokenizer: any Tokenizer
    /// The tokens that end a reply.
    let stopTokens: Set<Int32>

    /// Loads the tokenizer from a bundle.
    ///
    /// - Parameter bundle: The bundle directory.
    /// - Returns: The tokenizer.
    /// - Throws: When the bundle or its tokenizer cannot be read.
    static func load(from bundle: URL) async throws -> CoreAITokenizer {
        let language = try LanguageBundle(at: bundle)
        let tokenizer = try await language.loadTokenizer()
        var stops = Set<Int32>()
        if let eos = tokenizer.eosTokenId { stops.insert(Int32(eos)) }
        if let directory = language.tokenizerPath {
            stops.formUnion(LanguageConfig.additionalStopTokenIds(from: directory, tokenizer: tokenizer))
        }
        // The end of turn a template writes, which a tokenizer configuration need not list: ChatML's, and the
        // routed-message templates' (`ReplyFormat.channels`).
        let template = CoreAIBackend.chatTemplate(in: bundle) ?? ""
        for marker in ["<|im_end|>", ChannelSplitter.endOfTurn] where template.contains(marker) {
            if let end = tokenizer.convertTokenToId(marker) { stops.insert(Int32(end)) }
        }
        return CoreAITokenizer(tokenizer: tokenizer, stopTokens: stops)
    }

    /// The prompt rendered with the chat template, generation prompt included.
    ///
    /// - Throws: When the template cannot render the prompt.
    func tokens(for prompt: CoreAIPrompt) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: prompt.messages, tools: prompt.tools, additionalContext: prompt.context)
    }

    /// Tokens as text, special tokens kept.
    func text(of tokens: [Int]) -> String {
        tokenizer.decode(tokens: tokens, skipSpecialTokens: false)
    }
}

/// A bundle's weights in a Core AI inference engine, made as the bridge makes it (`CoreAIRunner`, warmed up), but
/// owned by wisp's engine rather than the bridge's shared resources.
struct CoreAIGenerator: CoreAIGenerating {
    /// The engine.
    let engine: any InferenceEngine
    /// The tokenizer, for guided generation's decoding.
    let tokenizer: any Tokenizer
    /// The vocabulary's size, for guided generation's grammar.
    let vocabularySize: Int
    /// Extra end-of-sequence tokens, for guided generation's stop sequences.
    let extraStops: [Int32]

    /// Loads the weights from a bundle.
    ///
    /// - Parameters:
    ///   - bundle: The bundle directory.
    ///   - tokenizer: The bundle's tokenizer, already loaded.
    /// - Returns: The generator.
    /// - Throws: When Core AI cannot make or warm the engine.
    static func load(from bundle: URL, tokenizer: CoreAITokenizer) async throws -> CoreAIGenerator {
        let language = try LanguageBundle(at: bundle)
        let engine = try await CoreAIRunner(bundle: language).makeInferenceEngine()
        try await engine.warmup(queryLength: 1, sampling: nil)
        let main = tokenizer.tokenizer.eosTokenId.map { Int32($0) }
        return CoreAIGenerator(
            engine: engine, tokenizer: tokenizer.tokenizer, vocabularySize: language.vocabSize,
            extraStops: tokenizer.stopTokens.filter { $0 != main }.sorted())
    }

    /// The sampling for a temperature: greedy when unset, as the bridge samples by default.
    static func sampling(_ temperature: Double?) -> SamplingConfiguration {
        temperature.map { SamplingConfiguration(temperature: max(0, $0)) } ?? .greedy
    }

    /// Streams tokens until a stop token, the budget, or `emit` says stop.
    ///
    /// - Throws: Runtime failures and cancellation.
    func generate(
        prompt: [Int], maxTokens: Int, temperature: Double?, stopTokens: Set<Int32>,
        emit: @Sendable (Int32) async -> Bool
    ) async throws -> (generated: Int, reused: Int) {
        let stream = try await engine.generate(
            with: prompt.map(Int32.init), samplingConfiguration: Self.sampling(temperature),
            inferenceOptions: InferenceOptions(maxTokens: maxTokens))
        var generated = 0
        for try await output in stream {
            if stopTokens.contains(output.tokenId) {
                stream.setStopReason(.eos)
                break
            }
            generated += 1
            guard await emit(output.tokenId) else { break }
        }
        return (generated, engine.lastPrefixHitCount)
    }

    /// Generates JSON constrained to the schema, with the strategy the bridge picks: the pipelined one for an
    /// engine that samples on the GPU and so gives no logits, the per-step one otherwise.
    ///
    /// - Throws: `LanguageModelError.unsupportedCapability` when the engine cannot constrain; runtime failures.
    func guided(
        prompt: [Int], schema: String, maxTokens: Int, temperature: Double?
    ) async throws -> (
        text: String, generated: Int
    ) {
        guard engine.supportsGuidedGeneration else {
            throw LanguageModelError.unsupportedCapability(
                .init(
                    capability: .guidedGeneration,
                    debugDescription: "this Core AI engine cannot constrain generation to a schema"))
        }
        let stops = StopSequences(for: tokenizer, additionalEosTokenIds: extraStops)
        let options = InferenceOptions(maxTokens: maxTokens)
        var text = ""
        var generated = 0
        if engine.supportsLogits {
            let stream = try await ConstrainedDecodingStrategy(jsonSchema: schema, vocabSize: vocabularySize).decode(
                from: .tokens(prompt), tokenizer: tokenizer, inferenceEngine: engine,
                samplingConfiguration: Self.sampling(temperature), options: options, stopSequences: stops)
            for try await result in stream {
                text += result.text
                generated += 1
            }
        } else {
            let stream = try await PipelinedConstrainedDecodingStrategy(jsonSchema: schema, vocabSize: vocabularySize)
                .decode(
                    from: .tokens(prompt), tokenizer: tokenizer, inferenceEngine: engine,
                    samplingConfiguration: Self.sampling(temperature), options: options, stopSequences: stops)
            for try await result in stream {
                text += result.text
                generated += 1
            }
        }
        return (text, generated)
    }

    /// Cancels the engine's generation, if any is still winding down, and waits for it.
    func shutdown() async {
        try? await engine.cancel()
    }
}
