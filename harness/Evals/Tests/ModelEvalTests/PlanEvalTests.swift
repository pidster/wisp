import Foundation
import Testing

@testable import WispCore

/// The plan probe (ADR 0081): whether a model keeps its plan while it works, over several turns, as a person drives a
/// chat with "go on". A first chat on 2026-10-25 (granite4.1:8b) added its tasks but never marked one, and restated
/// the plan turn after turn instead of working. Each problem runs under four variants of what the model is shown: no
/// help (`none`, what shipped before decision 12), a line naming the tree's next task and how to mark it in later
/// turns (`next`), the reminder after each other tool's result while a task is running or ready and none was marked
/// this turn (`reminder`, what wisp ships, decision 12), and both. Scored from the conversation's plan and audit, never
/// from the replies: whether every task was settled within the turns (finished), how many updates were made, how many
/// turns after the first made no call (stalls), and how many tasks were marked done ahead of the work (ahead: the
/// count of `done` marks so far exceeding the count of other tools' calls so far, which a task needing no call, or
/// one call doing several tasks, also counts). A conversation that adds no task in its first turn ends there, as
/// unplanned. A measurement for a design decision, run on purpose with `scripts/check eval plan`, like the context
/// eval; no floor. Needs the model; runs only with `WISP_MODEL_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISP_MODEL_TESTS"] != nil))
struct PlanEvalTests {
    /// What the model is shown beyond the plan tool itself.
    enum Variant: String, CaseIterable, Sendable {
        case none, next, reminder, both

        /// Whether later turns' lines name the next task.
        var namesNext: Bool { self == .next || self == .both }
        /// Whether other tools' results carry the reminder.
        var reminds: Bool { self == .reminder || self == .both }
    }

    /// One problem: the first message, given the scratch folder's path.
    struct Problem: Sendable {
        let id: String
        let prompt: @Sendable (String) -> String
    }

    static let problems = [
        Problem(id: "files") { dir in
            "In \(dir) there are three text files: a.txt, b.txt and c.txt. Make a plan with a task for each file, "
                + "then work through it: read each file and tell me in one line what it is about."
        },
        Problem(id: "machine") { _ in
            "Make a plan to check this Mac: the macOS version, the free disk space, and the memory. Then work through it."
        },
        Problem(id: "depends") { dir in
            "In \(dir), plan this and then do it: count the lines of a.txt, b.txt and c.txt with wc -l, one task "
                + "for each file, then a last task that depends on those three: say which file is longest."
        },
    ]

    /// What the person says after the first message while tasks are open.
    static let goOn = "go on"
    /// Turns in a conversation, the first included.
    static let turns = 6
    /// Conversations per problem and variant.
    static let attempts = 2

    /// The scratch folder's files.
    static let files = [
        "a.txt": "Shopping list: milk, eggs, bread, coffee.\n",
        "b.txt": "The team meeting moved to Thursday at 3 pm.\nBring the quarterly figures.\nRoom 4B.\n",
        "c.txt": "The web server's certificate expires on 30 November.\nRenew it before then.\n",
    ]

    /// How one conversation went, read from its plan and audit.
    struct Outcome: Sendable {
        let tasks: Int
        let settled: Int
        let updates: Int
        let work: Int
        let stalls: Int
        let ahead: Int
        let turns: Int

        /// Every task settled, and at least three planned.
        var finished: Bool { tasks >= 3 && settled == tasks }
    }

