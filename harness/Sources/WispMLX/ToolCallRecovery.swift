import Foundation
import WispCore

/// Where wisp's MLX executor goes beyond mlx-swift-lm's own tool-call parsing and stop tokens, each for a format
/// a model's chat template states and mlx-swift-lm does not handle
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-05). Compiled without
/// the `MLX` trait, so the gate tests it.
enum ToolCallRecovery {
    /// The frame a `<tool_call>` template puts a call in.
    static let frame = (open: "<tool_call>", close: "</tool_call>")

    /// The calls in a `<tool_call>` frame holding a JSON array of calls, the form Falcon-H1-Tiny-Tool-Calling's
    /// template asks for (`<tool_call>\n[{"name": …, "arguments": {…}}, …]\n</tool_call>`) and renders past calls
    /// in, which mlx-swift-lm's JSON parser rejects as malformed because it reads one object per frame.
    ///
    /// Strict, all or nothing, by the rules every text reading shares (`TextToolCalls`): the text, less surrounding
    /// whitespace, is exactly one frame; the payload is a non-empty array; each element an object of exactly `name`,
    /// a tool the request offers, and `arguments`, an object. Anything else is nil, and the reply stays as the model
    /// wrote it.
    ///
    /// - Parameters:
    ///   - raw: The framed text mlx-swift-lm rejected.
    ///   - offered: The names of the tools the request offers.
    /// - Returns: The calls, in order, or nil.
    static func framedArray(_ raw: String, offered: Set<String>) -> [TextToolCalls.Call]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(frame.open), text.hasSuffix(frame.close), text.count > frame.open.count + frame.close.count
        else { return nil }
        let payload = text.dropFirst(frame.open.count).dropLast(frame.close.count)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
            case .array(let elements) = value, !elements.isEmpty
        else { return nil }
        var calls: [TextToolCalls.Call] = []
        for element in elements {
            guard case .object(let object) = element, Set(object.keys) == ["name", "arguments"],
                case .string(let name) = object["name"], let arguments = object["arguments"],
                let call = TextToolCalls.Call(name: name, arguments: arguments, offered: offered)
            else { return nil }
            calls.append(call)
        }
        return calls
    }

    /// The ChatML end-of-turn marker.
    static let chatMLEnd = "<|im_end|>"

    /// The end-of-turn markers to stop generation at beyond the checkpoint's own: `<|im_end|>` when the chat
    /// template uses it. ChatML ends every turn with it, but a checkpoint's `generation_config.json` need not list
    /// it (Falcon-H1-Tiny-Tool-Calling lists only `<|end_of_text|>`), and generation then runs on past the
    /// reply, writing tool results and further turns, a call in which would be parsed as the model's.
    /// mlx-swift-lm adds the same marker for the ChatML models in its own registry, which a model loaded from a
    /// directory does not reach.
    ///
    /// - Parameter template: The chat template's text, when the model has one.
    /// - Returns: The markers, as text.
    static func endOfTurnMarkers(template: String?) -> Set<String> {
        guard let template, template.contains(chatMLEnd) else { return [] }
        return [chatMLEnd]
    }

    /// The chat template's text in a model directory: `chat_template.jinja`, else `tokenizer_config.json`'s
    /// `chat_template`, a string or the `tool_use` (else `default`) of a list of named templates, as mlx-swift-lm
    /// reads it.
    ///
    /// - Parameter directory: The model directory.
    /// - Returns: The template, or nil when there is none.
    static func chatTemplate(in directory: URL) -> String? {
        if let sidecar = try? String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8) {
            return sidecar
        }
        guard let data = try? Data(contentsOf: directory.appending(path: "tokenizer_config.json")),
            case .object(let config) = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        switch config["chat_template"] {
        case .string(let template): return template
        case .array(let named):
            let templates = named.compactMap { entry -> (String, String)? in
                guard case .object(let object) = entry, case .string(let name) = object["name"],
                    case .string(let template) = object["template"]
                else { return nil }
                return (name, template)
            }
            return (templates.first { $0.0 == "tool_use" } ?? templates.first { $0.0 == "default" })?.1
        default: return nil
        }
    }
}
