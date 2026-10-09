import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The assessment per request (phase 4d of the layered-context proposal, decision D12), driven through the agent
/// over a scripted model: rules decide without a call; the model call's answer is applied (tools registered, task
/// updated, facts repeated); a failed call falls back; an explicit tool list is never widened; the person's task is
/// never replaced; a tool the model calls but the request did not register is added by one retry; and the
/// assessment never enters the context. `AssessmentRulesTests` tests the pure parts.
@Suite struct AssessmentTests {
    /// The tools most tests offer, in the registry's order.
    static let names = ["current_date", "run_command", "read_file", "system_info", "memory"]

    /// An agent over `model` with the named built-in tools, recording to `sink`.
    static func agent(
        _ model: ScriptedModel, sink: MemoryAuditSink, tools names: [String] = names,
        settings: AssessmentSettings? = AssessmentSettings(infersTask: false), facts: Bool = false
    ) -> Agent {
        let audit = AuditLog(session: "assess", sink: sink)
        let tools = ToolRegistry(audit: audit).select(names).tools
        let agent = Agent(
            instructions: "You are wisp.", tools: tools, model: ResolvedModel(selection: .system, custom: model),
            audit: audit)
        if facts { agent.facts = FactSettings() }
        agent.assessment = settings
        return agent
    }

    /// The requests the model received.
    static func requests(_ model: ScriptedModel) -> [LanguageModelExecutorGenerationRequest] {
        model.script.requests.withLock { $0 }
    }

    /// The text of the instructions entry of `transcript`.
    static func instructions(_ transcript: Transcript) -> String {
        guard case .instructions(let instructions)? = Array(transcript).first else { return "" }
        return ContextArchive.text(instructions.segments)
    }

    /// The text of the now block of `transcript`, or empty.
    static func now(_ transcript: Transcript) -> String {
        Array(transcript).last { FactFrame.isFrame($0) && $0.id.contains(".now.") }.map(ThreadRecord.text(of:)) ?? ""
    }

    /// The `context.assessment` events.
    static func assessments(_ sink: MemoryAuditSink) -> [AuditEvent] { sink.events.filter { $0.kind == .assessment } }

