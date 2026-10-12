import Foundation

/// The thinking asked of the requests made in a scope, which a model's executor honours ahead of its configured
/// default ([ADR 0053](../../../../docs/decisions/0053-the-models-thinking-shown.md), amended 2026-10-11).
///
/// The configured defaults (`<runtime>.models.<name>.think`, then `<runtime>.think`) say what a model does when nobody
/// asks otherwise. Two callers ask otherwise, per request rather than by changing the configuration: wisp's own calls
/// that gain nothing from thinking (a classifier's verdict, a schema reply, the fact distiller, the running summary, the
/// assessment, `memory`'s `condense`), which ask for none, and an MCP caller that chose `think` when it started a
/// thread, whose turns ask for what it chose. The choice is a task local, as the turn's `ReasoningObserver` is,
/// because the framework runs each executor on the caller's task: a value bound around `respond` is visible inside
/// the executor (probed 2026-10-04).
public enum RequestThinking {
    /// The thinking asked of every request made in the current scope; nil leaves each model to its configured default.
    /// A model that cannot think is sent nothing whatever is asked (`ThinkingControl.thinkSent(_:)`).
    @TaskLocal public static var current: OllamaThink?

    /// Runs `operation` as one of wisp's own calls outside the conversation: no observer records its thinking as the
    /// turn's, and its requests ask a model that can think not to.
    ///
    /// - Parameter operation: The call.
    /// - Returns: What it returned.
    /// - Throws: What it threw.
    nonisolated(nonsending) public static func sideCall<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await ReasoningObserver.$current.withValue(nil) {
            try await $current.withValue(.off) { try await operation() }
        }
    }
}

/// A model whose executor sends a thinking switch with each request: Ollama's `think`, llama.cpp's
/// `chat_template_kwargs.enable_thinking`, MLX's template flag (ADR 0053, amended 2026-10-11). `ResolvedModel` reads it,
/// so the audit records what each request sent and a caller's choice is checked against what the runtime accepts.
public protocol ThinkingControl: Sendable {
    /// What a request sends when `requested` is asked of it: `requested` for a model that can think, the configured
    /// default when nothing is asked (or the model cannot take the request), and nil when nothing is sent at all.
    ///
    /// - Parameter requested: The thinking asked of the request (`RequestThinking.current`); nil asks nothing.
    /// - Returns: The value sent, or nil.
    func thinkSent(_ requested: OllamaThink?) -> OllamaThink?

    /// The levels the runtime accepts beyond `true` and `false`: Ollama's `low`, `medium`, `high`, and `max`; empty for a
    /// switch that is only on or off.
    var thinkLevels: [String] { get }
}

extension ThinkingControl {
    /// A switch that is only on or off.
    public var thinkLevels: [String] { [] }
}

extension OllamaThink {
    /// The value as a template's boolean flag takes it: off is false, on and every level true.
    public var enabled: Bool { self != .off }
}
