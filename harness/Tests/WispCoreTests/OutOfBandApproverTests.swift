import Foundation
import Synchronization
import Testing

@testable import WispCore

/// Notifications an approver asked for, kept for the test.
final class PostedNotifications: Sendable {
    /// What was posted.
    let messages = Mutex<[Notifier.Message]>([])
}

/// Whether a dialog leg saw its task cancelled.
final class CancelFlag: Sendable {
    /// Set by the cancellation handler.
    let cancelled = Mutex(false)
}

/// Asking through the pending channel and the client's dialog at once: the first answer wins, the other is
/// withdrawn, silence and cancellation deny, and every step is audited.
@Suite struct OutOfBandApproverTests {
    /// An approver over `channel`, polling quickly, recording notifications. The default wait is long, so a
    /// test that answers is never beaten by the timeout on a loaded machine (a 5 s default expired at 6.9 s on
    /// 2026-10-04); tests of the timeout pass a short one.
    private func approver(
        _ channel: PendingApprovals, timeout: Duration? = .seconds(60), posted: PostedNotifications = .init(),
        alongside: OutOfBandApprover.Ask? = nil
    ) -> OutOfBandApprover {
        OutOfBandApprover(
            channel: channel, timeout: timeout, alongside: { alongside }, client: { "claude-code" },
            notify: { message, _ in posted.messages.withLock { $0.append(message) } }, poll: .milliseconds(20))
    }

