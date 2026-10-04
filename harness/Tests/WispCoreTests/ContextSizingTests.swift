import Foundation
import Testing

@testable import WispCore

/// The window sizing rule of ADR 0043, over granite4.1:8b's shape as Ollama reported it on 2026-09-29.
@Suite struct ContextSizingTests {
    static let granite: [String: JSONValue] = [
        "general.architecture": "granite", "granite.context_length": 131_072, "granite.block_count": 40,
        "granite.attention.head_count": 32, "granite.attention.head_count_kv": 8, "granite.embedding_length": 4096,
    ]
    static let weights = 5_349_000_000
    static let gib = 1 << 30

    @Test func theShapeIsReadFromModelInfoAndItsCacheCostMatchesTheMeasurement() throws {
        let shape = try #require(ContextSizing.shape(from: Self.granite))
        #expect(shape == .init(maxContext: 131_072, layers: 40, keyValueHeads: 8, keyLength: 128, valueLength: 128))
        // 160 KiB a token; measured through Ollama at 162.6 KiB between 8k and 32k windows.
        #expect(shape.bytesPerToken == 163_840)
        var explicit = Self.granite
        explicit["granite.attention.key_length"] = 192
        explicit["granite.attention.value_length"] = 128
        #expect(ContextSizing.shape(from: explicit)?.bytesPerToken == 40 * 8 * 320 * 2)
        var partial = Self.granite
        partial["granite.block_count"] = nil
        #expect(ContextSizing.shape(from: partial) == nil)
        #expect(ContextSizing.shape(from: [:]) == nil)
    }

    @Test func theWindowIsTheLargestStepThatFitsHalfTheAvailableMemoryCappedAtTheMaximum() throws {
        let shape = try #require(ContextSizing.shape(from: Self.granite))
        // 20 GB available: a 10 GB budget less 5.35 GB of weights and 0.5 GiB of buffers leaves 25,104
        // tokens of cache, rounded down to 24,576. Measured on 2026-09-29 with 19.6 GB available: 24,576.
        let sized = ContextSizing.size(
            shape: shape, weights: Self.weights, memory: .init(installed: 51_539_607_552, available: 20_000_000_000))
        #expect(sized.window == 24_576)
        #expect(
            sized.reason.hasPrefix("24,576 of 131,072: ") && sized.reason.contains("GiB of a 9.3 GiB budget"),
            "\(sized.reason)")
        // Plenty of memory: the model's maximum, and never more.
        let roomy = ContextSizing.size(
            shape: shape, weights: Self.weights, memory: .init(installed: 512 * Self.gib, available: 400 * Self.gib))
        #expect(roomy.window == 131_072)
        // Three quarters of installed memory caps the budget however much is free.
        let capped = ContextSizing.size(
            shape: shape, weights: Self.weights, memory: .init(installed: 16 * Self.gib, available: 400 * Self.gib))
        #expect(capped.window == ((12 * Self.gib - Self.weights - ContextSizing.overhead) / 163_840) / 4096 * 4096)
        // What Ollama already holds for the model counts as available.
        let held = ContextSizing.size(
            shape: shape, weights: Self.weights, memory: .init(installed: 51_539_607_552, available: 10_000_000_000),
            held: 10_000_000_000)
        #expect(held.window == sized.window)
    }

    @Test func whenEvenTheFloorDoesNotFitItIsUsedAndTheReasonSaysSo() throws {
        let shape = try #require(ContextSizing.shape(from: Self.granite))
        let tight = ContextSizing.size(
            shape: shape, weights: Self.weights, memory: .init(installed: 8 * Self.gib, available: 2 * Self.gib))
        #expect(tight.window == ContextSizing.floor)
        #expect(tight.reason.contains("the floor") && tight.reason.contains("partly on the CPU"), "\(tight.reason)")
        let small = ContextSizing.Shape(maxContext: 4096, layers: 4, keyValueHeads: 1, keyLength: 64, valueLength: 64)
        #expect(ContextSizing.size(shape: small, weights: 0, memory: .init(installed: 0, available: 0)).window == 4096)
    }

    /// An MLX model's `config.json`, as `mlx-community/Qwen3-1.7B-4bit` ships it (the parts sizing reads).
    static let qwen3: [String: JSONValue] = [
        "model_type": "qwen3", "max_position_embeddings": 40960, "num_hidden_layers": 28,
        "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 128, "hidden_size": 2048,
    ]

    @Test func theShapeIsReadFromAModelConfigAsMLXCarriesIt() throws {
        let shape = try #require(ContextSizing.shape(fromModelConfig: Self.qwen3))
        #expect(shape == .init(maxContext: 40960, layers: 28, keyValueHeads: 8, keyLength: 128, valueLength: 128))
        #expect(shape.bytesPerToken == 28 * 8 * 256 * 2)
        // Without head_dim the head is the hidden size over the heads; without key-value heads, every head.
        var derived = Self.qwen3
        derived["head_dim"] = nil
        derived["num_key_value_heads"] = nil
        #expect(
            ContextSizing.shape(fromModelConfig: derived)
                == .init(maxContext: 40960, layers: 28, keyValueHeads: 16, keyLength: 128, valueLength: 128))
        // A multimodal model's language model is under text_config, read before the top level.
        let nested: [String: JSONValue] = ["model_type": "gemma3", "text_config": .object(Self.qwen3)]
        #expect(ContextSizing.shape(fromModelConfig: nested)?.layers == 28)
        var partial = Self.qwen3
        partial["num_hidden_layers"] = nil
        #expect(ContextSizing.shape(fromModelConfig: partial) == nil)
        #expect(ContextSizing.shape(fromModelConfig: [:]) == nil)
    }

    @Test func theFloorSaysWhatTheRuntimeDoesWhenItDoesNotFit() throws {
        let shape = try #require(ContextSizing.shape(fromModelConfig: Self.qwen3))
        let tight = ContextSizing.size(
            shape: shape, weights: 1 << 30, memory: .init(installed: 8 * Self.gib, available: Self.gib),
            shortfall: "so the cache may not fit")
        #expect(tight.window == ContextSizing.floor && tight.reason.hasSuffix("so the cache may not fit"))
        #expect(!tight.reason.contains("Ollama"))
    }

    @Test func theMacReportsItsMemory() {
        let memory = MemoryState.current()
        #expect(memory.installed > 0 && memory.available > 0 && memory.available <= memory.installed)
    }
}
