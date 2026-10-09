import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A command the person types after `!` has no timeout and is stopped by the person instead (ADR 0049, amended
/// 2026-10-09): Ctrl-C reaches it through `ChatInterrupt`, its process group is ended, the stop is audited, and the
/// chat goes on. The model's `run_command` keeps its timeout.
@Suite struct TypedCommandStopTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-stop-\(UUID().uuidString)")
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

    @Test func aTypedCommandOutlastsTheTimeoutAndTheModelsDoesNot() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let runner = CommandRunner(
            options: .init(writableRoot: dir.path, timeout: .seconds(1)), audit: AuditLog(session: "s", sink: sink))
        #expect(runner.timeout(for: .person) == nil && runner.timeout(for: .model) == .seconds(1))
        // Twice the timeout: the person's command finishes.
        let typed = try await runner.run("sleep 2; echo done", in: dir.path, origin: .person)
        #expect(typed.exitStatus == 0 && typed.stdout == "done\n" && !typed.timedOut && !typed.stopped)
        // The same command from the model is killed at the timeout, as before.
        let model = try await runner.run("sleep 2; echo done", in: dir.path)
        #expect(model.timedOut && !model.stopped && !model.stdout.contains("done"))
        let outcomes = sink.events.filter { $0.kind == .commandOutcome }
        #expect(outcomes.count == 2 && outcomes.allSatisfy { $0.details["stopped"] == nil })
    }

    @Test func ctrlCStopsATypedCommandAndItsGroupAndChatGoesOn() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let tap = ChatEvents.Tap()
        let audit = AuditLog(session: "chat", sink: TeeAuditSink([sink, tap]))
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])), audit: audit)
        // A short timeout the typed command would hit if it had one.
        agent.commandRunner = CommandRunner(
            options: .init(writableRoot: dir.path, timeout: .seconds(1)), audit: audit)
        let file = dir.appending(path: "child.pid")
        // The child ignores SIGTERM; the leader waits for it, so only the group's kill ends the child.
        let command = "(trap '' TERM; exec sleep 30) & echo $! > child.pid; wait"
        let capture = ChatLoopTests.Capture(lines: ["! " + command, "! echo after", "/quit"])
        var context = ChatLoopTests.context
        context.directory = dir.path
        let activity = ChatActivity()
        let states = Mutex<[ChatActivity.State?]>([])
        activity.onChange { state in states.withLock { $0.append(state) } }
        context.activity = activity
        let interrupt = ChatInterrupt()
        context.interrupt = interrupt
        #expect(interrupt.press() == .idle, "nothing runs yet")
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: capture.io)
        let presser = Task { () -> (pid: pid_t?, press: ChatInterrupt.Press?) in
            guard let pid = await pid(in: file) else { return (nil, nil) }
            // Past the timeout the runner would have applied to the model's command: it still runs.
            try? await Task.sleep(for: .milliseconds(1500))
            let alive = kill(pid, 0) == 0
            return (pid, alive ? interrupt.press() : nil)
        }
        try await loop.run()
        let (child, press) = await presser.value
        let pid = try #require(child, "the command never started")
        defer { kill(pid, SIGKILL) }
        #expect(press == .stopping(command), "the command had ended before the press")
        #expect(await gone(pid), "pid \(pid) outlived the stop")
        // The outcome line says it was stopped, with the exit status; then the next command runs as usual.
        let noted = capture.noted
        #expect(noted.contains { $0.hasPrefix("  ↳ exit -") && $0.hasSuffix("(stopped by you)") }, "\(noted)")
        #expect(noted.contains("  ↳ exit 0"))
        #expect(interrupt.press() == .idle && interrupt.running == nil, "disarmed once it ended")
        // The activity said it could be stopped, then that it was stopping, then ended.
        let seen = states.withLock { $0 }
        #expect(seen.first??.stoppable == true && seen.first??.doing.hasPrefix("running (trap") == true)
        #expect(seen.contains { $0?.stopping == true && $0?.doing.hasPrefix("stopping (trap") == true })
        // Audited as stopped, on the outcome and the typed command, and the model is told so.
        let outcome = try #require(sink.events.first { $0.kind == .commandOutcome })
        #expect(outcome.details["stopped"] == true && outcome.details["timedOut"] == false)
        let typed = try #require(sink.events.first { $0.kind == .commandTyped })
        #expect(typed.details["stopped"] == true)
        #expect(Set(typed.details.keys).isSubset(of: AuditEvent.fields(for: .commandTyped)))
        #expect(Set(outcome.details.keys).isSubset(of: AuditEvent.fields(for: .commandOutcome)))
        #expect(sink.events.filter { $0.kind == .commandTyped }.last?.details["stopped"] == nil)
        let entry = try #require(agent.store.entries.first { $0.kind == .command })
        let recorded = try #require(entry.command)
        #expect(recorded.stopped && !recorded.timedOut)
        let notice = OutputReference.personCommand(recorded, entry: entry.id, time: nil, output: "")
        #expect(notice.contains("stopped by the person"), "\(notice)")
    }

    @Test func aSecondRequestKillsAtOnceAndARequestBeforeTheStartActsAsItStarts() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CommandRunner(options: .init(writableRoot: dir.path))
        // Asked before it starts: the command is stopped as it starts, and ends long before its sleep.
        let early = CommandStop()
        #expect(early.request() == .stop && early.requested)
        let stopped = try await runner.run("sleep 30", in: dir.path, origin: .person, stop: early)
        #expect(stopped.stopped && stopped.exitStatus == -SIGTERM && !stopped.timedOut)
        // A command that ignores SIGTERM: a second request kills it.
        let stop = CommandStop()
        let interrupt = ChatInterrupt()
        let line = "trap '' TERM; echo $$ > leader.pid; sleep 30"
        interrupt.arm(line, stop: stop)
        let file = dir.appending(path: "leader.pid")
        let presses = Task { () -> [ChatInterrupt.Press] in
            guard await pid(in: file) != nil else { return [] }
            return [interrupt.press(), interrupt.press()]
        }
        let killed = try await runner.run(line, in: dir.path, origin: .person, stop: stop)
        #expect(await presses.value == [.stopping(line), .killing(line)])
        #expect(killed.stopped && killed.exitStatus == -SIGKILL, "\(killed)")
        #expect(killed.rendered.contains("stopped: the person stopped the command"))
        // Once it has ended, a request reaches nothing.
        stop.kill()
        interrupt.disarm()
        #expect(interrupt.press() == .idle)
    }

    @Test func theFrontEndsInterruptLineReachesTheChat() {
        #expect(ChatProtocol.Inbound(line: #"{"type":"interrupt"}"#) == .interrupt)
        let router = LineRouter()
        let pressed = Mutex(0)
        router.onInterrupt { pressed.withLock { $0 += 1 } }
        router.receive(#"{"type":"interrupt"}"#)
        #expect(pressed.withLock { $0 } == 1)
        // The activity line tells the front end it can stop the command, then that it is stopping.
        let now = Date()
        var state = ChatActivity.State(
            doing: "running ollama pull x", since: now, turnStarted: now, asking: false, stoppable: true)
        #expect(ChatProtocol.activity(state)["stoppable"] == true && ChatProtocol.activity(state)["stopping"] == nil)
        #expect(ChatActivity.line(state, now: now) == "0 s · running ollama pull x · Ctrl-C stops it")
        state.stoppable = false
        state.stopping = true
        #expect(ChatProtocol.activity(state)["stopping"] == true && ChatProtocol.activity(state)["stoppable"] == nil)
        #expect(ChatActivity.line(state, now: now).hasSuffix(" · Ctrl-C again quits"))
        #expect(ChatInterrupt.stoppingNote("ollama pull x") == "stopping ollama pull x; Ctrl-C again quits")
        // A model's turn is not stoppable: its activity has neither field, and stopping it changes nothing.
        let activity = ChatActivity()
        activity.begin()
        activity.stopping("stopping")
        #expect(activity.current?.doing == "waiting for the model" && activity.current?.stopping == false)
        #expect(ChatProtocol.activity(activity.current)["stoppable"] == nil)
    }

    @Test func aRecordSavedBeforeStopsExistedReadsAsNotStopped() throws {
        let old = #"{"line":"ls","directory":"/w","exitStatus":0,"timedOut":false,"truncated":false}"#
        let decoded = try JSONDecoder().decode(ThreadRecord.PersonCommand.self, from: Data(old.utf8))
        #expect(decoded == ThreadRecord.PersonCommand(line: "ls", directory: "/w", exitStatus: 0))
        // Not stopped writes as before; stopped round-trips.
        let plain = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!plain.contains("stopped"))
        let stopped = ThreadRecord.PersonCommand(line: "ls", directory: "/w", exitStatus: -15, stopped: true)
        let again = try JSONDecoder().decode(
            ThreadRecord.PersonCommand.self, from: try JSONEncoder().encode(stopped))
        #expect(again == stopped && again.stopped)
    }
}
