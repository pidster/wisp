import Foundation

/// Tool calls in `<tool_call>` frames, read from the text a model generates by an executor that parses it itself:
/// Core AI's ([ADR 0088](../../../../docs/decisions/0088-core-ai-through-wisps-executor.md)).
///
/// A frame holds one of three forms, each a chat template's own:
///
/// | Form | Written by | Body |
/// | --- | --- | --- |
/// | JSON object | Qwen3, Hermes-style templates | `{"name": "…", "arguments": {…}}` |
/// | JSON array | Falcon-H1-Tiny-Tool-Calling | `[{"name": "…", "arguments": {…}}, …]` |
/// | XML | Qwen3.5 and later, Qwen3-Coder, Nemotron 3 Nano | `<function=NAME><parameter=KEY>value</parameter>…</function>` |
///
/// Readings are strict and all or nothing, by the rules every text reading shares (`TextToolCalls`): each call names
/// a tool the request offers and carries an object of arguments, and the body holds nothing but the form's own
/// framing and whitespace. A frame that is none of these is not a call; the executor keeps it in the reply as the
/// model wrote it, where the person sees it, rather than dropping it.
public enum ToolCallFrames {
    /// The tag that opens a frame.
    public static let open = "<tool_call>"
    /// The tag that closes one.
    public static let close = "</tool_call>"

    /// A routed piece of the stream.
    public enum Piece: Equatable, Sendable {
        /// Text outside any frame.
        case text(String)
        /// A whole frame, tags included, as the model wrote it.
        case frame(String)
    }

    /// Splits streamed text into frames and the text around them as it arrives. A tag split across chunks is held
    /// back until it is whole; a frame never closed comes out as text when the stream ends.
    public struct Splitter: Sendable {
        /// Text held back: the start of an opening tag, or a frame not yet closed.
        private var held = ""
        /// Whether the held text is inside a frame.
        private var inside = false

        /// Creates a splitter outside any frame.
        public init() {}

        /// Routes one chunk.
        ///
        /// - Parameter chunk: The text as it streamed.
        /// - Returns: The pieces it resolves to, in order.
        public mutating func feed(_ chunk: String) -> [Piece] {
            var pieces: [Piece] = []
            var rest = Substring(held + chunk)
            held = ""
            while true {
                if inside {
                    guard let end = rest.range(of: ToolCallFrames.close) else {
                        held = String(rest)
                        return pieces
                    }
                    pieces.append(.frame(ToolCallFrames.open + String(rest[..<end.upperBound])))
                    inside = false
                    rest = rest[end.upperBound...]
                    continue
                }
                if let start = rest.range(of: ToolCallFrames.open) {
                    if start.lowerBound > rest.startIndex { pieces.append(.text(String(rest[..<start.lowerBound]))) }
                    inside = true
                    rest = rest[start.upperBound...]
                    continue
                }
                var keep = min(ToolCallFrames.open.count - 1, rest.count)
                while keep > 0, !ToolCallFrames.open.hasPrefix(rest.suffix(keep)) { keep -= 1 }
                let emit = rest.dropLast(keep)
                if !emit.isEmpty { pieces.append(.text(String(emit))) }
                held = String(rest.suffix(keep))
                return pieces
            }
        }

        /// Ends the stream: anything held back, an unclosed frame included, goes out as text.
        ///
        /// - Returns: The last piece, if any.
        public mutating func finish() -> [Piece] {
            defer {
                held = ""
                inside = false
            }
            let text = (inside ? ToolCallFrames.open : "") + held
            return text.isEmpty ? [] : [.text(text)]
        }
    }

