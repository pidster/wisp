import Foundation
import Testing

@testable import WispCore

/// The window sizing rule of ADR 0043 for hybrid models, whose recurrent layers keep a fixed state instead of a
/// key-value cache, over the shapes Ollama and the MLX models' `config.json` reported on 2026-10-05.
@Suite struct ContextSizingHybridTests {
    static let installed = 51_539_607_552
    static let gib = 1 << 30
    static let mib = 1 << 20

    /// qwen3.8:27b's `model_info` as Ollama 0.35.1 reported it (the parts sizing reads): 64 layers, every fourth
    /// one attention and the rest gated-delta recurrent, and one draft (multi-token prediction) layer after them.
    static let qwen38: [String: JSONValue] = [
        "general.architecture": "qwen35", "qwen35.context_length": 262_144, "qwen35.block_count": 65,
        "qwen35.embedding_length": 5120, "qwen35.attention.head_count": 24, "qwen35.attention.head_count_kv": 4,
        "qwen35.attention.key_length": 256, "qwen35.attention.value_length": 256,
        "qwen35.full_attention_interval": 4, "qwen35.nextn_predict_layers": 1, "qwen35.ssm.conv_kernel": 4,
        "qwen35.ssm.group_count": 16, "qwen35.ssm.inner_size": 6144, "qwen35.ssm.state_size": 128,
        "qwen35.ssm.time_step_rank": 48,
    ]
    static let qwen38Weights = 17_741_872_154

    /// ornith:9b's: the same architecture, 32 layers, without draft layers.
    static let ornith: [String: JSONValue] = [
        "general.architecture": "qwen35", "qwen35.context_length": 262_144, "qwen35.block_count": 32,
        "qwen35.embedding_length": 4096, "qwen35.attention.head_count": 16, "qwen35.attention.head_count_kv": 4,
        "qwen35.attention.key_length": 256, "qwen35.attention.value_length": 256,
        "qwen35.full_attention_interval": 4, "qwen35.ssm.conv_kernel": 4, "qwen35.ssm.group_count": 16,
        "qwen35.ssm.inner_size": 4096, "qwen35.ssm.state_size": 128, "qwen35.ssm.time_step_rank": 32,
    ]
    static let ornithWeights = 5_629_110_568

