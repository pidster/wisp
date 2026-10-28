import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The conversation's plan and the `plan` tool (ADR 0081): trees rooted at turns, tasks with dependencies anywhere in
/// the plan, the statuses the model sets and the checks on them, the limits, what each action returns, the line later
/// turns carry, and the plan saved with the record and resumed.
@Suite struct PlanTests {
    /// A fixed time, so tasks compare equal.
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A plan with tree t1 (three tasks, the third under the first and after the second) rooted at entry 4.
    static func sample() throws -> Plan {
        var plan = Plan()
        var current: Int?
        for (goal, parent, after) in [("Check", nil, []), ("List", nil, ["t1.1"]), ("Report", "t1.1", ["t1.2"])] {
            let added = try plan.adding(
                goal: goal, parent: parent, dependsOn: after, currentTree: current, now: now)
            plan = added.plan
            current = added.currentTree
        }
        return plan.rooting(1, at: 4)
    }

    @Test func aTaskWithoutAParentRootsTheTurnsTreeAndLaterOnesJoinIt() throws {
        var plan = Plan()
        let first = try plan.adding(
            goal: "  Check the disk ", parent: nil, dependsOn: [], currentTree: nil, now: Self.now)
        #expect(first.id == "t1.1" && first.currentTree == 1 && first.plan.trees.count == 1)
        #expect(first.plan.task("t1.1")?.goal == "Check the disk" && first.plan.trees[0].entry == nil)
        plan = first.plan
        let second = try plan.adding(goal: "List", parent: nil, dependsOn: ["t1.1"], currentTree: 1, now: Self.now)
        #expect(second.id == "t1.2" && second.plan.trees.count == 1)
        // The next turn, with no tree of its own yet, roots t2; a parent or a tree's name puts a task in another.
        plan = second.plan.rooting(1, at: 4)
        let next = try plan.adding(goal: "Again", parent: nil, dependsOn: [], currentTree: nil, now: Self.now)
        #expect(next.id == "t2.1" && next.currentTree == 2)
        let under = try next.plan.adding(goal: "Deeper", parent: "t1.2", dependsOn: [], currentTree: 2, now: Self.now)
        #expect(under.id == "t1.3" && under.plan.task("t1.3")?.parent == "t1.2" && under.currentTree == 2)
        let named = try under.plan.adding(goal: "Top", parent: "t1", dependsOn: [], currentTree: 2, now: Self.now)
        #expect(named.id == "t1.4" && named.plan.task("t1.4")?.parent == nil)
        #expect(named.plan.rooting(1, at: 9).tree(1)?.entry == 9)
    }

