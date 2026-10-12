import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// Whether the configured model, or each model `WISP_EVAL_MODELS` names (`EvalModels`), reaches for `system_info` with the right topic when asked a plain
/// question about the Mac, with `run_command` and `memory` also on offer, as they were in `wisp "…"` until `memory` went
/// off by default (ADR 0057) and as they are with `context.memory` on: `memory` is the conversation's, and its name is
/// shared with the `memory` topic (the Mac's RAM), so the turns that call it are counted, printed, and noted in the
/// measurement. The tool set is explicit, so the measurement stays comparable with those recorded before. Needs the
/// model (`scripts/check eval`). `run_command` sits behind a gate that refuses anything above safe, so the model
/// cannot change the Mac while being measured. A pass is a `system_info` call in the turn matching one the question
/// accepts: its topic, and its port, process, or folder where the question names one. A call the tool refuses with a
/// directive error, followed by the corrected call, passes, since recovering from that error is the design. The
/// questions are `system_info.json` (`EvalSets.SystemInfo`): every topic in several phrasings, the ambiguous ones
/// accepting each topic a careful operator would. Each is asked once; the release asks a fixed subset spread over the
/// topics (`WISP_EVAL_FULL=1` asks all), against a floor set from the configured model's history
/// (docs/measurements.md).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct SystemInfoEvalTests {
    @Test func picksTheTopicAPlainQuestionNeeds() async throws {
        let set = try EvalSets.SystemInfo.load()
        let cases = EvalModels.chosen(set.cases, release: set.release, id: \.id, stratum: \.stratum)
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: ["system_info"]) else { continue }
            await Self.measure(cases, of: set.cases.count, on: model)
        }
    }

    /// The questions on one model, each asked once; the floor applies to the configured model only.
    ///
    /// - Parameters:
    ///   - cases: The questions this run asks.
    ///   - total: The questions in the set.
    ///   - model: The model.
    static func measure(_ cases: [EvalSets.SystemInfo.Case], of total: Int, on model: ResolvedModel) async {
        let selection = model.selection
        var passed = 0
        var memoryTurns = 0
        var times: [Double] = []
        for item in cases {
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
                call in item.accept.contains { $0.matches(topic: call.topic, target: call.target, path: call.path) }
            }
            if ok { passed += 1 }
            if calls.contains(where: { $0.tool == "memory" }) { memoryTurns += 1 }
            print(
                "system_info eval: on \(selection) \(item.id) \(ok ? "pass" : "FAIL") \(item.question) "
                    + "calls=\(calls.map { "\($0.tool) \($0.arguments)" })")
        }
        EvalModels.result("system_info", on: selection, passed: passed, total: cases.count, milliseconds: times)
        try? Measurements.report(
            Measurement(
                task: "system_info.topic", tool: "system_info", model: selection.description, passed: passed,
                total: cases.count,
                notes:
                    "plain questions about the Mac over every topic (ports, processes, free space, a folder's usage, "
                    + "memory, one app, battery, the system, the network), some ambiguous, with run_command and memory "
                    + "also offered, \(EvalModels.scope(cases.count, of: total)) once each; a pass is a system_info "
                    + "call in the turn naming a topic a careful operator accepts, with its port, process, or folder; "
                    + "\(memoryTurns) turn\(memoryTurns == 1 ? "" : "s") called memory"))
        EvalModels.expectFloor(
            "system_info", passed: passed, total: cases.count, rate: EvalFloor.Historical.systemInfo, on: selection)
    }

    /// One tool call a turn made: the tool's name and its JSON arguments.
    struct Call: Sendable {
        /// The tool's name.
        let tool: String
        /// The call's arguments, as JSON text.
        let arguments: String
    }

    /// The topic, target (the port as text, or the process), and folder of a call's JSON arguments.
    ///
    /// - Parameter json: The call's arguments.
    /// - Returns: The parts, or nil when the arguments do not parse or name no topic.
    static func arguments(_ json: String) -> (topic: String, target: String?, path: String?)? {
        guard let data = json.data(using: .utf8),
            let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
            let topic = object["topic"]?.stringValue
        else { return nil }
        let target = object["port"].flatMap { $0.intValue.map(String.init) } ?? object["process"]?.stringValue
        return (topic, target, object["path"]?.stringValue)
    }
}
