import Foundation

/// Chooses a local model's context window from its shape and the Mac's memory: the largest window whose
/// key-value cache, with the weights and working buffers, fits the budget, capped at the model's maximum
/// ([ADR 0043](../../../../docs/decisions/0043-context-window-from-memory.md)).
public enum ContextSizing {
    /// What sizing needs to know about a model, from Ollama's `/api/show` `model_info` or an MLX model's
    /// `config.json`.
    public struct Shape: Equatable, Sendable {
        /// The longest window the model supports.
        public var maxContext: Int
        /// Transformer layers (`block_count`).
        public var layers: Int
        /// Key-value heads (`attention.head_count_kv`); for a model that reports them per layer, the most any
        /// layer has, for reference only: `perLayer` is what is sized.
        public var keyValueHeads: Int
        /// Size of one head's key and of its value.
        public var keyLength: Int
        /// See `keyLength`.
        public var valueLength: Int
        /// How the cache differs from layer to layer, for a model that reports its layers individually (gemma4),
        /// interleaves attention with recurrent layers (qwen35), or drafts with layers of its own; nil when every
        /// layer is alike and attends to the whole window.
        public var perLayer: PerLayer?
        /// The state a hybrid or state-space model's recurrent layers keep, which does not grow with the window;
        /// nil for a model without such layers or whose state the runtime does not describe.
        public var recurrent: Recurrent?

        /// Creates a shape.
        public init(
            maxContext: Int, layers: Int, keyValueHeads: Int, keyLength: Int, valueLength: Int,
            perLayer: PerLayer? = nil, recurrent: Recurrent? = nil
        ) {
            self.maxContext = maxContext
            self.layers = layers
            self.keyValueHeads = keyValueHeads
            self.keyLength = keyLength
            self.valueLength = valueLength
            self.perLayer = perLayer
            self.recurrent = recurrent
        }

        /// Cache bytes per token of window, with 16-bit entries: a quantised cache takes less, so this
        /// errs towards a smaller window. For a per-layer model, only the layers that attend to the whole window
        /// grow with it, and the draft layers' (a draft model's, or the model's own); recurrent layers do not.
        public var bytesPerToken: Int {
            guard let perLayer else { return layers * keyValueHeads * (keyLength + valueLength) * 2 }
            return (perLayer.globalHeads + perLayer.draftHeads) * (keyLength + valueLength) * 2
        }

        /// Working buffers that do not grow with the window: `ContextSizing.overhead`, twice for a model Ollama
        /// runs with a draft model, which has its own.
        public var overhead: Int { ContextSizing.overhead * (perLayer?.draftHeads ?? 0 > 0 ? 2 : 1) }

        /// Cache bytes that do not grow with a window of `window` tokens beyond the sliding window: the
        /// sliding-window layers', which keep the window plus a batch of cells, and the recurrent layers' state;
        /// zero without such layers.
        ///
        /// - Parameter window: The window, in tokens.
        /// - Returns: The bytes.
        public func fixedBytes(window: Int) -> Int {
            let state = recurrent?.bytes ?? 0
            guard let perLayer, perLayer.slidingHeads > 0 else { return state }
            let cells = min(window, perLayer.slidingWindow + ContextSizing.slidingBatch)
            return state + perLayer.slidingHeads * (perLayer.slidingKeyLength + perLayer.slidingValueLength) * 2
                * cells
        }

