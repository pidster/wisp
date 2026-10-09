import Foundation
import Testing

@testable import WispCore

@Suite struct ReceiptTests {
    /// An event in session `s`.
    private func event(
        _ kind: AuditEvent.Kind, turn: Int? = 1, call: String? = nil, _ details: [String: JSONValue] = [:]
    ) -> AuditEvent {
        AuditEvent(session: "s", kind: kind, turn: turn, call: call, details: details)
    }

    @Test func foldsOneTurnsEventsAndIgnoresOthers() {
        let events = [
            event(.sessionStart, turn: nil),
            event(.prompt, ["text": "go"]),
            event(.toolCall, call: "c1", ["tool": "run_command", "arguments": #"{"command":"ls"}"#]),
            event(.policyDecision, ["command": "ls", "verdict": "allowed"]),
            event(.approvalRequested, ["command": "ls", "level": "moderate"]),
            event(.approvalDecided, ["command": "ls", "decision": "approved", "scope": "session"]),
            event(
                .commandOutcome,
                ["command": "ls", "exitStatus": 0, "timedOut": false, "truncated": true, "seconds": 0.5]),
            event(.toolResult, call: "c1", ["tool": "run_command", "bytes": 12, "seconds": 0.6]),
            event(.toolCall, call: "c2", ["tool": "read_file", "arguments": "{}"]),
            event(.error, call: "c2", ["message": "boom", "context": "tool read_file"]),
            event(.policyDecision, ["command": "rm -rf /", "verdict": "denied", "reason": "deny pattern"]),
            event(.fileWrite, ["path": "/w/a.txt", "mode": "append", "created": false, "bytesAfter": 9]),
            event(.error, ["message": "turn failed"]),
            event(.condensation, ["turnsBefore": 3, "turnsAfter": 1]),
            event(.response, ["text": "done", "condensed": true, "seconds": 2]),
            event(.toolCall, turn: 2, call: "c3", ["tool": "current_date", "arguments": "{}"]),
        ]
        let receipt = Receipt(events: events, turn: 1)
        #expect(receipt.turn == 1)
        #expect(
            receipt.tools == [
                .init(name: "run_command", arguments: #"{"command":"ls"}"#, bytes: 12, seconds: 0.6, error: nil),
                .init(name: "read_file", arguments: "{}", bytes: nil, seconds: nil, error: "boom"),
            ])
        #expect(
            receipt.commands == [.init(command: "ls", exitStatus: 0, timedOut: false, truncated: true, seconds: 0.5)])
        #expect(receipt.denials == [.init(command: "rm -rf /", verdict: "denied", reason: "deny pattern")])
        #expect(receipt.files == [.init(path: "/w/a.txt", mode: "append", created: false, bytes: 9)])
        #expect(receipt.json.objectValue?["files"]?.arrayValue?.first?.objectValue?["bytes"] == 9)
        #expect(receipt.approvals == [.init(command: "ls", level: "moderate", decision: "approved", scope: "session")])
        #expect(receipt.errors == ["turn failed"])
        #expect(receipt.condensed && receipt.seconds == 2)
        let json = receipt.json.objectValue
        #expect(json?["turn"] == 1)
        #expect(json?["tools"]?.arrayValue?.count == 2)
        #expect(json?["tools"]?.arrayValue?.last?.objectValue?["error"] == "boom")
        #expect(json?["tools"]?.arrayValue?.last?.objectValue?["bytes"] == nil)
        #expect(json?["commands"]?.arrayValue?.first?.objectValue?["truncated"] == true)
        #expect(json?["denials"]?.arrayValue?.first?.objectValue?["reason"] == "deny pattern")
        #expect(json?["approvals"]?.arrayValue?.first?.objectValue?["scope"] == "session")
        #expect(json?["seconds"] == .double(2))
        // Turn 2 has just the call; an empty turn is an empty receipt with no timing.
        #expect(Receipt(events: events, turn: 2).tools.map(\.name) == ["current_date"])
        let empty = Receipt(events: events, turn: 3)
        #expect(empty.tools.isEmpty && empty.seconds == nil && !empty.condensed)
        #expect(empty.json.objectValue?["seconds"] == .null)
    }

    @Test func aFailedTurnIsCondensedOnlyWhenACondensationTookAStep() {
        let failed = [event(.prompt, ["text": "go"]), event(.error, ["message": "turn failed"])]
        // A condensation to a target that changed nothing (an overflow at the floor with no step to take).
        let none = event(.condensation, ["reason": "overflow", "steps": .array([])])
        #expect(!Receipt(events: [failed[0], none, failed[1]], turn: 1).condensed)
        let dropped = event(.condensation, ["reason": "overflow", "steps": .array(["dropped 2 turns"])])
        #expect(Receipt(events: [failed[0], dropped, failed[1]], turn: 1).condensed)
        // Phase 2's events name no steps; each one dropped turns.
        #expect(Receipt(events: [failed[0], event(.condensation, ["reason": "budget"]), failed[1]], turn: 1).condensed)
        // Two condensations, the second with no step: the first still condensed.
        #expect(Receipt(events: [failed[0], dropped, none, failed[1]], turn: 1).condensed)
    }

    @Test func listsAreBoundedAndMissingFieldsDefault() {
        let calls = (0..<(Receipt.maxEntries + 5)).map { event(.toolCall, call: "c\($0)", ["tool": "t"]) }
        let receipt = Receipt(events: calls + [event(.commandOutcome), event(.approvalDecided)], turn: 1)
        #expect(receipt.tools.count == Receipt.maxEntries)
        #expect(receipt.commands == [.init(command: "", exitStatus: -1, timedOut: false, truncated: false, seconds: 0)])
        #expect(receipt.approvals == [.init(command: "", level: nil, decision: "", scope: nil)])
    }

    @Test func collectorKeepsRecentEventsAndForgetsTakenTurns() {
        let collector = ReceiptCollector(capacity: 3)
        let sink = MemoryAuditSink()
        let log = AuditLog(session: "s", sink: sink).alsoRecording(to: collector)
        log.beginTurn()
        log.record(.prompt, details: ["text": "a"])
        log.record(.toolCall, call: "c", details: ["tool": "t1"])
        log.beginTurn()
        log.record(.toolCall, call: "d", details: ["tool": "t2"])
        log.record(.toolCall, call: "e", details: ["tool": "t3"])
        // The tee wrote everything to the real sink and kept only the newest three here.
        #expect(sink.events.count == 4)
        #expect(collector.take(turn: 1).tools.map(\.name) == ["t1"])
        let second = collector.take(turn: 2)
        #expect(second.tools.map(\.name) == ["t2", "t3"])
        #expect(collector.take(turn: 2).tools.isEmpty)
        #expect(log.currentTurn == 2)
        #expect(JSONValue.int(3).doubleValue == 3 && JSONValue.string("x").doubleValue == nil)
        #expect(JSONValue.bool(true).boolValue == true && JSONValue.int(1).boolValue == nil)
    }
}
