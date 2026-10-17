import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// Whether llama.cpp keeps a think level to its budget (ADR 0053, amended 2026-10-17): the margin a reply may think
/// past it, and `wisp doctor`'s probe against the fake server. In the serialized suite that owns the fake servers.
extension OpenAICompatibleExecutorTests {
    /// A non-streamed reply whose output was `completion` tokens, with `reasoning` of them thinking when given.
    static func budgetReply(completion: Int, reasoning: Int? = nil) -> String {
        let details = reasoning.map { #","completion_tokens_details":{"reasoning_tokens":\#($0)}"# } ?? ""
        return
            #"{"choices":[{"message":{"content":"dangerous"}}],"usage":{"completion_tokens":\#(completion)\#(details)}}"#
    }

    @Test func aReplyRunsPastItsBudgetOnlyBeyondTheEndOfTheBlock() {
        // A budget of 64 thought 64 and one of 256 thought 261 on llama.cpp 0.7.0: both kept to it.
        #expect(!ThinkingBudgetCheck.overran(thinking: 64, budget: 64))
        #expect(!ThinkingBudgetCheck.overran(thinking: 261, budget: 256))
        #expect(ThinkingBudgetCheck.overran(thinking: 81, budget: 64))
        #expect(!ThinkingBudgetCheck.overran(thinking: 1070, budget: 1024))
        #expect(ThinkingBudgetCheck.overran(thinking: 3088, budget: 1024))
        // No limit is never run past.
        #expect(!ThinkingBudgetCheck.overran(thinking: 50_000, budget: 0))
        let logged = ThinkingBudgetCheck.Logged()
        #expect(logged.first("a m") && !logged.first("a m") && logged.first("b m"))
    }

    @Test func doctorAsksAServerWhoseModelThinksToKeepToABudget() async throws {
        let settings = Self.llamaConfig.llamacpp
        // No thinking template: nothing to check, no finding.
        #expect(await ThinkingBudgetCheck.probe(settings) == nil)
        FakeChatServer.serve(Self.llama, "/props", Self.thinkingProps())
        FakeChatServer.serve(Self.llama, Self.chat, Self.budgetReply(completion: 37))
        let kept = try #require(await ThinkingBudgetCheck.probe(settings))
        #expect(kept.ok && kept.detail.contains("32 tokens asked, 37 used"))
        let sent = FakeChatServer.bodies(Self.llama, Self.chat).last ?? ""
        #expect(sent.contains(#""thinking_budget_tokens":32"#) && sent.contains(#""enable_thinking":true"#))
        // A server that ignores the budget thinks to the reply's limit, and the server's own count is read first.
        FakeChatServer.serve(Self.llama, Self.chat, Self.budgetReply(completion: 400, reasoning: 397))
        let ignored = try #require(await ThinkingBudgetCheck.probe(settings))
        #expect(!ignored.ok && ignored.detail.contains("thought 397 tokens past a budget of 32"))
        // The doctor puts the finding after the backends' own, ahead of the sandbox.
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let findings = await Doctor(
            home: Home(root: root),
            probes: Doctor.Probes(
                systemModel: { nil }, configuredModel: { _, _, _ in nil }, thinkingBudget: { _ in ignored })
        ).check()
        let names = findings.map(\.name)
        let budget = try #require(names.firstIndex(of: "llama.cpp thinking budget"))
        #expect(budget + 1 == names.firstIndex(of: "sandbox"))
    }
}
