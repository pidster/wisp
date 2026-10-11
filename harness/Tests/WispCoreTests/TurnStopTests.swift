import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Ctrl-C during a model's turn (ADR 0049, amended 2026-10-11): the first press stops the turn, cancelling its
/// request and stopping a `run_command` it started as a typed command is stopped, and returns to the prompt with
/// "stopped by you"; a second press kills what it still has running. The turn is recorded as stopped, with no call
/// left without its answer, and the next request composes cleanly.
@Suite(.timeLimit(.minutes(1))) struct TurnStopTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-turnstop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Waits up to ten seconds for `file` to hold a pid, as a command writes it once it has started.
    private func pid(in file: URL) async -> pid_t? {
        for _ in 0..<1000 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Waits up to five seconds for `pid` to be gone.
    private func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<500 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// A chat session's conversation with `run_command`, on `model`, auditing to `sink` and showing through `tap`.
    private func conversation(
        _ model: ScriptedModel, home: Home, sink: MemoryAuditSink, tap: ChatEvents.Tap
    ) throws -> Agent {
        try home.ensure()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
        let thread = try WispThread.setUp(
            session: session, audit: session.audit, host: session.host(approver: AutoApprover()),
            prompting: session.prompting, toolNames: ["run_command"], model: .system, observer: tap)
        return try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
    }

    @Test func ctrlCStopsTheTurnAndTheCommandItStartedAndChatGoesOn() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "child.pid")
        // The child ignores SIGTERM and the leader waits for it, so only the group's kill after the grace ends it.
        let command = "(trap '' TERM; exec sleep 30) & echo $! > child.pid; wait"
        let arguments = try String(
            decoding: JSONEncoder().encode(["command": command, "workingDirectory": dir.path]), as: UTF8.self)
        let model = ScriptedModel(steps: [
            .call(name: "run_command", arguments: arguments), .say("The second turn."),
        ])
        let sink = MemoryAuditSink()
        let tap = ChatEvents.Tap()
        let agent = try conversation(model, home: Home(root: dir.appending(path: "home")), sink: sink, tap: tap)
        let capture = ChatLoopTests.Capture(lines: ["run it", "and now?", "/quit"])
        var context = ChatLoopTests.context
        context.directory = dir.path
        let activity = ChatActivity()
        let states = Mutex<[ChatActivity.State?]>([])
        activity.onChange { state in states.withLock { $0.append(state) } }
        context.activity = activity
        let interrupt = ChatInterrupt()
        context.interrupt = interrupt
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: capture.io)
        let presser = Task { () -> (pid: pid_t?, press: ChatInterrupt.Press?) in
            guard let pid = await pid(in: file) else { return (nil, nil) }
            return (pid, interrupt.press())
        }
        let started = ContinuousClock.now
        try await loop.run()
        let (child, press) = await presser.value
        let pid = try #require(child, "the command never started")
        defer { kill(pid, SIGKILL) }
        #expect(press == .stoppingTurn)
        #expect(await gone(pid), "pid \(pid) outlived the stop")
        // Stopped within the grace and its margin, not at the command's 30 s or the runner's 60 s timeout.
        #expect(ContinuousClock.now - started < .seconds(15))
        // The person was told, and the chat went on: the next turn was answered.
        let noted = capture.noted
        #expect(noted.contains("stopped by you"), "\(noted)")
        #expect(capture.output.contains("The second turn."))
        #expect(capture.marks == ["start 1", "end 1 failed", "start 2", "end 2"])
        #expect(interrupt.press() == .idle, "disarmed once the turn ended")
        // The activity said it could be stopped, then that it was stopping the turn, then ended.
        let seen = states.withLock { $0 }
        #expect(seen.first??.stoppable == true && seen.first??.turn == true)
        #expect(seen.contains { $0?.stopping == true && $0?.doing == "stopping the turn" })
        // Audited: the command's outcome as stopped, and the turn as stopped; no error for it.
        let outcome = try #require(sink.events.first { $0.kind == .commandOutcome })
        #expect(outcome.details["stopped"] == true && outcome.details["timedOut"] == false)
        let stopped = try #require(sink.events.first { $0.kind == .turnStopped })
        #expect(stopped.turn == 1 && stopped.details["killed"] == false)
        #expect(Set(stopped.details.keys) == AuditEvent.fields(for: .turnStopped))
        #expect(!sink.events.contains { $0.kind == .error && $0.turn == 1 })
        // The model's second request was never sent: the stop came first. The stopped turn is recorded from its
        // events, and the next turn's request carries its prompt, its call, and the call's answer, which says the
        // command was stopped, and no reply it never gave.
        let recorded = agent.store.entries.filter { $0.turn == 1 }
        #expect(recorded.map(\.kind) == [.prompt, .toolCalls, .toolOutput])
        #expect(recorded.last.map { ThreadRecord.text(of: $0.value).contains("stopped") } == true)
        #expect(recorded.allSatisfy { !$0.sources.isEmpty }, "linked to the audit events that recorded them")
        let requests = model.script.requests.withLock { $0 }
        #expect(requests.count == 2)
        let carried = Array(try #require(requests.last).transcript)
        #expect(carried.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(carried.contains { if case .toolOutput = $0 { true } else { false } })
        #expect(!carried.contains { if case .response = $0 { true } else { false } })
        #expect(agent.store.entries.filter { $0.kind == .response }.count == 1)
    }

    @Test func ctrlCCancelsAModelRequestThatIsStillStreaming() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ScriptedModel(steps: [.hang("Thinking about"), .say("Answered.")])
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model),
            audit: AuditLog(session: "s", sink: sink))
        let capture = ChatLoopTests.Capture(lines: ["a long question", "again", "/quit"])
        var context = ChatLoopTests.context
        let interrupt = ChatInterrupt()
        context.interrupt = interrupt
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: capture.io)
        let presser = Task { () -> ChatInterrupt.Press? in
            // Pressed once the request is under way.
            for _ in 0..<1000 where model.script.requests.withLock({ $0.isEmpty }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return interrupt.press()
        }
        try await loop.run()
        #expect(await presser.value == .stoppingTurn)
        #expect(capture.noted.contains("stopped by you") && capture.output.contains("Answered."))
        #expect(sink.events.filter { $0.kind == .turnStopped }.count == 1)
        // The stopped turn's prompt is kept, so the next request knows what was asked.
        let prompts = agent.store.entries.filter { $0.kind == .prompt }.map { ThreadRecord.text(of: $0.value) }
        #expect(prompts == ["a long question", "again"])
    }

    @Test func theFrontEndsInterruptLineStopsATurnAndTheActivityTellsItSo() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ScriptedModel(steps: [.hang(""), .say("Answered.")])
        let agent = Agent(instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model))
        // As `wisp chat --json` wires it: messages and the interrupt arrive through the router.
        let router = LineRouter()
        let interrupt = ChatInterrupt()
        router.onInterrupt { _ = interrupt.press() }
        router.receive(#"{"type":"message","text":"a long question"}"#)
        router.receive(#"{"type":"message","text":"again"}"#)
        router.close()
        let activity = ChatActivity()
        let lines = Mutex<[JSONValue]>([])
        activity.onChange { state in lines.withLock { $0.append(.object(ChatProtocol.activity(state))) } }
        let capture = ChatLoopTests.Capture(lines: [])
        var io = capture.io
        io.readLine = { router.nextMessage() }
        var context = ChatLoopTests.context
        context.activity = activity
        context.interrupt = interrupt
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: context, io: io)
        let sender = Task {
            for _ in 0..<1000 where model.script.requests.withLock({ $0.isEmpty }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            router.receive(#"{"type":"interrupt"}"#)
        }
        try await loop.run()
        await sender.value
        #expect(capture.noted.contains("stopped by you") && capture.output.contains("Answered."))
        // The activity told the front end the turn could be stopped, then that it was stopping.
        let sent = lines.withLock { $0 }
        #expect(sent.first?.objectValue?["stoppable"] == true)
        #expect(
            sent.contains { $0.objectValue?["stopping"] == true && $0.objectValue?["doing"] == "stopping the turn" })
    }

    @Test func aSecondPressKillsWhatTheTurnHasRunningAndASkippedCallLeavesNoHalfCall() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CommandRunner(options: .init(writableRoot: dir.path))
        let stop = TurnStop()
        let interrupt = ChatInterrupt()
        interrupt.armTurn(stop)
        let line = "trap '' TERM; echo $$ > leader.pid; sleep 30"
        let file = dir.appending(path: "leader.pid")
        let presses = Task { () -> [ChatInterrupt.Press] in
            guard await pid(in: file) != nil else { return [] }
            return [interrupt.press(), interrupt.press()]
        }
        // A model's command, inside the turn: it follows the turn's stop.
        let killed = try await TurnStop.$current.withValue(stop) { try await runner.run(line, in: dir.path) }
        #expect(await presses.value == [.stoppingTurn, .killingTurn])
        #expect(killed.stopped && killed.exitStatus == -SIGKILL, "\(killed)")
        // A command the turn starts once it was stopped ends as it starts.
        let late = try await TurnStop.$current.withValue(stop) { try await runner.run("sleep 30", in: dir.path) }
        #expect(late.stopped && late.exitStatus == -SIGKILL)
        interrupt.disarmTurn()
        #expect(interrupt.press() == .idle)
        // A call whose answer never came is left out, with any answers it had; answered calls stay.
        let arguments = try GeneratedContent(json: "{}")
        let call = Transcript.ToolCall(id: "c1", toolName: "run_command", arguments: arguments)
        let calls = Transcript.Entry.toolCalls(.init([call, call]))
        let output = Transcript.Entry.toolOutput(
            .init(id: "c1", toolName: "run_command", segments: [.text(.init(content: "ok"))]))
        let prompt = Transcript.Entry.prompt(.init(segments: [.text(.init(content: "go"))]))
        #expect(Agent.answered([prompt, calls, output]).count == 1)
        #expect(Agent.answered([prompt, calls, output, output]).count == 4)
    }

    @Test func theActivityOfATurnFollowsItsEventsAndSaysWhenItIsStopping() {
        let activity = ChatActivity()
        let start = Date()
        activity.begin(stoppable: true, turn: true, at: start)
        // Unlike a typed command's, a turn's events change what it shows; it gives no hint until it is stopping.
        activity.apply(
            AuditEvent(
                session: "s", kind: .toolCall,
                details: AuditEvent.Details.toolCall(tool: "run_command", arguments: #"{"command":"make"}"#)),
            at: start)
        let running = activity.current
        #expect(running?.doing.hasPrefix("running") == true && running?.stoppable == true)
        #expect(running.map { ChatActivity.line($0, now: start) }?.contains("Ctrl-C") == false)
        #expect(ChatProtocol.activity(running)["stoppable"] == true)
        activity.stopping("stopping the turn", at: start)
        let stopping = activity.current
        #expect(stopping?.stopping == true && ChatProtocol.activity(stopping)["stopping"] == true)
        #expect(stopping.map { ChatActivity.line($0, now: start) } == "0 s · stopping the turn · Ctrl-C again quits")
        // Once stopping, the turn's last events do not take the line back.
        activity.apply(AuditEvent(session: "s", kind: .commandOutcome, details: [:]), at: start)
        #expect(activity.current?.doing == "stopping the turn")
        #expect(ChatInterrupt.stoppingTurnNote == "stopping the turn; Ctrl-C again quits")
    }
}
