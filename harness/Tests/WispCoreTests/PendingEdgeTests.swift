import Darwin
import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The refusals and edge answers around the requests waiting in `wisp mcp` servers: plain chat's slash commands,
/// the watcher's audit of a refused answer, `wisp-tui`'s relay of a question, and the line reader's ends.
@Suite(.timeLimit(.minutes(1))) struct PendingEdgeTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-pending-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func agent(_ sink: MemoryAuditSink? = nil) -> Agent {
        Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel()),
            audit: sink.map { AuditLog(session: "chat", sink: $0) })
    }

    private func run(
        _ lines: [String], channel: PendingApprovals, canAnswer: Bool = true, sink: MemoryAuditSink? = nil
    ) async throws -> ChatLoopTests.Capture {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var context = ChatLoopTests.context
        context.pending = ChatPending(
            channel: channel, facts: nil, auditFile: nil, canAnswer: canAnswer, patience: .milliseconds(200))
        let capture = ChatLoopTests.Capture(lines: lines + ["quit"])
        var loop = ChatLoop(
            agent: agent(sink), store: TranscriptStore(directory: dir), saveName: nil, context: context,
            io: capture.io)
        try await loop.run()
        return capture
    }

    @Test func pendingListsCommandsFactsAndQuestionsTogetherAndQuestionsAloneOnRequest() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        try channel.file(PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil))
        try channel.file(PendingApprovals.request(keeping: proposedFact(), thread: "git", client: nil, timeout: nil))
        let question = PendingApprovals.request(asking: Question(text: "Codename?", thread: "docs"), client: nil)
        try channel.file(question)
        let capture = try await run(["/approvals pending", "/questions", "/facts frob"], channel: channel)
        let out = capture.output
        // One listing, the three kinds in turn with a blank line between: the command, the fact, the question.
        #expect(out.contains("git push origin main") && out.contains(question.id), "\(out)")
        #expect(out.components(separatedBy: "\n\n").count >= 3, "a blank line separates each kind: \(out)")
        #expect(capture.noted.contains("unknown /facts frob; \(PendingFactsRequest.usage)"), "\(capture.noted)")
    }

    @Test func aChatWhoseInputIsNotATerminalDoesNotPromptForAQuestionsAnswer() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let question = PendingApprovals.request(asking: Question(text: "Codename?"), client: nil)
        try channel.file(question)
        let capture = try await run(["/questions answer \(question.id)"], channel: channel, canAnswer: false)
        #expect(capture.noted.contains { $0.contains("does not answer for the person") }, "\(capture.noted)")
        #expect(!capture.output.contains("? the model asks"), "no prompt was shown")
        #expect(channel.isFiled(question) && channel.delivery(of: question.id) == .waiting)
    }

    @Test func answeringAnUnknownIdOrACommandAsAQuestionIsRefusedAndWritesNothing() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let command = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(command)
        let capture = try await run(
            ["/questions answer deadbeef", "/questions answer \(command.id)"], channel: channel)
        let notes = capture.noted
        #expect(notes.contains { $0.contains("no pending request deadbeef") }, "\(notes)")
        #expect(notes.contains { $0.contains(command.id) && $0.contains("wisp approvals") }, "\(notes)")
        #expect(channel.delivery(of: command.id) == .waiting, "the command was not answered as a question")
        #expect(!capture.output.contains("? the model asks"))
    }

    @Test func leavingTheChoiceOfAQuestionToDeclineWritesNothing() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let question = PendingApprovals.request(asking: Question(text: "Codename?"), client: nil)
        try channel.file(question)
        // No id given: the choice lists the waiting question; an empty line leaves it as it was.
        let capture = try await run(["/questions decline", ""], channel: channel)
        #expect(capture.noted.contains("left as it was"), "\(capture.noted)")
        #expect(channel.isFiled(question) && channel.delivery(of: question.id) == .waiting)
    }

    @Test func aRefusedAnswerToAQuestionIsAuditedAsInquiryAnsweredNotAsAnApproval() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let question = PendingApprovals.request(asking: Question(text: "Which?", options: ["a", "b"]), client: nil)
        try channel.file(question)
        let sink = MemoryAuditSink()
        let pending = ChatPending(channel: channel, facts: nil, auditFile: nil, canAnswer: true)
        // A command's word is no answer to a question.
        let ending = await pending.answer(question.id, decision: "once", audit: AuditLog(session: "chat", sink: sink))
        guard case .usage = ending else {
            Issue.record("not refused: \(ending)")
            return
        }
        let event = try #require(sink.events.last)
        #expect(event.kind == .inquiryAnswered && event.details["delivery"] == "refused")
        #expect(event.details["inquiry"] == .string(question.id) && event.details["via"] == "chat")
        #expect(channel.isFiled(question), "a refused answer leaves the question waiting")
    }

    @Test func aFrontEndsAnswerToAQuestionThatLeftTheChannelIsRefusedAuditedAndSaidSo() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let sent = SentLines()
        let sink = MemoryAuditSink()
        let relay = PendingRelay(
            channel: channel, router: router, audit: AuditLog(session: "chat", sink: sink), kinds: [.question],
            send: sent.keep)
        let request = PendingApprovals.request(asking: Question(text: "Which?", options: ["a", "b"]), client: nil)
        try channel.file(request)
        relay.poll()
        _ = try #require(sent.of("choice").first)
        // The question is withdrawn (its thread closed) before the front end's answer arrives.
        channel.withdraw(request)
        router.receive(#"{"type":"choose","id":"mcp-\#(request.id)","value":"a"}"#)
        let note = try await firstValue("the refusal sent") { sent.of("note").first }
        #expect(note["text"]?.stringValue?.hasPrefix("the answer was not used") == true)
        let event = try #require(sink.events.last { $0.kind == .inquiryAnswered })
        #expect(event.details["delivery"] == "refused" && event.details["via"] == "tui")
    }

    @Test func theRelayPollsOnItsOwnUntilCancelled() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sent = SentLines()
        let relay = PendingRelay(
            channel: channel, router: LineRouter(), audit: nil, kinds: [.question], send: sent.keep)
        let running = Task { await relay.run(every: .milliseconds(5)) }
        try channel.file(PendingApprovals.request(asking: Question(text: "Codename?"), client: nil))
        _ = try await firstValue("the question shown by the loop") { sent.of("choice").first }
        running.cancel()
        await running.value
    }

    @Test func theLineReaderEndsOnAClosedDescriptorAndOnAReadThatFails() async throws {
        // A descriptor that is not open is reported by poll as invalid: the input has ended.
        let closed: Int32 = 9_999
        #expect(
            await LineReader(descriptor: closed, pollInterval: .milliseconds(10)).read(stop: nil, within: .seconds(5))
                == .end)
        // A descriptor poll calls ready but read cannot read (a directory) ends the input too, with no line.
        let directory = open("/", O_RDONLY)
        defer { close(directory) }
        #expect(
            await LineReader(descriptor: directory, pollInterval: .milliseconds(10)).read(
                stop: nil, within: .seconds(5))
                == .end)
    }
}
