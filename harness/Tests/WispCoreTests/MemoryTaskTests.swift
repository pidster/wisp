import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// `memory`'s `task` verb (phase 4d of the layered-context proposal, D6): the model proposes the task and its
/// objective as its own fact, recorded when the turn ends, never replacing the person's or a caller's; `task` alone
/// and `recall task` still recall it. `MemoryTests` tests the other verbs.
@Suite struct MemoryTaskTests {
    @Test func taskWithTextIsTheVerbAndTaskAloneStillRecalls() {
        #expect(Memory.command("task fix the build") == .task("fix the build"))
        #expect(
            Memory.command("Task: fix the build; objective: it passes") == .task("fix the build; objective: it passes"))
        #expect(Memory.command("task") == .recall("task"))
        #expect(Memory.command("recall task") == .recall("task"))
        #expect(Memory.command("task fix").action == "task")
    }

    /// A published copy with `facts`, keeping facts.
    static func material(_ facts: [Fact] = []) -> MemorySource.Material {
        MemorySource.Material(
            store: ThreadRecord(carrying: Transcript(entries: [])), facts: facts, kinds: .defaults, turn: 4)
    }

    @Test func theTaskIsTheModelsAndItsObjectiveIsKeptBesideIt() throws {
        let task = try Memory.task("fix the CI build. Objective: swift test passes", in: Self.material()).get()
        #expect(task.identity == FactIdentity(scope: .thread, subject: "task", name: ""))
        #expect(task.source == .model && task.method == .noted && task.turn == 4)
        #expect(task.value == "fix the CI build; objective: swift test passes")
        #expect(try Memory.task("\"tidy the docs\"", in: Self.material()).get().value == "tidy the docs")
        #expect(Memory.task("objective: nothing", in: Self.material()) == .failure(.taskShape))
        var off = Self.material()
        off.kinds = nil
        #expect(Memory.task("fix", in: off) == .failure(.off))
    }

    @Test func thePersonsOrACallersTaskIsNeverReplaced() {
        for source in [FactSource.person, .caller] {
            let pinned = Fact(
                id: "c1", identity: FactIdentity(scope: .thread, subject: "task", name: ""), source: source, version: 1,
                value: "fix the CI build", temporalClass: .dynamic, method: .stated, detail: nil, entries: [],
                audit: [], recorded: Date(), turn: 1, supersededBy: nil, state: .current, approved: nil)
            let refusal = Memory.task("something else", in: Self.material([pinned]))
            #expect(refusal == .failure(.pinned("fix the CI build")))
            if case .failure(let reason) = refusal {
                #expect(reason.description == "error: the person set the task, and it stays: fix the CI build")
                #expect(reason.reason == "pinned")
            }
        }
    }

    @Test func aProposedTaskIsRecordedWhenTheTurnEndsAndAudited() async throws {
        let model = ScriptedModel(steps: [
            .call(
                name: "memory", arguments: #"{"request":"task add a --dry-run flag; objective: it prints the plan"}"#),
            .say("Noted."),
            .call(name: "memory", arguments: #"{"request":"task something else"}"#),
            .say("Fine."),
        ])
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "task", sink: sink)
        let source = MemorySource()
        let agent = Agent(
            instructions: "You are wisp.", tools: ToolRegistry(audit: audit, memory: source).select(["memory"]).tools,
            model: ResolvedModel(selection: .system, custom: model), audit: audit)
        agent.facts = FactSettings()
        agent.memory = source
        let reply = try await agent.respond(to: "Let us add a dry-run flag")
        let task = try #require(agent.taskHistory.last)
        #expect(
            task.source == .model && task.method == .noted
                && task.value == "add a --dry-run flag; objective: it prints the plan")
        #expect(reply.facts.map(\.id) == [task.id])
        // Once the person states the task, a later proposal is refused.
        let pinned = try agent.setTask("fix the CI build")
        _ = try await agent.respond(to: "carry on")
        #expect(agent.factView.group(Agent.taskKey)?.winner.id == pinned.id)
        let events = sink.events.filter { $0.kind == .memory }
        #expect(events.allSatisfy { Set($0.details.keys).isSubset(of: AuditEvent.fields(for: .memory)) })
        #expect(events.map { $0.details["action"]?.stringValue } == ["task", "task"])
        #expect(events[0].details["noted"] == true && events[0].details["value"] == .string(task.value))
        #expect(events[1].details["noted"] == false && events[1].details["failure"] == "pinned")
    }
}
