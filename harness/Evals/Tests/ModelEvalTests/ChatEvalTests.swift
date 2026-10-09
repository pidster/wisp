import Foundation
import Testing

@testable import WispCore

/// How the model meets a message that asks for nothing: a bare "test", a greeting, a filler word.
/// Chat's prompt tells the model to quote tool output as returned, and a small model took "test" as
/// output to quote ("Test output: "test"."), then kept the shape for every later turn. A pass is a
/// short conversational reply: no tool call, no "output", and not the message said back. A control
/// case with a clear request must still reach its tool, so a prompt that makes the model shy of
/// tools fails here too. Needs the model; runs only with `WISP_MODEL_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct ChatEvalTests {
    /// One conversation: the messages in order, judged on the last reply; `tool` is the tool the last
    /// message must call, nil when it must call none.
    struct Case {
        let messages: [String]
        let tool: String?
    }

    static let cases = [
        Case(messages: ["test"], tool: nil),
        Case(messages: ["hello"], tool: nil),
        Case(messages: ["hmm"], tool: nil),
        Case(messages: ["ok"], tool: nil),
        Case(messages: ["testing 123"], tool: nil),
        Case(messages: ["test", "hello"], tool: nil),
        Case(messages: ["test", "hello", "nothing to say?"], tool: nil),
        Case(messages: ["What is the date today?"], tool: "current_date"),
    ]

    /// Whether `reply` echoes `message` or frames it as output: the failure this suite measures.
    static func echoes(_ reply: String, _ message: String) -> Bool {
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return reply.lowercased().contains("output") || letters(reply) == letters(message)
    }

    /// Runs one conversation on `model` as chat opens it: every built-in tool, memory wired to the agent, and the
    /// prompt with its memory rule (what chat opens with context.memory on; memory is off by default since ADR 0057,
    /// so it is set explicitly and the measurement stays comparable with those recorded before).
    ///
    /// - Parameters:
    ///   - messages: The messages, in order.
    ///   - model: The model.
    /// - Returns: The last reply and the tools its turn called.
    /// - Throws: What the agent throws.
    static func converse(
        _ messages: [String], on model: ResolvedModel
    ) async throws -> (
        reply: String, called: [String]
    ) {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "eval", sink: sink)
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "not during the eval"),
            threshold: .level(.moderate), audit: audit)
        let memory = MemorySource()
        let tools = ToolRegistry(audit: audit, approval: gate, memory: memory).select(ToolRegistry.builtInNames)
            .tools
        let agent = Agent(
            instructions: Prompting().rendered(toolsAvailable: true, memory: true), tools: tools, model: model,
            audit: audit)
        agent.memory = memory
        var reply = ""
        var lastTurn = 0
        for message in messages {
            lastTurn = agent.turns.current + 1
            reply = try await agent.respond(to: message).text
        }
        let called = sink.events.filter { $0.kind == .toolCall && $0.turn == lastTurn }
            .compactMap { $0.details["tool"]?.stringValue }
        return (reply, called)
    }

    /// Each model `EvalModels` names, each conversation bounded by its case limit; one that throws or runs out of
    /// time is a failed case, and the floor applies to the configured model only.
    @Test func answersAMessageWithNoRequestConversationally() async throws {
        let attempts = 3
        let total = Self.cases.count * attempts
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: ["chat"]) else { continue }
            var passed = 0
            var times: [Double] = []
            for (round, item) in (1...attempts).flatMap({ round in Self.cases.map { (round, $0) } }) {
                let (outcome, milliseconds) = await EvalModels.attempt(
                    "chat eval: \(item.messages) #\(round)", on: selection
                ) {
                    try await Self.converse(item.messages, on: model)
                }
                times.append(milliseconds)
                let reply = outcome?.reply ?? ""
                let called = outcome?.called ?? []
                let ok: Bool
                if outcome == nil {
                    ok = false
                } else if let tool = item.tool {
                    ok = called.contains(tool)
                } else {
                    ok = !reply.isEmpty && called.isEmpty && !Self.echoes(reply, item.messages.last ?? "")
                }
                if ok { passed += 1 }
                let shown = reply.replacingOccurrences(of: "\n", with: "⏎").prefix(120)
                print(
                    "chat eval: on \(selection) \(item.messages) #\(round): \(ok ? "pass" : "FAIL") tools=\(called) "
                        + "reply=\(shown)")
            }
            print("chat eval: on \(selection) measured: \(passed)/\(total)")
            EvalModels.result("chat", on: selection, passed: passed, total: total, milliseconds: times)
            if EvalModels.floorsApply(to: selection) {
                #expect(passed * 2 >= total, "chat unclear passed \(passed)/\(total)")
            }
            try? Measurements.report(
                Measurement(
                    task: "chat.unclear", model: selection.description, passed: passed, total: total,
                    notes: "a message with no request (test, hello, hmm, and the same after test) answered with a "
                        + "short reply, no tool, no echo; plus a clear question that must still call current_date; "
                        + "three attempts each"))
        }
    }
}
