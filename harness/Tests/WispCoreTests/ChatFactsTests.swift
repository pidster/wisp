import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The person's fact controls in chat (decisions D3 and D6 of the layered-context proposal): `/inspect facts`,
/// `/fact`, and `/task`, their parsing, completion, and what the loop does with them.
@Suite struct ChatFactsTests {
    @Test func commandsParse() {
        #expect(ChatInput(line: "/inspect facts") == .facts(all: false))
        #expect(ChatInput(line: "/inspect Facts all") == .facts(all: true))
        #expect(ChatInput(line: "/task") == .task(nil) && ChatInput(line: "/task  ship it ") == .task("ship it"))
        #expect(
            ChatInput(line: "/fact entity codename = BLUE HERON")
                == .fact(.state(subject: "entity", name: "codename", value: "BLUE HERON")))
        #expect(ChatInput(line: "/fact branch = main") == .fact(.state(subject: "branch", name: "", value: "main")))
        #expect(
            ChatInput(line: "/fact tests swift test --filter X = passed")
                == .fact(.state(subject: "tests", name: "swift test --filter X", value: "passed")))
        #expect(
            ChatInput(line: "/fact delete c3") == .fact(.delete("c3"))
                && ChatInput(line: "/fact c7 permanent") == .fact(.move("c7", .permanent))
                && ChatInput(line: "/fact git/c7 Session") == .fact(.move("git/c7", .session))
                && ChatInput(line: "/fact s2 thread") == .fact(.move("s2", .thread)))
        #expect(FactRequest("approve c7") == .usage && FactRequest("c7 forever") == .usage)
        #expect(FactRequest(nil) == .usage && FactRequest("entity codename") == .usage && FactRequest("= x") == .usage)
        #expect(FactRequest("x =") == .usage)
        #expect(FactRequest("delete a = b") == .state(subject: "delete", name: "a", value: "b"))
        #expect(ChatInput.helpText.contains("/inspect facts [all]") && ChatInput.helpText.contains("/task [text]"))
        #expect(
            ChatCompletion.complete("/fa").candidates == ["/fact"]
                && ChatCompletion.complete("/ta").candidates == ["/task"])
        #expect(ChatCompletion.complete("/inspect f").candidates == ["facts"])
        #expect(ChatCompletion.complete("/inspect facts ").candidates == ["all"])
        #expect(ChatCompletion.complete("/fact e").candidates == ["entity"])
        #expect(ChatCompletion.complete("/fact d").candidates == ["decision", "delete"])
        #expect(ChatCompletion.complete("/fact delete c", factIDs: ["c1", "p2"]).candidates == ["c1"])
        #expect(
            ChatCompletion.complete("/fact c1 ", factIDs: ["c1", "p2"]).candidates == [
                "permanent", "session", "thread",
            ])
        #expect(ChatCompletion.complete("/fact c1 s", factIDs: ["c1", "p2"]).candidates == ["session"])
    }

    @Test func theLoopStatesShowsAndChangesFacts() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
        agent.facts = FactSettings()
        let capture = ChatLoopTests.Capture(lines: [
            "/task add a --dry-run flag", "/task", "/fact tests ci = green", "/fact mood = fine", "/fact",
            "/inspect facts", "/fact delete c9", "/fact delete c3", "/inspect facts all", "/fact c1 thread",
            "/fact c4 session",
            "/fact s1 permanent", "quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context,
            io: capture.io)
        try await loop.run()
        // Chat's start recorded where it works: the directory and the branch, as the chat's own observation.
        #expect(agent.fact("c1")?.identity.subject == "workdir" && agent.fact("c1")?.value == "/repo")
        #expect(agent.fact("c2")?.value == "main" && agent.fact("c2")?.detail == "chat")
        let notes = capture.noted
        #expect(notes.contains("task set (c3); /task shows it and its history"))
        #expect(notes.contains("stated c4: tests ci = green"))
        #expect(notes.contains { $0.contains("error: no subject mood; the subjects are task, decision") })
        #expect(notes.contains(FactRequest.usageText))
        #expect(notes.contains { $0.contains("error: no current fact c9") })
        #expect(notes.contains("deleted c3: task "))
        #expect(notes.contains { $0.contains("error: fact c1 is already in scope thread") })
        #expect(notes.contains("moved c4 to session as s1"))
        #expect(notes.contains("moved s1 to permanent as p1 (kept in ~/.wisp/facts.json for every conversation)"))
        let out = capture.output
        #expect(out.contains("task: add a --dry-run flag\n  the person,"))
        #expect(out.contains("# Facts\n") && out.contains("| c4 | tests | ci | green | the person | dynamic |  |"))
        #expect(
            out.contains("# Facts, with their history")
                && out.contains("| c3 | task | - | add a --dry-run flag | the person | dynamic | deleted |"))
        // A front end gets the view whole, as a facts view.
        let shown = Mutex<[ChatView]>([])
        var io = ChatLoopTests.Capture(lines: ["/inspect facts", "quit"]).io
        io.view = { view in shown.withLock { $0.append(view) } }
        var front = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context, io: io)
        try await front.run()
        #expect(shown.withLock { $0.first?.kind } == .facts)
    }
}
