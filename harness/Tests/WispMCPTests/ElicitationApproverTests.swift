import Foundation
import MCP
import Synchronization
import Testing
import WispCore

@testable import WispMCP

/// Drives `ElicitationApprover` through a real in-process MCP client and server.
@Suite struct ElicitationApproverTests {
    private let request = ApprovalRequest(
        command: "touch x", pattern: "touch *", workingDirectory: "/tmp",
        assessment: RiskAssessment(level: .moderate, reasons: ["modifies files"], sources: ["rules"]))

    /// A connected client whose elicitation handler answers with `answer`, and the server it talks to.
    private func connectedPair(
        tracker: ElicitationTracker? = nil, cancelled: CancelledIDs = .init(),
        answering answer: @escaping @Sendable () async throws -> CreateElicitation.Result
    )
        async throws -> (client: Client, server: Server, flags: ClientCapabilityFlags)
    {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "t", version: "0", capabilities: .init(tools: .init(listChanged: false)))
        let flags = ClientCapabilityFlags()
        // With a tracker, the server's side goes through the transport that learns the dialogs' ids, as in wisp mcp.
        let transport: any Transport =
            tracker.map { CompatibilityTransport(transports.server, tracker: $0) } ?? transports.server
        try await server.start(transport: transport) { _, capabilities in
            flags.elicitation.withLock { $0 = capabilities.elicitation != nil }
        }
        let client = Client(
            name: "test-client", version: "0", capabilities: .init(elicitation: .init(form: .init())))
        _ = await client.withElicitationHandler { _ in try await answer() }
        await client.onNotification(CancelledNotification.self) { message in
            if let id = message.params.requestId { cancelled.ids.withLock { $0.append(id) } }
        }
        _ = try await client.connect(transport: transports.client)
        return (client, server, flags)
    }

    @Test func clientWithoutElicitationIsDeniedWithGuidance() async {
        let server = Server(name: "t", version: "0")
        let approver = ElicitationApprover(server: server, client: ClientCapabilityFlags(), timeout: .seconds(1))
        let decision = await approver.decide(request)
        guard case .denied(let reason) = decision else { Issue.record("expected denial, got \(decision)"); return }
        #expect(reason.contains("does not support elicitation"))
        #expect(reason.contains("touch x") == false)
        #expect(reason.contains("modifies files"))
    }

    @Test(arguments: [
        (CreateElicitation.Result.Action.accept, ApprovalDecision.approved(.once)),
        (CreateElicitation.Result.Action.decline, ApprovalDecision.denied("declined by the user")),
        (CreateElicitation.Result.Action.cancel, ApprovalDecision.denied("cancelled by the user")),
    ])
    func mapsTheClientsAnswer(action: CreateElicitation.Result.Action, expected: ApprovalDecision) async throws {
        let pair = try await connectedPair { CreateElicitation.Result(action: action, content: nil) }
        #expect(pair.flags.elicitation.withLock { $0 })
        let approver = ElicitationApprover(server: pair.server, client: pair.flags, timeout: .seconds(5))
        #expect(await approver.decide(request) == expected)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func silenceIsUnanswered() async throws {
        let pair = try await connectedPair {
            try await Task.sleep(for: .seconds(2))
            return CreateElicitation.Result(action: .accept, content: nil)
        }
        let approver = ElicitationApprover(server: pair.server, client: pair.flags, timeout: .milliseconds(300))
        #expect(await approver.decide(request) == .unanswered(.milliseconds(300)))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aDialogWhoseWaitLapsesIsWithdrawnFromTheClient() async throws {
        let tracker = ElicitationTracker()
        let cancelled = CancelledIDs()
        let pair = try await connectedPair(tracker: tracker, cancelled: cancelled) {
            try await Task.sleep(for: .seconds(2))
            return CreateElicitation.Result(action: .accept, content: nil)
        }
        let approver = ElicitationApprover(
            server: pair.server, client: pair.flags, timeout: .milliseconds(300), tracker: tracker)
        #expect(await approver.decide(request) == .unanswered(.milliseconds(300)))
        for _ in 0..<200 where cancelled.ids.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.ids.withLock { $0.count } == 1)
        #expect(tracker.counts == (0, 0, 0))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func anAnsweredDialogLeavesNothingTracked() async throws {
        let tracker = ElicitationTracker()
        let pair = try await connectedPair(tracker: tracker) {
            CreateElicitation.Result(action: .decline, content: nil)
        }
        let approver = ElicitationApprover(
            server: pair.server, client: pair.flags, timeout: .seconds(5), tracker: tracker)
        #expect(await approver.decide(request) == .denied("declined by the user"))
        #expect(tracker.counts == (0, 0, 0))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aDialogWithdrawnBeforeItIsSentIsCancelledAsItGoesOut() throws {
        let tracker = ElicitationTracker()
        let outgoing = Data(
            #"{"jsonrpc":"2.0","id":7,"method":"elicitation/create","params":{"_meta":{"wisp/approval":"k"}}}"#.utf8)
        tracker.begin("k")
        #expect(tracker.cancel("k") == nil)  // not sent yet: remembered
        #expect(tracker.observe(outgoing) == .number(7))  // so the transport cancels it straight after sending
        #expect(tracker.counts.cancelled == 0 && tracker.counts.ids == 0)
        tracker.end("k")
        #expect(tracker.counts == (0, 0, 0))
        // Sent first, then withdrawn: the id is handed back once.
        tracker.begin("m")
        let sent = Data(
            #"{"jsonrpc":"2.0","id":8,"method":"elicitation/create","params":{"_meta":{"wisp/approval":"m"}}}"#.utf8)
        #expect(tracker.observe(sent) == nil)
        #expect(tracker.cancel("m") == .number(8))
        #expect(tracker.cancel("m") == nil)
        tracker.end("m")
        // A dialog whose wait has ended is not tracked when its request goes out late.
        #expect(tracker.observe(sent) == nil && tracker.counts == (0, 0, 0))
        let notice = try #require(ElicitationTracker.cancellation(.number(8), reason: "r"))
        #expect(String(decoding: notice, as: UTF8.self).contains("notifications/cancelled"))
    }
}
