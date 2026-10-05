import Foundation
import Testing
import WispCore

@testable import WispMLX

/// What wisp's MLX executor adds to mlx-swift-lm's tool-call parsing and stop tokens, on the outputs and templates
/// of the Falcon-H1 models probed on 2026-10-05 through the executor with the capability check's request.
@Suite struct ToolCallRecoveryTests {
    /// Falcon-H1-Tiny-Tool-Calling-90M's reply, greedy, with the tool's schema less `x-order` and `title`: its
    /// template's array form, which mlx-swift-lm rejects as malformed.
    static let tinyArray = """
        <tool_call>
        [
          {"name": "record_word", "arguments":{"word": "heron"}}
        ]
        </tool_call>
        """

    @Test func readsTheFramedArrayTheTinyModelWrites() throws {
        let calls = try #require(ToolCallRecovery.framedArray(Self.tinyArray, offered: ["record_word"]))
        #expect(calls.count == 1)
        #expect(calls.first?.name == "record_word")
        #expect(calls.first?.arguments == ["word": "heron"])
    }

    @Test func readsEveryCallOfAnArrayInOrder() throws {
        let raw = """
            <tool_call>[{"name": "a", "arguments": {"x": 1}}, {"name": "b", "arguments": {}}]</tool_call>
            """
        let calls = try #require(ToolCallRecovery.framedArray(raw, offered: ["a", "b"]))
        #expect(calls.map(\.name) == ["a", "b"])
        #expect(calls.map(\.arguments) == [["x": 1], [:]])
    }

    /// The same model's reply with the schema wisp sends: an array that never closes. Not a call.
    @Test func refusesTheUnclosedArrayTheTinyModelWritesForTheCheck() {
        let raw = "<tool_call>\n[{\"name\": \"record_word\", \"arguments\": {}}\n</tool_call>"
        #expect(ToolCallRecovery.framedArray(raw, offered: ["record_word"]) == nil)
    }

    /// Falcon-H1-7B-Instruct's reply: a closing tag where the opening one belongs, a Python literal, and a tool
    /// the request does not offer. Not a call.
    @Test func refusesTheInstructModelsReply() {
        let raw = "</tool_call>\n{'arguments': {'word': 'heron'}, 'name': 'run_function'}\n</tool_call>"
        #expect(ToolCallRecovery.framedArray(raw, offered: ["record_word"]) == nil)
        let framed = "<tool_call>\n[{'arguments': {'word': 'heron'}, 'name': 'record_word'}]\n</tool_call>"
        #expect(ToolCallRecovery.framedArray(framed, offered: ["record_word"]) == nil)
    }

    @Test func refusesAnythingButAnArrayOfOfferedCallsInOneFrame() {
        let offered: Set<String> = ["record_word"]
        let refused = [
            "<tool_call>[{\"name\": \"other\", \"arguments\": {}}]</tool_call>",
            "<tool_call>[]</tool_call>",
            "<tool_call>{\"name\": \"record_word\", \"arguments\": {}}</tool_call>",
            "<tool_call>[{\"name\": \"record_word\", \"arguments\": \"{}\"}]</tool_call>",
            "<tool_call>[{\"name\": \"record_word\", \"arguments\": {}, \"id\": \"1\"}]</tool_call>",
            "<tool_call>[{\"name\": \"record_word\", \"arguments\": {}}, 3]</tool_call>",
            "[{\"name\": \"record_word\", \"arguments\": {}}]",
            "<tool_call>[{\"name\": \"record_word\", \"arguments\": {}}]",
            "Sure: <tool_call>[{\"name\": \"record_word\", \"arguments\": {}}]</tool_call>",
            "<tool_call></tool_call>",
        ]
        for raw in refused {
            #expect(ToolCallRecovery.framedArray(raw, offered: offered) == nil, "\(raw)")
        }
    }

    /// The tiny model's template ends turns with `<|im_end|>`, which its generation config does not list.
    @Test func stopsAtChatMLsEndOfTurnWhenTheTemplateUsesIt() {
        let chatML = "{%- for message in messages %}<|im_start|>{{ message.role }}\n{{ message.content }}<|im_end|>"
        #expect(ToolCallRecovery.endOfTurnMarkers(template: chatML) == ["<|im_end|>"])
        #expect(ToolCallRecovery.endOfTurnMarkers(template: "{{ bos_token }}[INST]{{ content }}[/INST]").isEmpty)
        #expect(ToolCallRecovery.endOfTurnMarkers(template: nil).isEmpty)
    }

    @Test func readsTheTemplateFromTheSidecarOrTheTokenizerConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wisp-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ToolCallRecovery.chatTemplate(in: directory) == nil)
        let config = directory.appending(path: "tokenizer_config.json")
        try Data(#"{"chat_template": "plain"}"#.utf8).write(to: config)
        #expect(ToolCallRecovery.chatTemplate(in: directory) == "plain")
        try Data(
            #"{"chat_template": [{"name": "default", "template": "d"}, {"name": "tool_use", "template": "t"}]}"#.utf8
        ).write(to: config)
        #expect(ToolCallRecovery.chatTemplate(in: directory) == "t")
        try Data(#"{"chat_template": [{"name": "default", "template": "d"}]}"#.utf8).write(to: config)
        #expect(ToolCallRecovery.chatTemplate(in: directory) == "d")
        try Data("sidecar".utf8).write(to: directory.appending(path: "chat_template.jinja"))
        #expect(ToolCallRecovery.chatTemplate(in: directory) == "sidecar")
    }
}