        /// How the layers were counted, for the reason (`16 of 64 layers attention, with 1 draft layer of its own;
        /// 748 MiB recurrent state`); nil for a model whose every layer is alike and attends to the whole window.
        var note: String? {
            let state = recurrent.map {
                "\(ContextSizing.mib($0.bytes)) recurrent state"
                    + (perLayer == nil ? " beside every layer's cache" : "")
            }
            let parts = [perLayer?.note, state].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    /// The state a recurrent (state-space) layer keeps in place of a key-value cache: a fixed size whatever the
    /// window, counted with the fixed bytes. Hybrid models interleave such layers with attention (qwen35, Qwen3.5 and
    /// Qwen3-Next in MLX) or run both side by side in every layer (Falcon-H1).
    public struct Recurrent: Equatable, Sendable {
        /// Layers that keep a state.
        public var layers: Int
        /// Bytes of one layer's state, as `bytesPerLayer(convKernel:inner:groupWidth:state:)` counts it.
        public var bytesPerLayer: Int
        /// Copies of the state kept: one, plus one per token drafted ahead when Ollama runs the model with draft
        /// layers (`draft_num_predict`): llama.cpp keeps a state per drafted token to roll back to, measured on
        /// 2026-10-05 as `4 rs_seq` for qwen3.8:27b drafting 4 tokens (ADR 0043).
        public var copies: Int

        /// Creates a recurrent state description.
        public init(layers: Int, bytesPerLayer: Int, copies: Int = 1) {
            self.layers = layers
            self.bytesPerLayer = bytesPerLayer
            self.copies = copies
        }

        /// Every copy of every layer's state.
        public var bytes: Int { layers * bytesPerLayer * copies }

        /// One layer's state with 32-bit entries, as llama.cpp allocates it: the convolution's last
        /// `convKernel - 1` inputs, each as wide as the inner size plus two group widths (the B and C projections),
        /// and the state matrix, `state` × the inner size. MLX keeps some of it in 16 bits, so this errs towards a
        /// smaller window there.
        ///
        /// - Parameters:
        ///   - convKernel: The convolution's width (`ssm.conv_kernel`, `mamba_d_conv`, `linear_conv_kernel_dim`).
        ///   - inner: The inner size (`ssm.inner_size`, `mamba_d_ssm`, value heads × value head size).
        ///   - groupWidth: Groups × state size (`ssm.group_count` × `ssm.state_size`, key heads × key head size).
        ///   - state: The state size per channel (`ssm.state_size`, `mamba_d_state`, the key head size).
        /// - Returns: The bytes.
        public static func bytesPerLayer(convKernel: Int, inner: Int, groupWidth: Int, state: Int) -> Int {
            4 * ((convKernel - 1) * (inner + 2 * groupWidth) + state * inner)
        }
    }

    /// The layers of a model whose cache differs between them: some attend to the whole window ("global"), some
    /// only to the last `slidingWindow` tokens. `attention.shared_kv_layers` is not read: gemma4's draft models set
    /// it for every layer, yet Ollama allocated each layer's cache when measured (ADR 0043).
    public struct PerLayer: Equatable, Sendable {
        /// Layers that attend to the whole window.
        public var globalLayers: Int
        /// Key-value heads summed over those layers.
        public var globalHeads: Int
        /// Layers that attend only to the last `slidingWindow` tokens.
        public var slidingLayers: Int
        /// Key-value heads summed over those layers.
        public var slidingHeads: Int
        /// Tokens a sliding-window layer attends to (`attention.sliding_window`); 0 without such layers.
        public var slidingWindow: Int
        /// Size of one sliding-window head's key (`attention.key_length_swa`, else the model's key length).
        public var slidingKeyLength: Int
        /// Size of one sliding-window head's value (`attention.value_length_swa`, else the model's value length).
        public var slidingValueLength: Int
        /// Key-value heads a draft model adds per token, when Ollama runs one beside the model for speculative
        /// decoding (a `DRAFT` in its Modelfile). `/api/show` does not describe the draft, so it is counted as one
        /// more whole-window layer as wide as the model's widest: what gemma4's drafts have (their GGUF) and what
        /// Ollama allocated for gemma4:12b's (ADR 0043). Its sliding layers fall within the doubled `overhead`.
        /// A model with draft layers of its own (`nextn_predict_layers`) adds theirs.
        public var draftHeads: Int
        /// Layers that keep no key-value cache: a hybrid model's recurrent layers, and a layer reported with no
        /// key-value heads.
        public var recurrentLayers: Int
        /// The model's own draft layers (`nextn_predict_layers`, multi-token prediction), which Ollama runs as a
        /// second context beside the model; they are the last of `block_count`.
        public var draftLayers: Int

        /// Creates a layer description.
        public init(
            globalLayers: Int, globalHeads: Int, slidingLayers: Int = 0, slidingHeads: Int = 0,
            slidingWindow: Int = 0, slidingKeyLength: Int = 0, slidingValueLength: Int = 0, draftHeads: Int = 0,
            recurrentLayers: Int = 0, draftLayers: Int = 0
        ) {
            self.globalLayers = globalLayers
            self.globalHeads = globalHeads
            self.slidingLayers = slidingLayers
            self.slidingHeads = slidingHeads
            self.slidingWindow = slidingWindow
            self.slidingKeyLength = slidingKeyLength
            self.slidingValueLength = slidingValueLength
            self.draftHeads = draftHeads
            self.recurrentLayers = recurrentLayers
            self.draftLayers = draftLayers
        }

        /// How the layers were counted, for the reason: `40 of 48 layers sliding-window (1,024 tokens)`, or
        /// `16 of 64 layers attention` for a hybrid model.
        var note: String {
            let total = globalLayers + slidingLayers + recurrentLayers
            var parts: [String] = []
            if recurrentLayers > 0 {
                parts.append("\(globalLayers + slidingLayers) of \(total) layers attention")
            } else if slidingLayers > 0 {
                parts.append(
                    "\(slidingLayers) of \(total) layers sliding-window (\(slidingWindow.formatted()) tokens)")
            } else {
                parts.append("\(globalLayers) of \(total) layers attending to the whole window")
            }
            if draftLayers > 0 {
                parts.append("with \(draftLayers) draft layer\(draftLayers == 1 ? "" : "s") of its own")
            } else if draftHeads > 0 {
                parts.append("with a draft model")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// A chosen window and why, for the audit.
    public struct Decision: Equatable, Sendable {
        /// The window, in tokens.
        public var window: Int
        /// One sentence, such as `32,768 of 131,072: 10.2 GiB of an 11.1 GiB budget`.
        public var reason: String

        /// Creates a decision.
        public init(window: Int, reason: String) {
            self.window = window
            self.reason = reason
        }
    }

    /// Why a window is what one model's own setting makes it, such as
    /// `configured for this model as ollama.models.qwen3.8:27b.contextLength`.
    ///
    /// - Parameters:
    ///   - runtime: The settings' section, `ollama` or `mlx`.
    ///   - name: The model's key in `<runtime>.models`.
    /// - Returns: The reason.
    public static func perModelReason(_ runtime: String, name: String) -> String {
        "\(perModelPrefix)\(runtime).models.\(name).contextLength"
    }

    /// How a reason for a window set for one model begins.
    public static let perModelPrefix = "configured for this model as "

    /// Windows are multiples of this.
    public static let step = 4096
    /// The smallest window chosen, as before this rule.
    public static let floor = 8192
    /// Working buffers that do not grow with the window; 0.2 GiB measured, with margin.
    public static let overhead = 512 << 20
    /// The share of memory available now that one model may take.
    public static let availableShare = 0.5
    /// The share of installed memory that is the most any model may take: about what macOS lets the GPU use.
    public static let installedShare = 0.75
    /// Cells a sliding-window layer keeps beyond its window: llama.cpp sizes that cache as the window plus one
    /// batch, and Ollama chose batches of 512 to 2,048 when gemma4:12b was measured on 2026-10-04 (ADR 0043).
    public static let slidingBatch = 2048

    /// Reads the shape from `/api/show`'s `model_info`, whose keys are prefixed by the architecture
    /// (`granite.block_count`); nil when any part is missing. A model that reports `attention.head_count_kv` per
    /// layer or a `sliding_window_pattern` (gemma4), interleaves attention with recurrent layers
    /// (`full_attention_interval`, qwen35), has draft layers of its own (`nextn_predict_layers`), or runs with a
    /// draft model, is sized layer by layer (`PerLayer`). Only layers with a key-value cache count per token: every
    /// `full_attention_interval`th layer (llama.cpp's and mlx-swift-lm's `(i + 1) % interval == 0`), and none
    /// reported with no key-value heads. The other layers' state is fixed (`Recurrent`), sized from `ssm.*`.
    ///
    /// - Parameters:
    ///   - info: `/api/show`'s `model_info`.
    ///   - drafted: Whether Ollama runs a draft model beside it (`OllamaModel.Shown.drafted`).
    ///   - draftTokens: Tokens drafted ahead per step (`OllamaModel.Shown.draftTokens`), which multiply a
    ///     drafting model's recurrent state.
    /// - Returns: The shape, or nil.
    public static func shape(from info: [String: JSONValue], drafted: Bool = false, draftTokens: Int = 0) -> Shape? {
        guard let architecture = info["general.architecture"]?.stringValue else { return nil }
        func value(_ key: String) -> JSONValue? { info["\(architecture).\(key)"] }
        func number(_ key: String) -> Int? { value(key)?.intValue }
        let heads = value("attention.head_count_kv")
        guard let maxContext = number("context_length"), let layers = number("block_count"),
            let keyValueHeads = heads?.intValue ?? heads?.arrayValue?.compactMap(\.intValue).max(),
            maxContext > 0, layers > 0, keyValueHeads > 0
        else { return nil }
        let headSize = number("embedding_length").flatMap { width in
            number("attention.head_count").flatMap { $0 > 0 ? width / $0 : nil }
        }
        guard let keyLength = number("attention.key_length") ?? headSize,
            let valueLength = number("attention.value_length") ?? headSize, keyLength > 0, valueLength > 0
        else { return nil }
        var shape = Shape(
            maxContext: maxContext, layers: layers, keyValueHeads: keyValueHeads, keyLength: keyLength,
            valueLength: valueLength)
        let pattern = value("attention.sliding_window_pattern")?.arrayValue
        let interval = number("full_attention_interval")
        let ownDraft = number("nextn_predict_layers") ?? 0
        guard heads?.arrayValue != nil || pattern != nil || drafted || interval != nil || ownDraft != 0 else {
            return shape
        }
        // Per layer: each layer's heads (one number for all, or one each), and whether it slides.
        let layerHeads =
            heads?.arrayValue.map { $0.compactMap(\.intValue) } ?? Array(repeating: keyValueHeads, count: layers)
        let sliding = pattern.map { $0.compactMap(\.boolValue) } ?? Array(repeating: false, count: layers)
        let window = number("attention.sliding_window") ?? 0
        guard layerHeads.count == layers, sliding.count == layers, !sliding.contains(true) || window > 0,
            (0..<layers).contains(ownDraft), (interval ?? 1) > 0
        else { return nil }
        // The model's own draft layers are the last; of the rest, a layer keeps a cache when it has heads and, in a
        // model that interleaves attention with recurrent layers, when it ends an interval.
        let main = layers - ownDraft
        let attends = (0..<main).filter { index in
            layerHeads[index] > 0 && interval.map { (index + 1) % $0 == 0 } ?? true
        }
        let global = attends.filter { !sliding[$0] }
        let slides = attends.filter { sliding[$0] }
        let modelDraft = drafted ? global.map { layerHeads[$0] }.max() ?? 0 : 0
        let perLayer = PerLayer(
            globalLayers: global.count, globalHeads: global.reduce(0) { $0 + layerHeads[$1] },
            slidingLayers: slides.count, slidingHeads: slides.reduce(0) { $0 + layerHeads[$1] },
            slidingWindow: slides.isEmpty ? 0 : window,
            slidingKeyLength: number("attention.key_length_swa") ?? keyLength,
            slidingValueLength: number("attention.value_length_swa") ?? valueLength,
            draftHeads: modelDraft + (main..<layers).reduce(0) { $0 + layerHeads[$1] },
            recurrentLayers: main - attends.count, draftLayers: ownDraft)
        shape.perLayer = perLayer
        if perLayer.recurrentLayers > 0, let convKernel = number("ssm.conv_kernel"),
            let inner = number("ssm.inner_size"), let state = number("ssm.state_size"), convKernel > 0, inner > 0,
            state > 0
        {
            shape.recurrent = Recurrent(
                layers: perLayer.recurrentLayers,
                bytesPerLayer: Recurrent.bytesPerLayer(
                    convKernel: convKernel, inner: inner, groupWidth: max(0, number("ssm.group_count") ?? 0) * state,
                    state: state),
                copies: drafted || ownDraft > 0 ? 1 + max(0, draftTokens) : 1)
        }
        return shape
    }

    /// Reads the shape from a Hugging Face `config.json`, as an MLX model directory carries it
    /// ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)): `max_position_embeddings`,
    /// `num_hidden_layers`, `num_key_value_heads` (else `num_attention_heads`), and `head_dim` (else
    /// `hidden_size` ÷ `num_attention_heads`). A multimodal model nests its language model's under
    /// `text_config`, which is read first. Nil when any part is missing.
    ///
    /// Hybrid models, as mlx-swift-lm builds their caches: with a `full_attention_interval` (Qwen3.5, Qwen3-Next)
    /// only every interval's last layer keeps a key-value cache and the rest a gated-delta state sized from the
    /// `linear_*` fields; with `mamba_d_ssm`, `mamba_d_state`, and `mamba_d_conv` (Falcon-H1) every layer keeps both a
    /// key-value cache and a Mamba-2 state (`mamba_n_groups`, else 1).
    ///
    /// - Parameter config: The decoded `config.json`.
    /// - Returns: The shape, or nil.
    public static func shape(fromModelConfig config: [String: JSONValue]) -> Shape? {
        let nested = config["text_config"]?.objectValue ?? [:]
        func number(_ keys: String...) -> Int? {
            for key in keys {
                if let value = nested[key]?.intValue ?? config[key]?.intValue { return value }
            }
            return nil
        }
        guard let maxContext = number("max_position_embeddings", "max_sequence_length", "n_positions"),
            let layers = number("num_hidden_layers", "n_layer"), let heads = number("num_attention_heads", "n_head"),
            maxContext > 0, layers > 0, heads > 0
        else { return nil }
        let keyValueHeads = number("num_key_value_heads") ?? heads
        guard let headSize = number("head_dim") ?? number("hidden_size", "n_embd").map({ $0 / heads }),
            keyValueHeads > 0, headSize > 0
        else { return nil }
        var shape = Shape(
            maxContext: maxContext, layers: layers, keyValueHeads: keyValueHeads, keyLength: headSize,
            valueLength: headSize)
        func positive(_ keys: String...) -> [Int]? {
            let values = keys.compactMap { number($0) }.filter { $0 > 0 }
            return values.count == keys.count ? values : nil
        }
        if let interval = number("full_attention_interval") {
            guard interval > 0 else { return nil }
            let attending = layers / interval
            shape.perLayer = PerLayer(
                globalLayers: attending, globalHeads: attending * keyValueHeads, recurrentLayers: layers - attending)
            if let linear = positive(
                "linear_conv_kernel_dim", "linear_num_value_heads", "linear_value_head_dim", "linear_num_key_heads",
                "linear_key_head_dim"), attending < layers
            {
                shape.recurrent = Recurrent(
                    layers: layers - attending,
                    bytesPerLayer: Recurrent.bytesPerLayer(
                        convKernel: linear[0], inner: linear[1] * linear[2], groupWidth: linear[3] * linear[4],
                        state: linear[4]))
            }
        } else if let mamba = positive("mamba_d_conv", "mamba_d_ssm", "mamba_d_state") {
            let groups = number("mamba_n_groups") ?? 1
            shape.recurrent = Recurrent(
                layers: layers,
                bytesPerLayer: Recurrent.bytesPerLayer(
                    convKernel: mamba[0], inner: mamba[1], groupWidth: max(0, groups) * mamba[2], state: mamba[2]))
        }
        return shape
    }

    /// What Ollama does when the floor does not fit, for the reason of a floor decision.
    public static let ollamaShortfall = "so Ollama may run it partly on the CPU"

    /// The window for a model of `shape` whose weights take `weights` bytes, given `memory` now and
    /// `held` bytes the runtime already holds for this model, which count as available.
    ///
    /// - Parameters:
    ///   - shape: The model's shape.
    ///   - weights: Bytes the weights take.
    ///   - memory: Memory now.
    ///   - held: Bytes the runtime already holds for this model.
    ///   - shortfall: What happens when even the floor does not fit, for the reason (Ollama's by default).
    /// - Returns: The window and why.
    public static func size(
        shape: Shape, weights: Int, memory: MemoryState, held: Int = 0, shortfall: String = ollamaShortfall
    ) -> Decision {
        let budget = min(
            Int(Double(memory.available + held) * availableShare), Int(Double(memory.installed) * installedShare))
        let fixed = shape.fixedBytes(window: shape.maxContext)
        let fits = max(0, budget - weights - shape.overhead - fixed) / max(1, shape.bytesPerToken)
        let window = min(shape.maxContext, fits / step * step)
        let floor = min(Self.floor, shape.maxContext)
        let chosen = max(window, floor)
        let needed = weights + shape.overhead + shape.fixedBytes(window: chosen) + chosen * shape.bytesPerToken
        let figures = "\(gib(needed)) of a \(gib(budget)) budget"
        let layers = shape.note.map { "; \($0)" } ?? ""
        if window < floor {
            return Decision(
                window: chosen,
                reason: "\(chosen.formatted()) of \(shape.maxContext.formatted()), the floor: needs \(gib(needed)) "
                    + "but the budget is \(gib(budget)), \(shortfall)\(layers)")
        }
        return Decision(
            window: chosen, reason: "\(chosen.formatted()) of \(shape.maxContext.formatted()): \(figures)\(layers)")
    }

    /// Bytes as GiB to one decimal place.
    static func gib(_ bytes: Int) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(1 << 30))
    }

    /// Bytes as whole MiB.
    static func mib(_ bytes: Int) -> String {
        String(format: "%.0f MiB", Double(bytes) / Double(1 << 20))
    }
}
