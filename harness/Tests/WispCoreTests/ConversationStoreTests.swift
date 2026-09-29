import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The conversation store, the composer, and the audit ids the store refers to (layered-context proposal,
/// phase 2). `ContextEquivalenceTests` proves the agent over them behaves as before; these pin the parts.
@Suite struct ConversationStoreTests {
    private func text(_ s: String) -> Transcript.Segment { .text(.init(content: s)) }
    private func prompt(_ s: String) -> Transcript.Entry { .prompt(.init(segments: [text(s)])) }
    private func response(_ s: String) -> Transcript.Entry { .response(.init(assetIDs: [], segments: [text(s)])) }
    private var instructions: Transcript.Entry {
        .instructions(.init(segments: [text("be brief")], toolDefinitions: []))
    }

    @Test func auditEventsCarryFreshIdsThatTheLogReturns() throws {
        let sink = MemoryAuditSink()
        let log = AuditLog(session: "s", sink: sink)
        log.beginTurn()
        let first = log.record(.prompt, details: ["text": "hi"])
        let second = log.record(.response)
        #expect(first != second)
        #expect(sink.events.map(\.id) == [first.event, second.event])
        #expect(first == AuditReference(session: "s", turn: 1, event: first.event))
        #expect(first.event.count == 16 && first.event.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // The id survives the file format, and a line written before ids decodes without one.
        let line = try AuditEvent.encoder.encode(try #require(sink.events.first))
        #expect(try AuditEvent.decoder.decode(AuditEvent.self, from: line).id == first.event)
        let old =
            #"{"schema":1,"time":"2026-09-29T10:00:00.000Z","version":"0.14.1","pid":1,"session":"s","kind":"prompt","details":{}}"#
        let decoded = try AuditEvent.decoder.decode(AuditEvent.self, from: Data(old.utf8))
        #expect(decoded.id == nil && AuditReference(decoded).event.isEmpty)
    }

    @Test func theToolTrailKeepsToolEventsOfATurnWithinItsBound() {
        let trail = ToolEventTrail(capacity: 2)
        for (turn, kind) in [(1, AuditEvent.Kind.toolCall), (1, .prompt), (2, .toolCall), (2, .toolResult)] {
            trail.write(AuditEvent(session: "s", kind: kind, turn: turn))
        }
        // Capacity two keeps the newest two tool events: turn 1's call is gone, the prompt never came in.
        #expect(trail.take(turn: 1).isEmpty)
        #expect(trail.take(turn: 2).map(\.kind) == [.toolCall, .toolResult])
        #expect(trail.take(turn: 2).isEmpty)
    }

    @Test func aStoreCarriesRecordsAndDropsWithoutForgetting() {
        let entries = [instructions, prompt("p1"), response("r1"), prompt("p2"), response("r2")]
        var store = ConversationStore(carrying: Transcript(entries: entries))
        #expect(store.entries.map(\.id) == [1, 2, 3, 4, 5])
        #expect(store.entries.map(\.kind) == [.instructions, .prompt, .response, .prompt, .response])
        #expect(store.entries.allSatisfy { $0.origin == .carried && $0.sources.isEmpty && $0.turn == nil })
        // Recording an entry the store holds changes nothing.
        store.record(entries[1], origin: .turn, turn: 9, sources: [])
        #expect(store.entries.count == 5)
        let reference = AuditReference(session: "s", turn: 3, event: "abc")
        let asked = prompt("p3")
        store.record(asked, origin: .turn, turn: 3, sources: [reference])
        #expect(store.entries.last?.origin == .turn && store.entries.last?.sources == [reference])
        let condensed = store.active.condensed(keepTurns: 1)
        store.retain(condensed, droppedBy: reference)
        #expect(store.active.map(\.id) == condensed.map(\.id))
        #expect(store.entries.count == 6)
        #expect(store.entries.map(\.state).filter { $0 == .dropped(by: reference) }.count == 4)
        #expect(store.entries[0].state == .active && store.entries[5].state == .active)
        #expect(store.contains(asked) && !store.contains(prompt("never stored")))
        #expect(ConversationStore().active.isEmpty)
    }

    @Test func sourcesLinkPromptsRepliesAndToolActivityToTheirEvents() throws {
        func event(_ kind: AuditEvent.Kind, call: String, tool: String, arguments: String? = nil) -> AuditEvent {
            var details: [String: JSONValue] = ["tool": .string(tool)]
            if let arguments { details["arguments"] = .string(arguments) }
            return AuditEvent(session: "s", kind: kind, turn: 1, call: call, details: details)
        }
        let arguments = try GeneratedContent(json: #"{"path":"a"}"#)
        let call = Transcript.ToolCall(id: "c1", toolName: "read_file", arguments: arguments)
        // A first attempt that overflowed ran the same call; the retry's events come later and win.
        let events = [
            event(.toolCall, call: "old", tool: "read_file", arguments: arguments.jsonString),
            event(.toolResult, call: "old", tool: "read_file"),
            event(.toolCall, call: "new", tool: "read_file", arguments: arguments.jsonString),
            event(.toolResult, call: "new", tool: "read_file"),
        ]
        let entries: [Transcript.Entry] = [
            prompt("read a"), response("let me look"), .toolCalls(.init([call])),
            .toolOutput(.init(id: "c1", toolName: "read_file", segments: [text("contents")])), response("done"),
        ]
        let asked = AuditReference(session: "s", turn: 1, event: "p")
        let replied = AuditReference(session: "s", turn: 1, event: "r")
        let sources = ConversationStore.sources(for: entries, prompt: asked, response: replied, toolEvents: events)
        #expect(sources[0] == [asked])
        #expect(sources[1].isEmpty)  // text before a tool call is in no event of its own
        #expect(sources[2] == [AuditReference(events[2])])
        #expect(sources[3] == [AuditReference(events[3])])
        #expect(sources[4] == [replied])
        // A failed turn has no response; a call no event matches has no sources; without arguments in the
        // event, the tool's name is enough.
        let other = Transcript.ToolCall(id: "c2", toolName: "notify", arguments: arguments)
        let bare = event(.toolCall, call: "k", tool: "read_file")
        let failed = ConversationStore.sources(
            for: [prompt("x"), .toolCalls(.init([other, call])), response("partial")], prompt: asked, response: nil,
            toolEvents: [bare])
        #expect(failed[1] == [AuditReference(bare)] && failed[2].isEmpty)
    }

    @Test func theComposerCondensesAheadOnlyPastTheBudgetAndWhenATurnWouldGo() {
        let entries = [instructions, prompt("p1"), response("r1"), prompt("p2"), response("r2")]
        let store = ConversationStore(carrying: Transcript(entries: entries))
        let composer = ContextComposer(policy: .condense(keepTurns: 1))
        #expect(composer.compose(store).map(\.id) == entries.map(\.id))
        #expect(composer.condensesAhead && !ContextComposer(policy: .failFast).condensesAhead)
        // 40 used + 12 bytes / 4 = 43 of 50 passes 85%; 30 used does not; nothing used says nothing.
        let ahead = composer.ahead(of: "twelve bytes", in: store, used: 40, window: 50)
        #expect(ahead?.estimate == 43 && ahead?.before.turnCount == 2 && ahead?.after.turnCount == 1)
        #expect(composer.ahead(of: "twelve bytes", in: store, used: 30, window: 50) == nil)
        #expect(composer.ahead(of: "twelve bytes", in: store, used: 0, window: 50) == nil)
        // Keeping as many turns as there are would not shrink it, so there is nothing to do ahead...
        let keeping = ContextComposer(policy: .condense(keepTurns: 2))
        #expect(keeping.ahead(of: "twelve bytes", in: store, used: 40, window: 50) == nil)
        // ...but an overflow still rebuilds, to shed the failed attempt; fail-fast never condenses.
        #expect(keeping.overflow(in: store)?.after.turnCount == 2)
        #expect(ContextComposer(policy: .failFast).overflow(in: store) == nil)
        #expect(ContextComposer(policy: .failFast).ahead(of: "x", in: store, used: 99, window: 10) == nil)
    }

    @Test func anAgentOpenedThroughAConversationLinksItsStoreToTheAuditAndKeepsItAcrossASwitch() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        let file = dir.appending(path: "a.txt")
        try Data("alpha\n".utf8).write(to: file)
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let conversation = try session.conversation(
            id: "t", approver: DenyingApprover(reason: "not in tests"), tools: .named(["read_file"]))
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("it says {tool}"), .say("two"),
        ])
        let agent = try conversation.openAgent(
            on: ResolvedModel(selection: .system, custom: model), transcript: nil)
        _ = try await agent.respond(to: "read it")
        let byID = Dictionary(sink.events.compactMap { event in event.id.map { ($0, event) } }) { first, _ in first }
        let turn = agent.store.entries.filter { $0.origin == .turn }
        #expect(turn.map(\.kind) == [.prompt, .toolCalls, .toolOutput, .response])
        #expect(turn.allSatisfy { $0.turn == 1 && $0.sources.count == 1 })
        let kinds = turn.compactMap { $0.sources.first.flatMap { byID[$0.event]?.kind } }
        #expect(kinds == [.prompt, .toolCall, .toolResult, .response])
        #expect(byID[turn[2].sources[0].event]?.details["output"]?.stringValue?.contains("alpha") == true)
        // A condensation marks what it dropped with its own event; the store keeps the entries.
        let windowed = Agent(
            store: agent.store, tools: agent.tools,
            model: ResolvedModel(selection: .system, custom: model, contextSize: 10),
            contextPolicy: .condense(keepTurns: 0), audit: conversation.audit)
        _ = try await windowed.respond(to: "a prompt long enough to pass the budget")
        let condensation = try #require(sink.events.last { $0.kind == .condensation })
        #expect(windowed.store.entries.count == agent.store.entries.count + 2)
        #expect(
            windowed.store.entries.filter { $0.state == .dropped(by: AuditReference(condensation)) }.map(\.kind)
                == [.prompt, .toolCalls, .toolOutput, .response])
        #expect(windowed.transcript.turnCount == 1)
        // A reset starts a new store over the instructions alone.
        windowed.reset()
        #expect(windowed.store.entries.map(\.kind) == [.instructions])
    }
}
