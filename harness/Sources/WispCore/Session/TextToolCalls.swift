import Foundation

/// Tool calls a model wrote as text in a format of its own that its runtime left unparsed, read back as calls by
/// the local executors: Mistral's `name[ARGS]{…}` for Ollama, and a `<tool_call>` frame holding an array for MLX
/// (`ToolCallRecovery` in WispMLX).
///
/// Every reading is strict and all or nothing: each call names a tool the request offers and carries a JSON object
/// of arguments, and the text holds nothing else but the format's own framing and whitespace. Anything else is not
/// a call, and the reply stays as the model wrote it, since text that only mentions a format must never run a tool.
public enum TextToolCalls {
    /// One call read from text.
    public struct Call: Equatable, Sendable {
        /// The tool's name, one the request offers.
        public var name: String
        /// Its arguments, an object.
        public var arguments: JSONValue

        /// The call, when it is one the strictness rules accept: `name` offered and `arguments` an object.
        ///
        /// - Parameters:
        ///   - name: The tool's name as the model wrote it.
        ///   - arguments: The arguments as the model wrote them.
        ///   - offered: The names of the tools the request offers.
        public init?(name: String, arguments: JSONValue, offered: Set<String>) {
            guard offered.contains(name), case .object = arguments else { return nil }
            self.name = name
            self.arguments = arguments
        }
    }

    /// The marker Mistral's chat template puts before its calls.
    static let mistralMarker = "[TOOL_CALLS]"
    /// What follows the tool's name in a Mistral call.
    static let mistralArguments = "[ARGS]"

    /// The calls in a reply written in Mistral's format, `name[ARGS]{…}`, one or several, each optionally after a
    /// `[TOOL_CALLS]` marker: what `ministral-3:14b` writes and its Ollama template leaves in `content` (seen in the
    /// 2026-10-04 comparison and probed on 2026-10-06: `read_file[ARGS]{"path": "/tmp/notes.txt"}`).
    ///
    /// - Parameters:
    ///   - text: The reply's whole text.
    ///   - offered: The names of the tools the request offers.
    /// - Returns: The calls, in order, or nil when the text is anything else.
    public static func mistral(_ text: String, offered: Set<String>) -> [Call]? {
        var rest = Substring(text)
        var calls: [Call] = []
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.hasPrefix(mistralMarker) { rest = rest.dropFirst(mistralMarker.count).drop { $0.isWhitespace } }
            if rest.isEmpty { return calls.isEmpty ? nil : calls }
            guard let marker = rest.range(of: mistralArguments) else { return nil }
            let name = String(rest[..<marker.lowerBound])
            let body = rest[marker.upperBound...]
            guard let end = objectEnd(body),
                let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(body[..<end].utf8)),
                let call = Call(name: name, arguments: arguments, offered: offered)
            else { return nil }
            calls.append(call)
            rest = body[end...]
        }
    }

    /// Whether a reply's text so far may yet turn out to be calls in Mistral's format, so an executor holds it back
    /// rather than streaming it as the reply: it is empty or whitespace, the start of the marker, or the start of an
    /// offered tool's name and `[ARGS]`, or it has a whole one of those at its start, after which only the reply's end
    /// can tell.
    ///
    /// - Parameters:
    ///   - text: The reply's text so far.
    ///   - offered: The names of the tools the request offers.
    /// - Returns: Whether to keep holding it.
    public static func mayBeMistral(_ text: String, offered: Set<String>) -> Bool {
        var rest = Substring(text).drop { $0.isWhitespace }
        if mistralMarker.hasPrefix(rest) { return true }
        if rest.hasPrefix(mistralMarker) { rest = rest.dropFirst(mistralMarker.count).drop { $0.isWhitespace } }
        return offered.contains { name in
            let head = name + mistralArguments
            return head.hasPrefix(rest) || rest.hasPrefix(head)
        }
    }

    /// The index just past the JSON object `text` begins with, found by matching braces outside strings; nil when it
    /// does not begin with `{` or the object never closes.
    ///
    /// - Parameter text: The text.
    /// - Returns: The end of the object.
    static func objectEnd(_ text: Substring) -> Substring.Index? {
        guard text.first == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
