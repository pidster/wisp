import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The model's thinking shown (ADR 0053): recorded at both edges and kept as the turn's reasoning entry, never composed
/// into a request or recalled for the model, shown in chat folded with `/show` and `/inspect thinking`, carried over
/// `wisp chat --json`, and drawn as an activity. The Ollama stream itself is tested in `OllamaExecutorTests`.
@Suite struct ThinkingTests {
    /// A home in a scratch directory.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-thinking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An agent on a scripted model whose audit is in memory and whose trail links reasoning entries to their events.
    private func agent(_ steps: [ScriptedModel.Step]) -> (agent: Agent, sink: MemoryAuditSink, model: ScriptedModel) {
        let sink = MemoryAuditSink()
        let trail = ToolEventTrail()
        let audit = AuditLog(session: "s", sink: sink).alsoRecording(to: trail)
        let model = ScriptedModel(steps: steps, capabilities: [.toolCalling, .guidedGeneration, .reasoning])
        let agent = Agent(
            instructions: "x", tools: [CurrentDateTool()], model: ResolvedModel(selection: .system, custom: model),
            audit: audit)
        agent.toolEvents = trail
        return (agent, sink, model)
    }

    @Test func aStretchTellsItsObserverWhenItBeginsAndEndsAndCountsEveryToken() {
        let seen = Mutex<[String]>([])
        let observer = ReasoningObserver(
            began: { seen.withLock { $0.append("began") } },
            ended: { text, tokens, seconds in seen.withLock { $0.append("ended \(text) \(tokens) \(seconds)") } })
        var stretch = ThinkingStretch(observer: observer)
        let start = Date(timeIntervalSince1970: 100)
        #expect(!stretch.thinking)
        stretch.end(at: start)  // Nothing under way: nothing told.
        stretch.think("Is", at: start)
        stretch.think(" 91", at: start.addingTimeInterval(1))
        #expect(stretch.thinking && stretch.text == "Is 91")
        stretch.end(at: start.addingTimeInterval(2))
        stretch.end(at: start.addingTimeInterval(3))  // Once only.
        stretch.think("again", tokens: 2, at: start.addingTimeInterval(4))
        stretch.end(at: start.addingTimeInterval(4.5))
        #expect(seen.withLock { $0 } == ["began", "ended Is 91 2 2.0", "began", "ended again 2 0.5"])
        // The request's reasoning tokens are every stretch's.
        #expect(stretch.tokens == 4 && !stretch.thinking)
        // Outside a turn there is no observer, and a stretch tells no one.
        #expect(ReasoningObserver.current == nil)
        var quiet = ThinkingStretch()
        quiet.think("x")
        quiet.end()
        #expect(quiet.tokens == 1)
    }

