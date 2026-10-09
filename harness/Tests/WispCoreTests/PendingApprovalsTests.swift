import Darwin
import Foundation
import Synchronization
import Testing

@testable import WispCore

/// A scratch pending channel under the temporary directory.
func scratchChannel() -> PendingApprovals {
    PendingApprovals(
        directory: FileManager.default.temporaryDirectory.appending(path: "wisp-pending-\(UUID().uuidString)"))
}

/// A gate's request for `command`.
func approvalRequest(_ command: String = "git push origin main", thread: String? = "git") -> ApprovalRequest {
    ApprovalRequest(
        command: command, pattern: "git push *", workingDirectory: "/tmp/repo",
        assessment: RiskAssessment(level: .moderate, reasons: ["publishes commits"], sources: ["rules"]),
        thread: thread)
}

/// The channel: filing, listing, answering, taking, binding, staleness, and the directory's safety.
@Suite struct PendingApprovalsTests {
    /// Requests filed at the same moment on a fresh channel are all filed: the directory is never seen open to
    /// others while it is being created (FileManager created it and then set its mode, and a request filed in
    /// between was refused).
    @Test func requestsFiledAtOnceOnAFreshChannelAreAllFiled() async throws {
        for _ in 0..<20 {
            let channel = scratchChannel()
            defer { try? FileManager.default.removeItem(at: channel.directory) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for tag in 0..<8 {
                    group.addTask {
                        try channel.file(
                            PendingApprovals.request(
                                for: approvalRequest("git tag v\(tag)"), client: nil, timeout: .seconds(60)))
                    }
                }
                try await group.waitForAll()
            }
            #expect(channel.waiting().count == 8)
        }
    }

