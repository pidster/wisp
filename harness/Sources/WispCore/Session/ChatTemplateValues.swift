import Foundation
import FoundationModels

/// The conversation and tools as the plain values a chat template reads, in the shape mlx-swift-lm's own message
/// generator writes ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)). For the local
/// executors that render a chat template themselves: MLX's and Core AI's
/// ([ADR 0088](../../../../docs/decisions/0088-core-ai-through-wisps-executor.md)).
public enum ChatTemplateValues {
    /// The template's context beyond the messages and tools: `enable_thinking` when the prompt sets it, and nothing
    /// otherwise, so the template's own default holds (ADR 0052, refined 2026-10-06).
    ///
    /// - Parameter thinking: The prompt's `enable_thinking`, or nil.
    /// - Returns: The context, or nil.
    public static func context(thinking: Bool?) -> [String: any Sendable]? {
        thinking.map { ["enable_thinking": $0] }
    }

    /// A message as the chat template takes it.
    ///
    /// - Parameter message: The message.
    /// - Returns: Its dictionary.
    public static func message(_ message: ChatMessage) -> [String: any Sendable] {
        var dictionary: [String: any Sendable] = ["role": message.role, "content": message.content]
        if !message.toolCalls.isEmpty {
            dictionary["tool_calls"] = message.toolCalls.map { call -> [String: any Sendable] in
                [
                    "type": "function",
                    "function": ["name": call.name, "arguments": value(call.arguments)] as [String: any Sendable],
                ]
            }
        }
        if let name = message.toolName { dictionary["name"] = name }
        return dictionary
    }

    /// A tool definition as the OpenAI-style specification chat templates take.
    ///
    /// - Parameter definition: The framework's definition.
    /// - Returns: The specification.
    public static func specification(_ definition: Transcript.ToolDefinition) -> JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(definition.name), "description": .string(definition.description),
                "parameters": ChatMessage.json(definition.parameters),
            ],
        ]
    }

    /// The tool specifications as the template takes them.
    ///
    /// - Parameter tools: The specifications.
    /// - Returns: Their dictionaries, or nil for none, so a template renders no tool block.
    public static func tools(_ tools: [JSONValue]) -> [[String: any Sendable]]? {
        tools.isEmpty ? nil : tools.compactMap { value($0) as? [String: any Sendable] }
    }

    /// A JSON value as the plain values the template engine reads. A null is an empty optional, which the engine
    /// reads as its own `none`: `NSNull`, which it cannot convert, made every later request of a thread fail to
    /// render once a tool call's arguments held a null ("Cannot convert value of type NSNull to Jinja Value").
    ///
    /// - Parameter value: The value.
    /// - Returns: A string, number, boolean, array, dictionary, or an empty optional.
    public static func value(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null: String?.none
        case .bool(let bool): bool
        case .int(let int): int
        case .double(let double): double
        case .string(let string): string
        case .array(let array): array.map(Self.value)
        case .object(let object): object.mapValues(Self.value)
        }
    }
}