    /// Waits until the channel has a request, then returns it.
    private func filed(_ channel: PendingApprovals, count: Int = 1) async throws -> [PendingApprovals.Request] {
        for _ in 0..<250 {
            let waiting = channel.waiting()
            if waiting.count >= count { return waiting }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("no request was filed")
        return []
    }

    @Test func aRequestAnsweredFromTheCommandLineDecides() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let posted = PostedNotifications()
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "git", sink: sink)
        let approver = approver(channel, posted: posted)
        let decision = Task { await approver.decide(approvalRequest(), audit: audit) }
        let request = try #require(try await filed(channel).first)
        #expect(request.thread == "git" && request.client == "claude-code" && request.expiresAt != nil)
        try channel.answer(request.id, decision: "session", via: "cli")
        #expect(await decision.value == .approved(.session))
        #expect(!channel.isFiled(request))
        // The person was told what waits and how to answer it.
        let message = try #require(posted.messages.withLock { $0.first })
        #expect(message.title == "wisp: approval needed")
        #expect(message.body == "git push origin main — wisp approvals approve \(request.id)")
        #expect(message.subtitle == "moderate risk · claude-code, thread git")
        let kinds = sink.events.map(\.kind)
        #expect(kinds == [.approvalPending, .approvalSettled])
        #expect(sink.events[0].details["outcome"] == "filed" && sink.events[0].details["alongside"] == nil)
        let settled = sink.events[1].details
        #expect(settled["outcome"] == "answered" && settled["via"] == "cli" && settled["decision"] == "session")
    }

    @Test func aDenialFromWispTUIIsADenialThatSaysWhere() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let approver = approver(channel)
        let decision = Task { await approver.decide(approvalRequest()) }
        let request = try #require(try await filed(channel).first)
        try channel.answer(request.id, decision: "no", via: "tui")
        #expect(await decision.value == .denied("declined by the person (wisp-tui)"))
    }

    @Test func silenceTimesOutAndWithdrawsTheRequest() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let approver = approver(channel, timeout: .seconds(1))
        let decision = await approver.decide(approvalRequest(), audit: AuditLog(session: "git", sink: sink))
        #expect(decision == .unanswered(.seconds(1)))
        #expect(channel.waiting().isEmpty && channel.sweep().isEmpty)
        #expect(sink.events.last?.details["outcome"] == "timed-out")
    }

    @Test func theClientsDialogAnsweringFirstWithdrawsTheRequest() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let approver = approver(channel) { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .answered(.approved(.once))
        }
        let decision = await approver.decide(approvalRequest(), audit: AuditLog(session: "git", sink: sink))
        #expect(decision == .approved(.once))
        #expect(channel.waiting().isEmpty)
        #expect(sink.events.first?.details["alongside"] == "elicitation")
        #expect(sink.events.last?.details["via"] == "elicitation")
    }

    @Test func anAnswerFromAnotherFaceWithdrawsTheClientsDialog() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let flag = CancelFlag()
        // A dialog that is never answered, as when Claude Code's dialog sticks; it sees its cancellation.
        let approver = approver(channel, timeout: nil) { _ in
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(30))
                return .answered(.denied("too late"))
            } onCancel: {
                flag.cancelled.withLock { $0 = true }
            }
        }
        let decision = Task { await approver.decide(approvalRequest()) }
        let request = try #require(try await filed(channel).first)
        try channel.answer(request.id, decision: "once", via: "cli")
        #expect(await decision.value == .approved(.once))
        #expect(flag.cancelled.withLock { $0 })
    }

    @Test func aDialogThatFailsLeavesTheOtherWayAsking() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let approver = approver(channel) { _ in .failed("the client went away") }
        let decision = Task { await approver.decide(approvalRequest()) }
        let request = try #require(try await filed(channel).first)
        try await Task.sleep(for: .milliseconds(100))
        try channel.answer(request.id, decision: "always", via: "tui")
        #expect(await decision.value == .approved(.always))
    }

    @Test func aCancelledCallAbandonsTheRequest() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let approver = approver(channel, timeout: nil)
        let decision = Task { await approver.decide(approvalRequest(), audit: AuditLog(session: "git", sink: sink)) }
        _ = try await filed(channel)
        decision.cancel()
        #expect(await decision.value == .denied("the call was cancelled while waiting for approval"))
        #expect(channel.waiting().isEmpty)
        #expect(sink.events.last?.details["outcome"] == "abandoned")
    }

    @Test func concurrentRequestsAreAnsweredEachOnItsOwn() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let approver = approver(channel)
        let push = Task { await approver.decide(approvalRequest("git push origin main", thread: "a")) }
        let tag = Task { await approver.decide(approvalRequest("git tag v1", thread: "b")) }
        let requests = try await filed(channel, count: 2)
        let byThread = Dictionary(uniqueKeysWithValues: requests.map { ($0.thread ?? "", $0) })
        try channel.answer(try #require(byThread["b"]).id, decision: "no", via: "cli")
        try channel.answer(try #require(byThread["a"]).id, decision: "once", via: "cli")
        #expect(await push.value == .approved(.once))
        #expect(await tag.value == .denied("declined by the person (wisp approvals)"))
    }

    @Test func aChannelThatCannotBeUsedDeniesOrLeavesTheDialog() async throws {
        let channel = PendingApprovals(directory: URL(fileURLWithPath: "/dev/null/pending"))
        let sink = MemoryAuditSink()
        let alone = await approver(channel).decide(approvalRequest(), audit: AuditLog(session: "git", sink: sink))
        guard case .denied(let reason) = alone else { Issue.record("expected a denial, got \(alone)"); return }
        #expect(reason.hasPrefix("approval could not be asked outside the client"))
        #expect(sink.events.first?.details["outcome"] == "failed")
        let withDialog = await approver(channel) { _ in .answered(.approved(.session)) }.decide(approvalRequest())
        #expect(withDialog == .approved(.session))
    }

    @Test func theGateNamesTheThreadAndHandsTheApproverItsLog() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: approver(channel), threshold: .default,
            audit: AuditLog(session: "t7", sink: sink))
        let cleared = Task { try await gate.clear(command: "git push origin main", workingDirectory: "/tmp") }
        let request = try #require(try await filed(channel).first)
        #expect(request.thread == "t7")
        try channel.answer(request.id, decision: "once", via: "cli")
        try await cleared.value
        let kinds = sink.events.map(\.kind)
        #expect(
            kinds == [.classifierVerdict, .approvalRequested, .approvalPending, .approvalSettled, .approvalDecided])
    }

    @Test func outOfBandOffKeepsTheDialogAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-oob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        try home.ensure()
        try Data(#"{"approval":{"outOfBand":false}}"#.utf8).write(to: home.configFile)
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing())
        #expect(session.config.approvalOutOfBand == false)
        let none = session.mcpApprover(elicitation: { nil }, fallback: DenyingApprover(reason: "no dialog"))
        #expect(await none.decide(approvalRequest()) == .denied("no dialog"))
        let dialog = session.mcpApprover(
            elicitation: { { _ in .answered(.approved(.once)) } }, fallback: DenyingApprover(reason: "x"))
        #expect(await dialog.decide(approvalRequest()) == .approved(.once))
        #expect(!FileManager.default.fileExists(atPath: home.pending.path), "nothing was filed")
        #expect(Config().resolved.approvalOutOfBand)
    }
}
