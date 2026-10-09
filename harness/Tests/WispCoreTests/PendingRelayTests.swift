import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Lines a relay sent, kept for the test.
final class SentLines: Sendable {
    /// Each line, decoded.
    let lines = Mutex<[[String: JSONValue]]>([])

    /// Keeps `line`.
    func keep(_ line: String) {
        let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue ?? [:]
        lines.withLock { $0.append(object) }
    }

    /// The lines of `type`.
    func of(_ type: String) -> [[String: JSONValue]] {
        lines.withLock { $0.filter { $0["type"] == .string(type) } }
    }
}

/// `wisp chat --json` shows a front end the commands waiting in `wisp mcp` servers and writes its answers back.
@Suite(.timeLimit(.minutes(1))) struct PendingRelayTests {
    @Test func showsAWaitingCommandAndWritesTheAnswer() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let sent = SentLines()
        let sink = MemoryAuditSink()
        let relay = PendingRelay(
            channel: channel, router: router, audit: AuditLog(session: "chat", sink: sink), send: sent.keep)
        let request = PendingApprovals.request(for: approvalRequest(), client: "claude-code", timeout: nil)
        try channel.file(request)
        relay.poll()
        relay.poll()  // shown once, not again
        let shown = sent.of("approval")
        #expect(shown.count == 1)
        let line = try #require(shown.first)
        #expect(line["id"] == .string("mcp-\(request.id)") && line["source"] == "mcp")
        #expect(line["thread"] == "git" && line["client"] == "claude-code" && line["request"] == .string(request.id))
        #expect(line["command"] == "git push origin main" && line["level"] == "moderate")
        router.receive(#"{"type":"answer","id":"mcp-\#(request.id)","decision":"session"}"#)
        let taken = try await firstValue("the answer written") { channel.take(request) }
        guard case .answer(let answer) = taken else { Issue.record("no answer written: \(taken)"); return }
        #expect(answer.decision == "session" && answer.via == "tui")
        #expect(sink.events.last?.kind == .approvalAnswered && sink.events.last?.details["via"] == "tui")
        // Once taken, the request is gone, and the front end is told to drop it.
        relay.poll()
        #expect(sent.of("withdrawn").map { $0["id"] } == [.string("mcp-\(request.id)")])
    }

    @Test func aRequestAnsweredElsewhereIsWithdrawnAndALateAnswerIgnored() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let sent = SentLines()
        let relay = PendingRelay(channel: channel, router: router, audit: nil, send: sent.keep)
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        relay.poll()
        channel.withdraw(request)  // the client's dialog answered
        relay.poll()
        #expect(sent.of("withdrawn").count == 1)
        router.receive(#"{"type":"answer","id":"mcp-\#(request.id)","decision":"always"}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.delivery(of: request.id) == .taken, "nothing was written")
        let pending = ChatProtocol.approval(id: "x", pending: request)
        #expect(pending["thread"] == "git" && pending["client"] == .null)
    }

    @Test func aRequestWithdrawnBeforeItsWaitStartsDoesNotLeaveATaskWaiting() async throws {
        // The relay shows a request and then starts a task to wait for it; a withdrawal can land in between.
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let relay = PendingRelay(channel: channel, router: router, audit: nil, send: { _ in })
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        router.withdraw(PendingRelay.protocolID(request.id))
        try await Timeout.run(.seconds(5)) { await relay.awaitAnswer(request) }
    }
}