    @Test func addingRefusesWhatTheModelMustCorrect() throws {
        let plan = try Self.sample()
        func refusal(_ goal: String, parent: String? = nil, after: [String] = []) -> Plan.Failure? {
            do {
                _ = try plan.adding(goal: goal, parent: parent, dependsOn: after, currentTree: nil, now: Self.now)
                return nil
            } catch { return error }
        }
        #expect(refusal("  ") == .badGoal("is empty"))
        #expect(refusal(String(repeating: "x", count: Plan.goalLimit + 1)) == .badGoal("is longer than 200 characters"))
        #expect(refusal("x", parent: "t9.1") == .unknown("t9.1"))
        #expect(refusal("x", parent: "t9") == .unknown("t9"))
        #expect(refusal("x", after: ["t1.9"]) == .unknown("t1.9"))
        #expect(refusal("x", after: (1...9).map { "t1.\($0)" }) == .limit("a task may depend on at most 8 tasks"))
        // Six deep at most.
        var deep = Plan()
        var parent: String?
        for level in 1...Plan.depthLimit {
            let added = try deep.adding(
                goal: "level \(level)", parent: parent, dependsOn: [], currentTree: 1, now: Self.now)
            deep = added.plan
            parent = added.id
        }
        #expect(throws: Plan.Failure.limit("a task may sit at most 6 deep; add it higher up")) {
            try deep.adding(goal: "too deep", parent: parent, dependsOn: [], currentTree: 1, now: Self.now)
        }
        // A tree holds 64 tasks.
        var full = Plan()
        for index in 1...Plan.tasksPerTree {
            full = try full.adding(goal: "task \(index)", parent: nil, dependsOn: [], currentTree: 1, now: Self.now)
                .plan
        }
        #expect(throws: Plan.Failure.limit("tree t1 holds 64 tasks, the most a tree may")) {
            try full.adding(goal: "one more", parent: nil, dependsOn: [], currentTree: 1, now: Self.now)
        }
    }

    @Test func dependenciesCrossTreesAndRefuseCycles() throws {
        var plan = try Self.sample()
        plan = try plan.adding(goal: "Later", parent: nil, dependsOn: [], currentTree: nil, now: Self.now).plan
        plan = try plan.depending("t2.1", on: "t1.3", now: Self.now)
        #expect(plan.task("t2.1")?.dependsOn == ["t1.3"])
        #expect(try plan.depending("t2.1", on: "t1.3", now: Self.now) == plan)
        #expect(throws: Plan.Failure.selfDependency("t1.1")) { try plan.depending("t1.1", on: "t1.1", now: Self.now) }
        #expect(throws: Plan.Failure.cycle(["t1.1", "t2.1", "t1.3", "t1.2", "t1.1"])) {
            try plan.depending("t1.1", on: "t2.1", now: Self.now)
        }
        #expect(throws: Plan.Failure.unknown("t3.1")) { try plan.depending("t1.1", on: "t3.1", now: Self.now) }
        #expect(
            Plan.Failure.cycle(["a", "b", "a"]).description == "that would make a cycle: a -> b -> a")
    }

    @Test func aTaskStartsOrFinishesOnlyOnceWhatItWaitsForIsDone() throws {
        var plan = try Self.sample()
        #expect(plan.ready.map(\.id) == ["t1.1"])
        #expect(throws: Plan.Failure.blocked(task: "t1.2", by: ["t1.1"])) {
            try plan.updating("t1.2", status: .done, note: nil, now: Self.now)
        }
        #expect(
            Plan.Failure.blocked(task: "t1.2", by: ["t1.1"]).description
                == "t1.2 depends on t1.1, not done yet; finish or settle it first, or mark t1.2 skipped")
        plan = try plan.updating("t1.1", status: .done, note: "  42 GB free ", now: Self.now)
        #expect(plan.task("t1.1")?.note == "42 GB free" && plan.ready.map(\.id) == ["t1.2"])
        // A note left out keeps the one there; failing or skipping a task waiting on others is allowed.
        plan = try plan.updating("t1.1", status: .done, note: nil, now: Self.now)
        #expect(plan.task("t1.1")?.note == "42 GB free")
        plan = try plan.updating("t1.3", status: .skipped, note: "not needed", now: Self.now)
        #expect(plan.task("t1.3")?.status == .skipped)
        #expect(throws: Plan.Failure.badNote) {
            try plan.updating("t1.2", status: .running, note: String(repeating: "n", count: 301), now: Self.now)
        }
        #expect(throws: Plan.Failure.unknown("t1.9")) {
            try plan.updating("t1.9", status: .done, note: nil, now: Self.now)
        }
    }

    @Test func findMatchesEveryCriterionGiven() throws {
        var plan = try Self.sample()
        plan = try plan.updating("t1.1", status: .done, note: "the cache is large", now: Self.now)
        #expect(plan.find(status: .done).map(\.id) == ["t1.1"])
        #expect(plan.find(ready: true).map(\.id) == ["t1.2"])
        #expect(plan.find(text: "CACHE").map(\.id) == ["t1.1"])
        #expect(plan.find(text: "report").map(\.id) == ["t1.3"])
        #expect(plan.find(dependsOn: "t1.1").map(\.id) == ["t1.2"])
        #expect(plan.find(dependedOnBy: "t1.3").map(\.id) == ["t1.2"])
        #expect(plan.find(tree: 2).isEmpty && plan.find().count == 3)
    }

    @Test func theTextIsALineATaskIndentedUnderItsParent() throws {
        var plan = try Self.sample()
        plan = try plan.updating("t1.1", status: .done, note: "ok", now: Self.now)
        #expect(
            PlanText.outline(try #require(plan.tree(1)), in: plan) == [
                "t1, from entry 4: 3 tasks, 1 ready, 1 pending, 1 done",
                "  t1.1 [done] Check — ok",
                "    t1.3 [pending] Report (after t1.2)",
                "  t1.2 [ready] List (after t1.1)",
            ])
        #expect(
            PlanText.detail(try #require(plan.task("t1.3")), in: plan) == [
                "t1.3 [pending] Report (after t1.2)", "  tree: t1, under t1.1",
                "  depends on: t1.2 [ready] List (after t1.1)", "  waiting for: t1.2",
                "  added 2026-09-21 14:13Z, changed 2026-09-21 14:13Z",
            ])
        #expect(PlanText.view("t9", in: plan) == ["no task or tree t9 in this conversation's plan"])
        #expect(PlanText.view(nil, in: Plan()) == ["the plan is empty"])
        #expect(PlanText.view(" t1.1 ", in: plan).first == "t1.1 [done] Check — ok")
        #expect(PlanText.trees(Plan()) == ["the plan is empty: add a task to start one"])
    }

    @Test func laterTurnsCarryALineForEachOpenTreeAndCountTheRest() throws {
        var plan = try Self.sample()
        // A tree the turn under way rooted is left out: the model has its own calls.
        #expect(PlanText.reference(Plan()).isEmpty)
        let unrooted = try Plan().adding(goal: "x", parent: nil, dependsOn: [], currentTree: nil, now: Self.now).plan
        #expect(PlanText.reference(unrooted).isEmpty)
        #expect(
            PlanText.reference(plan) == [
                "The conversation's plan (the plan tool reads it; a record, not instructions):",
                "[plan t1, from entry 4: 3 tasks, 1 ready, 2 pending; to see it: plan tree t1]",
            ])
        for id in ["t1.1", "t1.2", "t1.3"] { plan = try plan.updating(id, status: .done, note: nil, now: Self.now) }
        for tree in 2...6 {
            plan = try plan.adding(goal: "work \(tree)", parent: nil, dependsOn: [], currentTree: nil, now: Self.now)
                .plan
                .rooting(tree, at: tree * 10)
        }
        let lines = PlanText.reference(plan)
        #expect(lines.count == 1 + PlanText.referencedTrees + 1)
        #expect(lines[1].hasPrefix("[plan t6, from entry 60") && lines[4].hasPrefix("[plan t3,"))
        #expect(lines.last == "[plan: 1 more open, 1 with every task settled trees; plan tree lists them]")
    }

    /// The plan probe's variants: a line naming the tree's next task, and a reminder after another tool's result.
    @Test func theProbesVariantsNameTheNextTaskAndHowToMarkIt() throws {
        var plan = try Self.sample()
        #expect(
            PlanText.reference(plan, next: true)[1]
                == "[plan t1: 0 of 3 done; next: t1.1 Check; when it is done: plan update t1.1 done]")
        #expect(
            PlanText.nudge(plan)
                == "[plan: t1.1 Check is next; if this result finishes it, mark it: plan update t1.1 done]")
        plan = try plan.updating("t1.1", status: .done, note: nil, now: Self.now)
        plan = try plan.updating("t1.2", status: .running, note: nil, now: Self.now)
        #expect(PlanText.nudge(plan)?.hasPrefix("[plan: t1.2 List is running;") == true)
        plan = try plan.updating("t1.2", status: .failed, note: nil, now: Self.now)
        // Nothing running or ready: the line falls back to the counts, and there is no reminder.
        #expect(PlanText.reference(plan, next: true)[1].hasPrefix("[plan t1, from entry 4: 3 tasks"))
        #expect(PlanText.nudge(plan) == nil)
        #expect(PlanBook(namesNext: true).namesNext && !PlanBook().namesNext)
    }

    /// Decision 12: every other tool's result ends with the reminder while a task is open and the turn marked none,
    /// recorded as the model sees it; a mark quiets it until the next turn, and a book that does not remind adds none.
    @Test func otherToolsResultsRemindTheModelToMarkItsTask() async throws {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let book = PlanBook()
        let plan = PlanTool(book: book, audit: audit)
        let registry = ToolRegistry(audit: audit, plan: plan)
        let date = AuditedTool(CurrentDateTool(), audit: audit, plan: book)
        let reminder = "\n[plan: t1.1 Read a.txt is next; if this result finishes it, mark it: plan update t1.1 done]"
        #expect(!(try await date.call(arguments: .init(timeZone: "UTC"))).contains("[plan:"))
        var add = PlanTool.Arguments(action: "add")
        add.goal = "Read a.txt"
        _ = await plan.call(arguments: add)
        let output = try await date.call(arguments: .init(timeZone: "UTC"))
        #expect(output.hasSuffix(reminder))
        #expect(sink.events.last?.details["output"] == .string(output))
        // The registry wires the conversation's plan into every tool but `plan`.
        #expect(registry.select(["plan", "current_date"]).tools.count == 2)
        var update = PlanTool.Arguments(action: "update")
        update.id = "t1.1"
        update.status = "running"
        _ = await plan.call(arguments: update)
        #expect(!(try await date.call(arguments: .init(timeZone: "UTC"))).contains("[plan:"))
        book.beginTurn()
        #expect(
            try await date.call(arguments: .init(timeZone: "UTC")).hasSuffix(
                "is running; if this result finishes it, mark it: plan update t1.1 done]"))
        let quiet = PlanBook(reminds: false)
        _ = await PlanTool(book: quiet).call(arguments: add)
        #expect(quiet.reminder() == nil && book.reminder() != nil)
    }

    @Test func theToolActsAndAuditsAndRefusesWithReasons() async throws {
        let sink = MemoryAuditSink()
        let book = PlanBook()
        let tool = PlanTool(book: book, audit: AuditLog(session: "s", sink: sink))
        func call(_ action: String, _ fill: (inout PlanTool.Arguments) -> Void = { _ in }) async -> String {
            var arguments = PlanTool.Arguments(action: action)
            fill(&arguments)
            return await tool.call(arguments: arguments)
        }
        #expect(await call("tree") == "the plan is empty: add a task to start one")
        #expect(await call("ready") == "nothing is ready: the plan is empty")
        #expect(await call("add") == "error: add needs goal")
        #expect(await call("add") { $0.goal = "Check the disk" } == "added t1.1 [ready] Check the disk")
        #expect(
            await call("add") {
                $0.goal = "List the largest folders"
                $0.dependsOn = ["t1.1"]
            } == "added t1.2 [pending] List the largest folders (after t1.1)")
        #expect(
            await call("add") {
                $0.goal = "Report"; $0.parent = "t1.2"
            } == "added t1.3 [ready] Report")
        #expect(
            await call("depend") {
                $0.id = "t1.3"; $0.dependsOn = ["t1.2"]
            } == "t1.3 now waits for t1.2")
        #expect(
            await call("depend") {
                $0.id = "t1.1"; $0.dependsOn = ["t1.3"]
            }.hasPrefix("error: that would make a cycle"))
        #expect(
            await call("update") {
                $0.id = "t1.2"; $0.status = "done"
            }.hasPrefix("error: t1.2 depends on t1.1"))
        #expect(
            await call("update") {
                $0.id = "t1.1"; $0.status = "Done"; $0.note = "42 GB free"
            }
                == "t1.1 [done] Check the disk — 42 GB free\nnow ready: t1.2")
        #expect(
            await call("update") {
                $0.id = "t1.2"; $0.status = "failed"; $0.note = "du was refused"
            }
                == "t1.2 [failed] List the largest folders (after t1.1) — du was refused\n"
                + "cannot go on while this is failed: t1.3")
        #expect(
            await call("update") {
                $0.id = "t1.2"; $0.status = "finished"
            }.hasPrefix("error: unknown status"))
        // A note alone keeps the status; neither is refused.
        #expect(
            await call("update") {
                $0.id = "t1.2"; $0.note = "du needs a wider grant"
            } == "t1.2 [failed] List the largest folders (after t1.1) — du needs a wider grant")
        #expect(await call("update") { $0.id = "t1.2" }.hasPrefix("error: unknown status"))
        #expect(
            await call("show") { $0.id = "t1.3" }.hasPrefix(
                "t1.3 [pending] Report (after t1.2)\n  tree: t1, under t1.2"))
        #expect(
            await call("tree") { $0.id = "t1.2" }.hasPrefix("t1, from this turn: 3 tasks, 1 pending, 1 done, 1 failed"))
        #expect(await call("show") { $0.id = "t1" } == (await call("tree") { $0.id = "t1" }))
        #expect(
            await call("find") { $0.status = "failed" }
                == "t1.2 [failed] List the largest folders (after t1.1) — du needs a wider grant")
        #expect(await call("find") { $0.text = "nothing like this" } == "no task matches")
        #expect(await call("find") { $0.dependsOn = ["t1.2"] } == "t1.3 [pending] Report (after t1.2)")
        #expect(await call("find") { $0.status = "ready" } == "no task matches")
        #expect(await call("show") == "error: show needs id")
        #expect(
            await call("dance")
                == "error: unknown action \"dance\"; use tree, show, ready, find, add, depend, or update")
        #expect(book.changedThisTurn)
        let kinds = sink.events.map(\.kind)
        #expect(kinds.filter { $0 == .planAdd }.count == 3 && kinds.contains(.planDepend))
        #expect(kinds.filter { $0 == .planUpdate }.count == 3)
        let added = try #require(sink.events.first { $0.kind == .planAdd })
        #expect(
            added.details["task"] == "t1.1" && added.details["tree"] == "t1"
                && added.details["goal"] == "Check the disk")
        for event in sink.events where [.planAdd, .planDepend, .planUpdate].contains(event.kind) {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind)))
        }
    }

    @Test func aLongResultPagesAndNamesTheNextPage() async {
        let book = PlanBook()
        let tool = PlanTool(book: book)
        for index in 1...50 {
            var arguments = PlanTool.Arguments(action: "add")
            arguments.goal = "task \(index)"
            _ = await tool.call(arguments: arguments)
        }
        var arguments = PlanTool.Arguments(action: "tree")
        arguments.id = "t1"
        let first = await tool.call(arguments: arguments)
        #expect(first.split(separator: "\n").count == PlanTool.pageLines + 1)
        #expect(first.hasSuffix("(page 1 of 2; next: plan tree t1 page 2)"))
        arguments.page = 2
        let second = await tool.call(arguments: arguments)
        #expect(second.hasPrefix("  t1.40 [ready] task 40") && !second.contains("page"))
    }

    @Test func theAgentRootsTheTurnsTreeSavesItAndNamesItInLaterTurns() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let thread = try session.thread(
            id: "plans", approver: DenyingApprover(reason: "not in tests"), tools: .named(["plan"]))
        let book = try #require(thread.plan)
        let model = ScriptedModel(steps: [
            .call(name: "plan", arguments: #"{"action":"add","goal":"Check the disk"}"#),
            .call(name: "plan", arguments: #"{"action":"add","goal":"Report","dependsOn":["t1.1"]}"#),
            .say("Planned."),
            .call(name: "plan", arguments: #"{"action":"update","id":"t1.1","status":"done","note":"fine"}"#),
            .say("Checked."),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        _ = try await agent.respond(to: "Plan a disk check.")
        let prompt = try #require(agent.store.entries.first { $0.kind == .prompt })
        #expect(agent.store.plan.tree(1)?.entry == prompt.id && agent.store.plan.tasks.count == 2)
        // The next turn's request carries the tree, and the record saves the plan.
        let next = agent.transcript.compactMap { entry -> String? in
            if case .prompt(let prompt) = entry, FactFrame.isFrame(entry) {
                prompt.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
            } else {
                nil
            }
        }.joined(separator: "\n")
        #expect(
            next.contains("[plan t1, from entry \(prompt.id): 2 tasks, 1 ready, 1 pending; to see it: plan tree t1]"))
        _ = try await agent.respond(to: "Do the check.")
        #expect(agent.store.plan.task("t1.1")?.status == .done && agent.store.plan.trees.count == 1)
        let snapshot = agent.store.snapshot
        #expect(snapshot.plan == agent.store.plan)
        let decoded = try JSONDecoder().decode(ThreadRecord.Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.plan == agent.store.plan)
        // A book that holds a plan keeps it over the record's; an empty one takes the record's.
        let fresh = PlanBook()
        fresh.seed(agent.store.plan)
        #expect(fresh.plan == agent.store.plan)
        fresh.seed(Plan())
        #expect(fresh.plan == agent.store.plan)
        #expect(book.plan == agent.store.plan)
        // Saved with the thread, `wisp threads plan` reads it back without a model.
        var settings = ThreadStore.Settings(
            id: "plans", owner: "chat", model: "system", tools: ["plan"], instructions: nil, think: nil,
            commandTimeoutSeconds: nil, session: "plans-aaaaaaaa", now: Self.now)
        settings.state = .saved
        try ThreadStore(home: home).save(settings, record: agent.store)
        #expect(try ThreadAdmin(home: home).plan("plans") == agent.store.plan)
        #expect(throws: ThreadAdmin.Failure.notFound("nope")) { try ThreadAdmin(home: home).plan("nope") }
        // /new empties it.
        agent.reset()
        #expect(book.plan.isEmpty && agent.store.plan.isEmpty)
    }

    @Test func aThreadHasPlanWhenTheConfigTurnsItOnOrItsListNamesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        let deny = DenyingApprover(reason: "x")
        #expect(Config().resolved.toolsPlan == false && ConfigSettings.defaultValue("tools.plan") == false)
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing())
        let off = try session.thread(id: "off", approver: deny)
        #expect(!off.tools.map(\.name).contains("plan") && off.plan == nil)
        try Data(#"{"tools": {"plan": true}}"#.utf8).write(to: home.configFile)
        let on = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing())
        let all = try on.thread(id: "all", approver: deny)
        #expect(all.tools.map(\.name).contains("plan") && all.plan != nil)
        let view = Introspection(home: home, config: on.config).configuration.objectValue
        #expect(view?["tools"]?.objectValue?["plan"] == true)
        let catalogue = PlanTool()
        #expect(catalogue.limits.contains("nothing in the plan runs") && catalogue.examplePrompt.contains("plan"))
    }

    @Test func thePlanAndEachTaskHaveLimitsOfTheirOwn() throws {
        // 256 tasks in the plan, across trees of 64.
        var plan = Plan()
        for tree in 1...4 {
            for index in 1...Plan.tasksPerTree {
                plan = try plan.adding(
                    goal: "task \(index)", parent: nil, dependsOn: [], currentTree: tree, now: Self.now
                ).plan
            }
            plan = plan.rooting(tree, at: tree)
        }
        #expect(plan.tasks.count == Plan.tasksPerPlan)
        #expect(throws: Plan.Failure.limit("the plan holds 256 tasks, the most it may; settle or reuse them")) {
            try plan.adding(goal: "one more", parent: nil, dependsOn: [], currentTree: nil, now: Self.now)
        }
        // A task depends on eight at most, however they were added.
        var many = Plan()
        for index in 1...9 {
            many = try many.adding(goal: "t \(index)", parent: nil, dependsOn: [], currentTree: 1, now: Self.now).plan
        }
        for index in 2...9 { many = try many.depending("t1.1", on: "t1.\(index)", now: Self.now) }
        #expect(many.task("t1.1")?.dependsOn.count == Plan.dependencyLimit)
        let ten = try many.adding(goal: "t 10", parent: nil, dependsOn: [], currentTree: 1, now: Self.now).plan
        #expect(throws: Plan.Failure.limit("a task may depend on at most 8 tasks")) {
            try ten.depending("t1.1", on: "t1.10", now: Self.now)
        }
    }

    @Test func everyTreeIsShownWithABlankLineBetween() async throws {
        var plan = try Self.sample()
        plan = try plan.adding(goal: "Later", parent: nil, dependsOn: [], currentTree: nil, now: Self.now).plan
        let view = PlanText.view(nil, in: plan)
        #expect(view.first?.hasPrefix("t1, from entry 4") == true && view.contains(""))
        #expect(view.last == "  t2.1 [ready] Later" && view.contains("t2, from this turn: 1 task, 1 ready"))
        #expect(
            PlanText.trees(plan) == [
                "t1, from entry 4: 3 tasks, 1 ready, 2 pending", "t2, from this turn: 1 task, 1 ready",
            ])
        // The tool reads the same plan; a tree or task it does not hold is refused, and a task names its tree.
        let book = PlanBook()
        book.seed(plan)
        let tool = PlanTool(book: book)
        var arguments = PlanTool.Arguments(action: "tree")
        #expect(await tool.call(arguments: arguments).hasPrefix("t1, from entry 4: 3 tasks"))
        arguments.id = "t1.3"
        #expect(await tool.call(arguments: arguments).hasPrefix("t1, from entry 4"))
        arguments.id = "t7"
        #expect(await tool.call(arguments: arguments) == "error: no task or tree t7 in this conversation's plan")
        var find = PlanTool.Arguments(action: "find")
        find.id = "t2"
        #expect(await tool.call(arguments: find) == "t2.1 [ready] Later")
        find.id = "t1.2"
        #expect(await tool.call(arguments: find).split(separator: "\n").count == 3)
        find.id = "t9"
        #expect(await tool.call(arguments: find) == "error: no task or tree t9 in this conversation's plan")
        find.id = nil
        find.status = "lost"
        #expect(await tool.call(arguments: find).hasPrefix("error: unknown status \"lost\"; use pending,"))
        find.status = nil
        find.dependsOn = ["t5.5"]
        #expect(await tool.call(arguments: find) == "error: no task or tree t5.5 in this conversation's plan")
        var depend = PlanTool.Arguments(action: "depend")
        #expect(await tool.call(arguments: depend) == "error: depend needs id")
        depend.id = "t2.1"
        #expect(await tool.call(arguments: depend) == "error: depend needs dependsOn")
        #expect(await tool.call(arguments: PlanTool.Arguments(action: "update")) == "error: update needs id")
        var show = PlanTool.Arguments(action: "show")
        show.id = "t4.4"
        #expect(await tool.call(arguments: show) == "error: no task or tree t4.4 in this conversation's plan")
        #expect(
            await tool.call(arguments: PlanTool.Arguments(action: "ready")) == "t1.1 [ready] Check\nt2.1 [ready] Later")
    }

    @Test func chatShowsThePlan() async throws {
        let book = PlanBook()
        book.seed(try Self.sample())
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
        agent.plan = book
        let capture = ChatLoopTests.Capture(lines: ["/plan", "/plan t1.3", "/plan t8", "quit"])
        var loop = ChatLoop(agent: agent, context: ChatLoopTests.context, io: capture.io)
        try await loop.run()
        let out = capture.output
        #expect(out.contains("t1, from entry 4: 3 tasks, 1 ready, 2 pending\n  t1.1 [ready] Check"))
        #expect(out.contains("t1.3 [pending] Report (after t1.2)\n  tree: t1, under t1.1"))
        #expect(out.contains("no task or tree t8 in this conversation's plan"))
        #expect(ChatInput.helpText.contains("/plan [TREE|TASK]"))
    }

    @Test func addTakesTheCallsASmallModelMakes() async throws {
        // granite4.1:8b, 2026-10-25: it named the tree it expected as the parent, gave its own ids, and called for
        // every task at once, so a dependency could arrive before the task it names.
        let book = PlanBook()
        let tool = PlanTool(book: book)
        func add(_ id: String, _ goal: String, parent: String? = "t1", after: [String] = []) async -> String {
            var arguments = PlanTool.Arguments(action: "add")
            arguments.id = id
            arguments.goal = goal
            arguments.parent = parent
            arguments.dependsOn = after
            return await tool.call(arguments: arguments)
        }
        #expect(
            await add("t1.3", "Write a report", after: ["t1.2"])
                == "added t1.3 [pending] Write a report (after t1.2)\nt1.2 not in the plan yet; add it to go on")
        #expect(await add("t1.1", "Check free disk space") == "added t1.1 [ready] Check free disk space")
        #expect(await add("t1.2", "List the largest folders", after: ["t1.1"]).hasPrefix("added t1.2 [pending]"))
        // A cycle through a task named before it was added is refused; an id taken, or of another tree, is refused
        // with the one to give, which passes over an id a task waits for.
        #expect(await add("t1.4", "Loop", after: ["t1.5"]).hasPrefix("added t1.4"))
        #expect(await add("t1.5", "Back", after: ["t1.4"]) == "error: that would make a cycle: t1.5 -> t1.4 -> t1.5")
        #expect(await add("t1.1", "Again") == "error: t1.1 is already a task; give this task t1.6, or leave id out")
        #expect(
            await add("t9.9", "Elsewhere")
                == "error: t9.9 is not in t1, where this task goes; give this task t1.6, or leave id out")
        #expect(await add("t1.7", "Far", after: ["t2.1"]) == "error: no task or tree t2.1 in this conversation's plan")
        let plan = book.plan
        #expect(plan.trees.count == 1 && plan.ready.map(\.id) == ["t1.1"])
        #expect(
            PlanText.detail(try #require(plan.task("t1.4")), in: plan)[2] == "  depends on: t1.5, not in the plan yet")
        // The next turn's tree is named before it is rooted, too; an earlier tree is still a parent.
        book.beginTurn()
        _ = book.endTurn(promptEntry: 2)
        #expect(await add("", "Next turn", parent: "t2") == "added t2.1 [ready] Next turn")
        #expect(await add("", "Under the first tree", parent: "t1").hasPrefix("added t1.6"))
        var detail = Plan()
        detail = try detail.adding(goal: "a", parent: nil, dependsOn: ["t1.2"], currentTree: nil, now: Self.now).plan
        #expect(
            PlanText.detail(try #require(detail.task("t1.1")), in: detail)[2]
                == "  depends on: t1.2, not in the plan yet")
    }

    @Test func eachRequestNamesTheIdsTheTurnsTasksTake() throws {
        // granite4.2:8b and gemma4:26b, 2026-10-27, named a turn's first task t1, then used t1 as a task.
        #expect(PlanText.turn(Plan()) == "[plan: this turn's tasks are t1.1, t1.2, …]")
        #expect(PlanText.turn(try Self.sample()) == "[plan: this turn's tasks are t2.1, t2.2, …]")
    }

    @Test func aModelsOwnIdIsKeptOrRefusedWithTheIdToGive() throws {
        // The planning probe, 2026-10-27 and 2026-10-28: models named the first task t1, asked for t1.1.1 with and
        // without a parent, and gave ids already taken; each renumbered silently, the model went on with its own.
        func add(
            _ plan: Plan, _ id: String, parent: String? = nil, current: Int? = 1
        ) throws(Plan.Failure) -> Plan.Task {
            try plan.adding(
                goal: "g \(id) \(parent ?? "")", parent: parent, dependsOn: [], currentTree: current, requestedID: id,
                now: Self.now
            ).task
        }
        let plan = try Self.sample()
        // A tree's name, this turn's before it is rooted or another's.
        #expect(throws: Plan.Failure.badID("t1 names a tree; give this task t1.1, or leave id out")) {
            try add(Plan(), "t1", current: nil)
        }
        #expect(throws: Plan.Failure.badID("t2 names a tree; give this task t1.4, or leave id out")) {
            try add(plan, "t2")
        }
        // A deeper id is a child of the task its prefix names, with parent left out or naming it.
        let child = try add(plan, "t1.2.1")
        #expect(child.id == "t1.2.1" && child.parent == "t1.2")
        #expect(try add(plan, "t1.2.1", parent: "t1.2").parent == "t1.2")
        #expect(
            throws: Plan.Failure.badID(
                "t1.4.1 would go under t1.4, which is not in the plan; add t1.4 first, or leave id out")
        ) {
            try add(plan, "t1.4.1")
        }
        #expect(
            throws: Plan.Failure.badID(
                "t1.2.1 would go under t1.2, but parent is t1.1; make them agree, or leave id out")
        ) {
            try add(plan, "t1.2.1", parent: "t1.1")
        }
        #expect(
            throws: Plan.Failure.badID(
                "t1.2.1 would go under t1.2, but parent is t1; make them agree, or leave id out")
        ) {
            try add(plan, "t1.2.1", parent: "t1")
        }
        // A level id is kept anywhere in its tree, as the tool's own are; taken, it is refused.
        #expect(try add(plan, "t1.9", parent: "t1.1").id == "t1.9")
        #expect(throws: Plan.Failure.badID("t1.2 is already a task; give this task t1.4, or leave id out")) {
            try add(plan, "t1.2")
        }
        // A name written as an id is refused; anything else is not an id, and the next number is given.
        for name in ["t1.find", "t1.1a", "t1.new1"] {
            #expect(throws: Plan.Failure.badID("\(name) is not an id; give this task t1.4, or leave id out")) {
                try add(plan, name)
            }
        }
        #expect(try add(plan, "[t1.2]").id == "t1.4")
        #expect(try add(plan, "step 1").id == "t1.4")
        #expect(try add(plan, "task1.2").id == "t1.4")
        #expect(Plan.parts("t1.2.3")! == (1, [2, 3]) && Plan.parts("t1")! == (1, []))
        #expect(Plan.parts("t1.") == nil && Plan.parts("t1.+2") == nil && Plan.parts("t0.1") == nil)
    }

    @Test func aTreesNameWithoutATaskOfThatNameIsRefusedAsATree() throws {
        let plan = try Self.sample()
        #expect(throws: Plan.Failure.tree("t1")) { try plan.updating("t1", status: .done, note: nil, now: Self.now) }
        #expect(throws: Plan.Failure.tree("t1")) { try plan.depending("t1.2", on: "t1", now: Self.now) }
        #expect(throws: Plan.Failure.tree("t1")) {
            try plan.adding(goal: "x", parent: nil, dependsOn: ["t1"], currentTree: 1, now: Self.now)
        }
        #expect(
            Plan.Failure.tree("t1").description == "t1 is a tree, not a task; name one of its tasks, such as t1.1")
        // As a parent, a tree's name still puts the task at the top of that tree.
        let top = try plan.adding(goal: "Top", parent: "t1", dependsOn: [], currentTree: 2, now: Self.now)
        #expect(top.id == "t1.4" && top.task.parent == nil)
    }

    @Test func theSameGoalInTheSamePlaceIsAddedOnce() throws {
        // gemma4:26b, 2026-10-27, added one task eight times, each call told it was a repeat.
        let plan = try Self.sample()
        #expect(throws: Plan.Failure.duplicate("t1.3")) {
            try plan.adding(goal: " Report ", parent: "t1.1", dependsOn: [], currentTree: 1, now: Self.now)
        }
        #expect(Plan.Failure.duplicate("t1.3").description == "t1.3 already has that goal there; nothing added")
        let elsewhere = try plan.adding(goal: "Report", parent: nil, dependsOn: [], currentTree: 1, now: Self.now)
        #expect(elsewhere.id == "t1.4")
        // A parent written none or null is no parent.
        for none in ["none", "None", "null"] {
            let added = try plan.adding(goal: "Free", parent: none, dependsOn: [], currentTree: 1, now: Self.now)
            #expect(added.task.parent == nil && added.task.tree == 1)
        }
    }

    @Test func chatParsesPlan() {
        #expect(ChatInput(line: "/plan") == .plan(nil))
        #expect(ChatInput(line: "/plan t1.2") == .plan("t1.2"))
    }
}
