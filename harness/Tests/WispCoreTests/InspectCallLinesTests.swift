import Testing

@testable import WispCore

/// The one line `inspect calls` gives each tool call of a turn, for the outcomes a model must tell apart.
@Suite struct InspectCallLinesTests {
    /// A command turned away by the policy is not a command the person declined, a call with no result says so, and
    /// every other outcome reads as what happened.
    @Test func eachOutcomeOfACallReadsAsWhatHappened() {
        let calls: [TurnCalls.Call] = [
            .init(tool: "run_command", arguments: "{\"command\": \"rm x\"}", command: "rm x", verdict: "denied"),
            .init(tool: "run_command", arguments: "{}", command: "git push", verdict: "disapproved"),
            .init(tool: "read_file", arguments: "{\"path\": \"a\"}"),
            .init(tool: "run_command", arguments: "{}", command: "sleep 9", exitStatus: 124, timedOut: true),
            .init(tool: "edit_file", arguments: "{}", output: "error: no such file\nmore"),
            .init(tool: "system_info", arguments: "{}", output: "ok"),
            .init(tool: "inspect", arguments: "{}", error: "the request failed"),
        ]
        let lines = InspectTool.callLines(calls, turn: 4)
        #expect(lines[0] == "turn 4: 7 tool calls")
        #expect(lines[1].hasSuffix("→ denied by policy; did not run"))
        #expect(lines[2].hasSuffix("→ not approved; did not run"))
        #expect(lines[3].hasSuffix("→ no result"))
        #expect(lines[4].hasSuffix("→ exit status 124, timed out"))
        #expect(lines[5].hasSuffix("→ error: no such file"))
        #expect(lines[6].hasSuffix("→ ok, 2 bytes"))
        #expect(lines[7].hasSuffix("→ threw: the request failed"))
        #expect(InspectTool.callLines([], turn: 1) == ["turn 1: 0 tool calls"])
    }
}
