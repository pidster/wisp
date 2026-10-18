import Foundation
import MCP
import Synchronization
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// The model's question under `wisp mcp` (ADR 0062), driven over the real protocol: the server's own host asks
/// through the pending channel (and, switched on, the client's dialog), the call holds the dialog, then the turn
/// parks and the answer reaches the thread's next turn as a note.
@Suite(.timeLimit(.minutes(1))) struct InquiryWireTests {
    /// A server whose threads use its own host, with the hold shortened to `hold`, a client with or without a
    /// dialog, and the model scripted with `steps` on every thread.
    private func connected(
        steps: [ScriptedModel.Step], hold: Duration = .milliseconds(300), config: String? = nil,
        elicitation: (@Sendable (CreateElicitation.Parameters) async throws -> CreateElicitation.Result)? = nil,
        cancelled: CancelledIDs = .init()
    ) async throws -> (
        client: Client, server: WispServer, sink: MemoryAuditSink, channel: PendingApprovals, model: ScriptedModel
    ) {
        let sink = MemoryAuditSink()
        let session = try scratchSession(dependencies: .testing(sink: sink), config: config)
        let model = ScriptedModel(steps: steps)
        let server = WispServer(session: session, inquiryHold: hold) {
            session, host, start in
            let id = start.id
            let instructions = start.instructions
            let tools = start.tools
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools,
                auditSession: ThreadDirectory.auditSession(for: id))
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
            let actor = ThreadActor(id: id, agent: agent)
            thread.inquiries.onAnswer { question, answer in await actor.recordAnswer(to: question, answer: answer) }
            return OpenThread(
                thread: actor, gate: thread.gate, audit: thread.audit, receipts: thread.receipts,
                relay: thread.relay, inquiries: thread.inquiries)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(
            name: "wire-test", version: "0",
            capabilities: elicitation == nil ? .init() : .init(elicitation: .init(form: .init())))
        if let elicitation { _ = await client.withElicitationHandler { params in try await elicitation(params) } }
        await client.onNotification(CancelledNotification.self) { message in
            if let id = message.params.requestId { cancelled.ids.withLock { $0.append(id) } }
        }
        _ = try await client.connect(transport: transports.client)
        return (client, server, sink, PendingApprovals(home: session.home), model)
    }

    /// An `ask` call of the question, with options when given.
    private static func ask(_ question: String, options: [String]? = nil) -> ScriptedModel.Step {
        let encoded =
            options.map { opts in
                ", \"options\": "
                    + (String(data: (try? JSONEncoder().encode(opts)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]")
            } ?? ""
        return .call(name: "ask", arguments: "{\"question\": \"\(question)\"\(encoded)}")
    }

    /// A `respond` on thread `id`, with `ask` alone when the thread starts (`new`).
    private func respond(
        _ client: Client, _ id: String, _ prompt: String = "go", new: Bool = true
    ) async throws -> CallTool.Result {
        var arguments: [String: Value] = ["prompt": .string(prompt), "thread_id": .string(id)]
        if new { arguments["tools"] = .array([.string("ask")]) }
        return try await call(client, "respond", arguments)
    }

    /// The text of a result.
    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
    }

    /// Answers the first question filed in `channel`, as `wisp questions answer` does.
    private func answerWhenFiled(
        _ channel: PendingApprovals, decision: String, text: String?
    ) -> Task<PendingApprovals.Request?, Never> {
        Task {
            for _ in 0..<500 {
                if let request = channel.waiting(.question).first {
                    _ = try? channel.answer(request.id, decision: decision, text: text, via: "cli")
                    return request
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
    }

    /// The events of `kind` on thread `id`'s audit session.
    private func events(_ sink: MemoryAuditSink, _ kind: AuditEvent.Kind, thread id: String) -> [AuditEvent] {
        sink.events.filter { $0.kind == kind && $0.session.hasPrefix(id + "-") }
    }

    @Test func anAnswerWithinTheHoldIsTheToolsResult() async throws {
        let pair = try await connected(
            steps: [Self.ask("Which config?", options: ["~/.wisp", "./wisp.json"]), .say("{tool}")],
            hold: .seconds(10))
        let answering = answerWhenFiled(pair.channel, decision: "chose", text: "./wisp.json")
        let result = try await respond(pair.client, "q")
        let request = try #require(await answering.value)
        #expect(request.thread == "q" || request.thread?.hasPrefix("q-") == true)
        #expect(request.client == "wire-test" && request.question == "Which config?")
        #expect(text(result) == "chose: ./wisp.json\n(from the person)")
        let structured = try #require(result.structuredContent?.objectValue)
        let questions = try #require(structured["questions"]?.arrayValue)
        #expect(questions.count == 1)
        let question = try #require(questions.first?.objectValue)
        #expect(question["state"] == .string("answered") && question["answer"] == .string("./wisp.json"))
        #expect(question["delivered"] == .string("tool") && question["id"] == .string(request.id))
        // One notification, naming the command that answers it; the caller is told of it.
        let notes = try #require(structured["notifications"]?.arrayValue)
        #expect(notes.count == 1 && notes.first?.objectValue?["title"] == .string("wisp: the model asks"))
        let kinds: [AuditEvent.Kind] = pair.sink.events.filter { $0.session.hasPrefix("q-") }.map(\.kind)
        let inquiry: [AuditEvent.Kind] = kinds.filter { $0.rawValue.hasPrefix("inquiry") || $0 == .notification }
        let expected: [AuditEvent.Kind] = [.inquiryRequested, .notification, .inquirySettled]
        #expect(inquiry == expected)
        let settled = try #require(events(pair.sink, .inquirySettled, thread: "q").first)
        #expect(
            settled.details["outcome"] == "answered" && settled.details["via"] == "cli"
                && settled.details["delivered"] == "tool")
        #expect(pair.channel.waiting().isEmpty)
        // The thread resource shows the question answered.
        let json = try await pair.client.readResource(uri: "wisp://threads/q").first?.text ?? ""
        #expect(json.contains("\"questions\"") && json.contains("\"state\" : \"answered\""))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func theHoldLapsesTheTurnParksAndTheAnswerReachesTheNextTurnAsANote() async throws {
        let pair = try await connected(
            steps: [
                Self.ask("What is the codename?"), .say("{tool}"),
                Self.ask("Another?"), .say("{tool}"),
                .say("done"),
            ])
        let started = Date()
        let result = try await respond(pair.client, "p")
        #expect(Date().timeIntervalSince(started) >= 0.3 && Date().timeIntervalSince(started) < 10)
        let reply = text(result)
        #expect(reply.hasPrefix("waiting for the person: \"What is the codename?\" (question "))
        #expect(reply.contains("[a question waits for the person: \"What is the codename?\" — wisp questions answer "))
        #expect(reply.contains("its answer reaches thread p's next turn; do not answer it yourself]"))
        let structured = try #require(result.structuredContent?.objectValue)
        let question = try #require(structured["questions"]?.arrayValue?.first?.objectValue)
        #expect(question["state"] == .string("waiting") && question["parked"] == .bool(true))
        let id = try #require(question["id"]?.stringValue)
        #expect(
            structured["text"] == .string(reply.components(separatedBy: "\n\n[a question").first ?? ""),
            "the structured text is the reply alone")
        let parked = try #require(events(pair.sink, .inquiryParked, thread: "p").first)
        #expect(parked.details["inquiry"] == .string(id) && (parked.details["waitedSeconds"]?.doubleValue ?? 0) >= 0)
        #expect(events(pair.sink, .inquirySettled, thread: "p").isEmpty, "a parked question is not settled")
        // The question stays filed; exactly one notification however long it waits.
        #expect(pair.channel.waiting(.question).map(\.id) == [id])
        #expect(events(pair.sink, .notification, thread: "p").count == 1)
        // A different prompt while it waits: the still-waiting notice, and a second ask refused.
        let meanwhile = try await respond(pair.client, "p", "something else", new: false)
        #expect(
            text(meanwhile)
                == "error: a question is already waiting for the person; do not ask another until it is answered")
        let secondRequest = try #require(pair.model.script.requests.withLock { $0 }.dropFirst(2).first)
        let carried = secondRequest.transcript.map { "\($0)" }.joined()
        #expect(carried.contains("still waits for the person; do not assume its answer"))
        #expect(events(pair.sink, .notification, thread: "p").count == 1, "never a reminder")
        // The person answers from a terminal: the box takes it, posts the note, records the fact, and settles it.
        try pair.channel.answer(id, decision: "answer", text: "BLUE HERON", via: "cli")
        let settled = try await firstValue("settled") {
            events(pair.sink, .inquirySettled, thread: "p").first { $0.details["inquiry"] == .string(id) }
        }
        #expect(
            settled.details["outcome"] == "answered" && settled.details["delivered"] == "notice"
                && settled.details["via"] == "cli")
        #expect(pair.channel.delivery(of: id) == .taken)
        // The thread resource shows it answered from the moment it is taken.
        let json = try await pair.client.readResource(uri: "wisp://threads/p").first?.text ?? ""
        #expect(json.contains("\"answer\" : \"BLUE HERON\"") && json.contains("\"delivered\" : \"notice\""))
        // A bare "continue" carries the note to the model.
        let next = try await respond(pair.client, "p", "continue", new: false)
        #expect(text(next) == "done")
        let last = try #require(pair.model.script.requests.withLock { $0 }.last)
        let request = last.transcript.map { "\($0)" }.joined()
        #expect(request.contains("the person answered your question \"What is the codename?\": BLUE HERON"))
        // The answer is the thread's fact, the person's.
        let factsJSON = try await pair.client.readResource(uri: "wisp://threads/p/facts").first?.text ?? ""
        #expect(factsJSON.contains("\"subject\" : \"answer\"") && factsJSON.contains("\"source\" : \"person\""))
        #expect(factsJSON.contains("BLUE HERON"))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func closingTheThreadWithdrawsItsWaitingQuestionAndALateAnswerIsRefused() async throws {
        let pair = try await connected(steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")])
        _ = try await respond(pair.client, "c")
        let id = try #require(pair.channel.waiting(.question).first?.id)
        let closed = try await call(pair.client, "close_thread", ["thread_id": .string("c")])
        #expect(closed.isError == false)
        #expect(pair.channel.waiting(.question).isEmpty, "the pending file is removed at once")
        let settled = try #require(events(pair.sink, .inquirySettled, thread: "c").first)
        #expect(settled.details["outcome"] == "withdrawn" && settled.details["inquiry"] == .string(id))
        #expect(throws: PendingApprovals.Failure.unknown(id)) {
            try pair.channel.answer(id, decision: "chose", text: "a", via: "cli")
        }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aDeadlineSetAndPassedEndsTheQuestionUnanswered() async throws {
        let pair = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")], hold: .seconds(10),
            config: #"{"inquiry":{"timeoutSeconds":10}}"#)
        // The deadline is the floor, 10 s; a hold at least as long ends the question unanswered without a park.
        // Here the deadline is shortened by the hold: the asker holds for min(deadline, hold).
        let result = try await respond(pair.client, "d")
        #expect(text(result).hasPrefix("no answer within 10 s. Do not guess"))
        #expect(pair.channel.waiting(.question).isEmpty)
        #expect(events(pair.sink, .inquirySettled, thread: "d").first?.details["outcome"] == "unanswered")
        #expect(events(pair.sink, .inquiryParked, thread: "d").isEmpty)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func theClientsDialogAsksOnlyWhenSwitchedOnAndTheFirstAnswerWins() async throws {
        // Off (the default): a client with a dialog is never asked; the channel answers.
        let shown = Mutex(0)
        let off = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")], hold: .seconds(10),
            elicitation: { _ in
                shown.withLock { $0 += 1 }
                return .init(action: .accept, content: ["answer": .string("a")])
            })
        let answering = answerWhenFiled(off.channel, decision: "chose", text: "b")
        #expect(text(try await respond(off.client, "e")) == "chose: b\n(from the person)")
        _ = await answering.value
        #expect(shown.withLock { $0 } == 0)
        await off.client.disconnect()
        await off.server.stop()
        // On: the form carries the question and an enum of the options; Accept with the field answers inside the turn.
        let forms = Mutex<[CreateElicitation.Parameters.FormParameters]>([])
        let on = try await connected(
            steps: [
                Self.ask("Which?", options: ["a", "b"]), .say("{tool}"),
                Self.ask("Codename?"), .say("{tool}"),
            ], hold: .seconds(10), config: #"{"inquiry":{"elicitation":true}}"#,
            elicitation: { params in
                guard case .form(let form) = params else { return .init(action: .cancel, content: nil) }
                forms.withLock { $0.append(form) }
                let free = form.requestedSchema.properties["answer"]?.objectValue?["enum"] == nil
                return .init(action: .accept, content: ["answer": .string(free ? "BLUE HERON" : "b")])
            })
        #expect(text(try await respond(on.client, "f")) == "chose: b\n(from the person)")
        let form = try #require(forms.withLock { $0.first })
        #expect(form.message.contains("The model asks:\nWhich?") && form.message.contains("Never type a password here"))
        let options: Value? = form.requestedSchema.properties["answer"]?.objectValue?["enum"]
        #expect(options == Value.array([.string("a"), .string("b"), .string("none of these")]))
        #expect(events(on.sink, .inquirySettled, thread: "f").first?.details["via"] == "elicitation")
        #expect(on.channel.waiting(.question).isEmpty, "the channel's copy is withdrawn")
        #expect(text(try await respond(on.client, "f", "again", new: false)) == "answer: BLUE HERON\n(from the person)")
        let second = try #require(forms.withLock { $0.last })
        let maxLength: Value? = second.requestedSchema.properties["answer"]?.objectValue?["maxLength"]
        #expect(maxLength == Value.int(2000))
        #expect(
            events(on.sink, .inquiryRequested, thread: "f").first?.details["ways"]
                == .array(["elicitation", "pending"]))
        await on.client.disconnect()
        await on.server.stop()
        // On, with the dialog slow: the channel answers first and the dialog is withdrawn with notifications/cancelled.
        let cancelled = CancelledIDs()
        let slow = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")], hold: .seconds(10),
            config: #"{"inquiry":{"elicitation":true}}"#,
            elicitation: { _ in
                try await Task.sleep(for: .seconds(3))
                return .init(action: .accept, content: ["answer": .string("a")])
            }, cancelled: cancelled)
        let fromTerminal = answerWhenFiled(slow.channel, decision: "chose", text: "b")
        #expect(text(try await respond(slow.client, "g")) == "chose: b\n(from the person)")
        _ = await fromTerminal.value
        _ = try await firstValue("the dialog withdrawn") { cancelled.ids.withLock { $0.first } }
        await slow.client.disconnect()
        await slow.server.stop()
    }

    @Test func theHoldLapsingWithdrawsTheDialogBeforeTheTurnParks() async throws {
        let cancelled = CancelledIDs()
        let pair = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")],
            config: #"{"inquiry":{"elicitation":true}}"#,
            elicitation: { _ in
                try await Task.sleep(for: .seconds(3))
                return .init(action: .accept, content: ["answer": .string("a")])
            }, cancelled: cancelled)
        let result = try await respond(pair.client, "h")
        #expect(text(result).hasPrefix("waiting for the person"))
        _ = try await firstValue("the dialog withdrawn") { cancelled.ids.withLock { $0.first } }
        #expect(pair.channel.waiting(.question).count == 1, "the question stays filed out of band")
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aDialogThatFailsOrIsCancelledLeavesTheQuestionToTheChannel() async throws {
        struct DialogGone: Error {}
        // The client's handler throws: the dialog leg fails, and the out-of-band answer still wins.
        let broken = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")], hold: .seconds(10),
            config: #"{"inquiry":{"elicitation":true}}"#, elicitation: { _ in throw DialogGone() })
        let answering = answerWhenFiled(broken.channel, decision: "chose", text: "a")
        #expect(text(try await respond(broken.client, "x")) == "chose: a\n(from the person)")
        _ = await answering.value
        #expect(events(broken.sink, .inquirySettled, thread: "x").first?.details["via"] == "cli")
        await broken.client.disconnect()
        await broken.server.stop()
        // The person cancels the dialog: that is not an answer, and the question waits on the channel.
        let cancelling = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")], hold: .seconds(10),
            config: #"{"inquiry":{"elicitation":true}}"#, elicitation: { _ in .init(action: .cancel, content: nil) })
        let later = answerWhenFiled(cancelling.channel, decision: "none", text: nil)
        #expect(text(try await respond(cancelling.client, "y")) == "the person chose none of these options")
        _ = await later.value
        await cancelling.client.disconnect()
        await cancelling.server.stop()
    }

    @Test func aClientThatDisconnectsEndsEachOpenThreadsSession() async throws {
        let pair = try await connected(steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}"), .say("hi")])
        _ = try await respond(pair.client, "waiting")
        let id = try #require(pair.channel.waiting(.question).first?.id)
        _ = try await call(pair.client, "respond", ["prompt": .string("hi"), "thread_id": .string("quiet")])
        await pair.client.disconnect()
        await pair.server.stop()
        await pair.server.endThreads()
        // Each thread's session ends, after its last turn, and the question waiting on one is withdrawn with it.
        for thread in ["waiting", "quiet"] {
            let ended = try #require(events(pair.sink, .sessionEnd, thread: thread).first, "\(thread)")
            #expect(ended.details["reason"] == "disconnected")
        }
        let settled = try #require(events(pair.sink, .inquirySettled, thread: "waiting").first)
        #expect(settled.details["outcome"] == "withdrawn" && settled.details["inquiry"] == .string(id))
        #expect(pair.channel.waiting(.question).isEmpty)
    }

    @Test func aCallRefusedForItsArgumentsNeitherCreatesNorEvictsAThread() async throws {
        let pair = try await connected(steps: [.say("hello"), .say("again")], config: #"{"maxThreads":1}"#)
        _ = try await respond(pair.client, "old")
        // A schema the model cannot take, on a new thread_id: refused before a thread is made, so the only slot
        // stays the old thread's.
        let refused = try await call(
            pair.client, "respond",
            ["prompt": .string("hi"), "thread_id": .string("new"), "schema": .object(["type": .string("string")])])
        #expect(refused.isError == true && text(refused).contains("the root must be an object schema"))
        #expect(events(pair.sink, .sessionStart, thread: "new").isEmpty)
        #expect(events(pair.sink, .sessionEnd, thread: "old").isEmpty)
        #expect(text(try await respond(pair.client, "old", new: false)) == "again")
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func evictingAThreadWithAWaitingQuestionWithdrawsItAndEndsTheThreadsSession() async throws {
        let pair = try await connected(
            steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}"), .say("hello")],
            config: #"{"maxThreads":1}"#)
        _ = try await respond(pair.client, "old")
        let id = try #require(pair.channel.waiting(.question).first?.id)
        // A second thread needs the only slot: the first is evicted, and its question goes with it.
        let result = try await call(pair.client, "respond", ["prompt": .string("hi"), "thread_id": .string("new")])
        #expect(result.isError != true)
        #expect(pair.channel.waiting(.question).isEmpty, "the evicted thread's question is withdrawn from the channel")
        let settled = try #require(events(pair.sink, .inquirySettled, thread: "old").first)
        #expect(settled.details["outcome"] == "withdrawn" && settled.details["inquiry"] == .string(id))
        let ended = try await firstValue("the evicted session ended") {
            events(pair.sink, .sessionEnd, thread: "old").first
        }
        #expect(ended.details["reason"] == "evicted")
        #expect(throws: PendingApprovals.Failure.unknown(id)) {
            try pair.channel.answer(id, decision: "none", via: "cli")
        }
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func anUnknownResourceIsRefusedAsInvalid() async throws {
        let pair = try await connected(steps: [])
        await #expect(throws: (any Error).self) {
            _ = try await pair.client.readResource(uri: "wisp://no-such-collection")
        }
        await pair.client.disconnect()
        await pair.server.stop()
    }
}
