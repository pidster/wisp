import Darwin
import Foundation
import Testing

@testable import WispCore

/// The pending channel's edges: the doctor's finding, the sweep of leftovers, the progress lines, and a relay
/// answer that cannot be written.
@Suite struct PendingApprovalsEdgeTests {
    @Test func theDoctorReportsThePendingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-doctor-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        let doctor = Doctor(
            home: home, probes: Doctor.Probes(systemModel: { nil }, configuredModel: { _, _, _ in nil }))
        let absent = doctor.pendingApprovals()
        #expect(absent.ok && absent.detail.contains("yet"))
        let channel = PendingApprovals(home: home)
        try channel.file(PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil))
        try channel.file(PendingApprovals.request(for: approvalRequest("x"), client: nil, pid: 999_999, timeout: nil))
        let used = doctor.pendingApprovals()
        #expect(used.ok && used.detail.contains("1 waiting") && used.detail.contains("1 stale"), "\(used.detail)")
        chmod(channel.directory.path, 0o777)
        let open = doctor.pendingApprovals()
        #expect(!open.ok && open.detail.contains("chmod 700"))
    }

    @Test func theSweepRemovesOldLeftoversAndKeepsFreshOnes() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        try channel.ensureDirectory()
        let old = Date().addingTimeInterval(-600)
        func leftover(_ name: String, aged: Bool) throws {
            let url = channel.directory.appending(path: name)
            try Data("{".utf8).write(to: url)
            if aged { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        }
        try leftover("deadbeef.answer.json", aged: true)  // an answer whose request is gone
        try leftover(".crashed.tmp", aged: true)
        try leftover("cafebabe.request.json", aged: true)  // does not decode
        try leftover("feedface.answer.json", aged: false)  // too fresh to judge
        #expect(channel.sweep().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: channel.directory.path)
        #expect(left == ["feedface.answer.json"])
    }

    @Test func progressLinesSayWhereARequestWaitsWithoutItsID() {
        let request = PendingApprovals.request(for: approvalRequest(), client: "c", timeout: nil)
        let filed = AuditEvent(
            session: "t", kind: .approvalPending,
            details: AuditEvent.Details.approvalPending(request, outcome: "filed", alongside: "elicitation"))
        #expect(ChatEvents.progress(filed) == "· also waiting in wisp approvals pending and wisp-tui")
        for (via, place) in [("tui", "wisp-tui"), ("cli", "wisp approvals"), ("elicitation", "the client's dialog")] {
            let settled = AuditEvent(
                session: "t", kind: .approvalSettled,
                details: AuditEvent.Details.approvalSettled(request, outcome: "answered", via: via, decision: "once"))
            #expect(ChatEvents.progress(settled) == "· answered in \(place)")
        }
        let failed = AuditEvent(
            session: "t", kind: .approvalPending,
            details: AuditEvent.Details.approvalPending(request, outcome: "failed", alongside: nil, reason: "x"))
        #expect(ChatEvents.progress(failed) == nil)
        #expect(OutOfBandApprover.face("other") == "other")
    }

    @Test func aRelayAnswerThatCannotBeWrittenSaysSo() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let sent = SentLines()
        let sink = MemoryAuditSink()
        let relay = PendingRelay(
            channel: channel, router: router, audit: AuditLog(session: "chat", sink: sink), send: sent.keep)
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        relay.poll()
        try channel.answer(request.id, decision: "no", via: "cli")  // the command line got there first
        router.receive(#"{"type":"answer","id":"mcp-\#(request.id)","decision":"once"}"#)
        for _ in 0..<100 where sent.of("note").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent.of("note").first?["text"]?.stringValue?.contains("already has an answer") == true)
        #expect(sink.events.last?.details["delivery"] == "refused")
    }
}
