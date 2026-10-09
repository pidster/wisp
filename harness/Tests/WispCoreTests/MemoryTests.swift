import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// `memory` (phase 4c of the layered-context proposal, widened 2026-09-30): the verb its one argument starts
/// with, the notes the model makes and the rules they keep (subject kinds, names, a bound per turn, the model's
/// precedence, proposals for permanent kinds), their audit, when a thread has the tool, and the prompt rule that
/// names it. `RecallTests` tests what a recall restores.
@Suite struct MemoryTests {
    @Test func theFirstWordIsTheVerbAndARequestWithoutOneIsARecall() {
        #expect(Memory.command("recall entry 7") == .recall("entry 7"))
        #expect(Memory.command("Recall: turn 3") == .recall("turn 3"))
        #expect(Memory.command("\"recall task\"") == .recall("task"))
        #expect(Memory.command("entry 7") == .recall("entry 7"))
        #expect(Memory.command("task") == .recall("task"))
        #expect(Memory.command("notes on the task") == .recall("notes on the task"))
        #expect(
            Memory.command("note entity release codename = BLUE HERON") == .note("entity release codename = BLUE HERON")
        )
        #expect(Memory.command("remember: tests ci = green") == .note("tests ci = green"))
        #expect(Memory.command("note x").action == "note" && Memory.command("x").action == "recall")
    }

    @Test func aNoteIsSubjectNameAndValueInTheFormsASmallModelWrites() {
        let codename = Memory.Note(subject: "entity", name: "release codename", value: "BLUE HERON")
        #expect(Memory.note("entity release codename = BLUE HERON") == codename)
        #expect(Memory.note("entity: release codename = \"BLUE HERON\"") == codename)
        #expect(Memory.note("Entity release codename: BLUE HERON") == codename)
        #expect(
            Memory.note("task: add --dry-run to harbour sync")
                == .init(subject: "task", name: "", value: "add --dry-run to harbour sync"))
        #expect(Memory.note("tests ci = green: all 40 pass")?.value == "green: all 40 pass")
        #expect(Memory.note("the codename is BLUE HERON") == nil)
        #expect(Memory.note("entity codename =  ") == nil)
        #expect(Memory.note("= BLUE HERON") == nil)
    }

    @Test func aNoteNamesAKindTheModelMayNoteAndIsTheModelsFact() throws {
        let kinds = SubjectKinds.defaults
        let noted = try Memory.assertion("entity Release Codename = BLUE HERON", kinds: kinds, turn: 3).get()
        #expect(noted.identity == FactIdentity(scope: .permanent, subject: "entity", name: "release codename"))
        #expect(noted.source == .model && noted.method == .noted && noted.temporalClass == .permanent)
        #expect(noted.value == "BLUE HERON" && noted.turn == 3 && noted.entries.isEmpty)
        let task = try Memory.assertion("task = add --dry-run", kinds: kinds, turn: 1).get()
        #expect(task.identity.name.isEmpty && task.temporalClass == .dynamic)
        let long = try Memory.assertion("decision db = " + String(repeating: "x", count: 500), kinds: kinds, turn: 1)
            .get()
        #expect(long.value.count <= Memory.valueCharacters + 1)
        // Unknown kinds, and the kinds tools fill, are refused with the kinds the model may use.
        let allowed = Memory.notable(kinds)
        #expect(allowed == ["task", "decision", "preference", "entity", "tests", "workdir", "branch"])
        #expect(
            Memory.assertion("weather today = rain", kinds: kinds, turn: 1)
                == .failure(.subject("weather", allowed: allowed)))
        #expect(
            Memory.assertion("file a.md = read", kinds: kinds, turn: 1) == .failure(.subject("file", allowed: allowed)))
        #expect(Memory.assertion("entity = BLUE HERON", kinds: kinds, turn: 1) == .failure(.name("entity")))
        #expect(Memory.assertion("BLUE HERON", kinds: kinds, turn: 1) == .failure(.shape))
        #expect(
            Memory.Refusal.subject("weather", allowed: ["task", "entity"]).description
                == "error: no subject weather to note; use one of task, entity, such as "
                + "note entity release codename = BLUE HERON")
    }

    @Test func theToolKeepsNotesForTheEndOfTheTurnBoundedAndAudited() async {
        let sink = MemoryAuditSink()
        let source = MemorySource()
        let tool = MemoryTool(source: source, audit: AuditLog(session: "s", sink: sink))
        source.publish(store: ThreadRecord(), facts: [], kinds: nil, turn: 1)
        #expect(await tool.call(arguments: .init(request: "note task = x")) == Memory.Refusal.off.description)
        source.publish(store: ThreadRecord(), facts: [], kinds: .defaults, turn: 2)
        #expect(
            await tool.call(arguments: .init(request: "note entity release codename = BLUE HERON"))
                == "noted: entity release codename = BLUE HERON (a proposal until the person keeps it)")
        #expect(await tool.call(arguments: .init(request: "note tests ci = green")) == "noted: tests ci = green")
        #expect(await tool.call(arguments: .init(request: "note the codename is X")).hasPrefix("error: write note"))
        for index in 3...Memory.notesPerTurn {
            _ = await tool.call(arguments: .init(request: "note decision d\(index) = yes"))
        }
        #expect(
            await tool.call(arguments: .init(request: "note decision over = no")) == Memory.Refusal.full.description)
        let notes = source.takeNotes()
        #expect(notes.count == Memory.notesPerTurn && notes.first?.turn == 2)
        #expect(source.takeNotes().isEmpty)
        let events = sink.events.filter { $0.kind == .memory }
        #expect(events.allSatisfy { Set($0.details.keys).isSubset(of: AuditEvent.fields(for: .memory)) })
        #expect(events[0].details["action"] == "note" && events[0].details["failure"] == "off")
        #expect(events[1].details["noted"] == true && events[1].details["subject"] == "entity")
        #expect(events[1].details["name"] == "release codename" && events[1].details["class"] == "permanent")
        #expect(events[3].details["noted"] == false && events[3].details["failure"] == "shape")
        #expect(events.last?.details["failure"] == "full")
    }

    @Test func aNotedFactIsRecordedWhenTheTurnEndsBelowThePersons() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        // memory is off by default (ADR 0057); this conversation turns it on, as the operator can.
        try Data(#"{"context": {"memory": true}}"#.utf8).write(to: home.configFile)
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let thread = try session.thread(id: "notes", approver: DenyingApprover(reason: "not in tests"))
        #expect(thread.tools.map(\.name).contains("memory") && thread.memory != nil)
        let model = ScriptedModel(steps: [
            .call(name: "memory", arguments: #"{"request":"note entity release codename = BLUE HERON"}"#),
            .call(name: "memory", arguments: #"{"request":"note tests ci = failing"}"#),
            .say("Noted."), .say("second"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        let reply = try await agent.respond(to: "The codename is BLUE HERON and CI is failing.")
        let codename = try #require(reply.facts.first { $0.identity.subject == "entity" })
        #expect(codename.source == .model && codename.method == .noted && codename.turn == 1)
        // A permanent kind's note stays with the conversation, a proposal until the person keeps it (D2).
        #expect(codename.identity.scope == .thread && codename.proposed)
        let recorded = sink.events.filter { $0.kind == .factRecorded }.map { $0.details["method"] }
        #expect(recorded.filter { $0 == "noted" }.count == 2)
        #expect(
            FactComposition.line(try #require(agent.factView.group(codename.identity.key)))
                == "- entity release codename: BLUE HERON — from model, noted, turn 1")
        // The person's word on the same thing outranks the model's note.
        try agent.stateFact(subject: "tests", name: "ci", value: "green")
        let ci = try #require(agent.factView.group(FactIdentity.Key(subject: "tests", name: "ci")))
        #expect(ci.winner.source == .person && ci.winner.value == "green")
        _ = try await agent.respond(to: "second")
    }

    @Test func aThreadHasMemoryWhenTheConfigTurnsItOnOrItsListNamesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        let deny = DenyingApprover(reason: "x")
        // Off by default (ADR 0057): registered, but not among the tools a conversation given every tool gets.
        #expect(ToolRegistry.builtInNames.last == "memory" && ToolRegistry().all.last?.name == "memory")
        #expect(Config().resolved.contextMemory == false && ConfigSettings.defaultValue("context.memory") == false)
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing())
        let off = try session.thread(id: "off", approver: deny)
        #expect(!off.tools.map(\.name).contains("memory") && off.memory == nil)
        #expect(off.tools.map(\.name) == ToolRegistry.builtInNames.filter { $0 != "memory" })
        // With context.memory on, every tool includes it, and the prompt carries its rule.
        try Data(#"{"context": {"memory": true}}"#.utf8).write(to: home.configFile)
        let on = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing())
        let all = try on.thread(id: "all", approver: deny)
        #expect(all.tools.map(\.name).contains("memory") && all.memory != nil)
        #expect(all.tools.map(\.name) == ToolRegistry.builtInNames)
        #expect(all.prompting.rendered(toolsAvailable: true, memory: true).contains(Prompting.memoryRule))
        // An explicit list is exactly that list whatever the setting: MCP's git thread keeps run_command alone,
        // and a list that names memory gets it with the setting off.
        let git = try session.thread(id: "git", approver: deny, tools: .named(["run_command"]))
        #expect(git.tools.map(\.name) == ["run_command"] && git.memory == nil)
        let named = try session.thread(id: "named", approver: deny, tools: .named(["read_file", "memory"]))
        #expect(named.tools.map(\.name) == ["read_file", "memory"] && named.memory != nil)
        let none = try session.thread(id: "quiet", approver: deny, tools: .none)
        #expect(none.tools.isEmpty && none.memory == nil)
        // The prompt carries the memory rule only for a conversation that has memory, and no bracket clause.
        #expect(Prompting.memoryRule.contains("memory") && Prompting.systemPrompt.hasSuffix(Prompting.memoryRule))
        #expect(!Prompting().rendered(toolsAvailable: true).contains("memory"))
        #expect(Prompting().rendered(toolsAvailable: true, memory: true).contains(Prompting.memoryRule))
        #expect(!Prompting().rendered(toolsAvailable: false, memory: true).contains("memory"))
        #expect(!Prompting.systemPrompt.contains("bracket"))
        // The description tells it from system_info's memory topic, the Mac's RAM.
        #expect(MemoryTool(source: MemorySource()).description.contains("not the Mac's RAM"))
    }

    @Test func disablingMemoryLeavesItOutOfEveryThread() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        // tools.disabled wins over context.memory: the tool is not registered at all.
        try Data(#"{"tools": {"disabled": ["memory"]}, "context": {"memory": true}}"#.utf8).write(to: home.configFile)
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing())
        let thread = try session.thread(id: "all", approver: DenyingApprover(reason: "x"))
        #expect(!thread.tools.map(\.name).contains("memory") && thread.memory == nil)
        #expect(!thread.tools.isEmpty)
        #expect(throws: Session.Failure.self) {
            try session.thread(id: "named", approver: DenyingApprover(reason: "x"), tools: .named(["memory"]))
        }
    }

    @Test func aDefaultConversationIsToldOfNoToolItDoesNotHave() async throws {
        // Named without the word, which the reference's arguments line would otherwise carry.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-recall-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "overview.md")
        let text = (1...40).map { "line \($0) of the overview, with words enough to make it long" }
        try Data((text.joined(separator: "\n") + "\n").utf8).write(to: file)
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing())
        let thread = try session.thread(id: "default", approver: DenyingApprover(reason: "not in tests"))
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("Forty lines."), .say("second"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        #expect(agent.memory == nil)
        _ = try await agent.respond(to: "Read \(file.path)")
        _ = try await agent.respond(to: "How long was it?")
        let requests = model.script.requests.withLock { $0 }
        let last = try #require(requests.last)
        // Neither the tool, the prompt's rule, nor a reference's recall hint: the reference says what it stands for
        // and how to see it again without memory.
        #expect(!last.enabledToolDefinitions.map(\.name).contains("memory"))
        let instructions = ThreadRecord.text(of: try #require(last.transcript.first))
        #expect(!instructions.contains(Prompting.memoryRule) && !instructions.contains("memory"))
        let output = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        let reference = ThreadRecord.text(of: try #require(last.transcript.first { $0.id == output.value.id }))
        #expect(reference.hasPrefix("[output of entry \(output.id) not repeated: read_file at "))
        #expect(reference.contains("; call it again to see it]") && !reference.contains("memory"))
    }
}
