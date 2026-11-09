import Foundation
import Testing

@testable import WispCore

/// Reading tool calls from `<tool_call>` frames and ATEM blocks, and splitting frames out of streamed text.
@Suite struct ToolCallFramesTests {
    /// Schemas for two offered tools.
    private let schemas: [String: JSONValue] = [
        "current_date": ["type": "object", "properties": ["timeZone": ["type": "string"]]],
        "read_file": [
            "type": "object",
            "properties": ["path": ["type": "string"], "offset": ["type": "integer"], "all": ["type": "boolean"]],
        ],
    ]

    @Test func aJSONObjectFrameIsOneCall() {
        let calls = ToolCallFrames.calls(
            in:
                "<tool_call>\n{\"name\": \"current_date\", \"arguments\": {\"timeZone\": \"Asia/Tokyo\"}}\n</tool_call>",
            schemas: schemas)
        #expect(calls?.map(\.name) == ["current_date"])
        #expect(calls?.first?.arguments == ["timeZone": "Asia/Tokyo"])
    }

    @Test func argumentsWrittenAsAJSONStringAreDecoded() {
        let calls = ToolCallFrames.calls(
            in: #"<tool_call>{"name": "read_file", "arguments": "{\"path\": \"/tmp/a\"}"}</tool_call>"#,
            schemas: schemas)
        #expect(calls?.first?.arguments == ["path": "/tmp/a"])
    }

    @Test func aJSONArrayFrameIsSeveralCalls() {
        let calls = ToolCallFrames.calls(
            in:
                #"<tool_call>[{"name": "current_date", "arguments": {}}, {"name": "read_file", "arguments": {"path": "/a"}}]</tool_call>"#,
            schemas: schemas)
        #expect(calls?.map(\.name) == ["current_date", "read_file"])
    }

    @Test func anXMLFrameIsReadWithItsParametersTypedByTheSchema() {
        // The form Qwen3.5's and Nemotron 3 Nano's templates ask for (their chat_template.jinja, 2026-10-05).
        let frame = """
            <tool_call>
            <function=read_file>
            <parameter=path>
            /tmp/notes.txt
            </parameter>
            <parameter=offset>
            40
            </parameter>
            <parameter=all>
            false
            </parameter>
            </function>
            </tool_call>
            """
        let calls = ToolCallFrames.calls(in: frame, schemas: schemas)
        #expect(calls?.first?.name == "read_file")
        #expect(calls?.first?.arguments == ["path": "/tmp/notes.txt", "offset": 40, "all": false])
        let empty = ToolCallFrames.calls(
            in: "<tool_call>\n<function=current_date>\n</function>\n</tool_call>", schemas: schemas)
        #expect(empty?.first?.arguments == [:])
    }

    @Test func aStringParameterKeepsItsTextEvenWhenItLooksLikeJSON() {
        let frame = "<tool_call><function=read_file><parameter=path>\n42\n</parameter></function></tool_call>"
        #expect(ToolCallFrames.calls(in: frame, schemas: schemas)?.first?.arguments == ["path": "42"])
    }

    @Test func framesThatAreNotCallsToOfferedToolsAreNotCalls() {
        for frame in [
            "<tool_call>{\"name\": \"rm_rf\", \"arguments\": {}}</tool_call>",
            "<tool_call><function=rm_rf></function></tool_call>",
            "<tool_call>call current_date please</tool_call>",
            "<tool_call><function=current_date></function> and then some</tool_call>",
            "<tool_call>{\"name\": \"current_date\", \"arguments\": {}, \"extra\": 1}</tool_call>",
            "<tool_call></tool_call>",
            "{\"name\": \"current_date\", \"arguments\": {}}",
        ] {
            #expect(ToolCallFrames.calls(in: frame, schemas: schemas) == nil, "\(frame)")
        }
    }

    @Test func anATEMBlockIsReadWithItsParametersTypedByTheSchema() {
        // The form Muse Glimmer's template writes after a `to=TOOL` header (its chat_template.jinja, 2026-10-08).
        let block = """
            <atem:function_calls>
            <atem:invoke name="read_file">
            <atem:parameter name="path">/tmp/a b.txt</atem:parameter>
            <atem:parameter name="offset">3</atem:parameter>
            </atem:invoke>
            </atem:function_calls>
            """
        let calls = ToolCallFrames.atem(block, schemas: schemas)
        #expect(calls?.first?.name == "read_file")
        #expect(calls?.first?.arguments == ["path": "/tmp/a b.txt", "offset": 3])
        let none = "<atem:function_calls>\n<atem:invoke name=\"current_date\">\n</atem:invoke>\n</atem:function_calls>"
        #expect(ToolCallFrames.atem(none, schemas: schemas)?.first?.arguments == [:])
        #expect(
            ToolCallFrames.atem(none.replacingOccurrences(of: "current_date", with: "nope"), schemas: schemas) == nil)
        #expect(ToolCallFrames.atem("<atem:function_calls>text</atem:function_calls>", schemas: schemas) == nil)
    }

    @Test func theSplitterHoldsATagSplitAcrossChunksAndPassesTextThrough() {
        var splitter = ToolCallFrames.Splitter()
        var pieces: [ToolCallFrames.Piece] = []
        for chunk in ["Let me check. <tool", "_call>{\"name\": ", "\"x\"}</tool_", "call> done"] {
            pieces += splitter.feed(chunk)
        }
        pieces += splitter.finish()
        #expect(
            pieces == [
                .text("Let me check. "), .frame("<tool_call>{\"name\": \"x\"}</tool_call>"), .text(" done"),
            ])
    }

    @Test func anUnclosedFrameComesOutAsTextAtTheEnd() {
        var splitter = ToolCallFrames.Splitter()
        #expect(splitter.feed("a <tool_call>{\"name\"") == [.text("a ")])
        #expect(splitter.finish() == [.text("<tool_call>{\"name\"")])
        #expect(splitter.feed("<to") == [])
        #expect(splitter.finish() == [.text("<to")])
    }
}
