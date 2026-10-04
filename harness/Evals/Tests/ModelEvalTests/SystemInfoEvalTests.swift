import Foundation
import Testing

@testable import WispCore

/// Whether the configured model, or each model `WISP_EVAL_MODELS` names (`EvalModels`), reaches for `system_info` with the right topic when asked a plain
/// question about the Mac, with `run_command` and `memory` also on offer as they are in `wisp "…"`: `memory` is
/// the conversation's, and its name is shared with the `memory` topic (the Mac's RAM), so the turns that call it
/// are counted, printed, and noted in the measurement. Needs the model
/// (`scripts/check eval`). `run_command` sits behind a gate that refuses anything above safe, so the model
/// cannot change the Mac while being measured. A pass is a `system_info` call in the turn naming the
/// expected topic (and target, where the question gives one): a call the tool refuses with a directive
/// error, followed by the corrected call, passes, since recovering from that error is the design.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct SystemInfoEvalTests {
    /// A question and what a right first call looks like.
    struct Case {
        let question: String
        let topics: Set<String>
        let target: String?
    }

    static let cases: [Case] = [
        Case(question: "What is listening on port 11434 on this Mac?", topics: ["ports"], target: "11434"),
        Case(question: "Which process is using the most CPU right now?", topics: ["processes"], target: nil),
        Case(question: "How much free disk space do I have?", topics: ["freeSpace"], target: nil),
        Case(question: "What is taking up the space in ~/Library/Caches?", topics: ["folderSizes"], target: nil),
        Case(question: "How much battery is left?", topics: ["battery"], target: nil),
        Case(question: "Which version of macOS is this Mac running?", topics: ["system"], target: nil),
        Case(question: "How much memory is in use, and by what?", topics: ["memory"], target: nil),
        Case(question: "Is Ollama running, and how much memory does it use?", topics: ["process"], target: "ollama"),
    ]

    @Test func picksTheTopicAPlainQuestionNeeds() async throws {
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: ["system_info"]) else { continue }
            await Self.measure(on: model)
        }
    }

    /// The questions on one model, each asked twice; the floor applies to the configured model only.
    ///
    /// - Parameter model: The model.
    static func measure(on model: ResolvedModel) async {
        let selection = model.selection
        let attempts = 2
        var passed = 0
        var memoryTurns = 0
        var times: [Double] = []
        for (round, item) in (1...attempts).flatMap({ round in Self.cases.map { (round, $0) } }) {
            let question = item.question
            let (made, milliseconds) = await EvalModels.attempt(
                "system_info eval: \(question)", on: selection
            ) {
                let sink = MemoryAuditSink()
                let audit = AuditLog(session: "eval", sink: sink)
                let gate = ApprovalGate(
                    classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "not during the eval"),
                    threshold: .level(.moderate), audit: audit)
                let memory = MemorySource()
                let tools = ToolRegistry(audit: audit, approval: gate, memory: memory)
                    .select(["system_info", "run_command", "memory"]).tools
                let agent = Agent(
                    instructions: Prompting.systemPrompt(memory: true), tools: tools, model: model, audit: audit)
                agent.memory = memory
                // The calls are what is scored, so a turn that ends in an error still counts the calls it made.
                do {
                    _ = try await agent.respond(to: question)
                } catch {
                    print("system_info eval: on \(selection) \(question): error \(error)")
                }
                return sink.events.filter { $0.kind == .toolCall }.map {
                    Call(
                        tool: $0.details["tool"]?.stringValue ?? "",
                        arguments: $0.details["arguments"]?.stringValue ?? "")
                }
            }
            times.append(milliseconds)
            let calls = made ?? []
            let ok = calls.filter { $0.tool == "system_info" }.compactMap { Self.arguments($0.arguments) }.contains {
                call in
                item.topics.contains(call.topic)
                    && (item.target.map { call.target?.localizedCaseInsensitiveContains($0) == true } ?? true)
            }
            if ok { passed += 1 }
            if calls.contains(where: { $0.tool == "memory" }) { memoryTurns += 1 }
            print(
                "system_info eval: on \(selection) #\(round) \(ok ? "pass" : "FAIL") \(item.question) "
                    + "calls=\(calls.map { "\($0.tool) \($0.arguments)" })")
        }
        let total = Self.cases.count * attempts
        EvalModels.result("system_info", on: selection, passed: passed, total: total, milliseconds: times)
        try? Measurements.report(
            Measurement(
                task: "system_info.topic", tool: "system_info", model: selection.description, passed: passed,
                total: total,
                notes:
                    "eight plain questions about the Mac (a port, the busiest process, free space, a folder's usage, "
                    + "battery, macOS version, memory, one app) with run_command and memory also offered, twice each; "
                    + "a pass is a system_info call in the turn naming the expected topic and target; "
                    + "\(memoryTurns) turn\(memoryTurns == 1 ? "" : "s") called memory"))
        if EvalModels.floorsApply(to: selection) {
            #expect(passed * 2 >= total, "system_info topic passed \(passed)/\(total)")
        }
    }

    /// One tool call a turn made: the tool's name and its JSON arguments.
    struct Call: Sendable {
        /// The tool's name.
        let tool: String
        /// The call's arguments, as JSON text.
        let arguments: String
    }

    /// The topic and target of a call's JSON arguments.
    static func arguments(_ json: String) -> (topic: String, target: String?)? {
        guard let data = json.data(using: .utf8),
            let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
            let topic = object["topic"]?.stringValue
        else { return nil }
        return (topic, object["port"].flatMap { $0.intValue.map(String.init) } ?? object["process"]?.stringValue)
    }
}
