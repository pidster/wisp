import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Thinking chosen per model and per call (ADR 0053, amended 2026-10-11): `<runtime>.models.<name>.think` ahead of the
/// runtime's `think`; wisp's own calls that gain nothing from thinking ask a model that can think not to; a
/// conversation's choice (`respond`'s `think`) asks its turns; a model that cannot think is sent nothing.
@Suite struct ThinkSettingsTests {
    /// The configuration `json` decodes to.
    private func config(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func aModelsOwnThinkComesAheadOfTheRuntimes() throws {
        let ollama = try config(
            #"{"ollama":{"think":true,"models":{"granite4.2:8b":{"think":false},"q":{"think":"high"}}}}"#
        )
        .resolved.ollama
        #expect(ollama.configuredThink(for: "granite4.2:8b") == .off)
        #expect(ollama.configuredThink(for: "gemma4:12b") == .on, "the runtime's for every other model")
        // A name with or without its `:latest` tag finds the model's own.
        #expect(ollama.configuredThink(for: "q:latest") == .level("high"))
        #expect(
            try config(#"{"ollama":{"models":{"q":{"think":false}}}}"#).resolved.ollama.configuredThink(for: "z") == nil
        )
        let mlx = try config(#"{"mlx":{"think":true,"models":{"Qwen3-1.7B-4bit":{"think":false}}}}"#).resolved
        #expect(mlx.mlxModelThinks == ["Qwen3-1.7B-4bit": false] && mlx.mlxThink == true)
        // Setting only its thinking declares nothing: the model stays undeclared, as a window alone leaves it.
        #expect(mlx.mlxModels["Qwen3-1.7B-4bit"] == nil)
        let llama = try config(#"{"llamacpp":{"models":{"Qwen3-8B":{"think":false}}}}"#).resolved.llamacpp
        #expect(llama.declared["Qwen3-8B"]?.think == false && llama.declared["Qwen3-8B"]?.capabilities == nil)
    }

    @Test func aModelsThinkIsValidatedAsTheRuntimesIs() throws {
        #expect(throws: DecodingError.self) { try config(#"{"ollama":{"models":{"q":{"think":"extreme"}}}}"#) }
        #expect(throws: DecodingError.self) { try config(#"{"mlx":{"models":{"m":{"think":"high"}}}}"#) }
        // LM Studio sets thinking per model in the app, so a model's `think` there is refused at load.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-think-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(#"{"lmstudio":{"models":{"qwen/qwen3-8b":{"think":false}}}}"#.utf8).write(to: file)
        #expect(throws: DecodingError.self) { try Config.load(from: file) }
    }

    @Test func wispConfigSetsListsAndDefaultsAModelsThink() throws {
        let set = try ConfigEdit.set("ollama.models.granite4.2:8b.think", to: "false", in: nil)
        #expect(set.path == "ollama.models.granite4.2:8b.think")
        let written = try JSONDecoder().decode(Config.self, from: set.data)
        #expect(written.resolved.ollama.configuredThink(for: "granite4.2:8b") == .off)
        #expect(throws: ConfigEdit.Failure.self) {
            try ConfigEdit.set("ollama.models.granite4.2:8b.think", to: "extreme", in: nil)
        }
        let mlx = try ConfigEdit.set("mlx.models.Qwen3-1.7B-4bit.think", to: "off", in: set.data)
        #expect(try ConfigEdit.current(keys: ["mlx", "models", "Qwen3-1.7B-4bit", "think"], in: mlx.data) == false)
        let llama = try ConfigEdit.set("llamacpp.models.Qwen3-8B.think", to: "true", in: mlx.data)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("lmstudio.models.x.think", to: "true", in: nil) }
        // Listed beside the fixed settings, and each falls back to its runtime's.
        let listed = ConfigSettings.listed(in: llama.data).map(\.path)
        #expect(
            listed.contains("ollama.models.granite4.2:8b.think") && listed.contains("mlx.models.Qwen3-1.7B-4bit.think"))
        #expect(listed.contains("llamacpp.models.Qwen3-8B.think"))
        #expect(ConfigSettings.defaultValue("ollama.models.q.think") == ConfigSettings.defaultValue("ollama.think"))
        #expect(ConfigSettings.setting("ollama.models.q.think")?.kind == .choice(OllamaThink.choices))
        #expect(ConfigSettings.setting("mlx.models.m.think")?.kind == .flag)
        // A window and thinking for one model are two settings of it.
        let both = try ConfigEdit.set("ollama.models.granite4.2:8b.contextLength", to: "16384", in: set.data)
        let decoded = try JSONDecoder().decode(Config.self, from: both.data).resolved.ollama
        #expect(decoded.modelContextLengths["granite4.2:8b"] == 16384 && decoded.modelThinks["granite4.2:8b"] == .off)
    }

