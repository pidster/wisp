import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// llama.cpp's thinking, on a par with Ollama's (ADR 0053, amended 2026-10-17): a template that thinks is found from
/// `/props`, takes Ollama's values, `true`, `false`, and the levels, and each means what it means to Ollama: off is
/// no thinking whatever the template calls its switch, and a level is thinking within a budget. In the serialized
/// suite that owns the fake servers.
extension OpenAICompatibleExecutorTests {
    /// `/props` for a model whose chat template takes `enable_thinking`, as Qwen3's and Qwen3.5's do, and whose
    /// capabilities say whether it takes `reasoning_effort`.
    static func thinkingProps(effort: Bool = false) -> String {
        #"{"default_generation_settings":{"n_ctx":16384},"chat_template":"{%- if enable_thinking is defined and enable_thinking is false %}<think>\n\n</think>{%- endif %}","chat_template_caps":{"supports_tool_calls":true,"supports_reasoning_effort":"#
            + (effort ? "true" : "false") + "}}"
    }

    /// A schema with one string, `answer`.
    static func answer() throws -> OutputSchema {
        try OutputSchema(
            json: .object(["type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"]]))
    }

    /// The body of the last chat request a turn on `Qwen3-8B-Q4_K_M` sent, with `section` as `llamacpp`.
    ///
    /// - Parameters:
    ///   - section: The `llamacpp` section.
    ///   - schema: A schema for a schema reply, one of wisp's own calls, or nil for a turn.
    ///   - asked: The thinking the conversation asks of the turn, as an MCP caller's `think` does.
    /// - Returns: The body, as sent.
    /// - Throws: What resolving the model or the turn threw.
    func lastBody(
        _ section: Config.OpenAICompatibleConfig, schema: OutputSchema? = nil, asked: OllamaThink? = nil
    ) async throws -> String {
        FakeChatServer.serve(Self.llama, Self.chat, Self.reply([schema == nil ? "ok" : #"{"answer":"a"}"#]))
        let model = try ModelSelection.local(backend: "llamacpp", name: "Qwen3-8B-Q4_K_M").resolve(
            config: Config(llamacpp: section).resolved)
        let agent = Agent(instructions: "x", tools: [], model: model)
        agent.thinking = asked
        if let schema {
            _ = try await agent.respond(to: "hi", schema: schema)
        } else {
            _ = try await agent.respond(to: "hi")
        }
        return FakeChatServer.bodies(Self.llama, Self.chat).last ?? ""
    }

    @Test func aTemplateThatThinksIsReportedAsThinkingAndTakesOllamasLevels() throws {
        FakeChatServer.serve(Self.llama, "/props", Self.thinkingProps())
        let thinking = try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M")
        #expect(thinking.capabilities.contains(.reasoning))
        #expect(thinking.thinkLevels == OllamaThink.levels)
        #expect(thinking.thinkSent(.level("low")) == .level("low") && thinking.thinkSent(.off) == .off)
        try thinking.checkThink(.level("max"))
        // A template that says nothing of thinking is a model that cannot think: no levels, nothing sent.
        FakeChatServer.serve(Self.llama, "/props", Self.llamaProps)
        let plain = try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M")
        #expect(!plain.capabilities.contains(.reasoning) && plain.thinkLevels.isEmpty)
        #expect(plain.thinkSent(.off) == nil)
        #expect(throws: ModelSelection.Failure.self) { try plain.checkThink(.level("low")) }
    }

    @Test func wispsOwnCallsAskATemplateThatThinksForNoneWithoutADeclaration() async throws {
        // A thinking template found from `/props` alone: a schema reply, one of wisp's own calls, asks for no
        // thinking both ways, and a turn with nothing asked sends nothing, leaving the template's default.
        FakeChatServer.serve(Self.llama, "/props", Self.thinkingProps())
        let section = Config.OpenAICompatibleConfig(baseURL: "http://\(Self.llama):1")
        let side = try await lastBody(section, schema: try Self.answer())
        #expect(side.contains(#""chat_template_kwargs":{"enable_thinking":false}"#))
        #expect(side.contains(#""reasoning_effort":"none""#))
        #expect(!(try await lastBody(section).contains("chat_template_kwargs")))
    }

    @Test func aLevelThinksWithinItsBudgetAndIsAnEffortToATemplateThatTakesOne() async throws {
        FakeChatServer.serve(Self.llama, "/props", Self.thinkingProps())
        let base = Config.OpenAICompatibleConfig(baseURL: "http://\(Self.llama):1")
        // A level asked of a turn thinks, within the level's default budget; on thinks without one.
        let low = try await lastBody(base, asked: .level("low"))
        #expect(low.contains(#""enable_thinking":true"#) && low.contains(#""thinking_budget_tokens":1024"#))
        #expect(!low.contains("reasoning_effort"))
        let on = try await lastBody(base, asked: .on)
        #expect(on.contains(#""enable_thinking":true"#) && !on.contains("thinking_budget_tokens"))
        // The configured level and budget: `llamacpp.think` and `llamacpp.thinkingBudget`, 0 for no limit.
        let configured = Config.OpenAICompatibleConfig(
            baseURL: "http://\(Self.llama):1", think: .level("medium"), thinkingBudget: ["medium": 300, "max": 0])
        #expect(try await lastBody(configured).contains(#""thinking_budget_tokens":300"#))
        #expect(!(try await lastBody(configured, asked: .level("max")).contains("thinking_budget_tokens")))
        // A template that takes `reasoning_effort` is sent the level too, `max` as `high`.
        FakeChatServer.serve(Self.llama, "/props", Self.thinkingProps(effort: true))
        #expect(try await lastBody(base, asked: .level("low")).contains(#""reasoning_effort":"low""#))
        #expect(try await lastBody(base, asked: .level("max")).contains(#""reasoning_effort":"high""#))
    }

    @Test func theThinkingFieldsForEachChoice() {
        let budget = OpenAICompatibleSettings.defaultThinkingBudget
        typealias Executor = OpenAICompatibleModel.Executor
        #expect(
            Executor.thinking(.off, budget: budget, effort: false) == [
                "chat_template_kwargs": ["enable_thinking": false], "reasoning_effort": "none",
            ])
        #expect(
            Executor.thinking(.on, budget: budget, effort: true) == ["chat_template_kwargs": ["enable_thinking": true]])
        #expect(
            Executor.thinking(.level("high"), budget: budget, effort: true) == [
                "chat_template_kwargs": ["enable_thinking": true], "reasoning_effort": "high",
                "thinking_budget_tokens": 16_384,
            ])
        #expect(budget == ["low": 1024, "medium": 4096, "high": 16_384, "max": 0])
    }

    @Test func propsSayWhetherTheTemplateThinks() throws {
        func props(_ json: String) throws -> OpenAICompatibleModel.Props {
            .init(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        #expect(try props(Self.thinkingProps()).thinks)
        #expect(try props(Self.thinkingProps(effort: true)).takesReasoningEffort)
        #expect(try props(#"{"chat_template":"<|im_start|>assistant\n<think>\n"}"#).thinks)
        #expect(try !props(#"{"chat_template":"<|im_start|>assistant\n"}"#).thinks)
        #expect(try !props(Self.llamaProps).thinks)
    }

    @Test func theListingShowsTheQuantisationAsOllamasDoes() throws {
        let listing =
            #"{"data":[{"id":"/m/Bonsai-Q2_0.gguf","meta":{"n_params":8953803264,"size":2545600512,"ftype":"Q2_0"}}]}"#
        let served = try Catalogs.llamaServer(try JSONDecoder().decode(JSONValue.self, from: Data(listing.utf8)))
        #expect(served.first?.format == "Q2_0" && served.first?.name == "Bonsai-Q2_0")
    }
}
