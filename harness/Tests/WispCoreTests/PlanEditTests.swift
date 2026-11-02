import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The person's changes to a conversation's plan (ADR 0079, decision 22): read from `/plan` and `wisp threads plan`,
/// applied with the model's checks but for a task the person marks done, told to the model at the next turn, made from
/// a terminal only on a thread nobody holds, and refused to wisp's model.
@Suite struct PlanEditTests {
    /// A fixed time.
    static let now = PlanTests.now

    @Test func theWordsSpellAChangeOrAreLeftAView() throws {
        #expect(try PlanEdit.parse([]) == nil)
        #expect(try PlanEdit.parse(["t1.2"]) == nil)
        #expect(try PlanEdit.parse(["done", "t1.2"]) == .done("t1.2", note: nil))
        #expect(try PlanEdit.parse(["Skip", "t1.2", "not", "needed"]) == .skip("t1.2", note: "not needed"))
        #expect(try PlanEdit.parse(["reopen", "t1.1", "again"]) == .reopen("t1.1", note: "again"))
        #expect(
            try PlanEdit.parse(["add", "Check", "the", "logs", "after", "t1.1,t1.2", "under", "t1"])
                == .add(goal: "Check the logs", under: "t1", after: ["t1.1", "t1.2"]))
        #expect(
            try PlanEdit.parse(["add", "Read", "what", "came", "after"])
                == .add(goal: "Read what came after", under: nil, after: []))
        #expect(throws: PlanEdit.Failure.missing("a task, such as t1.2", verb: "done")) {
            try PlanEdit.parse(["done"])
        }
        #expect(throws: PlanEdit.Failure.missing("a goal", verb: "add")) { try PlanEdit.parse(["add", "under", "t1"]) }
        #expect("\(PlanEdit.Failure.missing("a goal", verb: "add"))" == "plan add needs a goal")
    }

    @Test func thePersonsChangesKeepTheChecksButForDone() throws {
        let plan = try PlanTests.sample()
        // The model may not finish t1.2 before t1.1; the person may, knowing it done some other way.
        #expect(throws: Plan.Failure.blocked(task: "t1.2", by: ["t1.1"])) {
            try plan.updating("t1.2", status: .done, note: nil, now: Self.now)
        }
        let done = try PlanEdit.done("t1.2", note: "done by hand").apply(
            to: plan, by: .person, lastPrompt: 9, now: Self.now)
        #expect(done.plan.task("t1.2")?.status == .done && done.line == "t1.2 done: done by hand")
        #expect(done.kind == .planUpdate && done.details["by"] == .string("person"))
        #expect(Set(done.details.keys).isSubset(of: AuditEvent.fields(for: .planUpdate)))
        #expect(done.plan.untold == ["the person: t1.2 done: done by hand"])
        let skipped = try PlanEdit.skip("t1.1", note: nil).apply(
            to: done.plan, by: .person, lastPrompt: 9, now: Self.now)
        #expect(skipped.line == "t1.1 skipped" && skipped.plan.task("t1.1")?.status == .skipped)
        let reopened = try PlanEdit.reopen("t1.1", note: nil).apply(
            to: skipped.plan, by: .person, lastPrompt: 9, now: Self.now)
        #expect(reopened.line == "t1.1 reopened" && reopened.plan.task("t1.1")?.status == .pending)
        #expect(reopened.plan.untold.count == 3)
        #expect(throws: Plan.Failure.unknown("t9.9")) {
            try PlanEdit.skip("t9.9", note: nil).apply(to: plan, by: .person, lastPrompt: 9, now: Self.now)
        }
    }

    @Test func aTaskThePersonAddsGoesToTheNewestTreeOrRootsOne() throws {
        let plan = try PlanTests.sample()
        let added = try PlanEdit.add(goal: "Tidy up", under: nil, after: ["t1.3"])
            .apply(to: plan, by: .person, lastPrompt: 9, now: Self.now)
        #expect(added.line == "added t1.4 Tidy up (after t1.3)" && added.plan.task("t1.4")?.parent == nil)
        #expect(added.kind == .planAdd && added.details["by"] == .string("person"))
        #expect(Set(added.details.keys).isSubset(of: AuditEvent.fields(for: .planAdd)))
        let under = try PlanEdit.add(goal: "Look closer", under: "t1.2", after: [])
            .apply(to: plan, by: .person, lastPrompt: 9, now: Self.now)
        #expect(under.plan.tasks.last?.parent == "t1.2" && under.line == "added t1.4 Look closer")
        let fresh = try PlanEdit.add(goal: "Start", under: nil, after: []).apply(
            to: Plan(), by: .person, lastPrompt: 9, now: Self.now)
        #expect(fresh.plan.trees.first?.entry == 9 && fresh.plan.task("t1.1")?.goal == "Start")
        let unrooted = try PlanEdit.add(goal: "Start", under: nil, after: [])
            .apply(to: Plan(), by: .person, lastPrompt: nil, now: Self.now)
        #expect(unrooted.plan.trees.first?.entry == nil)
    }

    @Test func theModelIsToldAtItsNextTurnAndOnlyThen() throws {
        var plan = try PlanTests.sample()
        for index in 1...10 { plan.tellModel("change \(index)") }
        #expect(plan.untold.count == Plan.untoldKept && plan.untold.first == "change 3")
        let book = PlanBook()
        book.seed(plan)
        #expect(book.told.isEmpty)
        book.beginTurn()
        #expect(book.told.count == Plan.untoldKept && book.plan.untold.isEmpty)
        #expect(
            PlanText.told(["the person: t1.2 skipped: not needed"])
                == ["The plan was changed since your last turn:", "[plan: the person: t1.2 skipped: not needed]"])
        #expect(PlanText.told([]).isEmpty)
        book.beginTurn()
        #expect(book.told.isEmpty)
        // A plan saved before the person could change it resumes with nothing to tell.
        var encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        encoded["untold"] = nil
        let decoded = try JSONDecoder().decode(Plan.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.untold.isEmpty && decoded.tasks == plan.tasks)
    }

    @Test func chatChangesThePlanAndTheNextTurnTellsTheModel() async throws {
        let book = PlanBook()
        book.seed(try PlanTests.sample())
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
        agent.plan = book
        let capture = ChatLoopTests.Capture(
            lines: ["/plan skip t1.2 not needed", "/plan done", "/plan t1.2", "hello", "quit"])
        var loop = ChatLoop(agent: agent, context: ChatLoopTests.context, io: capture.io)
        try await loop.run()
        let out = capture.output
        let notes = capture.noted.joined(separator: "\n")
        #expect(notes.contains("plan: t1.2 skipped: not needed; the model is told at its next turn"))
        #expect(notes.contains("error: plan done needs a task, such as t1.2"))
        #expect(out.contains("t1.2 [skipped] List (after t1.1) — not needed"))
        #expect(book.told == ["the person: t1.2 skipped: not needed"] && agent.store.plan.untold.isEmpty)
        #expect(ChatInput.helpText.contains("/plan done|skip|reopen TASK [NOTE]"))
    }

    @Test func aChangeWithoutTheToolGoesToTheRecord() throws {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
        let applied = try agent.editPlan(.add(goal: "Remember this", under: nil, after: []), now: Self.now)
        #expect(applied.line == "added t1.1 Remember this" && agent.store.plan.task("t1.1") != nil)
    }

    @Test func theTerminalChangesAThreadOrQueuesTheChangeForItsHolder() throws {
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-plan-edit-\(UUID().uuidString)"))
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: home.root) }
        var record = ThreadRecord()
        record.plan = try PlanTests.sample()
        let settings = ThreadStore.Settings(
            id: "work", owner: "chat", model: "system", tools: ["plan"], instructions: "", think: nil,
            commandTimeoutSeconds: nil, session: "work-aaaaaaaa", now: Self.now)
        let admin = ThreadAdmin(home: home)
        try admin.store.save(settings, record: record)
        let queue = PlanQueue(home: home)
        guard
            case .applied(let applied) = try admin.editPlan(
                "work", .skip("t1.2", note: "later"), queue: queue, now: Self.now)
        else { throw Failure.unexpected }
        #expect(applied.details["thread"] == .string("work"))
        #expect(Set(applied.details.keys).isSubset(of: AuditEvent.fields(for: .planUpdate)))
        let saved = try admin.plan("work")
        #expect(saved.task("t1.2")?.status == .skipped && saved.untold == ["the person: t1.2 skipped: later"])
        // Held, the change is queued for the holder, in the order filed, and nothing else is touched.
        let lock = try admin.store.lock("work", owner: "claude-code")
        let holder = ThreadLock.Holder(pid: getpid(), owner: "claude-code")
        guard case .queued(let first, let named) = try admin.editPlan("work", .done("t1.1", note: nil), queue: queue)
        else { throw Failure.unexpected }
        #expect(named == holder)
        _ = try admin.editPlan("work", .skip("t9.9", note: nil), queue: queue)
        lock.release()
        #expect(try admin.plan("work").task("t1.1")?.status == .pending)
        let mode = try FileManager.default.attributesOfItem(atPath: queue.directory("work").path)[.posixPermissions]
        #expect(mode as? Int == 0o700)
        // The holder makes them as its next turn begins: one made, one refused and told.
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
        agent.plan = PlanBook()
        agent.plan?.seed(saved)
        #expect(agent.applyQueuedPlanChanges(from: queue, thread: "work") == 1)
        #expect(agent.plan?.plan.task("t1.1")?.status == .done && agent.store.plan.task("t1.1")?.status == .done)
        #expect(
            agent.plan?.plan.untold.last
                == "the person: skip t9.9 could not be made: no task or tree t9.9 in this conversation's plan")
        #expect(first.edit == .done("t1.1", note: nil))
        #expect(queue.take(thread: "work").isEmpty && queue.take(thread: "../x").isEmpty)
        #expect(throws: ThreadAdmin.Failure.notFound("nope")) {
            try admin.editPlan("nope", .done("t1.1", note: nil), queue: queue)
        }
    }

    /// What the tests throw on a case they did not expect.
    enum Failure: Error { case unexpected }

    @Test func aChangeReadsBackFromItsWords() throws {
        for edit in [
            PlanEdit.done("t1.2", note: "by hand"), .skip("t1.1", note: nil), .reopen("t2.1", note: "again"),
            .add(goal: "Run the tests", under: "t1", after: ["t1.1", "t1.2"]),
            .add(goal: "Tidy", under: nil, after: []),
        ] {
            #expect(try PlanEdit.parse(edit.words.split(separator: " ").map(String.init)) == edit)
        }
    }

    /// The caller's change is checked as the model's: no finishing ahead of what a task depends on.
    @Test func theCallersChangesAreToldAsTheCallersAndKeepEveryCheck() throws {
        let plan = try PlanTests.sample()
        #expect(throws: Plan.Failure.blocked(task: "t1.2", by: ["t1.1"])) {
            try PlanEdit.done("t1.2", note: nil).apply(to: plan, by: .caller, lastPrompt: 9, now: Self.now)
        }
        let skipped = try PlanEdit.skip("t1.2", note: nil).apply(to: plan, by: .caller, lastPrompt: 9, now: Self.now)
        #expect(skipped.details["by"] == .string("caller") && skipped.plan.untold == ["the caller: t1.2 skipped"])
    }

    @Test func theModelIsRefusedChangingThePlanAsThePerson() {
        let policy = CommandPolicy.default
        #expect(policy.check("wisp threads plan git done t1.2") != .allowed)
        #expect(policy.check("wisp threads plan git 'skip' t1.2 not needed") != .allowed)
        #expect(policy.check("/opt/homebrew/bin/wisp threads plan git add Do it") != .allowed)
        #expect(policy.check("wisp threads plan git reopen t1.1") != .allowed)
        #expect(policy.check("wisp threads plan git") == .allowed)
        #expect(policy.check("wisp threads plan git t1.2 --json") == .allowed)
    }
}
