import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// `memory`'s recall (phase 4c of the layered-context proposal): what the words after `recall` name, what it
/// restores and from where (the audit log, else the store's copy), its pages, the references that name it, its
/// audit, and a recall ageing out after its turn. `MemoryTests` tests the verbs, notes, and registration.
@Suite struct RecallTests {
    /// A prompt entry.
    static func prompt(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(.init(content: text))]))
    }

    /// A reply entry.
    static func response(_ text: String) -> Transcript.Entry {
        .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))]))
    }

    /// A tool output entry.
    static func output(_ text: String, tool: String = "read_file") -> Transcript.Entry {
        .toolOutput(
            Transcript.ToolOutput(id: UUID().uuidString, toolName: tool, segments: [.text(.init(content: text))]))
    }

    /// A store of `entries`, each of `turn`, with `sources`.
    static func store(_ entries: [(Transcript.Entry, Int, [AuditReference])]) -> ThreadRecord {
        ThreadRecord(
            entries: entries.enumerated().map { index, item in
                ThreadRecord.Entry(
                    id: index + 1, kind: ThreadRecord.Kind(item.0), origin: .turn, turn: item.1, sources: item.2,
                    state: .active, value: item.0)
            })
    }

    /// A fact.
    static func fact(
        _ id: String, subject: String, name: String = "", value: String, source: FactSource = .tool,
        state: Fact.State = .current, by: String? = nil, entries: [Int] = [], turn: Int = 1, at seconds: Double = 0
    ) -> Fact {
        Fact(
            id: id, identity: FactIdentity(scope: .thread, subject: subject, name: name), source: source, version: 1,
            value: value, temporalClass: .dynamic, method: source == .tool ? .extracted : .stated,
            detail: source == .tool ? "run_command" : nil, entries: entries, audit: [],
            recorded: Date(timeIntervalSince1970: 1_000_000 + seconds), turn: turn, supersededBy: by, state: state)
    }

    static let utc = TimeZone(identifier: "UTC") ?? .current

    @Test func theArgumentIsReadLeniently() {
        #expect(Recall.target("entry 7") == .entry(7))
        #expect(Recall.target(" 7 ") == .entry(7))
        #expect(Recall.target("output of entry 12.") == .entry(12))
        #expect(Recall.target("Turn 3") == .turn(3))
        #expect(Recall.target("task") == .task)
        #expect(Recall.target("the task in full") == .task)
        #expect(Recall.target("summary") == .summary)
        #expect(Recall.target("earlier summary versions") == .summary)
        #expect(Recall.target("c12") == .fact("c12"))
        #expect(Recall.target("fact s3") == .fact("s3"))
        #expect(Recall.target("fact tests") == .fact("tests"))
        #expect(Recall.target("facts") == .fact(""))
        #expect(Recall.target("\"codename\"") == .fact("codename"))
        #expect(Recall.target("CI build") == .fact("ci build"))
        // A later page is named in the same argument, as the end of a page spells it.
        #expect(Recall.request("entry 4 from line 60") == (.entry(4), 60, "entry 4", .none))
        #expect(Recall.request("turn 2, starting at line 9") == (.turn(2), 9, "turn 2", .none))
        #expect(Recall.request("summary") == (.summary, 1, "summary", .none))
        // A stored output by the id a held-back note names, and the filters, with a later page after them.
        #expect(Recall.target("output 3f9a2c1b") == .output("3f9a2c1b"))
        #expect(Recall.target("output 7") == .entry(7))
        #expect(
            Recall.request("output 3f9a2c1b matching error: from line 3") == (
                .output("3f9a2c1b"), 3, "output 3f9a2c1b", .matching("error:")
            ))
        #expect(Recall.request("entry 7 lines 100-200") == (.entry(7), 1, "entry 7", .lines(100, 200)))
        #expect(Recall.request("entry 7 head 20") == (.entry(7), 1, "entry 7", .head(20)))
        #expect(Recall.request("entry 7, last 5 lines") == (.entry(7), 1, "entry 7", .tail(5)))
        #expect(Recall.Filter.matching("x").phrase == " matching x" && Recall.Filter.none.phrase.isEmpty)
    }

    @Test func filtersNumberTheLinesTheyKeepAndSayHowMany() {
        let lines = (1...50).map { "line \($0)" + ($0 % 10 == 0 ? " error here" : "") }
        let matched = Recall.Filter.matching("ERROR").apply(to: lines)
        #expect(matched.lines == [10, 20, 30, 40, 50].map { "\($0): line \($0) error here" })
        #expect(matched.note == "5 of 50 lines matching ERROR")
        let literal = Recall.Filter.matching("line 1(").apply(to: lines)
        #expect(literal.lines.isEmpty && literal.note == "0 of 50 lines containing line 1(")
        let range = Recall.Filter.lines(48, 90).apply(to: lines)
        #expect(
            range.lines == ["48: line 48", "49: line 49", "50: line 50 error here"] && range.note == "lines 48-50 of 50"
        )
        #expect(Recall.Filter.lines(60, 70).apply(to: lines).note == "no lines 60-70: it has 50 lines")
        #expect(Recall.Filter.head(2).apply(to: lines).lines == ["1: line 1", "2: line 2"])
        #expect(Recall.Filter.tail(1).apply(to: lines).lines == ["50: line 50 error here"])
        let material = Recall.Material(header: "h", lines: lines, found: true)
        let filtered = Recall.filtered(material, by: .head(3))
        #expect(filtered.header == "h; the first 3 of 50 lines" && filtered.lines.count == 3)
        #expect(Recall.filtered(material, by: .none) == material)
    }

    @Test func anEntryComesFromTheAuditLogAndElseFromTheStore() {
        let result = AuditEvent(
            session: "s", kind: .toolResult, turn: 2, details: ["output": "1\tfirst\n2\tsecond from the audit"])
        let reference = AuditReference(result)
        let store = Self.store([
            (Self.prompt("read it"), 2, []), (Self.output("1\tfirst\n2\tsecond"), 2, [reference]),
            (Self.response("It has two lines."), 2, []),
        ])
        let material = MemorySource.Material(store: store, facts: [])
        let read = { (wanted: AuditReference) in wanted == reference ? result : nil }
        let audited = Recall.material(.entry(2), in: material, read: read, timeZone: Self.utc)
        #expect(audited.found && audited.from == "audit" && audited.entries == [2])
        #expect(audited.events == [result.id ?? ""])
        #expect(audited.header == "entry 2: read_file output, turn 2, from the audit log")
        #expect(audited.lines == ["1\tfirst", "2\tsecond from the audit"])
        // With the event gone (rotated out, or the audit off), the store's copy serves, and says so.
        let copied = Recall.material(.entry(2), in: material, read: { _ in nil }, timeZone: Self.utc)
        #expect(copied.from == "store" && copied.lines == ["1\tfirst", "2\tsecond"])
        #expect(copied.header.hasSuffix("from the conversation's store"))
        // A reply without a reference (text before a tool call) is the store's.
        let reply = Recall.material(.entry(3), in: material, read: read)
        #expect(reply.header.hasPrefix("entry 3: reply, turn 2") && reply.lines == ["It has two lines."])
        // An entry the store does not hold says what it does hold.
        let missing = Recall.material(.entry(9), in: material, read: read)
        #expect(!missing.found && missing.header.contains("entries run from 1 to 3"))
        #expect(Recall.page(missing, what: "entry 9", offset: 1) == missing.header)
        // An event of another kind under the reference is not taken for the content.
        let wrong = AuditEvent(session: "s", kind: .prompt, turn: 2, details: ["text": "not the output"])
        let mismatched = Recall.material(.entry(2), in: material, read: { _ in wrong })
        #expect(mismatched.from == "store")
    }

    @Test func aTurnGathersItsEntriesInOrder() {
        let store = Self.store([
            (Self.prompt("first"), 1, []), (Self.response("one"), 1, []), (Self.prompt("read"), 2, []),
            (Self.output("the output"), 2, []), (Self.response("two"), 2, []),
        ])
        let found = Recall.material(.turn(2), in: .init(store: store, facts: []), read: { _ in nil })
        #expect(found.header == "turn 2: entries 3-5, from the conversation's store")
        #expect(
            found.lines == [
                "[entry 3, prompt]", "read", "[entry 4, read_file output]", "the output", "[entry 5, reply]", "two",
            ])
        #expect(found.entries == [3, 4, 5])
        let none = Recall.material(.turn(7), in: .init(store: store, facts: []), read: { _ in nil })
        #expect(!none.found && none.header.contains("turns run from 1 to 2"))
    }

    @Test func toolCallsTheAuditDoesNotHoldComeFromTheStore() throws {
        let call = Transcript.ToolCall(
            id: "c1", toolName: "read_file", arguments: try GeneratedContent(json: #"{"path":"a.md"}"#))
        let store = Self.store([(Self.prompt("read a.md"), 1, []), (.toolCalls(.init([call])), 1, [])])
        let found = Recall.material(.entry(2), in: .init(store: store, facts: []), read: { _ in nil })
        #expect(found.header == "entry 2: tool calls, turn 1, from the conversation's store")
        #expect(found.lines.first?.hasPrefix("read_file {") == true)
    }

    @Test func theTaskHasItsVersionsAndTheFirstPrompt() {
        let store = Self.store([(Self.prompt("We are adding --dry-run. The codename is BLUE HERON."), 1, [])])
        let facts = [
            Self.fact("c1", subject: "task", value: "add a flag", source: .person, state: .superseded, by: "c4"),
            Self.fact("c4", subject: "task", value: "add --dry-run to harbour sync", source: .person, at: 60),
            Self.fact("c2", subject: "tests", name: "ci", value: "failing"),
        ]
        let found = Recall.material(
            .task, in: .init(store: store, facts: facts), read: { _ in nil }, timeZone: Self.utc)
        #expect(found.found && found.facts == ["c1", "c4"] && found.entries == [1])
        #expect(found.lines[0] == "2 versions, oldest first:")
        #expect(found.lines[1] == "- c1 [the person], turn 1 at 13:46:40: add a flag; superseded by c4")
        #expect(found.lines[2].hasSuffix("add --dry-run to harbour sync; current"))
        #expect(found.lines[3] == "The conversation began with entry 1, turn 1:")
        #expect(found.lines[4].contains("BLUE HERON"))
        // Without a task fact, the first prompt still answers.
        let bare = Recall.material(.task, in: .init(store: store, facts: []), read: { _ in nil })
        #expect(bare.lines.first == "No task has been set or inferred." && bare.entries == [1])
        // Before anything is stored, every target says the first turn is all in view, not that there is no task.
        let empty = Recall.material(.task, in: .init(store: ThreadRecord(), facts: []), read: { _ in nil })
        #expect(!empty.found && empty.header == Recall.nothingEarlier)
        #expect(Recall.material(.entry(1), in: .init(store: ThreadRecord(), facts: []), read: { _ in nil }) == empty)
    }

    @Test func aFactsHistoryAndSourcesAreFoundByIdOrByWords() {
        let facts = [
            Self.fact("c2", subject: "tests", name: "ci", value: "failing", state: .superseded, by: "c9", entries: [5]),
            Self.fact("c9", subject: "tests", name: "ci", value: "green", entries: [30], turn: 11, at: 300),
            Self.fact(
                "c3", subject: "entity", name: "blue heron", value: "the release codename", source: .model,
                entries: [2, 3]),
        ]
        let material = MemorySource.Material(store: ThreadRecord(), facts: facts)
        let byID = Recall.material(.fact("c9"), in: material, read: { _ in nil }, timeZone: Self.utc)
        #expect(byID.header == "fact \"c9\": 1 subject" && byID.facts == ["c2", "c9"])
        #expect(byID.lines[0] == "tests ci: 2 versions, oldest first:")
        #expect(byID.lines[1] == "- c2 [tool run_command, turn 1, entry 5] at 13:46:40: failing; superseded by c9")
        #expect(byID.lines[2] == "- c9 [tool run_command, turn 11, entry 30] at 13:51:40: green; current")
        #expect(byID.lines.last == "memory \"recall entry N\" shows what a fact came from.")
        #expect(Recall.material(.fact("ci"), in: material, read: { _ in nil }).facts == ["c2", "c9"])
        #expect(Recall.material(.fact("codename"), in: material, read: { _ in nil }).facts == ["c3"])
        #expect(Recall.material(.fact("BLUE HERON"), in: material, read: { _ in nil }).facts == ["c3"])
        #expect(Recall.matching("release", in: facts).map(\.subject) == ["entity"])
        // Part of a name, then a shared word, when nothing closer matches.
        #expect(Recall.matching("blue", in: facts).map(\.subject) == ["entity"])
        #expect(Recall.matching("heron release notes", in: facts).map(\.subject) == ["entity"])
        // No match, or no query, lists what is known.
        let none = Recall.material(.fact("weather"), in: material, read: { _ in nil })
        #expect(!none.found && none.header.contains("known: entity blue heron; tests ci"))
        #expect(!Recall.material(.fact(""), in: material, read: { _ in nil }).found)
    }

    @Test func theSummaryHasItsVersionsNewestFirst() {
        var store = ThreadRecord()
        #expect(!Recall.material(.summary, in: .init(store: store, facts: []), read: { _ in nil }).found)
        for version in 1...2 {
            store.summarise(
                RunningSummary(
                    version: version, text: "summary \(version)", covered: version * 4, turns: [1, 2, 3, 4],
                    entries: [], audit: [], through: 10, recorded: Date(), turn: 13, model: "system"))
        }
        let found = Recall.material(.summary, in: .init(store: store, facts: []), read: { _ in nil })
        #expect(found.header == "summary: 2 versions, newest first" && found.summaries == [2, 1])
        #expect(
            found.lines == [
                "- v2 of 8 turns, added turns 1-4, written at turn 13 by system:", "summary 2",
                "- v1 of 4 turns, added turns 1-4, written at turn 13 by system:", "summary 1",
            ])
    }

    @Test func pagesAreBoundedAndSayWhereTheNextStarts() {
        let lines = (1...200).map { "line \($0) " + String(repeating: "x", count: 60) }
        let material = Recall.Material(header: "entry 4: read_file output", lines: lines, found: true, entries: [4])
        let first = Recall.page(material, what: "entry 4", offset: 1)
        let firstLines = first.split(separator: "\n").map(String.init)
        #expect(firstLines.first == "entry 4: read_file output")
        #expect(first.utf8.count <= Recall.pageBytes + 200)
        // Lines 1 to 9 take 68 bytes with their newlines and later ones 69: 59 lines fill 4,062 of 4,096 bytes.
        #expect(firstLines.count == 1 + 59 + 1)
        #expect(firstLines.last == "[more: memory \"recall entry 4 from line 60\"]")
        #expect(firstLines[firstLines.count - 2].hasPrefix("line 59 "))
        #expect(Recall.page(material, what: "entry 4", offset: 60).split(separator: "\n")[1].hasPrefix("line 60 "))
        let last = Recall.page(material, what: "entry 4", offset: 195)
        #expect(last.hasSuffix("[end of what recall found]") && last.contains("line 200 "))
        #expect(Recall.page(material, what: "entry 4", offset: 900).hasSuffix("[no line 900: it has 200 lines]"))
        // A single line longer than a page is cut, not dropped.
        let long = Recall.Material(header: "h", lines: [String(repeating: "y", count: 9000)], found: true)
        #expect(Recall.page(long, what: "x", offset: 1).utf8.count < Recall.pageBytes + 200)
    }

    @Test func anAgentWithoutMemorySaysSoAndReferencesKeepTheRerunHint() async throws {
        let tool = MemoryTool(source: MemorySource())
        #expect(await tool.call(arguments: .init(request: "recall entry 1")).hasPrefix("error: nothing in memory"))
        let time = Date(timeIntervalSince1970: 0)
        let page = (1...40).map { "\($0)\tsome line of text long enough" }.joined(separator: "\n")
        #expect(
            OutputReference.text(tool: "read_file", entry: 3, time: time, arguments: nil, output: page)
                .contains("; call it again to see it]"))
        #expect(
            OutputReference.text(
                tool: "read_file", entry: 3, time: time, arguments: nil, output: page, recallable: true
            )
            .contains("; to see it: memory \"recall entry 3\"]"))
    }

    @Test func theModelRecallsAnEarlierOutputThatThenAgesOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "overview.md")
        let text = (1...40).map { "line \($0) of the overview, with words enough to make it long" }
        try Data((text.joined(separator: "\n") + "\n").utf8).write(to: file)
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let thread = try session.thread(
            id: "recall", approver: DenyingApprover(reason: "not in tests"), tools: .named(["read_file", "memory"]))
        #expect(thread.tools.map(\.name) == ["read_file", "memory"])
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("Forty lines."),
            .call(name: "memory", arguments: #"{"request":"recall entry 4"}"#), .say("Line 7 says: {tool}"),
            .say("third"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        #expect(agent.memory != nil)
        _ = try await agent.respond(to: "Read \(file.path)")
        let output = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        #expect(output.id == 4)  // after the instructions, the prompt, and the tool call
        let reply = try await agent.respond(to: "What exactly does line 7 say?").text
        // The reference in the second turn's first request names memory, and the recall restored the output from
        // the audit log in full.
        let requests = model.script.requests.withLock { $0 }
        let referenced = try #require(requests[2].transcript.first { $0.id == output.value.id })
        #expect(ThreadRecord.text(of: referenced).contains("; to see it: memory \"recall entry 4\"]"))
        #expect(reply.contains("entry 4: read_file output, turn 1") && reply.contains("from the audit log"))
        #expect(reply.contains("line 7 of the overview") && reply.contains("[end of what recall found]"))
        let event = try #require(sink.events.first { $0.kind == .memory })
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .memory)))
        #expect(event.details["request"] == "recall entry 4" && event.details["action"] == "recall")
        #expect(event.details["target"] == "entry")
        #expect(event.details["found"] == true && event.details["from"] == "audit")
        #expect(event.details["entries"] == .array([.int(4)]) && event.turn == 2)
        #expect(event.details["events"] == .array([.string(output.sources.first?.event ?? "")]))
        // After its turn the recalled text is itself a reference, not repeated in full.
        _ = try await agent.respond(to: "third")
        let recalled = try #require(agent.store.entries.last { $0.kind == .toolOutput })
        let last = try #require(model.script.requests.withLock { $0 }.last)
        let carried = try #require(last.transcript.first { $0.id == recalled.value.id })
        #expect(ThreadRecord.text(of: carried).hasPrefix("[output of entry \(recalled.id) not repeated: memory at "))
        #expect(ThreadRecord.text(of: carried).contains(#"arguments: {"request": "recall entry 4"}"#))
        // A whole turn comes from the audit log, tool calls included; the instructions are not repeated; and a
        // conversation that condensed nothing has no summary yet.
        let tool = MemoryTool(source: try #require(agent.memory), audit: thread.audit)
        let turn = await tool.call(arguments: .init(request: "recall turn 1"))
        #expect(turn.hasPrefix("turn 1: entries 2-5, from the audit log"))
        #expect(turn.contains("[entry 3, tool calls]\nread_file {"))
        #expect(
            turn.contains("[entry 2, prompt]\nRead \(file.path)") && turn.contains("[entry 5, reply]\nForty lines."))
        #expect(await tool.call(arguments: .init(request: "entry 1")).contains("which every request carries in full"))
        #expect(await tool.call(arguments: .init(request: "recall summary")).hasPrefix("memory: no summary has been"))
    }
}
