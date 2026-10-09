import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Tool output as a structured reference after its turn (decision D12 of the layered-context proposal,
/// phase 3b): the reference's text and notes, the composer's switch, the agent's once-per-turn change and
/// its audit, a resumed conversation composing the same references, and the context of an earlier turn
/// composed again from the store.
@Suite struct OutputReferenceTests {
    /// A page of a file as `read_file` renders it.
    static let page =
        (1...40).map { "\($0)\tline \($0) of the overview, with some words to make it long" }
        .joined(separator: "\n") + "\n[end of file]"

    @Test func notesAreMechanical() {
        let rendered = "exit status: 1\nstdout:\nBuilding\nCompiling 3 files\nstderr:\nerror: no such module"
        let command = OutputReference.notes(on: rendered, tool: "run_command")
        #expect(command.status == "exit status 1")
        #expect(command.first == "Building" && command.last == "error: no such module")
        #expect(command.lines == 6 && command.bytes == rendered.utf8.count)
        let failed = OutputReference.notes(on: "error: file not found: /x", tool: "read_file")
        #expect(failed.status == "failed" && failed.first == "error: file not found: /x" && failed.last == nil)
        let file = OutputReference.notes(on: Self.page, tool: "read_file")
        #expect(file.status == "ok" && file.lines == 41 && file.more == nil)
        #expect(file.last?.hasPrefix("40\tline 40 of the overview") == true)
        #expect(file.first?.hasPrefix("1\tline 1 of the overview") == true)
        let empty = OutputReference.notes(on: "", tool: "notify")
        #expect(empty.first == nil && empty.last == nil && empty.lines == 1 && empty.bytes == 0)
        // A command that printed nothing has only its status.
        #expect(OutputReference.notes(on: "exit status: 0", tool: "run_command").first == nil)
    }

    @Test func aPagingHintIsNotTheLastLineAndIsKeptApart() {
        let page = (1...3).map { "\($0)\tline \($0)" }.joined(separator: "\n") + "\n[more: call again with offset 94]"
        let notes = OutputReference.notes(on: page, tool: "read_file")
        #expect(notes.first == "1\tline 1" && notes.last == "3\tline 3" && notes.more == "more from offset 94")
        #expect(notes.lines == 4)
        let text = OutputReference.text(tool: "read_file", entry: 2, time: nil, arguments: nil, output: page)
        #expect(text.contains("last line: 3\tline 3") && text.hasSuffix("paging: more from offset 94"))
        #expect(!text.contains("[more:"))
    }

    @Test func aBoundedCommandOutputMarksItsFragmentFirstLine() {
        let output =
            "exit status: 0\noutput truncated: only the tail of each stream is shown\nstdout:\nize.\nnext line\ndone"
        let notes = OutputReference.notes(on: output, tool: "run_command")
        #expect(notes.status == "exit status 0" && notes.first == "…ize." && notes.last == "done")
        // The bound's marker is a trailer, and the line before it was cut.
        let cut = "alpha\nbeta\ngam\n[truncated: 9000 bytes, showing 4096]"
        let bounded = OutputReference.notes(on: cut, tool: "run_command")
        #expect(bounded.first == "alpha" && bounded.last == "gam…" && bounded.more == nil)
        // A timed-out system_info note is a trailer too.
        #expect(
            OutputReference.notes(on: "a\nb\n(timed out; partial)", tool: "system_info").last == "b")
    }

    @Test func oneLineAndEmptyOutputsHaveOnlyWhatTheyHave() {
        let one = OutputReference.notes(on: "only line", tool: "inspect")
        #expect(one.first == "only line" && one.last == nil && one.more == nil && one.lines == 1)
        let read = OutputReference.notes(on: "1\tx\n[end of file]", tool: "read_file")
        #expect(read.first == "1\tx" && read.last == nil)
        let empty = OutputReference.notes(on: "", tool: "read_file")
        #expect(empty.first == nil && empty.last == nil && empty.more == nil)
        #expect(OutputReference.notes(on: "[more: call again with offset 5]", tool: "read_file").first == nil)
    }

    @Test func theReferenceNamesTheCallAndStaysBounded() throws {
        let time = try #require(ISO8601DateFormatter().date(from: "2026-09-30T14:05:12Z"))
        let text = OutputReference.text(
            tool: "read_file", entry: 7, time: time, arguments: #"{"path":"/work/overview.md"}"#, output: Self.page,
            timeZone: try #require(TimeZone(identifier: "UTC")))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(
            lines.first
                == "[output of entry 7 not repeated: read_file at 14:05:12, ok, 41 lines, \(Self.page.utf8.count) bytes; "
                + "call it again to see it]")
        #expect(lines[1] == #"arguments: {"path":"/work/overview.md"}"#)
        // A command is never suggested again: it may not print the same twice, or may change something.
        let command = OutputReference.text(tool: "run_command", entry: 8, time: time, arguments: nil, output: "done")
        #expect(command.contains("; its output is not repeated; do not run it again to see it]"))
        #expect(!command.contains("call it again"))
        #expect(lines[2].hasPrefix("first line: 1\tline 1") && lines[3].hasPrefix("last line: 40\tline 40"))
        // Long arguments and lines are shortened; the whole never passes the bound.
        let huge = OutputReference.text(
            tool: String(repeating: "t", count: 300), entry: 1, time: nil,
            arguments: String(repeating: "a\n", count: 2000), output: String(repeating: "é", count: 5000) + "\nend")
        #expect(huge.utf8.count <= OutputReference.maxBytes)
        #expect(!huge.contains(" at ") && huge.split(separator: "\n")[1].hasPrefix("arguments: a a a"))
    }

    @Test func aTurnThatReplacesTheSessionForAReferenceStillReportsItsTokens() async throws {
        let (dir, file, small) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let session = try Session.begin(
            .init(entryPoint: .mcp), home: home, dependencies: .testing(sink: MemoryAuditSink()))
        let thread = try session.thread(
            id: "refs-tokens", approver: DenyingApprover(reason: "not in tests"), tools: .named(["read_file"]))
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("forty"),
            .call(name: "read_file", arguments: #"{"path":"\#(small.path)"}"#), .say("tiny"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        _ = try await agent.respond(to: "Read \(file.path)")
        let first = agent.tokensUsed
        #expect(first.input == 40)
        // The second turn recomposes the first output as a reference, so its session is a new one.
        _ = try await agent.respond(to: "Read the tiny one")
        let second = agent.tokensUsed
        #expect(second.input >= first.input)
        #expect(TurnTokens.between(first, second)?.input == 40)
    }

    /// A scratch file of `page`'s text, removed with its directory by the caller.
    private func scratch() throws -> (dir: URL, file: URL, small: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "overview.md")
        let text = (1...40).map { "line \($0) of the overview, with some words to make it long" }.joined(
            separator: "\n")
        try Data((text + "\n").utf8).write(to: file)
        let small = dir.appending(path: "tiny.txt")
        try Data("ok\n".utf8).write(to: small)
        return (dir, file, small)
    }

    /// The text of every tool output in `transcript`, in order.
    private func outputs(_ transcript: Transcript) -> [String] {
        transcript.compactMap { if case .toolOutput = $0 { ThreadRecord.text(of: $0) } else { nil } }
    }

    @Test func anOutputIsWholeInItsTurnAndAReferenceFromTheNextAndIsAuditedOnce() async throws {
        let (dir, file, small) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let thread = try session.thread(
            id: "refs", approver: DenyingApprover(reason: "not in tests"), tools: .named(["read_file"]))
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("It has forty lines."),
            .call(name: "read_file", arguments: #"{"path":"\#(small.path)"}"#), .say("tiny"), .say("third"),
            .say("fourth"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        _ = try await agent.respond(to: "Read \(file.path)")
        // Within the turn, the request after the call carries the output whole.
        let inTurn = try #require(model.script.requests.withLock { $0 }.last)
        #expect(outputs(inTurn.transcript).first?.contains("line 40 of the overview") == true)
        let output = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        #expect(output.referencedAt == nil && output.time != nil)
        #expect(!sink.events.contains { $0.kind == .outputReferenced })
        _ = try await agent.respond(to: "Read the tiny one")
        // The next turn carries the first output as its reference, under the same id, and the tiny output of
        // this turn whole.
        let requests = model.script.requests.withLock { $0 }
        let next = requests[2].transcript
        let carried = try #require(next.first { $0.id == output.value.id })
        let reference = ThreadRecord.text(of: carried)
        #expect(reference.hasPrefix("[output of entry \(output.id) not repeated: read_file at "))
        #expect(reference.contains(#"arguments: {"path": "\#(file.path)"}"#))
        #expect(reference.contains("41 lines") && reference.contains("last line: 40\tline 40"))
        #expect(agent.store.entries.first { $0.id == output.id }?.referencedAt == 2)
        let event = try #require(sink.events.first { $0.kind == .outputReferenced })
        #expect(Set(event.details.keys) == AuditEvent.fields(for: .outputReferenced))
        #expect(event.turn == 2 && event.details["entry"] == .int(output.id))
        #expect(event.details["tool"] == .string("read_file"))
        #expect(event.details["result"]?.stringValue == output.sources.first?.event)
        let bytes = try #require(event.details["bytes"]?.intValue)
        let referenceBytes = try #require(event.details["referenceBytes"]?.intValue)
        #expect(bytes == ThreadRecord.text(of: output.value).utf8.count && referenceBytes == reference.utf8.count)
        #expect(event.details["tokens"] == .int((bytes - referenceBytes) / 4))
        // The tiny output is shorter than a reference, so it is always sent whole and never audited.
        _ = try await agent.respond(to: "third")
        let tiny = try #require(agent.store.entries.last { $0.kind == .toolOutput })
        #expect(tiny.referencedAt == nil)
        #expect(outputs(agent.transcript).last == ThreadRecord.text(of: tiny.value))
        #expect(sink.events.filter { $0.kind == .outputReferenced }.count == 1)
        // The store and the person keep the output whole.
        #expect(ThreadRecord.text(of: output.value).contains("line 40 of the overview"))
        // Saved and resumed, the store composes the same references and audits none again.
        let transcripts = TranscriptStore(directory: dir.appending(path: "transcripts"))
        try FileManager.default.createDirectory(at: transcripts.directory, withIntermediateDirectories: true)
        try transcripts.save(agent.store, as: "refs")
        let saved = try transcripts.loadThread("refs")
        let resumedSink = MemoryAuditSink()
        let resumed = Agent(
            transcript: saved.transcript, tools: agent.tools,
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("again")])),
            audit: AuditLog(session: "resumed", sink: resumedSink), links: saved.links)
        resumed.memory = agent.memory.map { _ in MemorySource() }
        #expect(resumed.store.entries.first { $0.id == output.id }?.referencedAt == 0)
        #expect(resumed.store.entries.first { $0.id == output.id }?.time == output.time)
        #expect(outputs(resumed.transcript) == outputs(agent.transcript))
        _ = try await resumed.respond(to: "again")
        #expect(!resumedSink.events.contains { $0.kind == .outputReferenced })
    }

    @Test func withReferencesOffEveryOutputIsSentWhole() async throws {
        let (dir, file, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "off", sink: sink)
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("read"), .say("next"),
        ])
        let agent = Agent(
            instructions: "x", tools: ToolRegistry(audit: audit).select(["read_file"]).tools,
            model: ResolvedModel(selection: .system, custom: model), audit: audit)
        agent.referencesOutput = false
        _ = try await agent.respond(to: "read it")
        _ = try await agent.respond(to: "and now?")
        let second = try #require(model.script.requests.withLock { $0 }.last)
        #expect(outputs(second.transcript).first?.contains("line 40 of the overview") == true)
        #expect(!sink.events.contains { $0.kind == .outputReferenced })
        #expect(agent.store.entries.allSatisfy { $0.referencedAt == nil })
    }

    /// A store of three turns: a read, a question, and a read after a condensation during turn 3 dropped
    /// turn 1.
    private func history() -> ThreadRecord {
        let segment = { (text: String) in Transcript.Segment.text(.init(content: text)) }
        let call = { (id: String, path: String) in
            Transcript.Entry.toolCalls(
                .init([
                    Transcript.ToolCall(
                        id: id, toolName: "read_file",
                        arguments: (try? GeneratedContent(json: #"{"path":"\#(path)"}"#)) ?? GeneratedContent(""))
                ]))
        }
        var store = ThreadRecord(
            carrying: Transcript(entries: [.instructions(.init(segments: [segment("x")], toolDefinitions: []))]))
        let turns: [[Transcript.Entry]] = [
            [
                .prompt(.init(segments: [segment("read a")])), call("c1", "/a"),
                .toolOutput(.init(id: "c1", toolName: "read_file", segments: [segment(Self.page)])),
                .response(.init(assetIDs: [], segments: [segment("read a")])),
            ],
            [
                .prompt(.init(segments: [segment("what?")])),
                .response(.init(assetIDs: [], segments: [segment("that")])),
            ],
            [
                .prompt(.init(segments: [segment("read b")])), call("c2", "/b"),
                .toolOutput(.init(id: "c2", toolName: "read_file", segments: [segment(Self.page)])),
                .response(.init(assetIDs: [], segments: [segment("read b")])),
            ],
        ]
        for (index, entries) in turns.enumerated() {
            let turn = index + 1
            if turn == 2 { store.reference(4, from: 2) }
            if turn == 3 {
                // Condensed ahead of turn 3's request to the last turn.
                let kept = Transcript(
                    entries: [store.entries[0].value] + store.entries.filter { $0.turn == 2 }.map(\.value))
                store.retain(kept, droppedBy: nil, at: 3)
            }
            for entry in entries { store.record(entry, origin: .turn, turn: turn, sources: []) }
        }
        return store
    }

    @Test func theContextOfAnEarlierTurnIsComposedAgain() throws {
        let store = history()
        let composer = ContextComposer()
        // Turn 1: the instructions, then the turn's own entries, its output whole.
        let first = composer.compose(store, atTurn: 1)
        #expect(first.transcript.count == 5 && first.own == 4)
        #expect(outputs(first.transcript) == [Self.page])
        // Turn 2: turn 1's output is a reference by then; the turn's own two entries follow.
        let second = composer.compose(store, atTurn: 2)
        #expect(second.transcript.count == 7 && second.own == 2)
        #expect(outputs(second.transcript).first?.hasPrefix("[output of entry 4 not repeated: read_file") == true)
        #expect(outputs(second.transcript).first?.contains(#"arguments: {"path": "/a"}"#) == true)
        // Turn 3: the condensation during it dropped turn 1; turn 3's output is whole in its own turn.
        let third = composer.compose(store, atTurn: 3)
        #expect(third.own == 4 && third.transcript.count == 1 + 2 + 4)
        #expect(outputs(third.transcript) == [Self.page])
        // The next request: turn 3's output as a reference, turn 1 gone.
        let next = composer.compose(store)
        #expect(next.count == 7 && outputs(next).first?.hasPrefix("[output of entry 10 not repeated") == true)
        // With references off, an earlier turn's output is whole.
        var literal = ContextComposer()
        literal.referencesOutput = false
        #expect(outputs(literal.compose(store, atTurn: 2).transcript) == [Self.page])
    }

    @Test func newReferencesAreTheStoredOutputsNotYetReferenced() {
        var store = history()
        let composer = ContextComposer()
        // Turn 1's output is dropped and was referenced; turn 3's is active and not yet.
        #expect(composer.newReferences(in: store).map(\.entry) == [10])
        store.reference(10, from: 4)
        store.reference(10, from: 5)
        #expect(store.entries[9].referencedAt == 4)
        store.reference(99, from: 4)
        #expect(composer.newReferences(in: store).isEmpty)
        var off = ContextComposer()
        off.referencesOutput = false
        #expect(off.newReferences(in: history()).isEmpty)
    }
}
