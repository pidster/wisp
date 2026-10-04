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

    /// gemma4:12b's `model_info` as Ollama 0.35.1 reported it on 2026-10-04 (the parts sizing reads): key-value
    /// heads and sliding-window attention per layer, five sliding layers to each global one.
    static let gemma4: [String: JSONValue] = [
        "general.architecture": "gemma4", "gemma4.context_length": 262_144, "gemma4.block_count": 48,
        "gemma4.embedding_length": 3840, "gemma4.attention.head_count": 16,
        "gemma4.attention.head_count_kv": [
            8, 8, 8, 8, 8, 1, 8, 8, 8, 8, 8, 1, 8, 8, 8, 8, 8, 1, 8, 8, 8, 8, 8, 1,
            8, 8, 8, 8, 8, 1, 8, 8, 8, 8, 8, 1, 8, 8, 8, 8, 8, 1, 8, 8, 8, 8, 8, 1,
        ],
        "gemma4.attention.sliding_window": 1024,
        "gemma4.attention.sliding_window_pattern": [
            true, true, true, true, true, false, true, true, true, true, true, false,
            true, true, true, true, true, false, true, true, true, true, true, false,
            true, true, true, true, true, false, true, true, true, true, true, false,
            true, true, true, true, true, false, true, true, true, true, true, false,
        ],
        "gemma4.attention.key_length": 512, "gemma4.attention.value_length": 512,
        "gemma4.attention.key_length_swa": 256, "gemma4.attention.value_length_swa": 256,
        "gemma4.attention.shared_kv_layers": 0,
    ]
    static let gemma4Weights = 8_021_618_941

    @Test func aModelReportedPerLayerIsSizedLayerByLayerAsOllamaAllocatesIt() throws {
        let shape = try #require(ContextSizing.shape(from: Self.gemma4))
        #expect(
            shape.perLayer
                == .init(
                    globalLayers: 8, globalHeads: 8, slidingLayers: 40, slidingHeads: 320, slidingWindow: 1024,
                    slidingKeyLength: 256, slidingValueLength: 256))
        // The eight global layers grow with the window: 16 KiB a token, what llama.cpp allocated for them at
        // 8,192, 65,536, and 131,072 tokens on 2026-10-04 (128 MiB, 1,024 MiB, 2,048 MiB).
        #expect(shape.bytesPerToken == 16384)
        // The 40 sliding layers keep the window plus a batch: 960 MiB, as allocated with a 2,048-token batch.
        #expect(shape.fixedBytes(window: 262_144) == 960 << 20)
        #expect(shape.fixedBytes(window: 2048) == 640 << 20)
        #expect(shape.overhead == ContextSizing.overhead)
        // With its draft model, one more global layer as wide as the widest: 18 KiB, measured 16 + 2.
        let drafted = try #require(ContextSizing.shape(from: Self.gemma4, drafted: true))
        #expect(drafted.bytesPerToken == 18432 && drafted.perLayer?.draftHeads == 1)
        #expect(drafted.overhead == 2 * ContextSizing.overhead)
    }

    @Test func aPerLayerWindowIsCappedAtTheMaximumAndItsReasonSaysHowTheLayersWereCounted() throws {
        let shape = try #require(ContextSizing.shape(from: Self.gemma4, drafted: true))
        let installed = 51_539_607_552
        // 30 GB available: room for 265,734 tokens, capped at the model's 262,144.
        let roomy = ContextSizing.size(
            shape: shape, weights: Self.gemma4Weights, memory: .init(installed: installed, available: 30_000_000_000))
        #expect(roomy.window == 262_144)
        #expect(
            roomy.reason == "262,144 of 262,144: 13.9 GiB of a 14.0 GiB budget; "
                + "40 of 48 layers sliding-window (1,024 tokens), with a draft model", "\(roomy.reason)")
        // 25 GB: the sliding layers' fixed 960 MiB comes off the budget before the window is counted.
        let sized = ContextSizing.size(
            shape: shape, weights: Self.gemma4Weights, memory: .init(installed: installed, available: 25_000_000_000))
        let room = 12_500_000_000 - Self.gemma4Weights - 2 * ContextSizing.overhead - (960 << 20)
        #expect(sized.window == room / 18432 / 4096 * 4096 && sized.window == 126_976)
        // The floor names the layers too, after the shortfall.
        let tight = ContextSizing.size(
            shape: shape, weights: Self.gemma4Weights, memory: .init(installed: installed, available: 20_000_000_000))
        #expect(tight.window == 8192)
        #expect(
            tight.reason.hasPrefix("8,192 of 262,144, the floor: needs 9.5 GiB")
                && tight.reason.hasSuffix(
                    "partly on the CPU; 40 of 48 layers sliding-window (1,024 tokens), "
                        + "with a draft model"),
            "\(tight.reason)")
    }

    @Test func perLayerFieldsFallBackOrFailAsTheyShould() throws {
        // Without the sliding layers' own key and value lengths, the model's are used.
        var noSWA = Self.gemma4
        noSWA["gemma4.attention.key_length_swa"] = nil
        noSWA["gemma4.attention.value_length_swa"] = nil
        let fallback = try #require(ContextSizing.shape(from: noSWA)?.perLayer)
        #expect(fallback.slidingKeyLength == 512 && fallback.slidingValueLength == 512)
        // Heads per layer and no sliding pattern: every layer global, summed per layer.
        var allGlobal = Self.gemma4
        allGlobal["gemma4.attention.sliding_window_pattern"] = nil
        let global = try #require(ContextSizing.shape(from: allGlobal))
        #expect(global.bytesPerToken == (40 * 8 + 8 * 1) * 1024 * 2 && global.fixedBytes(window: 262_144) == 0)
        let note = ContextSizing.size(
            shape: global, weights: 0, memory: .init(installed: 512 * Self.gib, available: 400 * Self.gib))
        #expect(note.reason.hasSuffix("; 48 of 48 layers attending to the whole window"), "\(note.reason)")
        // An array that does not cover every layer, or sliding layers without a window, gives no shape.
        var short = Self.gemma4
        short["gemma4.block_count"] = 47
        #expect(ContextSizing.shape(from: short) == nil)
        var windowless = Self.gemma4
        windowless["gemma4.attention.sliding_window"] = nil
        #expect(ContextSizing.shape(from: windowless) == nil)
    }

    @Test func aModelReportedAsOneNumberIsSizedExactlyAsBefore() throws {
        let granite = try #require(ContextSizing.shape(from: Self.granite))
        #expect(granite.perLayer == nil && granite.fixedBytes(window: 131_072) == 0)
        #expect(granite.overhead == ContextSizing.overhead && granite.bytesPerToken == 163_840)
        let sized = ContextSizing.size(
            shape: granite, weights: Self.weights, memory: .init(installed: 51_539_607_552, available: 20_000_000_000))
        #expect(sized.reason == "24,576 of 131,072: 9.2 GiB of a 9.3 GiB budget", "\(sized.reason)")
        // A sliding window with no per-layer pattern is not guessed at: every layer counts in full.
        var windowed = Self.granite
        windowed["granite.attention.sliding_window"] = 4096
        #expect(ContextSizing.shape(from: windowed) == granite)
    }

    @Test func ollamaSaysWhenItRunsADraftModel() throws {
        let drafted = #"{"capabilities":["completion"],"modelfile":"FROM /blobs/a\nDRAFT /blobs/b\nFROM /blobs/c\n"}"#
        #expect(try JSONDecoder().decode(OllamaModel.Shown.self, from: Data(drafted.utf8)).drafted)
        let plain = #"{"capabilities":["completion"],"modelfile":"FROM /blobs/a\nPARAMETER draft_num_predict 3\n"}"#
        #expect(try !JSONDecoder().decode(OllamaModel.Shown.self, from: Data(plain.utf8)).drafted)
        #expect(try !JSONDecoder().decode(OllamaModel.Shown.self, from: Data("{}".utf8)).drafted)
    }

    @Test func theMacReportsItsMemory() {
        let memory = MemoryState.current()
        #expect(memory.installed > 0 && memory.available > 0 && memory.available <= memory.installed)
    }
}