    @Test func rulesDecideWithoutACallAndTheRequestRegistersOnlyItsTools() async throws {
        let model = ScriptedModel(steps: [
            .call(name: "current_date", arguments: #"{"timeZone":"Asia/Tokyo"}"#), .say("It is {tool}"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        let reply = try await agent.respond(to: "What is the date today?")
        #expect(reply.text.hasPrefix("It is"))
        let requests = Self.requests(model)
        #expect(requests.count == 2 && requests.allSatisfy { $0.schema == nil }, "no assessment call")
        #expect(requests[0].enabledToolDefinitions.map(\.name) == ["current_date", "run_command", "memory"])
        // The instructions carry the catalogue of every allowed tool, and only the registered definitions.
        let instructions = Self.instructions(requests[0].transcript)
        #expect(instructions.hasPrefix("You are wisp.") && instructions.contains(ToolCatalogue.header))
        #expect(instructions.contains("- read_file: read a text file, a page at a time"))
        #expect(
            Self.now(requests[0].transcript).hasSuffix("Tools for this request: current_date, run_command, memory."))
        let events = Self.assessments(sink)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .assessment)))
        #expect(event.details["method"] == "rules" && event.details["taskChanged"] == false)
        #expect(event.details["registered"] == .array(["current_date", "run_command", "memory"]))
        #expect(event.details["bytes"] == 0 && event.details["model"] == nil)
        // In the audit after the prompt and before the response.
        let kinds = sink.events.map(\.kind)
        #expect(
            (kinds.firstIndex(of: .prompt) ?? 99) < (kinds.firstIndex(of: .assessment) ?? 0)
                && (kinds.firstIndex(of: .assessment) ?? 99) < (kinds.firstIndex(of: .response) ?? 0))
    }

    /// The model's answer in the next test: it names a tool the conversation does not have, and a fact that does not
    /// exist, beside ones that do.
    static func answer(fact: String) -> String {
        #"{"intent":"start the dry-run work","tools":["read_file","notify"],"#
            + #""task":"add a --dry-run flag to harbour sync","objective":"sync prints the plan and copies nothing","#
            + #""facts":["\#(fact)","c99"]}"#
    }

    @Test func theModelsAnswerRegistersToolsUpdatesTheTaskAndRepeatsFacts() async throws {
        let model = ScriptedModel(steps: [.say("placeholder"), .say("On it.")])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink, settings: AssessmentSettings(), facts: true)
        let codename = try agent.stateFact(subject: "entity", name: "release codename", value: "BLUE HERON")
        model.script.steps.withLock { $0[0] = .say(Self.answer(fact: codename.id)) }
        let reply = try await agent.respond(
            to: "Let us add a dry-run flag to harbour sync and keep the codename in mind for its notes")
        #expect(reply.text == "On it.")
        let requests = Self.requests(model)
        #expect(requests.count == 2)
        // The assessment: its own session, the schema, greedy and bounded; shown identities, not values.
        let asked = requests[0]
        #expect(asked.schema != nil && asked.generationOptions.maximumResponseTokens == Assessor.maximumResponseTokens)
        #expect(Self.instructions(asked.transcript) == Assessor.instructions)
        let prompt = ThreadRecord.text(of: try #require(Array(asked.transcript).last))
        #expect(prompt.contains(ToolCatalogue.header) && prompt.contains("- \(codename.id) entity release codename"))
        #expect(!prompt.contains("BLUE HERON"), "fact values are not shown to the assessment")
        // Applied: the tools (only allowed ones), the task as the model's, the facts repeated.
        let request = requests[1]
        #expect(request.enabledToolDefinitions.map(\.name) == ["run_command", "read_file", "memory"])
        let task = try #require(agent.taskHistory.last)
        #expect(task.source == .model && task.method == .inferred && task.turn == 1)
        #expect(
            task.value == "add a --dry-run flag to harbour sync; objective: sync prints the plan and copies nothing")
        #expect(reply.facts.map(\.id) == [task.id], "the inferred task is listed with the turn's new facts")
        let now = Self.now(request.transcript)
        #expect(
            now.contains(
                "- task: add a --dry-run flag to harbour sync; objective: sync prints the plan and copies nothing "
                    + "— from model, inferred, turn 1"))
        #expect(now.contains("Relevant to this request:\n- entity release codename: BLUE HERON — from the person"))
        #expect(now.hasSuffix("Tools for this request: run_command, read_file, memory."))
        // Order by stability: the instructions and catalogue first, the now block just before the request.
        let entries = Array(request.transcript)
        #expect(entries.count >= 3 && FactFrame.isFrame(entries[entries.count - 2]))
        let event = try #require(Self.assessments(sink).first)
        #expect(event.details["method"] == "model" && event.details["taskChanged"] == true)
        #expect(event.details["task"] == .string(task.id) && event.details["intent"] == "start the dry-run work")
        #expect(event.details["facts"] == .array([.string(codename.id)]))
        #expect(event.details["tools"] == .array(["run_command", "read_file", "memory"]))
        #expect(event.details["ruleTools"] == .array(["run_command", "memory"]))
        #expect((event.details["bytes"]?.intValue ?? 0) > 0 && event.details["model"] == "system")
    }

    @Test func theAssessmentNeverEntersTheContextAndItsFindingsStayOnThePromptSide() async throws {
        let model = ScriptedModel(steps: [.say("placeholder"), .say("On it."), .say("Still on it.")])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink, settings: AssessmentSettings(), facts: true)
        let codename = try agent.stateFact(subject: "entity", name: "release codename", value: "BLUE HERON")
        model.script.steps.withLock { $0[0] = .say(Self.answer(fact: codename.id)) }
        _ = try await agent.respond(to: "Let us add a dry-run flag to harbour sync and keep the codename in mind")
        _ = try await agent.respond(to: "And then?")
        for transcript in [agent.transcript, Self.requests(model)[2].transcript] {
            let text = Array(transcript).map(ThreadRecord.text(of:)).joined(separator: "\n")
            #expect(!text.contains("start the dry-run work"), "the intent is audited, never sent")
            #expect(!text.contains("You plan one request"), "the assessment's instructions are not in it")
            #expect(!text.contains("\"tools\""), "nor its answer")
            // Authority by position: the task and the repeated facts are in a prompt-side record, not the instructions.
            let instructions = Self.instructions(transcript)
            #expect(!instructions.contains("harbour sync") && !instructions.contains("BLUE HERON"))
            #expect(instructions.contains(ToolCatalogue.header))
        }
        // The store keeps only the conversation's own entries.
        #expect(agent.store.entries.filter { $0.kind == .prompt }.count == 2)
    }

    @Test func aFailedCallFallsBackToEveryToolAndNeverFailsTheTurn() async throws {
        // A model that cannot follow a schema, then an answer that does not parse.
        for (model, failure) in [
            (ScriptedModel(steps: [.say("Hello.")], capabilities: [.toolCalling]), "guided"),
            (ScriptedModel(steps: [.say("not json at all"), .say("Hello.")]), "json"),
        ] {
            let sink = MemoryAuditSink()
            let agent = Self.agent(model, sink: sink, settings: AssessmentSettings(), facts: true)
            let reply = try await agent.respond(to: "Let us work out why the harbour build broke last night")
            #expect(reply.text == "Hello.")
            let last = try #require(Self.requests(model).last)
            #expect(last.enabledToolDefinitions.map(\.name) == Self.names, "every allowed tool")
            #expect(agent.taskHistory.isEmpty, "the task unchanged")
            let event = try #require(Self.assessments(sink).first)
            #expect(event.details["method"] == "fallback" && event.details["taskChanged"] == false)
            #expect(event.details["failure"]?.stringValue?.lowercased().contains(failure) == true, "\(event.details)")
        }
    }

    @Test func anExplicitToolListIsNeverWidened() async throws {
        let model = ScriptedModel(steps: [
            .say(
                #"{"intent":"x","tools":["read_file","system_info","current_date"],"task":"","objective":"","facts":[]}"#
            ),
            .say("ok"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink, tools: ["current_date", "run_command"])
        _ = try await agent.respond(to: "Work out why the harbour build broke last night and report back")
        let requests = Self.requests(model)
        #expect(requests[1].enabledToolDefinitions.map(\.name) == ["current_date", "run_command"])
        // MCP's git thread: nothing to choose, so the rules settle it and no call is made.
        let git = ScriptedModel(steps: [.say("ok")])
        let gitAgent = Self.agent(git, sink: MemoryAuditSink(), tools: ["run_command"])
        _ = try await gitAgent.respond(to: "Use run_command to run exactly `git status`")
        #expect(
            Self.requests(git).count == 1 && Self.requests(git)[0].enabledToolDefinitions.map(\.name) == ["run_command"]
        )
    }

    @Test func thePersonsTaskIsNeverReplaced() async throws {
        let model = ScriptedModel(steps: [
            .say(#"{"intent":"x","tools":[],"task":"something else entirely","objective":"","facts":[]}"#),
            .say("ok"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink, settings: AssessmentSettings(), facts: true)
        let pinned = try agent.setTask("fix the CI build")
        _ = try await agent.respond(to: "Work out why the harbour build broke last night and report back")
        #expect(
            agent.taskHistory.map(\.id) == [pinned.id] && agent.factView.group(Agent.taskKey)?.winner.id == pinned.id)
        // Pinned, the task needs no inference: the call happened only because the tools were not settled, and was
        // told the task is fixed.
        let prompt = ThreadRecord.text(of: try #require(Array(Self.requests(model)[0].transcript).last))
        #expect(prompt.contains("The task: fix the CI build (fixed; leave task and objective empty)"))
        #expect(Self.assessments(sink).first?.details["taskChanged"] == false)
        #expect(agent.recordTask("another", method: .inferred) == nil)
    }

    @Test func underRestatedTheTaskChangesOnlyOnARequestThatStatesOne() async throws {
        let answer = { (task: String) in
            #"{"intent":"x","tools":[],"task":"\#(task)","objective":"","facts":[]}"#
        }
        let model = ScriptedModel(steps: [
            .say(answer("add a dry-run flag")), .say("ok"), .say("Blue Heron."),
            .say(answer("fix the CI build")), .say("ok"),
        ])
        let sink = MemoryAuditSink()
        let agent = Self.agent(
            model, sink: sink, settings: AssessmentSettings(tools: .all, taskChanges: .restated), facts: true)
        _ = try await agent.respond(to: "Today's task: add a dry-run flag to harbour sync for the next release.")
        _ = try await agent.respond(to: "What is the codename for this release, as we agreed before?")
        _ = try await agent.respond(to: "Change of plan. Let's switch to fixing the CI build before anything else.")
        #expect(agent.taskHistory.map(\.value) == ["add a dry-run flag", "fix the CI build"])
        let events = Self.assessments(sink)
        #expect(events.map { $0.details["method"] } == ["model", "rules", "model"])
        #expect(events.map { $0.details["taskChanged"] } == [true, false, true])
        // The question took no assessment call: three requests for the replies, two for the assessments.
        #expect(Self.requests(model).count == 5)
    }

    @Test func aToolTheRequestDidNotRegisterIsAddedByOneRetry() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wisp-assess-\(UUID().uuidString).txt")
        try "the notes\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let read = ScriptedModel.Step.call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#)
        let model = ScriptedModel(steps: [read, read, .say("It says {tool}")])
        let sink = MemoryAuditSink()
        let agent = Self.agent(model, sink: sink)
        let reply = try await agent.respond(to: "What is the date today?")
        #expect(reply.text.contains("the notes"))
        let requests = Self.requests(model)
        #expect(requests.count == 3)
        #expect(requests[0].enabledToolDefinitions.map(\.name) == ["current_date", "run_command", "memory"])
        #expect(requests[1].enabledToolDefinitions.map(\.name) == Self.names, "retried with every allowed tool")
        let events = Self.assessments(sink)
        #expect(events.map { $0.details["method"]?.stringValue } == ["rules", "retry"])
        #expect(events[1].details["registered"] == "all" && events[1].details["failure"] != nil)
        // The retried request is the turn's: one prompt stored, and the tool used is kept for a follow-up.
        #expect(agent.store.entries.filter { $0.kind == .prompt }.count == 1)
        #expect(agent.assessed.previous == ["read_file"])
        // An unrelated failure is not retried.
        #expect(!Agent.unregisteredTool(in: LanguageModelError.timeout(.init(debugDescription: "slow"))))
    }

    @Test func theTaskToolSetGrowsWithinTheTaskWhereThePerRequestSetDoesNot() async throws {
        for (sets, expected) in [
            (AssessmentSettings.ToolSets.request, ["current_date", "run_command", "read_file", "memory"]),
            (.task, ["current_date", "run_command", "read_file", "system_info", "memory"]),
            (.all, Self.names),
        ] {
            let model = ScriptedModel(steps: [
                .call(name: "current_date", arguments: #"{"timeZone":"UTC"}"#), .say("ok"), .say("ok"),
            ])
            let agent = Self.agent(
                model, sink: MemoryAuditSink(), settings: AssessmentSettings(tools: sets, infersTask: false))
            _ = try await agent.respond(to: "What is the date, and how much memory is in use?")
            _ = try await agent.respond(to: "Read notes.md for me please")
            #expect(Self.requests(model).last?.enabledToolDefinitions.map(\.name) == expected, "\(sets)")
            let instructions = Self.instructions(agent.transcript)
            #expect(instructions.contains(ToolCatalogue.header) == (sets != .all), "no catalogue without a selection")
        }
    }

    @Test func offByDefaultAndSwitchedOnByConfig() throws {
        #expect(Config().resolved.assessmentEnabled == false && Config().resolved.assessmentTools == .request)
        let config = try JSONDecoder().decode(
            Config.self, from: Data(#"{"assessment":{"enabled":true,"tools":"task"}}"#.utf8))
        #expect(config.resolved.assessmentEnabled && config.resolved.assessmentTools == .task)
        #expect(ConfigSettings.setting("assessment.enabled")?.kind == .flag)
        #expect(ConfigSettings.defaultValue("assessment.tools") == "request")
        #expect(ConfigSettings.defaultValue("assessment.taskChanges") == "restated")
        #expect(Config().resolved.assessmentTaskChanges == .restated)
        let any = try JSONDecoder().decode(
            Config.self, from: Data(#"{"assessment":{"enabled":true,"taskChanges":"any"}}"#.utf8))
        #expect(any.resolved.assessmentTaskChanges == .any)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Config.self, from: Data(#"{"assessment":{"tools":"some"}}"#.utf8))
        }
        // An agent made directly assesses nothing and composes as before.
        let agent = Agent(
            instructions: "be brief", tools: [CurrentDateTool()],
            model: ResolvedModel(selection: .system, custom: ScriptedModel()))
        #expect(agent.assessment == nil && Self.instructions(agent.transcript) == "be brief")
    }

    @Test func aThreadAssessesWhenTheConfigSaysAndInfersTheTaskOnlyInChat() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-assess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        try Data(#"{"assessment":{"enabled":true}}"#.utf8).write(to: home.configFile)
        for (entry, infers) in [(EntryPoint.mcp, false), (.chat, true)] {
            let session = try Session.begin(
                .init(entryPoint: entry), home: home, dependencies: .testing(sink: MemoryAuditSink()))
            let thread = try session.thread(id: "t", approver: DenyingApprover(reason: "not in tests"))
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: ScriptedModel()))
            #expect(agent.assessment == AssessmentSettings(tools: .request, infersTask: infers))
        }
    }
}