    @Test func theListingShowsAModelsThinkingDefault() {
        var entry = ModelListing.Entry(selection: .ollama("granite4.2:8b"), capabilities: ["toolCalling", "reasoning"])
        #expect(entry.plainCapabilities == ["tools", "thinking"])
        entry.think = "false"
        #expect(entry.plainCapabilities == ["tools", "thinking (false)"])
    }

    @Test func aCallerMayAskALevelOnlyOfARuntimeThatTakesLevels() throws {
        let scripted = ResolvedModel(selection: .system, custom: ScriptedModel())
        #expect(scripted.thinkSent(.off) == nil, "a model with no thinking switch is sent nothing")
        try scripted.checkThink(.off)
        try scripted.checkThink(.on)
        #expect(throws: ModelSelection.Failure.self) { try scripted.checkThink(.level("high")) }
        let ollama = ResolvedModel(
            selection: .ollama("q"), custom: OllamaModel(name: "q", reported: ["completion", "thinking"]))
        try ollama.checkThink(.level("high"))
        #expect(ollama.thinkLevels == OllamaThink.levels)
        #expect(ollama.thinkSent(nil) == nil && ollama.thinkSent(.off) == .off)
        let silent = ResolvedModel(selection: .ollama("q"), custom: OllamaModel(name: "q", reported: ["completion"]))
        #expect(silent.thinkSent(.off) == nil, "a model that cannot think is sent nothing")
    }
}

/// wisp's own calls ask a model that can think not to; the conversation's turns ask what it chose, else nothing.
@Suite struct SideCallThinkingTests {
    @Test func theDistillerAsksForNoThinkingAndTheTurnsForNothing() async throws {
        let model = ScriptedModel(steps: [
            .say("Noted."), .say("Understood."), .say(FactDistillationTests.answer), .say("It is BLUE HERON."),
        ])
        let sink = MemoryAuditSink()
        let agent = FactDistillationTests.agent(model, sink: sink)
        _ = try await agent.respond(to: "The codename is BLUE HERON." + FactDistillationTests.long)
        _ = try await agent.respond(to: "By the way, CI is green." + FactDistillationTests.long)
        _ = try await agent.respond(to: "What is the codename?" + FactDistillationTests.long)
        let asked = model.script.thinking.withLock { $0 }
        #expect(asked.count == 4)
        #expect(asked[2] == .off, "the distiller")
        #expect([asked[0], asked[1], asked[3]] == [nil, nil, nil], "the turns leave the model its default")
        // A conversation that chose its thinking asks for it on every turn.
        agent.thinking = .on
        model.script.steps.withLock { $0 = [.say("ok")] }
        _ = try await agent.respond(to: "hi")
        #expect(model.script.thinking.withLock { $0.last } == .on)
    }

    @Test func theAssessmentAndTheClassifierAskForNoThinking() async throws {
        let model = ScriptedModel(steps: [
            .say(#"{"intent":"dry run","tools":["read_file"],"task":"","objective":"","facts":[]}"#), .say("Done."),
        ])
        let sink = MemoryAuditSink()
        let agent = AssessmentTests.agent(model, sink: sink, settings: AssessmentSettings(), facts: true)
        _ = try await agent.respond(
            to: "Let us add a dry-run flag to harbour sync and keep the codename in mind for its notes")
        #expect(AssessmentTests.assessments(sink).first?.details["method"] == "model")
        #expect(model.script.thinking.withLock { $0 } == [.off, nil], "the assessment, then the turn")
        // The classifier, inside a turn that asked for thinking, still asks for none.
        let judge = ScriptedModel(steps: [.say(#"{"risk":"safe","reason":"reads"}"#)])
        let classifier = ModelRiskClassifier(model: ResolvedModel(selection: .system, custom: judge))
        let verdict = await RequestThinking.$current.withValue(.on) {
            await classifier.classify(command: "ls", workingDirectory: "/tmp")
        }
        #expect(verdict.level == .safe && judge.script.thinking.withLock { $0 } == [.off])
        #expect(verdict.metadata["think"] == nil, "a model with no thinking switch records none")
    }

    @Test func aSchemaReplyAsksForNoThinkingUnlessTheConversationOrTheCallerKeepsIt() async throws {
        let schema = try OutputSchema(
            json: .object([
                "type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"],
            ]))
        let model = ScriptedModel(steps: [.say(#"{"answer":"a"}"#), .say(#"{"answer":"b"}"#), .say(#"{"answer":"c"}"#)])
        let agent = Agent(instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model))
        _ = try await agent.respond(to: "one", schema: schema)
        _ = try await agent.respond(to: "two", schema: schema, keepsThinking: true)
        agent.thinking = .level("high")
        _ = try await agent.respond(to: "three", schema: schema)
        #expect(model.script.thinking.withLock { $0 } == [.off, nil, .level("high")])
    }
}