    /// The calls a whole frame holds, in any of the three forms.
    ///
    /// - Parameters:
    ///   - frame: The frame, tags included.
    ///   - schemas: The offered tools' parameter schemas by name; their keys are the names offered. An XML
    ///     parameter is read as JSON when its schema's type is not `string`, and as text otherwise.
    /// - Returns: The calls, in order, or nil when the frame is not one of the forms or names a tool not offered.
    public static func calls(in frame: String, schemas: [String: JSONValue]) -> [TextToolCalls.Call]? {
        let text = frame.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(open), text.hasSuffix(close), text.count >= open.count + close.count else { return nil }
        let body = text.dropFirst(open.count).dropLast(close.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let offered = Set(schemas.keys)
        if body.hasPrefix("<function=") { return xml(body, schemas: schemas) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)) else { return nil }
        let elements = value.arrayValue ?? [value]
        guard !elements.isEmpty else { return nil }
        var calls: [TextToolCalls.Call] = []
        for element in elements {
            guard let object = element.objectValue, Set(object.keys) == ["name", "arguments"],
                let name = object["name"]?.stringValue, var arguments = object["arguments"]
            else { return nil }
            // Some templates write the arguments as a JSON string of the object.
            if let encoded = arguments.stringValue,
                let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8))
            {
                arguments = decoded
            }
            guard let call = TextToolCalls.Call(name: name, arguments: arguments, offered: offered) else { return nil }
            calls.append(call)
        }
        return calls
    }

    /// The calls in an XML body: one or more `<function=NAME>` blocks, each holding `<parameter=KEY>` blocks.
    ///
    /// - Parameters:
    ///   - body: The frame's body, trimmed.
    ///   - schemas: The offered tools' parameter schemas by name.
    /// - Returns: The calls, or nil when anything but the blocks and whitespace is there.
    static func xml(_ body: String, schemas: [String: JSONValue]) -> [TextToolCalls.Call]? {
        var rest = Substring(body)
        var calls: [TextToolCalls.Call] = []
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { return calls.isEmpty ? nil : calls }
            guard rest.hasPrefix("<function="), let nameEnd = rest.firstIndex(of: ">"),
                let blockEnd = rest.range(of: "</function>")
            else { return nil }
            let name = String(rest[rest.index(rest.startIndex, offsetBy: "<function=".count)..<nameEnd])
            guard let schema = schemas[name],
                let arguments = parameters(rest[rest.index(after: nameEnd)..<blockEnd.lowerBound], schema: schema),
                let call = TextToolCalls.Call(name: name, arguments: .object(arguments), offered: Set(schemas.keys))
            else { return nil }
            calls.append(call)
            rest = rest[blockEnd.upperBound...]
        }
    }

    /// The parameters inside one function block.
    ///
    /// - Parameters:
    ///   - text: What lies between `<function=…>` and `</function>`.
    ///   - schema: The tool's parameter schema.
    /// - Returns: The arguments, or nil when anything but parameter blocks and whitespace is there.
    static func parameters(_ text: Substring, schema: JSONValue) -> [String: JSONValue]? {
        var rest = text
        var arguments: [String: JSONValue] = [:]
        let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { return arguments }
            guard rest.hasPrefix("<parameter="), let keyEnd = rest.firstIndex(of: ">"),
                let valueEnd = rest.range(of: "</parameter>")
            else { return nil }
            let key = String(rest[rest.index(rest.startIndex, offsetBy: "<parameter=".count)..<keyEnd])
            var value = rest[rest.index(after: keyEnd)..<valueEnd.lowerBound]
            // The template writes a newline after the opening tag and before the closing one.
            if value.first == "\n" { value = value.dropFirst() }
            if value.last == "\n" { value = value.dropLast() }
            arguments[key] = coerce(String(value), schema: properties[key])
            rest = rest[valueEnd.upperBound...]
        }
    }

    /// The calls in an ATEM block, the form Muse Glimmer's template writes after a `to=TOOL` header:
    /// `<atem:function_calls>` holding `<atem:invoke name="NAME">` blocks, each holding
    /// `<atem:parameter name="KEY">value</atem:parameter>`. The template writes an object or array as JSON and a
    /// boolean or null as JSON's words, so a value is read as its schema asks, as an XML parameter is.
    ///
    /// - Parameters:
    ///   - text: The message's body.
    ///   - schemas: The offered tools' parameter schemas by name.
    /// - Returns: The calls, in order, or nil when anything but the blocks and whitespace is there or a name is not
    ///   offered.
    public static func atem(_ text: String, schemas: [String: JSONValue]) -> [TextToolCalls.Call]? {
        let open = "<atem:function_calls>"
        let close = "</atem:function_calls>"
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix(open), body.hasSuffix(close), body.count >= open.count + close.count else { return nil }
        var rest = body.dropFirst(open.count).dropLast(close.count)
        var calls: [TextToolCalls.Call] = []
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { return calls.isEmpty ? nil : calls }
            guard let (name, inner, after) = element("atem:invoke", in: rest), let schema = schemas[name] else {
                return nil
            }
            var parameters = inner
            var arguments: [String: JSONValue] = [:]
            let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
            while true {
                parameters = parameters.drop { $0.isWhitespace }
                if parameters.isEmpty { break }
                guard let (key, value, next) = element("atem:parameter", in: parameters) else { return nil }
                arguments[key] = coerce(String(value), schema: properties[key])
                parameters = next
            }
            guard let call = TextToolCalls.Call(name: name, arguments: .object(arguments), offered: Set(schemas.keys))
            else { return nil }
            calls.append(call)
            rest = after
        }
    }

    /// The element `text` begins with: `<TAG name="NAME">CONTENT</TAG>`.
    ///
    /// - Parameters:
    ///   - tag: The element's tag.
    ///   - text: The text, starting at the element.
    /// - Returns: The name, the content, and the text after the element; nil when `text` does not begin with one.
    static func element(_ tag: String, in text: Substring) -> (String, Substring, Substring)? {
        let head = "<\(tag) name=\""
        guard text.hasPrefix(head) else { return nil }
        let afterHead = text.dropFirst(head.count)
        guard let quote = afterHead.firstIndex(of: "\""), afterHead[quote...].hasPrefix("\">"),
            let end = afterHead.range(of: "</\(tag)>")
        else { return nil }
        let name = String(afterHead[..<quote])
        let content = afterHead[afterHead.index(quote, offsetBy: 2)..<end.lowerBound]
        return (name, content, afterHead[end.upperBound...])
    }

    /// A parameter's text as the value its schema asks for: text for a `string` or an unknown type, otherwise
    /// the text read as JSON, falling back to the text when it is not JSON.
    ///
    /// - Parameters:
    ///   - text: The value as written.
    ///   - schema: The property's schema, when the tool declares it.
    /// - Returns: The value.
    static func coerce(_ text: String, schema: JSONValue?) -> JSONValue {
        guard let type = schema?.objectValue?["type"]?.stringValue, type != "string" else { return .string(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))) ?? .string(text)
    }
}