    @Test func aRequestIsFiledAnsweredAndTakenOnce() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest(), client: "claude-code", timeout: .seconds(60))
        try channel.file(request)
        // The directory and the file are the user's alone.
        let directoryMode = try FileManager.default.attributesOfItem(atPath: channel.directory.path)[.posixPermissions]
        #expect(directoryMode as? Int == 0o700)
        let file = channel.directory.appending(path: "\(request.id).request.json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(channel.waiting() == [request])
        #expect(channel.take(request) == nil, "no answer yet")
        let answered = try channel.answer(request.id, decision: "session", via: "cli")
        #expect(answered == request)
        #expect(channel.delivery(of: request.id) == .waiting)
        guard case .answer(let answer)? = channel.take(request) else { Issue.record("no answer taken"); return }
        #expect(answer.decision == "session" && answer.via == "cli" && answer.binding == request.binding)
        #expect(!channel.isFiled(request) && channel.waiting().isEmpty)
        #expect(channel.delivery(of: request.id) == .taken)
        // The id is spent: answering again finds nothing.
        #expect(throws: PendingApprovals.Failure.unknown(request.id)) {
            try channel.answer(request.id, decision: "once", via: "cli")
        }
    }

    @Test func theFirstAnswerWins() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        try channel.answer(request.id, decision: "no", via: "tui")
        #expect(throws: PendingApprovals.Failure.answered(request.id)) {
            try channel.answer(request.id, decision: "always", via: "cli")
        }
        guard case .answer(let answer)? = channel.take(request) else { Issue.record("no answer"); return }
        #expect(answer.decision == "no" && answer.via == "tui")
    }

    @Test func anAlteredRequestIsNotAnswered() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest("git status"), client: nil, timeout: nil)
        try channel.file(request)
        // Someone swaps the command after it was filed; the binding no longer matches what would be shown.
        let file = channel.directory.appending(path: "\(request.id).request.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "git status", with: "git push --force")
        try Data(text.utf8).write(to: file)
        #expect(throws: PendingApprovals.Failure.altered(request.id)) {
            try channel.answer(request.id, decision: "once", via: "cli")
        }
    }

    /// The reasons shown and the expiry are bound too: changing either in the file refuses the answer, and a file
    /// changed to claim the older binding is refused by the server, which keeps the binding it computed (the
    /// 2026-10-09 review). A request filed by an older wisp, without a binding version, can still be answered.
    @Test func reasonsAndExpiryAreBoundAndOlderRequestsStillAnswer() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest("git status"), client: nil, timeout: .seconds(600))
        #expect(request.bindingVersion == 2 && request.binding == request.expectedBinding)
        var reasons = request
        reasons.reasons = ["a harmless read"]
        #expect(reasons.expectedBinding != request.binding)
        var expiry = request
        expiry.expiresAt = request.expiresAt?.addingTimeInterval(3600)
        #expect(expiry.expectedBinding != request.binding)
        try channel.file(request)
        let file = channel.directory.appending(path: "\(request.id).request.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "publishes commits", with: "a harmless read").utf8).write(to: file)
        #expect(throws: PendingApprovals.Failure.altered(request.id)) {
            try channel.answer(request.id, decision: "once", via: "cli")
        }
        // Claiming the first binding set: the answer is computed over it, and the server refuses it.
        var downgraded = request
        downgraded.bindingVersion = nil
        downgraded.binding = downgraded.expectedBinding
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(downgraded).write(to: file)
        try channel.answer(request.id, decision: "once", via: "cli")
        guard case .rejected = channel.take(request) else {
            Issue.record("a downgraded binding was taken")
            return
        }
        // An older request file, with no binding version, decodes and answers as before.
        var older = PendingApprovals.request(for: approvalRequest("git log"), client: nil, timeout: nil)
        older.bindingVersion = nil
        older.binding = older.expectedBinding
        try channel.file(older)
        let decoded = try channel.request(id: older.id)
        #expect(decoded.bindingVersion == nil && decoded.expectedBinding == older.binding)
        try channel.answer(older.id, decision: "once", via: "cli")
        guard case .answer = channel.take(older) else {
            Issue.record("an older request was not answered")
            return
        }
    }

    @Test func anAnswerBoundToAnotherRequestIsRejectedAndTheWaitGoesOn() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        // An answer replayed from another request, under this one's id: its binding is the other's.
        let other = PendingApprovals.request(for: approvalRequest("rm -rf build"), client: nil, timeout: nil)
        let replay = PendingApprovals.Answer(
            id: request.id, binding: other.binding, decision: "always", via: "cli", pid: getpid(), answeredAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(replay).write(to: channel.directory.appending(path: "\(request.id).answer.json"))
        #expect(channel.take(request) == .rejected("the answer was not bound to this request"))
        #expect(channel.isFiled(request), "the request still waits")
        try channel.answer(request.id, decision: "once", via: "cli")
        guard case .answer(let answer)? = channel.take(request) else { Issue.record("no answer"); return }
        #expect(answer.decision == "once")
    }

    @Test func staleRequestsAreSkippedAndSwept() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let now = Date()
        let expired = PendingApprovals.request(
            for: approvalRequest("a"), client: nil, now: now.addingTimeInterval(-120), timeout: .seconds(60))
        let orphan = PendingApprovals.request(for: approvalRequest("b"), client: nil, pid: 999_999, timeout: nil)
        let live = PendingApprovals.request(for: approvalRequest("c"), client: nil, timeout: nil)
        for request in [expired, orphan, live] { try channel.file(request) }
        let alive: (Int32) -> Bool = { $0 != 999_999 }
        #expect(channel.waiting(now: now, alive: alive).map(\.command) == ["c"])
        #expect(throws: PendingApprovals.Failure.stale(expired.id)) {
            try channel.answer(expired.id, decision: "once", via: "cli", now: now, alive: alive)
        }
        #expect(Set(channel.sweep(now: now, alive: alive).map(\.command)) == ["a", "b"])
        #expect(channel.waiting(now: now, alive: alive) == [live])
        #expect(channel.sweep(now: now, alive: alive).isEmpty)
    }

    @Test func anAnswerToAWithdrawnRequestIsTooLate() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(request)
        try channel.answer(request.id, decision: "once", via: "cli")
        channel.withdraw(request)  // the client's dialog answered first
        #expect(channel.delivery(of: request.id) == .tooLate)
        #expect(channel.delivery(of: request.id) == .taken, "the stray answer was removed")
    }

    @Test func refusesBadIdsDecisionsAndAnOpenDirectory() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        #expect(throws: PendingApprovals.Failure.unknown("../approvals")) {
            _ = try channel.request(id: "../approvals")
        }
        #expect(throws: PendingApprovals.Failure.invalidDecision("maybe")) {
            try channel.answer("abcd1234", decision: "maybe", via: "cli")
        }
        try channel.ensureDirectory()
        chmod(channel.directory.path, 0o755)
        #expect(throws: PendingApprovals.Failure.self) {
            try channel.file(PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil))
        }
        #expect(PendingApprovals.problem(with: channel.directory.path)?.contains("chmod 700") == true)
    }

    @Test func listsWaitingRequestsForPeopleAndForScripts() {
        let now = Date()
        let request = PendingApprovals.request(
            for: approvalRequest(), client: "claude-code", now: now.addingTimeInterval(-90), timeout: nil)
        let piped = ListingLayout.pending([request], width: nil, now: now)
        #expect(piped == ["\(request.id)\tmoderate\t90\tclaude-code/git\t/tmp/repo\tgit push origin main"])
        let terminal = ListingLayout.pending([request], width: 100, now: now)
        #expect(terminal.first?.hasPrefix("ID") == true && terminal.first?.contains("COMMAND") == true)
        #expect(terminal.last?.contains("1 min") == true && terminal.last?.contains("git push origin main") == true)
    }

    @Test func theDefaultPolicyRefusesTheModelAnsweringAnApproval() {
        let policy = CommandPolicy()
        #expect(policy.check("wisp approvals approve a1b2c3d4") != .allowed)
        #expect(policy.check("/usr/local/bin/wisp approvals deny a1b2c3d4 ") != .allowed)
        #expect(policy.check("wisp approvals pending") == .allowed)
        #expect(policy.check("wisp approvals") == .allowed)
    }
}