    @Test func aHybridModelCountsOnlyItsAttentionLayersPerTokenAsLlamaCppAllocatesThem() throws {
        let shape = try #require(ContextSizing.shape(from: Self.qwen38, drafted: false, draftTokens: 4))
        #expect(
            shape.perLayer
                == .init(
                    globalLayers: 16, globalHeads: 64, slidingKeyLength: 256, slidingValueLength: 256, draftHeads: 4,
                    recurrentLayers: 48, draftLayers: 1))
        // 64 KiB a token for the 16 attention layers and 4 KiB for the draft layer: what llama.cpp allocated on
        // 2026-10-05 (512 + 32 MiB at 8,192 tokens, 2,048 + 128 MiB at 32,768). Counting all 65 layers gave 260.
        #expect(shape.bytesPerToken == 69632)
        #expect(8192 * 64 * 1024 == 512 * Self.mib && 32768 * 64 * 1024 == 2048 * Self.mib)
        // The recurrent state, kept once and once per drafted token: 748.125 MiB, as measured at both windows.
        let state = try #require(shape.recurrent)
        #expect(state == .init(layers: 48, bytesPerLayer: 3_268_608, copies: 5))
        #expect(shape.fixedBytes(window: 8192) == 784_465_920 && shape.fixedBytes(window: 262_144) == 784_465_920)
        // Its draft layer runs as a second context with its own buffers, as a draft model does.
        #expect(shape.overhead == 2 * ContextSizing.overhead)
        // Ollama's modelfile sets no draft_num_predict: one copy.
        #expect(ContextSizing.shape(from: Self.qwen38)?.recurrent?.copies == 1)
    }

    @Test func aHybridModelWithoutDraftLayersKeepsOneStateAndOneOverhead() throws {
        let shape = try #require(ContextSizing.shape(from: Self.ornith, draftTokens: 4))
        #expect(
            shape.perLayer
                == .init(
                    globalLayers: 8, globalHeads: 32, slidingKeyLength: 256, slidingValueLength: 256,
                    recurrentLayers: 24))
        // 32 KiB a token: llama.cpp allocated 256 MiB at 8,192 tokens and 1,024 MiB at 32,768 (2026-09-23 and
        // 2026-10-04); the state 50.25 MiB (`0 rs_seq`).
        #expect(shape.bytesPerToken == 32768)
        #expect(shape.fixedBytes(window: 8192) == 52_690_944 && shape.recurrent?.copies == 1)
        #expect(shape.overhead == ContextSizing.overhead)
    }

    @Test func aHybridWindowNamesItsLayersAndItsState() throws {
        let qwen = try #require(ContextSizing.shape(from: Self.qwen38, draftTokens: 4))
        // 50 GB available: a 25 GB budget less the weights, two overheads, and the state leaves 73,728 tokens,
        // where every layer counted gave 24,576.
        let roomy = ContextSizing.size(
            shape: qwen, weights: Self.qwen38Weights,
            memory: .init(installed: Self.installed, available: 50_000_000_000))
        let room = 25_000_000_000 - Self.qwen38Weights - 2 * ContextSizing.overhead - 784_465_920
        #expect(roomy.window == room / 69632 / 4096 * 4096 && roomy.window == 73728)
        #expect(
            roomy.reason == "73,728 of 262,144: 23.0 GiB of a 23.3 GiB budget; "
                + "16 of 64 layers attention, with 1 draft layer of its own; 748 MiB recurrent state",
            "\(roomy.reason)")
        let ornith = try #require(ContextSizing.shape(from: Self.ornith))
        let sized = ContextSizing.size(
            shape: ornith, weights: Self.ornithWeights,
            memory: .init(installed: Self.installed, available: 30_000_000_000))
        #expect(sized.window == 262_144, "\(sized.reason)")
        #expect(sized.reason.hasSuffix("; 8 of 32 layers attention; 50 MiB recurrent state"), "\(sized.reason)")
    }

    @Test func malformedOrPartialHybridFieldsFallBackAsTheyShould() throws {
        // An interval of 0, or draft layers that are all the layers, give no shape.
        var zero = Self.ornith
        zero["qwen35.full_attention_interval"] = 0
        #expect(ContextSizing.shape(from: zero) == nil)
        var allDraft = Self.ornith
        allDraft["qwen35.nextn_predict_layers"] = 32
        #expect(ContextSizing.shape(from: allDraft) == nil)
        var negative = Self.ornith
        negative["qwen35.nextn_predict_layers"] = -1
        #expect(ContextSizing.shape(from: negative) == nil)
        // Without the ssm fields the layers are still counted, but no state is guessed at.
        var stateless = Self.ornith
        stateless["qwen35.ssm.inner_size"] = nil
        let counted = try #require(ContextSizing.shape(from: stateless))
        #expect(counted.bytesPerToken == 32768 && counted.recurrent == nil && counted.fixedBytes(window: 8192) == 0)
        // Without a group count the B and C projections add nothing (Mamba-1's shape).
        var ungrouped = Self.ornith
        ungrouped["qwen35.ssm.group_count"] = nil
        #expect(
            ContextSizing.shape(from: ungrouped)?.recurrent?.bytesPerLayer
                == ContextSizing.Recurrent.bytesPerLayer(convKernel: 4, inner: 4096, groupWidth: 0, state: 128))
        // A layer reported with no key-value heads keeps no cache, and counts as recurrent.
        var zeroHeads = Self.ornith
        zeroHeads["qwen35.full_attention_interval"] = nil
        zeroHeads["qwen35.attention.head_count_kv"] = .array(
            (0..<32).map { ($0 + 1) % 4 == 0 ? 4 : 0 })
        let byHeads = try #require(ContextSizing.shape(from: zeroHeads))
        #expect(byHeads.perLayer == ContextSizing.shape(from: Self.ornith)?.perLayer)
        #expect(byHeads.recurrent == ContextSizing.shape(from: Self.ornith)?.recurrent)
    }

    @Test func modelsWithoutRecurrentLayersSizeExactlyAsBefore() throws {
        // granite4.1:8b, llama3.2:3b, and deepseek-coder-v2 (deepseek2, whose kv_lora_rank llama.cpp did not use:
        // 2,160 MiB at 8,192 tokens on 2026-10-05, 270 KiB a token, the estimate) as Ollama reported them.
        let deepseek: [String: JSONValue] = [
            "general.architecture": "deepseek2", "deepseek2.context_length": 163_840, "deepseek2.block_count": 27,
            "deepseek2.embedding_length": 2048, "deepseek2.attention.head_count": 16,
            "deepseek2.attention.head_count_kv": 16, "deepseek2.attention.key_length": 192,
            "deepseek2.attention.value_length": 128, "deepseek2.attention.kv_lora_rank": 512,
            "deepseek2.rope.dimension_count": 64,
        ]
        let llama: [String: JSONValue] = [
            "general.architecture": "llama", "llama.context_length": 131_072, "llama.block_count": 28,
            "llama.attention.head_count": 24, "llama.attention.head_count_kv": 8, "llama.attention.key_length": 128,
            "llama.attention.value_length": 128, "llama.embedding_length": 3072,
        ]
        let cases: [([String: JSONValue], ContextSizing.Shape, Int, Int, String)] = [
            (
                ContextSizingTests.granite,
                .init(maxContext: 131_072, layers: 40, keyValueHeads: 8, keyLength: 128, valueLength: 128),
                ContextSizingTests.weights, 53248, "53,248 of 131,072: 13.6 GiB of a 14.0 GiB budget"
            ),
            (
                llama, .init(maxContext: 131_072, layers: 28, keyValueHeads: 8, keyLength: 128, valueLength: 128),
                2_019_393_189, 106_496, "106,496 of 131,072: 13.8 GiB of a 14.0 GiB budget"
            ),
            (
                deepseek, .init(maxContext: 163_840, layers: 27, keyValueHeads: 16, keyLength: 192, valueLength: 128),
                8_905_126_121, 16384, "16,384 of 163,840: 13.0 GiB of a 14.0 GiB budget"
            ),
        ]
        for (info, expected, weights, window, reason) in cases {
            let shape = try #require(ContextSizing.shape(from: info, draftTokens: 4))
            #expect(shape == expected && shape.recurrent == nil && shape.note == nil)
            let sized = ContextSizing.size(
                shape: shape, weights: weights, memory: .init(installed: Self.installed, available: 30_000_000_000))
            #expect(sized == .init(window: window, reason: reason), "\(sized.reason)")
        }
        // gemma4 with its draft model: the draft's tokens change nothing without recurrent layers.
        let gemma = try #require(ContextSizing.shape(from: ContextSizingTests.gemma4, drafted: true, draftTokens: 3))
        #expect(gemma == ContextSizing.shape(from: ContextSizingTests.gemma4, drafted: true) && gemma.recurrent == nil)
        #expect(gemma.perLayer?.recurrentLayers == 0 && gemma.perLayer?.draftLayers == 0)
    }

    @Test func ollamaSaysHowManyTokensItDraftsAhead() throws {
        let drafting = #"{"modelfile":"FROM /blobs/a\nPARAMETER draft_num_predict 4\nPARAMETER top_k 20\n"}"#
        #expect(try JSONDecoder().decode(OllamaModel.Shown.self, from: Data(drafting.utf8)).draftTokens == 4)
        let malformed = #"{"modelfile":"FROM /blobs/a\nPARAMETER draft_num_predict many\n"}"#
        #expect(try JSONDecoder().decode(OllamaModel.Shown.self, from: Data(malformed.utf8)).draftTokens == 0)
        #expect(try JSONDecoder().decode(OllamaModel.Shown.self, from: Data("{}".utf8)).draftTokens == 0)
    }

    /// Falcon-H1-7B-Instruct-4bit's `config.json` (mlx-community, the parts sizing reads): attention and Mamba-2 side
    /// by side in every layer. Falcon-H1R-7B-4bit's has the same shape.
    static let falcon7B: [String: JSONValue] = [
        "model_type": "falcon_h1", "max_position_embeddings": 262_144, "num_hidden_layers": 44,
        "num_attention_heads": 12, "num_key_value_heads": 2, "head_dim": 128, "hidden_size": 3072,
        "attn_layer_indices": nil, "mamba_d_conv": 4, "mamba_d_head": 128, "mamba_d_ssm": 3072, "mamba_d_state": 256,
        "mamba_expand": 2, "mamba_n_groups": 1, "mamba_n_heads": 24,
    ]
    /// Falcon-H1-Tiny-Tool-Calling-90M-bf16's.
    static let falconTiny: [String: JSONValue] = [
        "model_type": "falcon_h1", "max_position_embeddings": 262_144, "num_hidden_layers": 24,
        "num_attention_heads": 8, "num_key_value_heads": 2, "head_dim": 64, "hidden_size": 512, "mamba_d_conv": 4,
        "mamba_d_head": 32, "mamba_d_ssm": 768, "mamba_d_state": 64, "mamba_expand": 2, "mamba_n_groups": 1,
        "mamba_n_heads": 24,
    ]
    static let falcon7BWeights = 4_268_832_515

    @Test func aParallelHybridKeepsEveryLayersCacheAndAddsItsMambaState() throws {
        let shape = try #require(ContextSizing.shape(fromModelConfig: Self.falcon7B))
        // Every layer attends, as before: 44 KiB a token.
        #expect(shape.perLayer == nil && shape.bytesPerToken == 44 * 2 * 256 * 2)
        // And keeps a Mamba-2 state, as mlx-swift-lm's FalconH1 cache does: a 3-input convolution window 3,072 +
        // 2 × 256 wide and a 256 × 3,072 state, 32-bit, 3.0 MiB a layer, 134 MiB in all.
        #expect(shape.recurrent == .init(layers: 44, bytesPerLayer: 3_188_736))
        #expect(shape.fixedBytes(window: 8192) == 140_304_384)
        let sized = ContextSizing.size(
            shape: shape, weights: Self.falcon7BWeights,
            memory: .init(installed: Self.installed, available: 30_000_000_000))
        let room = 15_000_000_000 - Self.falcon7BWeights - ContextSizing.overhead - 140_304_384
        #expect(sized.window == room / 45056 / 4096 * 4096 && sized.window == 221_184)
        #expect(sized.reason.hasSuffix("; 134 MiB recurrent state beside every layer's cache"), "\(sized.reason)")
        let tiny = try #require(ContextSizing.shape(fromModelConfig: Self.falconTiny))
        #expect(tiny.bytesPerToken == 24 * 2 * 128 * 2 && tiny.recurrent == .init(layers: 24, bytesPerLayer: 207_360))
        // Without the state's fields, the cache is sized as before and no state is guessed at.
        var partial = Self.falcon7B
        partial["mamba_d_ssm"] = nil
        #expect(ContextSizing.shape(fromModelConfig: partial)?.recurrent == nil)
    }

    @Test func anInterleavedHybridInMLXIsSizedAsOllamaSizesIt() throws {
        // A Qwen3.5 configuration with qwen3.8:27b's dimensions, under the fields mlx-swift-lm's Qwen35 reads.
        let config: [String: JSONValue] = [
            "model_type": "qwen3_5",
            "text_config": [
                "max_position_embeddings": 262_144, "num_hidden_layers": 64, "num_attention_heads": 24,
                "num_key_value_heads": 4, "head_dim": 256, "hidden_size": 5120, "full_attention_interval": 4,
                "linear_conv_kernel_dim": 4, "linear_num_value_heads": 48, "linear_value_head_dim": 128,
                "linear_num_key_heads": 16, "linear_key_head_dim": 128,
            ],
        ]
        let shape = try #require(ContextSizing.shape(fromModelConfig: config))
        let ollama = try #require(ContextSizing.shape(from: Self.qwen38))
        #expect(shape.perLayer == .init(globalLayers: 16, globalHeads: 64, recurrentLayers: 48))
        #expect(shape.bytesPerToken == 65536 && shape.recurrent == ollama.recurrent)
        // Without the linear fields, the layers are counted and no state is guessed at; an interval of 0 is no shape.
        var partial = config
        partial["text_config"] = .object(
            (config["text_config"]?.objectValue ?? [:]).filter { !$0.key.hasPrefix("linear_") })
        let counted = try #require(ContextSizing.shape(fromModelConfig: partial))
        #expect(counted.bytesPerToken == 65536 && counted.recurrent == nil)
        var zero = ContextSizingTests.qwen3
        zero["full_attention_interval"] = 0
        #expect(ContextSizing.shape(fromModelConfig: zero) == nil)
        // A dense model is sized exactly as before.
        let dense = try #require(ContextSizing.shape(fromModelConfig: ContextSizingTests.qwen3))
        #expect(dense.perLayer == nil && dense.recurrent == nil && dense.bytesPerToken == 28 * 8 * 256 * 2)
    }
}
