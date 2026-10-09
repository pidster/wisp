import Foundation
import Testing

@testable import WispCore

@Suite struct ApprovalStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "wisp-approvals-\(UUID().uuidString)/approvals.json")
    }

    /// Two stores on one file, as `wisp mcp` and `wisp approvals revoke` in a terminal are: each sees the other's
    /// grants, and a revocation made by one is never undone by the other's next grant (the 2026-10-09 review).
    @Test func twoStoresOnOneFileMergeAndRevocationsWin() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = ApprovalStore(url: url)
        let terminal = ApprovalStore(url: url)
        let first = try await server.grant(
            pattern: "touch *", directory: "/a", scope: .project, level: .moderate, source: "mcp")
        let second = try await terminal.grant(
            pattern: "mv *", directory: "/a", scope: .project, level: .moderate, source: "cli")
        #expect(Set(await server.all.map(\.id)) == [first.id, second.id])
        #expect(try await terminal.revoke(id: first.id))
        #expect(await server.find(pattern: "touch *", directory: "/a") == nil)
        let third = try await server.grant(
            pattern: "cp *", directory: "/a", scope: .project, level: .moderate, source: "mcp")
        #expect(Set(await terminal.all.map(\.id)) == [second.id, third.id])
        #expect(Set(await ApprovalStore(url: url).all.map(\.id)) == [second.id, third.id])
        try await terminal.clear()
        #expect(await server.all.isEmpty)
        // Written whole and private, with the lock beside it.
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(FileManager.default.fileExists(atPath: url.path + ".lock"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted() == [
                "approvals.json", "approvals.json.lock",
            ])
    }

    @Test func concurrentGrantsFromTwoStoresAreAllKept() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stores = [ApprovalStore(url: url), ApprovalStore(url: url)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await stores[index % 2].grant(
                        pattern: "p\(index) *", directory: "/a", scope: .project, level: .safe, source: "t")
                }
            }
            try await group.waitForAll()
        }
        #expect(await stores[0].all.count == 20)
    }

    @Test func grantsFindsPersistsAndRevokes() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ApprovalStore(url: url)
        let project = try await store.grant(
            pattern: "swift *", directory: "/a", scope: .project, level: .moderate, source: "chat")
        let always = try await store.grant(
            pattern: "git *", directory: "/a", scope: .always, level: .moderate, source: "mcp")
        #expect(await store.find(pattern: "swift *", directory: "/a")?.id == project.id)
        #expect(await store.find(pattern: "swift *", directory: "/b") == nil)
        #expect(await store.find(pattern: "git *", directory: "/anywhere")?.id == always.id)
        #expect(await store.find(pattern: "gh *", directory: "/a") == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let reloaded = ApprovalStore(url: url)
        #expect(await reloaded.all.map(\.id).sorted() == [project.id, always.id].sorted())
        #expect(try await reloaded.revoke(id: project.id))
        #expect(!(try await reloaded.revoke(id: project.id)))
        #expect(await ApprovalStore(url: url).all.map(\.id) == [always.id])
        try await reloaded.clear()
        #expect(await ApprovalStore(url: url).all.isEmpty)
    }

    @Test func expiredEntriesAreIgnoredAndDroppedOnLoad() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let short = ApprovalStore(url: url, lifetime: .seconds(0))
        _ = try await short.grant(pattern: "ls *", directory: "/", scope: .always, level: .moderate, source: "t")
        #expect(await short.find(pattern: "ls *", directory: "/") == nil)
        #expect(await ApprovalStore(url: url).all.isEmpty)
    }

    @Test func unreadableFileMeansEmpty() async throws {
        let url = temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{not json".utf8).write(to: url)
        #expect(await ApprovalStore(url: url).all.isEmpty)
    }

    @Test func configResolvesLifetime() {
        #expect(Config().resolved.approvalLifetime == .seconds(30 * 24 * 3600))
        #expect(Config(approval: .init(persistDays: 1)).resolved.approvalLifetime == .seconds(24 * 3600))
    }
}

@Suite struct PersistedApprovalGateTests {
    struct Fixed: RiskClassifier {
        let level: RiskLevel
        func classify(command: String, workingDirectory: String) async -> RiskAssessment {
            RiskAssessment(level: level, reasons: ["because"], sources: ["fixed"])
        }
    }

