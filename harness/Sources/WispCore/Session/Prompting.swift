/// The three layers of what the model is told before any prompt, and how they become one
/// `Instructions` value ([ADR 0017](../../../../docs/decisions/0017-three-layer-instructions.md)).
///
/// 1. wisp's system prompt: fixed in code, the same for every face and release. Cannot be removed.
/// 2. The system prompt extension: this Mac's operator, from `config.json`, for every session.
/// 3. The conversation's instructions: the caller, from `--instructions` or MCP `instructions`, for one
///    session or one thread.
public struct Prompting: Equatable, Sendable {
    /// Layer 1: the text of `Resources/system-prompt.md`, embedded at build time by the
    /// `EmbedSystemPrompt` plugin, trimmed. Identity, tool discipline, faithful reporting, and brevity,
    /// kept short because the on-device model's window is about 4k tokens.
    public static let systemPrompt = SystemPromptText.text.trimmingCharacters(in: .whitespacesAndNewlines)

    /// The system prompt's standing rule on memory (decision D12 of the layered-context proposal, layer 1): its
    /// last line, which says that earlier turns may reach the model only as a summary, facts, or references, and
    /// that `memory` recalls them. A conversation without `memory` is not given it, so no model is told of a tool
    /// it cannot call.
    public static let memoryRule = String(
        systemPrompt.split(separator: "\n").last { $0.contains("memory") } ?? "")

    /// The system prompt, with the memory rule only when the conversation has `memory`.
    ///
    /// - Parameter memory: Whether the conversation has the `memory` tool.
    /// - Returns: The text.
    public static func systemPrompt(memory: Bool) -> String {
        guard !memory, !memoryRule.isEmpty else { return systemPrompt }
        return systemPrompt.replacingOccurrences(of: memoryRule, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Layer 2, or nil when the operator set none.
    public var systemPromptExtension: String?
    /// Layer 3, or nil when the caller gave none.
    public var instructions: String?

    /// Creates the layers.
    public init(systemPromptExtension: String? = nil, instructions: String? = nil) {
        self.systemPromptExtension = systemPromptExtension
        self.instructions = instructions
    }

    /// The three layers as one text, in order, each optional layer under a short heading so the model
    /// and a log reader can tell whose words they are.
    /// The memory rule is left out, as for a conversation opened without `memory`.
    public var rendered: String { rendered(toolsAvailable: true) }

    /// `rendered`, with one more sentence of wisp's own when the conversation has no tools, so a
    /// model told about tool discipline does not invent tool calls it cannot make, and the system prompt's
    /// memory rule only when the conversation has `memory`.
    ///
    /// - Parameters:
    ///   - toolsAvailable: Whether the conversation has any tools.
    ///   - memory: Whether one of them is `memory`.
    /// - Returns: The text the framework is given as instructions.
    public func rendered(toolsAvailable: Bool, memory: Bool = false) -> String {
        var parts = [Self.systemPrompt(memory: toolsAvailable && memory)]
        if !toolsAvailable {
            parts[0] += " This conversation has no tools; answer directly from what you know."
        }
        if let extra = systemPromptExtension?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            parts.append("Guidance for this Mac:\n\(extra)")
        }
        if let task = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            parts.append("Instructions for this conversation:\n\(task)")
        }
        return parts.joined(separator: "\n\n")
    }
}
