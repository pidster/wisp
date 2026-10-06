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

    @Test func aCallNeedsAnOfferedNameAndObjectArguments() {
        #expect(TextToolCalls.Call(name: "read_file", arguments: ["path": "x"], offered: Self.offered) != nil)
        #expect(TextToolCalls.Call(name: "rm", arguments: [:], offered: Self.offered) == nil)
        #expect(TextToolCalls.Call(name: "read_file", arguments: "x", offered: Self.offered) == nil)
    }
}
