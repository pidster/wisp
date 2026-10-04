import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The line beside each reply that says what the turn actually ran (ADR 0051), counted from its audit events.
@Suite struct TurnToolSummaryTests {
    /// Builds the events of one turn, numbering call ids as it goes.
    private struct Turn {
        var events: [AuditEvent] = []
        var next = 0

        /// A call and its result.
        mutating func call(_ tool: String, arguments: String = "{}", output: String = "ok") {
            let id = "c\(next)"
            next += 1
            events.append(
                AuditEvent(
                    session: "s", kind: .toolCall, turn: 1, call: id,
                    details: ["tool": .string(tool), "arguments": .string(arguments)]))
            events.append(
                AuditEvent(
                    session: "s", kind: .toolResult, turn: 1, call: id,
                    details: AuditEvent.Details.toolResult(tool: tool, output: output, seconds: 0)))
        }

        /// A `run_command` call with its policy decision and, when it ran, its outcome.
        mutating func command(
            _ line: String, verdict: String = "allowed", exit: Int? = 0, timedOut: Bool = false, origin: String? = nil
        ) {
            let id = "c\(next)"
            next += 1
            events.append(
                AuditEvent(
                    session: "s", kind: .toolCall, turn: 1, call: id,
                    details: ["tool": "run_command", "arguments": .string(#"{"command":"\#(line)"}"#)]))
            var decision: [String: JSONValue] = ["command": .string(line), "verdict": .string(verdict)]
            if let origin { decision["origin"] = .string(origin) }
            events.append(AuditEvent(session: "s", kind: .policyDecision, turn: 1, details: decision))
            if let exit {
                events.append(
                    AuditEvent(
                        session: "s", kind: .commandOutcome, turn: 1,
                        details: ["command": .string(line), "exitStatus": .int(exit), "timedOut": .bool(timedOut)]))
            }
            events.append(
                AuditEvent(
                    session: "s", kind: .toolResult, turn: 1, call: id,
                    details: AuditEvent.Details.toolResult(tool: "run_command", output: "x", seconds: 0)))
        }

        /// The line for these events.
        func line(_ reply: String = "done", tools: [String] = []) -> String? {
            TurnToolSummary(events: events, turn: 1).line(reply: reply, tools: tools)
        }
    }

    @Test func countsEachToolInTheOrderOfItsFirstUse() {
        var turn = Turn()
        turn.call("read_file")
        turn.command("ls")
        turn.call("read_file")
        turn.call("edit_file")
        turn.command("pwd")
        turn.call("notify")
        #expect(turn.line() == "ran: read_file ×2 · run_command ×2 · edit_file · notify")
    }

    @Test func failuresAreCountedApartFromDenialsAndDeclines() {
        var turn = Turn()
        turn.command("make test", exit: 2)
        turn.command("sleep 99", exit: 0, timedOut: true)
        turn.command("ls")
        turn.command("sudo ls", verdict: "denied", exit: nil)
        turn.command("rm scratch.txt", verdict: "disapproved", exit: nil)
        // A command that could not start (a missing directory) has no outcome: it failed.
        turn.command("ls /nowhere", exit: nil)
        turn.call("read_file", output: "error: no such file")
        turn.call("read_file", output: "line 1: error: in the middle is not a failure")
        #expect(
            turn.line()
                == "ran: run_command ×6 (3 failed, 1 denied, 1 declined) · read_file ×2 (1 failed)")
    }

    @Test func aThrownToolErrorIsAFailure() {
        var turn = Turn()
        turn.events.append(
            AuditEvent(
                session: "s", kind: .toolCall, turn: 1, call: "x", details: ["tool": "notify", "arguments": "{}"]))
        turn.events.append(AuditEvent(session: "s", kind: .error, turn: 1, call: "x", details: ["message": "boom"]))
        #expect(turn.line() == "ran: notify (1 failed)")
    }

    @Test func aCommandThePersonTypedIsNeverTakenForTheModels() {
        var turn = Turn()
        // The person's `! ls` was denied in the same turn number; the model's `ls` ran and succeeded.
        turn.events.append(
            AuditEvent(
                session: "s", kind: .policyDecision, turn: 1,
                details: ["command": "ls", "verdict": "denied", "origin": "person"]))
        turn.command("ls")
        #expect(turn.line() == "ran: run_command")
    }

    @Test func otherTurnsAreLeftOut() {
        var turn = Turn()
        turn.call("read_file")
        turn.events.append(
            AuditEvent(
                session: "s", kind: .toolCall, turn: 2, call: "z", details: ["tool": "notify", "arguments": "{}"]))
        #expect(turn.line() == "ran: read_file")
    }

    @Test func theLineNamesAtMostSixToolsAndCountsTheRest() {
        var turn = Turn()
        for index in 1...8 { turn.call("tool_\(index)") }
        #expect(
            turn.line()
                == "ran: tool_1 · tool_2 · tool_3 · tool_4 · tool_5 · tool_6 · +2 more")
    }

    @Test func aTurnWithoutToolsShowsNothingUnlessTheReplyNamesOne() {
        let tools = ["read_file", "run_command", "inspect", "system_info"]
        let turn = Turn()
        #expect(turn.line("The answer is 42.", tools: tools) == nil)
        #expect(
            turn.line("Ran `inspect(config)` and system_info(ports=8080): port 8080 is free.", tools: tools)
                == "ran: no tools")
        #expect(turn.line(#"I passed run_command(command="sudo ls")."#, tools: tools) == "ran: no tools")
        // Inside a longer word it is not a tool's name.
        #expect(turn.line("The unread_files folder and inspector are empty.", tools: tools) == nil)
        #expect(turn.line("anything", tools: []) == nil)
    }

