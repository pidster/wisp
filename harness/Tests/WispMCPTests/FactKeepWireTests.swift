import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// Permanent facts over MCP (ADR 0048), driven over the real protocol: a caller asks with `set_fact_scope`
/// `permanent`, the call returns at once, and the test answers as `wisp facts keep|drop` or `wisp-tui` would.
@Suite struct FactKeepWireTests {
    /// The text of a result.
    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    /// Waits until the thread's fact `fact` shows a request that is no longer pending, and returns it.
    private func outcome(_ client: Client, fact: String = "c1") async throws -> [String: Value] {
        for _ in 0..<250 {
            let read = try await FactScopeWireTests.read(client, "wisp://threads/git/facts/\(fact)")
            if let request = read["request"]?.objectValue, request["state"] != "pending" { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func aCallerAsksAndThePersonKeepsTheFactFromTheCommandLine() async throws {
        let pair = try await FactScopeWireTests.connected()
        let channel = PendingApprovals(home: pair.server.session.home)
        defer { try? FileManager.default.removeItem(at: pair.server.session.home.root) }
        let quiet = try await call(pair.client, "respond", ["prompt": "hello", "thread_id": "git"])
        #expect(
            quiet.structuredContent?.objectValue?["factsProposed"]
                == .object(["count": 0, "thread": 0, "uri": "wisp://facts/proposed"]))
        let turn = try await call(
            pair.client, "respond", ["prompt": "propose release codename=BLUE HERON;team=Platform", "thread_id": "git"])
        // The model's proposals wait silently; the result says how many, and where.
        #expect(
            turn.structuredContent?.objectValue?["factsProposed"]
                == .object(["count": 2, "thread": 2, "uri": "wisp://facts/proposed"]))
        #expect(turn.structuredContent?.objectValue?["notifications"] == .array([]))

        let asked = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "permanent"])
        #expect(asked.isError == false)
        let result = try #require(asked.structuredContent?.objectValue)
        let id = try #require(result["request"]?.stringValue)
        #expect(result["state"] == "pending" && result["from"] == "c1" && result["thread_id"] == "git")
        #expect(result["uri"] == "wisp://threads/git/facts/c1" && result["expiresAt"]?.stringValue != nil)
        #expect(result["fact"]?.objectValue?["value"] == "BLUE HERON")
        #expect(text(asked).contains("request \(id)") && text(asked).contains("wisp facts keep or drop"))
        let filed = try #require(channel.waiting(.fact).first)
        #expect(filed.id == id && filed.thread == "git" && filed.client == "wire-test")
        #expect(
            filed.fact
                == .init(id: "c1", subject: "entity", name: "release codename", value: "BLUE HERON", source: "model"))
        // Asking again while it waits returns the same request.
        let again = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "permanent"])
        #expect(again.structuredContent?.objectValue?["request"] == .string(id))
        #expect(text(again).contains("already waiting") && channel.waiting(.fact).count == 1)
        // The proposal shows its request while it waits.
        let proposed = try await FactScopeWireTests.read(pair.client, "wisp://facts/proposed")
        let row = try #require(proposed["facts"]?.arrayValue?.first { $0.objectValue?["id"] == "c1" }?.objectValue)
        #expect(row["request"]?.objectValue?["state"] == "pending" && row["request"]?.objectValue?["id"] == .string(id))

        // The person keeps it, as `wisp facts keep` does.
        try channel.answer(id, decision: "keep", via: "cli")
        let request = try await outcome(pair.client)
        #expect(request["state"] == "kept" && request["kept"] == "p1" && request["via"] == "cli")
        #expect(channel.delivery(of: id) == .taken)
        let kept = try #require(pair.server.session.permanentFacts.current.first)
        #expect(kept.id == "p1" && kept.value == "BLUE HERON" && kept.approved != nil)
        #expect(
            try await FactScopeWireTests.read(pair.client, "wisp://facts/p1")["fact"]?.objectValue?["value"]
                == "BLUE HERON")
        #expect(try await FactScopeWireTests.read(pair.client, "wisp://facts/proposed")["total"] == 1)

        // A caller can neither move nor remove the permanent fact.
        do {
            _ = try await call(pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "p1", "scope": "thread"])
            Issue.record("a caller moved a permanent fact")
        } catch let error as MCPError {
            #expect("\(error)".contains("the person's"))
        }
        #expect(pair.server.session.permanentFacts.current.map(\.id) == ["p1"])

        let events = pair.sink.events
        let pending = try #require(events.first { $0.kind == .approvalPending })
        #expect(pending.details["kind"] == "fact" && pending.details["outcome"] == "filed")
        #expect(pending.details["request"] == .string(id) && pending.details["thread"] == "git")
        let banner = try #require(events.first { $0.kind == .notification })
        #expect(banner.details["title"] == "wisp: keep as a permanent fact?" && banner.details["source"] == "approval")
        #expect(banner.details["body"] == .string("release codename = BLUE HERON — wisp facts keep \(id)"))
        let settled = try #require(events.first { $0.kind == .approvalSettled })
        #expect(settled.details["decision"] == "keep" && settled.details["kept"] == "p1")
        let change = try #require(events.first { $0.kind == .factScopeChanged })
        #expect(change.details["by"] == "person" && change.details["request"] == .string(id))
        #expect(change.details["to"] == "permanent")
        for event in events where [.approvalPending, .approvalSettled, .factScopeChanged].contains(event.kind) {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind)))
        }
    }

    @Test func aDroppedFactStaysInItsThreadAndIsNotAskedAboutAgain() async throws {
        let pair = try await FactScopeWireTests.connected()
        let channel = PendingApprovals(home: pair.server.session.home)
        defer { try? FileManager.default.removeItem(at: pair.server.session.home.root) }
        _ = try await call(
            pair.client, "respond", ["prompt": "propose release codename=BLUE HERON", "thread_id": "git"])
        let asked = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "permanent"])
        let id = try #require(asked.structuredContent?.objectValue?["request"]?.stringValue)
        try channel.answer(id, decision: "drop", via: "tui")
        let request = try await outcome(pair.client)
        #expect(request["state"] == "dropped" && request["kept"] == .null && request["via"] == "tui")
        #expect(pair.server.session.permanentFacts.facts.isEmpty)
        // The fact is still the thread's, no longer proposed, so it no longer waits for the person.
        let fact = try await FactScopeWireTests.read(pair.client, "wisp://threads/git/facts/c1")["fact"]?.objectValue
        #expect(fact?["state"] == "current" && fact?["proposed"] == false)
        #expect(try await FactScopeWireTests.read(pair.client, "wisp://facts/proposed")["total"] == 0)
        // The thread is not asked about it again.
        let again = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "permanent"])
        #expect(again.isError == true && text(again).contains("the person dropped release codename = BLUE HERON"))
        #expect(channel.waiting(.fact).isEmpty)
        // Asking about a fact the thread does not have is an error, and nothing is filed.
        let missing = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c9", "scope": "permanent"])
        #expect(missing.isError == true && text(missing).contains("no current fact c9"))
    }

    @Test func closingTheThreadWithdrawsItsRequest() async throws {
        let pair = try await FactScopeWireTests.connected()
        let channel = PendingApprovals(home: pair.server.session.home)
        defer { try? FileManager.default.removeItem(at: pair.server.session.home.root) }
        _ = try await call(pair.client, "respond", ["prompt": "propose team=Platform", "thread_id": "git"])
        _ = try await call(pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "permanent"])
        #expect(channel.waiting(.fact).count == 1)
        _ = try await call(pair.client, "close_thread", ["thread_id": "git"])
        for _ in 0..<250 where !channel.waiting(.fact).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(channel.waiting(.fact).isEmpty)
        for _ in 0..<250 where pair.server.factKeeper.records.first?.state == .pending {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pair.server.factKeeper.records.first?.state == .withdrawn)
        #expect(pair.sink.events.contains { $0.kind == .approvalSettled && $0.details["outcome"] == "withdrawn" })
    }
}
