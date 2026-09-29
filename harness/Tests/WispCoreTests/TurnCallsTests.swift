import Foundation
import Testing

@testable import WispCore

/// The tool calls a `respond` result lists (D9), folded from a turn's audit events.
@Suite struct TurnCallsTests {
    @Test func foldsCallsResultsErrorsAndCommandOutcomes() throws {
        let log = AuditLog(session: "t", sink: MemoryAuditSink())
        func event(
            _ kind: AuditEvent.Kind, call: String?, turn: Int = 2, _ details: [String: JSONValue]
        )
            -> AuditEvent
        {
            AuditEvent(session: log.session, kind: kind, turn: turn, call: call, details: details)
        }
        let big = String(repeating: "x", count: 2000)
        let events = [
            event(.toolCall, call: "c0", turn: 1, ["tool": "read_file", "arguments": "{}"]),
            event(
                .toolCall, call: "c1",
                ["tool": "run_command", "arguments": #"{"command":"ls","workingDirectory":"/"}"#]),
            event(.commandOutcome, call: nil, ["command": "ls", "exitStatus": 0]),
            event(
                .toolResult, call: "c1", AuditEvent.Details.toolResult(tool: "run_command", output: "a\nb", seconds: 0)),
            event(.toolCall, call: "c2", ["tool": "read_file", "arguments": #"{"path":"/big"}"#]),
            event(.toolResult, call: "c2", AuditEvent.Details.toolResult(tool: "read_file", output: big, seconds: 0)),
            event(.toolCall, call: "c3", ["tool": "run_command", "arguments": #"{"command":"rm -rf /"}"#]),
            event(
                .toolResult, call: "c3",
                AuditEvent.Details.toolResult(tool: "run_command", output: "error: denied", seconds: 0)),
            event(.toolCall, call: "c4", ["tool": "notify", "arguments": "{}"]),
            event(.error, call: "c4", ["message": "boom"]),
        ]
        let folded = TurnCalls(events: events, turn: 2)
        #expect(folded.calls.map(\.tool) == ["run_command", "read_file", "run_command", "notify"])
        #expect(folded.calls[0].command == "ls" && folded.calls[0].exitStatus == 0 && folded.calls[0].bytes == 3)
        #expect(folded.calls[0].id == events[3].id && folded.calls[0].call == "c1")
        #expect(folded.calls[2].command == "rm -rf /" && folded.calls[2].exitStatus == nil)
        #expect(folded.calls[3].error == "boom" && folded.calls[3].id == nil && folded.calls[3].bytes == nil)
        let json = folded.json(inlineBytes: 1024) { "wisp://output/t/\($0)" }
        let calls = try #require(json.arrayValue).compactMap(\.objectValue)
        #expect(calls[0]["output"] == .string("a\nb") && calls[0]["outputURI"] == nil && calls[0]["bytes"] == .int(3))
        #expect(calls[0]["command"] == .string("ls") && calls[0]["exitStatus"] == .int(0))
        #expect(calls[1]["output"] == nil && calls[1]["bytes"] == .int(2000))
        #expect(calls[1]["outputURI"] == .string("wisp://output/t/\(events[5].id ?? "")"))
        #expect(calls[3]["error"] == .string("boom") && calls[3]["id"] == .null && calls[3]["bytes"] == nil)
        // With nothing to resolve a reference from, large output is left out, its size kept.
        let unresolvable = try #require(folded.json(inlineBytes: 1024) { _ in nil }.arrayValue)
        #expect(unresolvable[1].objectValue?["outputURI"] == nil && unresolvable[1].objectValue?["bytes"] == .int(2000))
        #expect(TurnCalls.command(in: "not json") == nil)
    }
}
