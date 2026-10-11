import Foundation
import FoundationModels
import Testing
import WispCore
import WispTestSupport

@testable import WispMLX

/// MLX's thinking chosen per call (ADR 0053, amended 2026-10-11): the template's `enable_thinking` is what a request's
/// scope asks for a template that takes it, else the model's configured default; a template that does not take it is
/// sent its default whatever is asked.
@Suite struct MLXThinkPerCallTests {
    @Test func aRequestsChoiceReachesATemplateThatTakesIt() {
        let engine = MLXExecutorTests.engine(RuntimeLog())
        let toggled = MLXModel(
            engine: engine, window: 64, capabilities: [.reasoning], thinkingFormat: ThinkingSplitTests.think)
        #expect(toggled.thinkSent(nil) == .on, "declared reasoning: asked to think by default")
        #expect(toggled.thinkSent(.off) == .off && toggled.thinkSent(.level("high")) == .on)
        // A template that marks thinking but takes no switch keeps its default.
        let fixed = MLXModel(
            engine: engine, window: 64, capabilities: [.reasoning],
            thinkingFormat: ThinkingFormat(open: "<think>", close: "</think>", toggle: false))
        #expect(fixed.thinkSent(.off) == .on)
        // Nothing declared, nothing configured, no tags: nothing is sent.
        #expect(MLXModel(engine: engine, window: 64, capabilities: []).thinkSent(.off) == nil)
        // A model's own `mlx.models.<name>.think` is resolved ahead of `mlx.think`.
        let config = Config(mlx: .init(models: ["m": .init(think: false)], think: true)).resolved
        #expect(config.mlxModelThinks["m"] == false && config.mlxThink == true)
    }

    @Test func aConversationThatChoseNoThinkingRendersItsTurnsWithoutIt() async throws {
        let log = RuntimeLog(steps: [[.text("No.")], [.text("Yes.")]])
        let resolved = MLXBackend.resolved(
            selection: .local(backend: "mlx", name: "words"), engine: MLXExecutorTests.engine(log), capabilities: [],
            declared: false, sizing: .init(window: 4096, reason: "configured as mlx.contextLength"), asset: "/m",
            thinkingFormat: ThinkingSplitTests.think, think: true)
        #expect(resolved.thinkSent(nil) == .on)
        let agent = Agent(instructions: "x", tools: [], model: resolved)
        _ = try await agent.respond(to: "a turn")
        agent.thinking = .off
        _ = try await agent.respond(to: "another")
        #expect(log.prompts.withLock { $0.map(\.thinking) } == [true, false])
    }

    /// Ctrl-C during a turn on MLX (ADR 0049, amended 2026-10-11): a stoppable turn's generation runs beside the
    /// turn's stop and is cancelled by it; one stopped already generates nothing.
    @Test func aStoppableTurnGeneratesUntilItIsStopped() async throws {
        let log = RuntimeLog(steps: [[.text("Fine.")]])
        let model = MLXModel(engine: MLXExecutorTests.engine(log), window: 4096, capabilities: [])
        let agent = Agent(instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model))
        let reply = try await agent.stream("hi", stop: TurnStop()) { _ in }
        #expect(reply.text == "Fine.")
        let stopped = TurnStop()
        stopped.request()
        await #expect(throws: TurnStop.Failure.stopped) { try await agent.stream("again", stop: stopped) { _ in } }
        #expect(log.prompts.withLock { $0.count } == 1, "nothing generated once stopped")
    }
}