    /// Runs one conversation: the problem's message, then "go on" while a task is open, up to `turns`; one whose
    /// first turn added no task ends there.
    ///
    /// - Parameters:
    ///   - problem: The problem.
    ///   - variant: What the model is shown.
    ///   - dir: The scratch folder.
    ///   - model: The model.
    /// - Returns: How it went.
    /// - Throws: What the agent throws.
    static func converse(
        _ problem: Problem, _ variant: Variant, in dir: String, on model: ResolvedModel
    )
        async throws -> Outcome
    {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "eval", sink: sink)
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "not during the eval"),
            threshold: .level(.moderate), audit: audit)
        let book = PlanBook(namesNext: variant.namesNext, reminds: variant.reminds)
        let registry = ToolRegistry(
            runner: .init(writableRoot: dir), audit: audit, approval: gate, plan: PlanTool(book: book, audit: audit))
        let tools = registry.select(["plan", "run_command", "read_file", "system_info"]).tools
        let agent = Agent(
            instructions: Prompting().rendered(toolsAvailable: true, memory: false), tools: tools, model: model,
            audit: audit)
        agent.plan = book
        var used = 0
        for turn in 1...turns {
            let plan = book.plan
            if turn > 1, plan.isEmpty || plan.tasks.allSatisfy(\.status.isSettled) { break }
            _ = try await agent.respond(to: turn == 1 ? problem.prompt(dir) : goOn)
            used = turn
        }
        let events = sink.events
        let calls = events.filter { $0.kind == .toolCall }
        let tool = { (event: AuditEvent) in event.details["tool"]?.stringValue ?? "" }
        let stalls = (2...max(2, used)).filter { turn in turn <= used && !calls.contains { $0.turn == turn } }.count
        var (work, done, ahead) = (0, 0, 0)
        for event in events {
            if event.kind == .toolCall, tool(event) != "plan" { work += 1 }
            if event.kind == .planUpdate, event.details["status"]?.stringValue == "done" {
                done += 1
                if done > work { ahead += 1 }
            }
        }
        let plan = book.plan
        return Outcome(
            tasks: plan.tasks.count, settled: plan.tasks.count(where: { $0.status.isSettled }),
            updates: events.count(where: { $0.kind == .planUpdate }),
            work: calls.count(where: { tool($0) != "plan" }), stalls: stalls, ahead: ahead, turns: used)
    }

    /// Every problem under every variant, `attempts` times, on each model `EvalModels` names.
    @Test func keepsThePlanWhileItWorks() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-plan-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in Self.files { try Data(text.utf8).write(to: dir.appending(path: name)) }
        let path = dir.resolvingSymlinksInPath().path
        for selection in EvalModels.selections {
            guard let model = EvalModels.resolve(selection, for: Variant.allCases.map { "plan.\($0.rawValue)" })
            else { continue }
            for variant in Variant.allCases {
                var finished = 0
                var updates = 0
                var stalls = 0
                var ahead = 0
                var unplanned = 0
                var times: [Double] = []
                let runs = Self.problems.flatMap { problem in (1...Self.attempts).map { (problem, $0) } }
                for (problem, round) in runs {
                    let label = "plan eval: \(problem.id) \(variant.rawValue) #\(round)"
                    let (outcome, milliseconds) = await EvalModels.attempt(label, on: selection) {
                        try await Self.converse(problem, variant, in: path, on: model)
                    }
                    times.append(milliseconds)
                    guard let outcome else { continue }
                    if outcome.finished { finished += 1 }
                    updates += outcome.updates
                    stalls += outcome.stalls
                    ahead += outcome.ahead
                    if outcome.tasks == 0 { unplanned += 1 }
                    print(
                        "\(label) on \(selection): \(outcome.finished ? "finished" : "UNFINISHED") "
                            + "tasks=\(outcome.tasks) settled=\(outcome.settled) updates=\(outcome.updates) "
                            + "work=\(outcome.work) stalls=\(outcome.stalls) ahead=\(outcome.ahead) "
                            + "turns=\(outcome.turns) "
                            + "ms=\(Int(milliseconds))")
                }
                print("plan eval: on \(selection) \(variant.rawValue) measured: \(finished)/\(runs.count) finished")
                EvalModels.result(
                    "plan.\(variant.rawValue)", on: selection, passed: finished, total: runs.count,
                    milliseconds: times,
                    note: "\(updates) updates, \(stalls) stalled turns, \(ahead) marked ahead, \(unplanned) unplanned")
            }
        }
    }
}
