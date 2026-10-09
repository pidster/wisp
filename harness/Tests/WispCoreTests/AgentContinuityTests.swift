import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// What an agent keeps of its own conversation, apart from the side calls it makes and across the agents that take its
/// store over: the conversation's token figure, the reasoning its turns recorded, its name among the proposals and its
/// counters after `/new` and `/model`, the instructions `/new` starts from, the facts each distillation reads, and how
/// a command the person typed ranks against a later run.
@Suite struct AgentContinuityTests {
    /// A prompt long enough to pass the budget of a 60-token window.
    static let long = FactDistillationTests.long

    @Test func condensingAheadUsesTheConversationsFigureNotASideCallsReport() async throws {
        let model = ScriptedModel(steps: [.say("a"), .say("b"), .say("c")])
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model, contextSize: 8192),
            contextPolicy: .condense(keepTurns: 1))
        _ = try await agent.respond(to: "one")
        _ = try await agent.respond(to: "two")
        #expect(agent.lastInputTokens == 40)
        // An assessment, a distiller, or a summary asks the same model with a far larger request of its own.
        model.script.lastInputTokens.withLock { $0 = 8000 }
        let tokens = try await agent.contextTokens()
        #expect(agent.lastInputTokens == 40 && tokens == 40)
        // The conversation itself holds 40 tokens: nothing to condense, though the shared figure passes the budget.
        let reply = try await agent.respond(to: "three")
        #expect(!reply.condensed && agent.condensations == 0)
        // /new forgets the old conversation's figure.
        agent.reset()
        #expect(agent.lastInputTokens == 0)
    }

    @Test func aDistillersThinkingDuringOverflowRecoveryIsNotTheTurns() async throws {
        let model = ScriptedModel(
            steps: [
                .say("Noted."), .say("Understood."),
                .think("the distiller weighs the turn"), .say(#"{"facts":[]}"#),
                .think("the turn thinks"), .say("It is done."),
            ], capabilities: [.toolCalling, .guidedGeneration, .reasoning])
        let sink = MemoryAuditSink()
        let trail = ToolEventTrail()
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 100_000),
            contextPolicy: .condense(keepTurns: 1), audit: AuditLog(session: "s", sink: sink).alsoRecording(to: trail))
        agent.toolEvents = trail
        agent.facts = FactSettings()
        _ = try await agent.respond(to: "one")
        _ = try await agent.respond(to: "two")
        // The third request overflows; recovery distils the dropped turn, then retries.
        model.script.overflows.withLock { $0 = 1 }
        let reply = try await agent.respond(to: "three")
        #expect(reply.text == "It is done." && reply.condensed)
        #expect(sink.events.contains { $0.kind == .distillation })
        // Only the turn's own thinking was recorded, and its entry links to that event.
        let ended = sink.events.filter { $0.kind == .modelReasoning && $0.details["phase"] == "end" }
        #expect(ended.map { $0.details["text"] } == ["the turn thinks"], "\(ended.map(\.details))")
        let entry = try #require(agent.store.entries.last { $0.kind == .reasoning })
        #expect(ThreadRecord.text(of: entry.value) == "the turn thinks")
        #expect(entry.sources.map(\.event) == [ended.last?.id ?? ""])
    }

    @Test func reasoningEntriesLinkToTheLatestStretchesAsToolCallsDo() {
        func ended(_ id: String, _ text: String) -> AuditEvent {
            var event = AuditEvent(
                session: "s", kind: .modelReasoning, turn: 1, details: ["phase": "end", "text": .string(text)])
            event.id = id
            return event
        }
        let thought = Transcript.Entry.reasoning(.init(segments: [.text(.init(content: "kept"))]))
        let response = Transcript.Entry.response(.init(assetIDs: [], segments: [.text(.init(content: "ok"))]))
        // A failed attempt thought first; the retry's session holds only the second stretch.
        let sources = ThreadRecord.sources(
            for: [thought, response], prompt: nil, response: nil,
            toolEvents: [ended("e1", "discarded"), ended("e2", "kept")])
        #expect(sources[0].map(\.event) == ["e2"])
    }

    /// A chat thread of a scratch session, with the person's facts and every tool `run_command` needs.
    private func thread(
        _ home: Home, tools: [String] = ["run_command"]
    ) throws -> (session: Session, thread: WispThread) {
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing())
        let thread = try WispThread.setUp(
            session: session, audit: session.audit,
            host: session.host(approver: DenyingApprover(reason: "not in tests")),
            prompting: session.prompting, toolNames: tools, model: .system)
        return (session, thread)
    }

    /// A scratch home.
    private func home() throws -> Home {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-continuity-\(UUID())"))
        try home.ensure()
        try Data(OfflineBackends.file().utf8).write(to: home.configFile)
        return home
    }

    @Test func modelAfterNewKeepsTheConversationsNameAndCounters() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let (session, thread) = try thread(home)
        defer { session.end() }
        let model = ScriptedModel(steps: [.say("a"), .say("b")])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        _ = try await agent.respond(to: "one")
        agent.reset()
        let renamed = agent.threadID
        #expect(renamed.hasSuffix(".1"))
        agent.condensations = 3
        agent.assessed.previous = ["run_command"]
        // `/model` opens an agent on the store; it goes on as the same conversation.
        let next = try thread.openAgent(
            on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("c")])), store: agent.store)
        #expect(next.threadID == renamed)
        #expect(next.condensations == 3 && next.assessed.previous == ["run_command"])
        // Another /new on it counts on from there.
        next.reset()
        #expect(next.threadID.hasSuffix(".2"))
    }

    @Test func newStartsFromTheInstructionsAsCreatedNotTheLastRequestsNarrowedOnes() async throws {
        let model = ScriptedModel(steps: [
            .call(name: "current_date", arguments: #"{"timeZone":"Asia/Tokyo"}"#), .say("It is {tool}"), .say("hi"),
        ])
        let sink = MemoryAuditSink()
        let agent = AssessmentTests.agent(model, sink: sink)
        _ = try await agent.respond(to: "What is the date today?")
        // The request registered three of the five tools.
        let first = try #require(model.script.requests.withLock { $0 }.first)
        #expect(first.enabledToolDefinitions.count == 3)
        agent.reset()
        guard case .instructions(let instructions)? = agent.store.entries.first?.value else {
            Issue.record("the new store starts with the instructions")
            return
        }
        // Every tool's definition, and no catalogue: the composer adds that to each request.
        #expect(instructions.toolDefinitions.map(\.name).sorted() == AssessmentTests.names.sorted())
        #expect(!ContextArchive.text(instructions.segments).contains(ToolCatalogue.header))
        #expect(agent.store.entries.count == 1)
        // The next request is composed from it as any first request is.
        _ = try await agent.respond(to: "hello there")
        let next = try #require(model.script.requests.withLock { $0 }.last)
        #expect(AssessmentTests.instructions(next.transcript).components(separatedBy: ToolCatalogue.header).count == 2)
    }

    @Test func aDistillationReadsOnlyTheTurnsLeavingNowSoAnOlderValueIsNotReasserted() async throws {
        let older = #"{"facts":[{"subject":"entity","name":"codename","value":"BLUE HERON","speaker":"person"}]}"#
        let newer = #"{"facts":[{"subject":"entity","name":"codename","value":"GREY HERON","speaker":"person"}]}"#
        let model = ScriptedModel(steps: [
            .say("Noted."), .say("Understood."),
            .say(older), .say("Three."),
            .say(newer), .say("The person named the codename twice."), .say("Four."),
        ])
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "You are wisp.", tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 60),
            contextPolicy: .condense(keepTurns: 1), audit: AuditLog(session: "s", sink: sink))
        agent.facts = FactSettings(summaryWithFacts: true)
        agent.summaryBatchTurns = 2
        _ = try await agent.respond(to: "The codename is BLUE HERON.")
        _ = try await agent.respond(to: "No, the codename is GREY HERON now.")
        // The third drops the first turn and distils it; the fourth drops the second, and the batch of two is due.
        _ = try await agent.respond(to: "three" + Self.long)
        _ = try await agent.respond(to: "four" + Self.long)
        // The second condensation's batch holds the first turn, distilled already: the facts' call reads the second
        // turn only, and the summary has a call of its own.
        let requests = model.script.requests.withLock { $0 }
        let prompts = requests.map { ThreadRecord.text(of: Array($0.transcript).last ?? .prompt(.init(segments: []))) }
        let distilling = prompts.filter { $0.hasPrefix("Subjects:") }
        try #require(distilling.count == 2, "\(prompts)")
        #expect(distilling[1].contains("Turn 2, the person: No, the codename") && !distilling[1].contains("Turn 1,"))
        #expect(agent.store.summary?.turns == [1, 2])
        let codename = agent.store.facts.current.filter { $0.identity.name == "codename" }
        #expect(codename.map(\.value) == ["GREY HERON"], "\(codename.map(\.value))")
    }

    @Test func aCondensationClaimsADistillationOnlyWhenOneSucceeded() async throws {
        // A model that cannot answer in a schema: every distillation fails.
        let model = ScriptedModel(steps: [], capabilities: [.toolCalling], reportsUsage: false)
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(
                selection: .system, custom: model, contextSize: 400,
                countTokens: { ContextComposer.bytes(of: $0) / ContextComposer.bytesPerToken }),
            contextPolicy: .target(.default), audit: AuditLog(session: "s", sink: sink))
        agent.facts = FactSettings()
        let words = String(repeating: "the harbour sync plan has more steps ", count: 8)
        for turn in 1...6 { _ = try await agent.respond(to: "Turn \(turn): \(words)") }
        let condensations = sink.events.filter { $0.kind == .condensation }
        let steps = condensations.flatMap { $0.details["steps"]?.arrayValue ?? [] }.compactMap(\.stringValue)
        #expect(steps.contains { $0.hasPrefix("dropped") }, "\(steps)")
        #expect(!steps.contains { $0.hasPrefix("distilled") }, "\(steps)")
        #expect(sink.events.contains { $0.kind == .distillation && $0.details["failure"] != nil })
    }

    @Test func aTypedCommandsObservationGivesWayToALaterRun() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-continuity-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appending(path: "flag"))
        let (session, thread) = try thread(home)
        defer { session.end() }
        let arguments = #"{"command":"test -e flag","workingDirectory":"\#(dir.path)"}"#
        let model = ScriptedModel(steps: [.call(name: "run_command", arguments: arguments), .say("It failed.")])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        var settings = try #require(agent.facts)
        settings.kinds = SubjectKinds(kinds: settings.kinds.kinds, testCommands: ["test"])
        agent.facts = settings
        // The person's run passes.
        let typed = await agent.runTyped("test -e flag", in: dir.path)
        let passed = try #require(typed.facts.first { $0.identity.subject == "tests" })
        #expect(passed.value == "passed (exit status 0)" && passed.source == .tool)
        // The model's later run of the same command fails, and is what the conversation now holds.
        try FileManager.default.removeItem(at: dir.appending(path: "flag"))
        _ = try await agent.respond(to: "Run the check again.")
        let group = try #require(agent.factView.group(passed.identity.key))
        #expect(group.winner.value == "failed (exit status 1)", "\(group)")
        #expect(agent.fact(passed.id)?.state == .superseded)
    }
}
