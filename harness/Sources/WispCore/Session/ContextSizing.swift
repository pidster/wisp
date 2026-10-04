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
        /// Key-value heads (`attention.head_count_kv`).
        public var keyValueHeads: Int
        /// Size of one head's key and of its value.
        public var keyLength: Int
        /// See `keyLength`.
        public var valueLength: Int

        /// Creates a shape.
        public init(maxContext: Int, layers: Int, keyValueHeads: Int, keyLength: Int, valueLength: Int) {
            self.maxContext = maxContext
            self.layers = layers
            self.keyValueHeads = keyValueHeads
            self.keyLength = keyLength
            self.valueLength = valueLength
        }

        /// Cache bytes per token of window, with 16-bit entries: a quantised cache takes less, so this
        /// errs towards a smaller window.
        public var bytesPerToken: Int { layers * keyValueHeads * (keyLength + valueLength) * 2 }
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

    /// Reads the shape from `/api/show`'s `model_info`, whose keys are prefixed by the architecture
    /// (`granite.block_count`); nil when any part is missing.
    public static func shape(from info: [String: JSONValue]) -> Shape? {
        guard let architecture = info["general.architecture"]?.stringValue else { return nil }
        func number(_ key: String) -> Int? { info["\(architecture).\(key)"]?.intValue }
        guard let maxContext = number("context_length"), let layers = number("block_count"),
            let keyValueHeads = number("attention.head_count_kv"), maxContext > 0, layers > 0, keyValueHeads > 0
        else { return nil }
        let headSize = number("embedding_length").flatMap { width in
            number("attention.head_count").flatMap { $0 > 0 ? width / $0 : nil }
        }
        guard let keyLength = number("attention.key_length") ?? headSize,
            let valueLength = number("attention.value_length") ?? headSize, keyLength > 0, valueLength > 0
        else { return nil }
        return Shape(
            maxContext: maxContext, layers: layers, keyValueHeads: keyValueHeads, keyLength: keyLength,
            valueLength: valueLength)
    }

    /// Reads the shape from a Hugging Face `config.json`, as an MLX model directory carries it
    /// ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)): `max_position_embeddings`,
    /// `num_hidden_layers`, `num_key_value_heads` (else `num_attention_heads`), and `head_dim` (else
    /// `hidden_size` ÷ `num_attention_heads`). A multimodal model nests its language model's under
    /// `text_config`, which is read first. Nil when any part is missing.
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
        return Shape(
            maxContext: maxContext, layers: layers, keyValueHeads: keyValueHeads, keyLength: headSize,
            valueLength: headSize)
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
        let fits = max(0, budget - weights - overhead) / max(1, shape.bytesPerToken)
        let window = min(shape.maxContext, fits / step * step)
        let floor = min(Self.floor, shape.maxContext)
        let chosen = max(window, floor)
        let needed = weights + overhead + chosen * shape.bytesPerToken
        let figures = "\(gib(needed)) of a \(gib(budget)) budget"
        if window < floor {
            return Decision(
                window: chosen,
                reason: "\(chosen.formatted()) of \(shape.maxContext.formatted()), the floor: needs \(gib(needed)) "
                    + "but the budget is \(gib(budget)), \(shortfall)")
        }
        return Decision(window: chosen, reason: "\(chosen.formatted()) of \(shape.maxContext.formatted()): \(figures)")
    }

    /// Bytes as GiB to one decimal place.
    static func gib(_ bytes: Int) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(1 << 30))
    }
}
