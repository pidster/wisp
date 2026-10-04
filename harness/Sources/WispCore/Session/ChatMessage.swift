import Foundation
import FoundationModels

/// One message of a chat-shaped conversation, as a local runtime's chat API or chat template takes it: what
/// wisp's executors map the framework's transcript onto ([ADR 0016](../../../../docs/decisions/0016-local-runtimes-through-an-executor.md),
/// [ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
public struct ChatMessage: Equatable, Sendable {
    /// One tool call an assistant message carries.
    public struct ToolCall: Equatable, Sendable {
        /// The tool's name.
        public var name: String
        /// The arguments, as an object.
        public var arguments: JSONValue

        /// Creates a call.
        public init(name: String, arguments: JSONValue) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// `system`, `user`, `assistant`, or `tool`.
    public var role: String
    /// The text.
    public var content: String
    /// The calls an assistant message makes; empty otherwise.
    public var toolCalls: [ToolCall]
    /// For a `tool` message, the tool whose output it carries.
    public var toolName: String?

    /// Creates a message.
    public init(role: String, content: String, toolCalls: [ToolCall] = [], toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    /// Maps the framework transcript onto chat messages: instructions become the system message, prompts and
    /// responses alternate, tool calls ride on an assistant message, and tool outputs are `tool` messages
    /// naming the tool. Reasoning and anything else the transcript holds are left out.
    ///
    /// - Parameter transcript: The transcript a request carries.
    /// - Returns: The messages, in order.
    public static func messages(from transcript: Transcript) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(ChatMessage(role: "system", content: text(instructions.segments)))
            case .prompt(let prompt):
                messages.append(ChatMessage(role: "user", content: text(prompt.segments)))
            case .response(let response):
                messages.append(ChatMessage(role: "assistant", content: text(response.segments)))
            case .toolCalls(let calls):
                let mapped = calls.map { call in
                    ToolCall(name: call.toolName, arguments: json(call.arguments.jsonString))
                }
                messages.append(ChatMessage(role: "assistant", content: "", toolCalls: mapped))
            case .toolOutput(let output):
                messages.append(ChatMessage(role: "tool", content: text(output.segments), toolName: output.toolName))
            default:
                break
            }
        }
        return messages
    }

    /// The text of transcript segments: text as it is, structured content as its JSON.
    ///
    /// - Parameter segments: The segments.
    /// - Returns: Their text, joined.
    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap {
            switch $0 {
            case .text(let segment): segment.content
            case .structure(let segment): segment.content.jsonString
            default: nil
            }
        }.joined()
    }

    /// Parses JSON text into a value, or an empty object when it does not parse.
    ///
    /// - Parameter text: JSON text.
    /// - Returns: The value.
    public static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .object([:])
    }

    /// Re-encodes an `Encodable`, such as a `GenerationSchema`, as a `JSONValue`.
    ///
    /// - Parameter value: The value.
    /// - Returns: Its JSON, or an empty object when it does not encode.
    public static func json(_ value: some Encodable) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value) else { return .object([:]) }
        return json(String(decoding: data, as: UTF8.self))
    }

    /// A tool call's arguments with each required property the model left out filled with its type's empty
    /// value: `""` for a string, `[]` for an array, `false` for a boolean. A local model is not held to the
    /// tool's schema when it writes arguments, and the framework refuses a call missing a required property
    /// by ending the whole turn; `system_info`'s `process`, required so the on-device model always names one,
    /// is "otherwise empty" by its own description. A missing number or choice has no neutral value and is
    /// left out.
    ///
    /// - Parameters:
    ///   - arguments: The arguments as the model wrote them.
    ///   - schema: The tool's parameters, as JSON Schema.
    /// - Returns: The arguments, completed where that is safe.
    public static func completed(_ arguments: JSONValue, schema: JSONValue) -> JSONValue {
        guard var fields = arguments.objectValue, let object = schema.objectValue,
            let properties = object["properties"]?.objectValue, let required = object["required"]?.arrayValue
        else { return arguments }
        for name in required.compactMap(\.stringValue) where fields[name] == nil {
            let property = properties[name]?.objectValue ?? [:]
            guard property["enum"] == nil else { continue }
            switch property["type"]?.stringValue {
            case "string": fields[name] = ""
            case "array": fields[name] = .array([])
            case "boolean": fields[name] = false
            default: continue
            }
        }
        return .object(fields)
    }
}