    final class Answering: Approver {
        let decision: ApprovalDecision
        let asked = MemoryAuditSink()
        init(_ decision: ApprovalDecision) { self.decision = decision }
        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            asked.write(AuditEvent(session: "x", kind: .approvalRequested))
            return decision
        }
    }

    @Test func projectApprovalPersistsAcrossGatesAndIsAudited() async throws {
        let store = ApprovalStore(url: nil)
        let sink = MemoryAuditSink()
        let approver = Answering(.approved(.project))
        let first = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .level(.moderate),
            audit: AuditLog(session: "s", sink: sink), store: store, source: .chat)
        try await first.clear(command: "swift test", workingDirectory: "/repo")
        #expect(sink.events.last?.details["decision"] == "approved")
        #expect(sink.events.last?.details["scope"] == "project")
        #expect(sink.events.last?.details["approvalID"] != nil)
        // A new gate (new process) with the same store does not ask.
        let second = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: Answering(.denied("should not ask")),
            threshold: .level(.moderate),
            audit: AuditLog(session: "s2", sink: sink), store: store, source: .chat)
        try await second.clear(command: "swift test", workingDirectory: "/repo")
        #expect(sink.events.last?.details["decision"] == "cached-project")
        // A different directory asks again.
        await #expect(throws: ApprovalGate.Failure.self) {
            try await second.clear(command: "swift test", workingDirectory: "/other")
        }
        #expect(approver.asked.events.count == 1)
    }

    @Test func dangerousCommandsAreNeverPersisted() async throws {
        let store = ApprovalStore(url: nil)
        let sink = MemoryAuditSink()
        let gate = ApprovalGate(
            classifier: Fixed(level: .dangerous), approver: Answering(.approved(.always)), threshold: .level(.moderate),
            audit: AuditLog(session: "s", sink: sink), store: store, source: .chat)
        try await gate.clear(command: "rm -rf build", workingDirectory: "/repo")
        #expect(sink.events.last?.details["scope"] == "session")
        #expect(sink.events.last?.details["downgradedFrom"] == "always")
        #expect(await store.all.isEmpty)
        // Cached for the session, though.
        try await gate.clear(command: "rm -rf build", workingDirectory: "/repo")
        #expect(sink.events.last?.details["decision"] == "cached")
    }

    @Test func approvalsAreRememberedPerPatternNotPerArguments() async throws {
        let approver = Answering(.approved(.session))
        let gate = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .level(.moderate),
            store: ApprovalStore(url: nil))
        try await gate.clear(command: "head -x 1 -y 2 -z 3", workingDirectory: "/")
        try await gate.clear(command: "head -n 5 other.txt", workingDirectory: "/")
        #expect(approver.asked.events.count == 1)
        try await gate.clear(command: "tail -n 5", workingDirectory: "/")
        #expect(approver.asked.events.count == 2)
    }

    @Test func eachSimpleCommandInALineIsApprovedSeparately() async throws {
        struct ByName: RiskClassifier {
            func classify(command: String, workingDirectory: String) async -> RiskAssessment {
                let level: RiskLevel = command.hasPrefix("ls") ? .safe : .moderate
                return RiskAssessment(level: level, reasons: [command], sources: ["byname"])
            }
        }
        final class Recorder: Approver {
            let seen = MemoryAuditSink()
            func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
                seen.write(
                    AuditEvent(
                        session: "x", kind: .approvalRequested,
                        details: [
                            "command": .string(request.command), "line": .string(request.line),
                            "pattern": .string(request.pattern),
                        ]))
                return request.command.hasPrefix("rm") ? .denied("no") : .approved(.once)
            }
        }
        let recorder = Recorder()
        let gate = ApprovalGate(classifier: ByName(), approver: recorder, threshold: .level(.moderate))
        try await gate.clear(command: "ls && touch a | wc -l", workingDirectory: "/")
        #expect(recorder.seen.events.map { $0.details["command"]?.stringValue } == ["touch a", "wc -l"])
        #expect(recorder.seen.events.first?.details["pattern"] == "touch *")
        #expect(recorder.seen.events.first?.details["line"] == "ls && touch a | wc -l")
        await #expect(throws: ApprovalGate.Failure.refused("rm -r x: no")) {
            try await gate.clear(command: "ls; rm -r x; echo after", workingDirectory: "/")
        }
        await #expect(throws: ApprovalGate.Failure.refused("no")) {
            try await gate.clear(command: "rm -r x", workingDirectory: "/")
        }
    }

    @Test func sessionApprovalsCanBeSharedAcrossGates() async throws {
        let shared = SessionApprovals()
        let approver = Answering(.approved(.session))
        let first = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .level(.moderate),
            sessionApprovals: shared)
        let second = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: Answering(.denied("should not ask")),
            threshold: .level(.moderate),
            sessionApprovals: shared)
        try await first.clear(command: "touch a", workingDirectory: "/repo")
        try await second.clear(command: "touch b", workingDirectory: "/repo")
        #expect(approver.asked.events.count == 1)
    }

    @Test func refusalsAreReportedAndCleared() async throws {
        let gate = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: Answering(.denied("no")), threshold: .level(.moderate))
        await #expect(throws: ApprovalGate.Failure.self) {
            try await gate.clear(command: "touch a", workingDirectory: "/")
        }
        #expect(await gate.takeRefusals() == [Refusal(command: "touch a", reason: "no")])
        #expect(await gate.takeRefusals().isEmpty)
    }

    @Test func refusalsBelongToTheTurnTheyHappenedIn() async throws {
        let turns = TurnClock()
        let gate = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: Answering(.denied("no")), threshold: .level(.moderate),
            turns: turns)
        turns.advance()
        await #expect(throws: ApprovalGate.Failure.self) {
            try await gate.clear(command: "touch a", workingDirectory: "/")
        }
        turns.advance()
        #expect(await gate.takeRefusals().isEmpty)
    }

    @Test func onceCoversTheRestOfTheTurnOnly() async throws {
        let approver = Answering(.approved(.once))
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let gate = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .level(.moderate), audit: audit,
            store: ApprovalStore(url: nil))
        audit.beginTurn()
        try await gate.clear(command: "touch x", workingDirectory: "/")
        try await gate.clear(command: "touch y", workingDirectory: "/")  // same pattern, same turn
        #expect(approver.asked.events.count == 1)
        #expect(sink.events.last?.details["decision"] == "cached-turn")
        audit.beginTurn()
        try await gate.clear(command: "touch z", workingDirectory: "/")  // next turn asks again
        #expect(approver.asked.events.count == 2)
    }

    @Test func onceFollowsTheClockWithoutAnAuditLog() async throws {
        let approver = Answering(.approved(.once))
        let turns = TurnClock()
        let gate = ApprovalGate(
            classifier: Fixed(level: .moderate), approver: approver, threshold: .level(.moderate), turns: turns)
        turns.advance()
        try await gate.clear(command: "touch x", workingDirectory: "/")
        try await gate.clear(command: "touch x", workingDirectory: "/")
        #expect(approver.asked.events.count == 1)
        turns.advance()
        try await gate.clear(command: "touch x", workingDirectory: "/")
        #expect(approver.asked.events.count == 2)
    }
}