    @Test func wholeWordsOnly() {
        #expect(TurnToolSummary.mentions("read_file", in: "read_file"))
        #expect(TurnToolSummary.mentions("read_file", in: "used read_file."))
        #expect(TurnToolSummary.mentions("read_file", in: "xread_file, then read_file"))
        #expect(!TurnToolSummary.mentions("read_file", in: "read_files"))
        #expect(!TurnToolSummary.mentions("read_file", in: "read file"))
        #expect(!TurnToolSummary.mentions("", in: "anything"))
    }

    @Test func theTrailKeepsTheEventsThatSayHowACallEnded() {
        let trail = ToolEventTrail()
        for kind in [
            AuditEvent.Kind.prompt, .toolCall, .policyDecision, .commandOutcome, .toolResult, .error, .response,
        ] {
            trail.write(AuditEvent(session: "s", kind: kind, turn: 1))
        }
        #expect(trail.take(turn: 1).map(\.kind) == [.toolCall, .policyDecision, .commandOutcome, .toolResult, .error])
    }

    @Test func theJSONTurnCarriesTheLineAndTheTerminalShowsItUnderTheReply() {
        let end = ChatTurn.end(turn: 2, seconds: 1.5, failed: false, ran: "ran: read_file ×2")
        #expect(ChatProtocol.turn(end)["ran"] == "ran: read_file ×2")
        #expect(ChatProtocol.turn(.end(turn: 2, seconds: 1.5, failed: false))["ran"] == nil)
        #expect(end.footer(style: .plain) == "  ran: read_file ×2\n  1.5 s")
        #expect(ChatTurn.end(turn: 2, seconds: 1.5, failed: false).footer(style: .plain) == "  1.5 s")
    }

    @Test func chatShowsWhatTheTurnRanAfterTheReplyAndNothingForATypedCommand() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-turn-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        try Data(#"{"commandPolicy":{"deny":["^echo forbidden"]}}"#.utf8).write(to: home.configFile)
        let session = try Session.begin(
            .init(entryPoint: .chat), home: home, dependencies: .testing(sink: MemoryAuditSink()))
        let tap = ChatEvents.Tap()
        let thread = try WispThread.setUp(
            session: session, audit: session.audit,
            host: session.host(approver: DenyingApprover(reason: "not in tests")),
            prompting: session.prompting, toolNames: ["read_file", "run_command"], model: .system, observer: tap)
        let missing = dir.appending(path: "missing.txt").path
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(missing)"}"#),
            .call(name: "run_command", arguments: #"{"command":"echo forbidden","workingDirectory":"\#(dir.path)"}"#),
            .say("I removed the file with run_command."),
            .say("Nothing to do."),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        let capture = ChatLoopTests.Capture(lines: ["clean up", "! echo hi", "thanks", "/quit"])
        var context = ChatLoopTests.context
        context.directory = dir.path
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: capture.io)
        try await loop.run()
        let ends = capture.turns.withLock { $0 }.compactMap { mark -> String?? in
            guard case .end(_, _, _, _, _, let ran) = mark else { return nil }
            return .some(ran)
        }
        // Two model turns, no third for the typed command: the first ran two tools, neither successfully; the
        // second ran none and names none.
        #expect(ends == ["ran: read_file (1 failed) · run_command (1 denied)", nil])
    }
}