    @Test func theThinkingIsAuditedKeptAsTheTurnsReasoningAndNeverComposedOrRecalled() async throws {
        let (agent, sink, model) = agent([.think("Is 91 prime? 7 times 13."), .say("No."), .say("ok")])
        let reply = try await agent.stream("Is 91 prime? One word.") { _ in }
        #expect(reply.text == "No.")
        // Two events: the start, and the end with the text and its tokens, before the reply's.
        let thoughts = sink.events.filter { $0.kind == .modelReasoning }
        #expect(thoughts.map { $0.details["phase"] } == ["start", "end"])
        let end = try #require(thoughts.last)
        #expect(end.details["text"] == "Is 91 prime? 7 times 13." && end.details["tokens"] == 6 && end.turn == 1)
        #expect(end.details["bytes"] == .int("Is 91 prime? 7 times 13.".utf8.count))
        #expect(Set(end.details.keys) == AuditEvent.fields(for: .modelReasoning))
        let kinds = sink.events.map(\.kind)
        #expect(
            (kinds.firstIndex(of: .modelReasoning) ?? 99) < (kinds.firstIndex(of: .response) ?? 0), "\(kinds)")
        // The store keeps it as the turn's reasoning, linked to the event that ended it.
        let entry = try #require(agent.store.entries.first { $0.kind == .reasoning })
        #expect(entry.turn == 1 && entry.sources.map(\.event) == [end.id ?? ""])
        #expect(ThreadRecord.text(of: entry.value) == "Is 91 prime? 7 times 13.")
        // No request carries it: not the next, and not the turn's own composition either.
        let next = agent.composition(atTurn: nil) ?? []
        #expect(!next.contains { $0.entry.kind == .reasoning })
        #expect(!agent.transcript.contains { if case .reasoning = $0 { true } else { false } })
        #expect(!(agent.composition(atTurn: 1) ?? []).contains { $0.entry.kind == .reasoning })
        _ = try await agent.respond(to: "and 97?")
        let sent = try #require(model.script.requests.withLock { $0 }.last)
        #expect(!sent.transcript.contains { if case .reasoning = $0 { true } else { false } })
        #expect(!sent.transcript.contains { ThreadRecord.text(of: $0).contains("7 times 13") })
        // Recall does not hand it to the model either.
        let recalled = Recall.material(
            .entry(entry.id), in: MemorySource.Material(store: agent.store, facts: []), read: { _ in nil })
        let lines = recalled.lines.joined(separator: "\n")
        #expect(!lines.contains("7 times 13") && lines.contains("not recalled"), "\(lines)")
        #expect(recalled.header.contains("the model's thinking"))
    }

    @Test func condensingLeavesTheThinkingWhereItIs() {
        var store = ThreadRecord()
        let prompt = Transcript.Entry.prompt(.init(segments: [.text(.init(content: "q"))]))
        let thought = Transcript.Entry.reasoning(.init(segments: [.text(.init(content: "hmm"))]))
        store.record(prompt, origin: .turn, turn: 1, sources: [])
        store.record(thought, origin: .turn, turn: 1, sources: [])
        store.retain(Transcript(entries: []), droppedBy: nil, at: 2)
        #expect(store.entries.map(\.state) == [.dropped(by: nil), .active])
        // A composer with every switch off still leaves it out.
        var composer = ContextComposer()
        composer.cutsPresentation = false
        composer.referencesOutput = false
        #expect(composer.compose(store).isEmpty)
    }

    @Test func chatShowsTheThinkingFoldedAndAgainWithShowAndInspect() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
        let tap = ChatEvents.Tap()
        let thread = try WispThread.setUp(
            session: session, audit: session.audit,
            host: session.host(approver: DenyingApprover(reason: "not in tests")),
            prompting: session.prompting, toolNames: [], model: .system, observer: tap)
        let model = ScriptedModel(
            steps: [.think("one two three four five six"), .say("Done.")],
            capabilities: [.toolCalling, .guidedGeneration, .reasoning])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        let activity = ChatActivity()
        let seen = Mutex<[String]>([])
        activity.onChange { state in seen.withLock { $0.append(state.map { "\($0.doing) \($0.thinking)" } ?? "idle") } }
        var context = ChatLoopTests.context
        context.shownOutputLines = 1
        context.activity = activity
        let entryLine = "/show 3"
        let capture = ChatLoopTests.Capture(lines: [
            "think", entryLine, "/inspect thinking", "/inspect thinking 1", "/inspect thinking 7",
            "/inspect thinking x", "/quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap, context: context,
            io: capture.io)
        try await loop.run()
        // The activity said it was thinking, then went back to waiting for the reply.
        #expect(
            seen.withLock { $0 } == [
                "waiting for the model false", "thinking true", "waiting for the model false", "idle",
            ])
        // A muted line with its time and tokens; the thinking under it, as one line here, which it is.
        let noted = capture.noted
        #expect(noted.contains { $0.hasPrefix("∴ thought for") && $0.hasSuffix(", 6 tokens") }, "\(noted)")
        #expect(noted.contains("    one two three four five six"), "\(noted)")
        // `/show` by entry number prints it whole; `/inspect thinking` shows every stretch, or a turn's.
        let entry = try #require(agent.store.entries.first { $0.kind == .reasoning })
        #expect(entry.id == 3, "\(agent.store.entries.map(\.kind))")
        #expect(capture.output.contains("one two three four five six\n"))
        #expect(capture.output.contains("# The model's thinking\n\n## 3 · turn 1 · thought for"))
        #expect(capture.output.contains("# The model's thinking in turn 1"))
        #expect(
            capture.output.contains("# The model's thinking in turn 7\n\nThe model did not think aloud in that turn."))
        #expect(noted.contains("usage: /inspect thinking [N]"))
        // `/show` with an event-id prefix finds it too.
        let id = try #require(entry.sources.first?.event)
        #expect(ChatEvents.output(String(id.prefix(8)), in: agent.store, last: nil) == "one two three four five six")
        // `/show` alone stays the last tool output, which there is none of.
        #expect(ChatEvents.output(nil, in: agent.store, last: nil) == nil)
    }

    @Test func theEventsReadAsALineAndTheirTextAsFoldedOutput() throws {
        let start = AuditEvent(session: "s", kind: .modelReasoning, details: AuditEvent.Details.reasoningStarted())
        let text = (1...4).map { "step \($0)" }.joined(separator: "\n")
        let end = AuditEvent(
            session: "s", kind: .modelReasoning, turn: 1,
            details: AuditEvent.Details.reasoningEnded(text: text, tokens: 1, seconds: 1.25))
        #expect(ChatEvents.render(start, style: .plain) == nil)
        #expect(ChatEvents.render(end, style: .plain) == "∴ thought for 1.2 s, 1 token")
        #expect(ChatEvents.progress(end) == "∴ thought for 1.2 s, 1 token")
        let shown = try #require(ChatEvents.shownOutput(end, lines: 2, style: .plain))
        #expect(
            shown.hasPrefix("    step 1\n    step 2\n    … 2 more lines")
                && shown.hasSuffix(String(end.id?.prefix(8) ?? "")))
        #expect(ChatEvents.shownOutput(start, lines: 2, style: .plain) == nil)
        // Over `wisp chat --json` the end carries the thinking as `output`, as a tool result does.
        let fields = ChatProtocol.event(end, shownLines: 3)
        #expect(fields["text"] == "∴ thought for 1.2 s, 1 token")
        let output = try #require(fields["output"]?.objectValue)
        #expect(output["text"] == .string(text) && output["lines"] == 4 && output["shownLines"] == 3)
        #expect(ChatProtocol.event(start)["output"] == nil)
        #expect(end.summary.contains("model.reasoning") && end.summary.contains("end tokens=1 step 1"))
    }

    @Test func theActivitySaysThinkingWhileItThinksAndTheProtocolFlagsIt() throws {
        let activity = ChatActivity()
        let start = Date()
        activity.begin(at: start)
        let think = AuditEvent(session: "s", kind: .modelReasoning, details: AuditEvent.Details.reasoningStarted())
        activity.apply(think, at: start.addingTimeInterval(1))
        let thinking = try #require(activity.current)
        #expect(thinking.doing == "thinking" && thinking.thinking && !thinking.asking)
        #expect(ChatActivity.line(thinking, now: start.addingTimeInterval(4)) == "4 s · thinking (3 s)")
        #expect(ChatProtocol.activity(thinking)["thinking"] == true)
        let ended = AuditEvent(
            session: "s", kind: .modelReasoning,
            details: AuditEvent.Details.reasoningEnded(text: "x", tokens: 1, seconds: 1))
        activity.apply(ended)
        let after = try #require(activity.current)
        #expect(after.doing == "waiting for the model" && !after.thinking)
        #expect(ChatProtocol.activity(after)["thinking"] == nil)
        // A tool call after thinking clears the flag too.
        activity.apply(think)
        activity.apply(AuditEvent(session: "s", kind: .toolCall, details: ["tool": "current_date", "arguments": "{}"]))
        #expect(activity.current?.thinking == false)
    }

    @Test func theThinkSettingAcceptsWhatOllamaAcceptsAndReachesConfig() throws {
        #expect(OllamaThink("true") == .on && OllamaThink("FALSE") == .off && OllamaThink("max") == .level("max"))
        #expect(OllamaThink("extreme") == nil)
        #expect(OllamaThink.choices == ["true", "false", "low", "medium", "high", "max"])
        let decoded = try JSONDecoder().decode(
            [OllamaThink].self, from: Data(#"[true, false, "low", "true", "high"]"#.utf8))
        #expect(decoded == [.on, .off, .level("low"), .on, .level("high")])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([OllamaThink].self, from: Data(#"["x"]"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([OllamaThink].self, from: Data("[1]".utf8)) }
        #expect(
            String(decoding: try JSONEncoder().encode([OllamaThink.on, .level("low")]), as: UTF8.self)
                == #"[true,"low"]"#)
        // `/config set` writes it; the file loads with it; an unknown value is refused.
        let outcome = try ConfigEdit.set("ollama.think", to: "low", in: nil)
        let config = try JSONDecoder().decode(Config.self, from: outcome.data)
        #expect(config.resolved.ollama.think == .level("low"))
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"ollama":{"think":false}}"#.utf8))
        #expect(off.resolved.ollama.think == .off)
        #expect(Config().resolved.ollama.think == nil)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("ollama.think", to: "extreme", in: nil) }
        #expect(ConfigSettings.defaultValue("ollama.think") == "the model's default")
    }
}
