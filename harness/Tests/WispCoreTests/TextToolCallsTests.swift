import Foundation
import Testing

@testable import WispCore

/// Tool calls read from a reply's text (`TextToolCalls`), from the shapes models were seen to write.
@Suite struct TextToolCallsTests {
    static let offered: Set<String> = ["read_file", "system_info"]

    @Test func mistralsCallsAreReadAsTheModelWroteThem() throws {
        // ministral-3:14b in the context eval on 2026-10-04, and probed on 2026-10-06.
        let one = try #require(
            TextToolCalls.mistral(#"read_file[ARGS]{"path": "/tmp/notes.txt"}"#, offered: Self.offered))
        #expect(
            one == [TextToolCalls.Call(name: "read_file", arguments: ["path": "/tmp/notes.txt"], offered: Self.offered)]
        )
        // With the template's marker, several calls, and whitespace around them.
        let several = try #require(
            TextToolCalls.mistral(
                "\n[TOOL_CALLS]read_file[ARGS]{\"path\": \"a {b}\\\" c\"}\n[TOOL_CALLS]system_info[ARGS]{\"topic\": \"disk\"} ",
                offered: Self.offered))
        #expect(several.map(\.name) == ["read_file", "system_info"])
        #expect(several.map(\.arguments) == [["path": "a {b}\" c"], ["topic": "disk"]])
        #expect(TextToolCalls.mistral("read_file[ARGS]{}", offered: Self.offered)?.first?.arguments == [:])
    }

    @Test func anythingElseIsNotACall() {
        for text in [
            "",
            "[TOOL_CALLS]",
            // Text that only mentions the format.
            #"Use read_file[ARGS]{"path": "x"} to read it."#,
            #"read_file[ARGS]{"path": "x"} would read it."#,
            "The [ARGS] marker follows a tool's name.",
            // A tool the request does not offer.
            #"write_file[ARGS]{"path": "x"}"#,
            // Arguments that are not one whole object.
            #"read_file[ARGS]["x"]"#,
            #"read_file[ARGS] {"path": "x"}"#,
            #"read_file[ARGS]{"path": "x""#,
            #"read_file[ARGS]{path: x}"#,
            // Space between the name and the marker.
            #"read_file [ARGS]{"path": "x"}"#,
        ] {
            #expect(TextToolCalls.mistral(text, offered: Self.offered) == nil, "\(text)")
        }
    }

    @Test func aReplyIsHeldOnlyWhileItMayStillBeACall() {
        for text in [
            "", "  ", "[TOO", "[TOOL_CALLS]", "[TOOL_CALLS] read", "read", "read_file[AR", "read_file[ARGS]{\"pa",
        ] {
            #expect(TextToolCalls.mayBeMistral(text, offered: Self.offered), "\(text)")
        }
        for text in ["The", "read ", "read_file is", "[TOOL_CALLS] hello", "write_file[ARGS]"] {
            #expect(!TextToolCalls.mayBeMistral(text, offered: Self.offered), "\(text)")
        }
    }

    @Test func mistralsJSONArrayIsReadWithOrWithoutIDs() throws {
        // The form Mistral-7B-Instruct-v0.3's template writes after `[TOOL_CALLS]` (its chat_template.jinja,
        // 2026-11-23), with the id it gives each call it renders.
        let calls = try #require(
            TextToolCalls.mistralArray(
                #" [{"name": "read_file", "arguments": {"path": "a"}}, {"name": "system_info", "arguments": {}, "id": "call00001"}]"#,
                offered: Self.offered))
        #expect(calls.map(\.name) == ["read_file", "system_info"])
        #expect(calls.map(\.arguments) == [["path": "a"], [:]])
        for text in [
            "", "[]", "[TOOL_CALLS]", #"{"name": "read_file", "arguments": {}}"#,
            #"[{"name": "rm", "arguments": {}}]"#, #"[{"name": "read_file", "arguments": "x"}]"#,
            #"[{"name": "read_file", "arguments": {}, "extra": 1}]"#, #"[{"name": "read_file", "arguments": {}}] and"#,
        ] {
            #expect(TextToolCalls.mistralArray(text, offered: Self.offered) == nil, "\(text)")
        }
    }

    @Test func anArrayEndsWhereItsBracketsBalance() {
        let text: Substring = #" [{"name": "a", "arguments": {"s": "]}"}}] then more"#
        let end = TextToolCalls.arrayEnd(text)
        #expect(end.map { String(text[..<$0]) } == #" [{"name": "a", "arguments": {"s": "]}"}}]"#)
        #expect(TextToolCalls.arrayEnd(#"[{"name": "a""#) == nil)
        #expect(TextToolCalls.arrayEnd("{}") == nil)
    }

    @Test func aCallNeedsAnOfferedNameAndObjectArguments() {
        #expect(TextToolCalls.Call(name: "read_file", arguments: ["path": "x"], offered: Self.offered) != nil)
        #expect(TextToolCalls.Call(name: "rm", arguments: [:], offered: Self.offered) == nil)
        #expect(TextToolCalls.Call(name: "read_file", arguments: "x", offered: Self.offered) == nil)
    }
}

/// The ids the chat-template values give calls and their results (`ChatTemplateValues.messages`).
@Suite struct ChatTemplateCallIDTests {
    /// Mistral-7B-Instruct-v0.3's template stops rendering unless every call and tool message carries an id of nine
    /// letters and digits; the transcript keeps none, so each call is numbered and each tool message takes the id of
    /// the oldest call not yet answered.
    @Test func callsAndTheirResultsShareNineCharacterIDs() {
        let messages = ChatTemplateValues.messages([
            ChatMessage(role: "user", content: "Date and disk?"),
            ChatMessage(
                role: "assistant", content: "",
                toolCalls: [.init(name: "current_date", arguments: [:]), .init(name: "system_info", arguments: [:])]),
            ChatMessage(role: "tool", content: "today", toolName: "current_date"),
            ChatMessage(role: "tool", content: "full", toolName: "system_info"),
            ChatMessage(role: "assistant", content: "", toolCalls: [.init(name: "current_date", arguments: [:])]),
            ChatMessage(role: "tool", content: "still today", toolName: "current_date"),
        ])
        let ids = (messages[1]["tool_calls"] as? [[String: any Sendable]])?.compactMap { $0["id"] as? String }
        #expect(ids == ["call00001", "call00002"])
        #expect(messages.compactMap { $0["tool_call_id"] as? String } == ["call00001", "call00002", "call00003"])
        #expect(messages[0]["tool_call_id"] == nil && messages[0]["tool_calls"] == nil)
        #expect(ChatTemplateValues.callID(7) == "call00007" && ChatTemplateValues.callID(123_456) == "call123456")
    }
}
