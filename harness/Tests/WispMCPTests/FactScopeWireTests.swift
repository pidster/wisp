import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// Setting a fact's scope over MCP, and the facts a turn recorded in `respond`'s result (decided 2026-09-30,
/// ADR 0044 amended): `set_fact_scope` moves a thread's fact or a session fact to `thread` or `session`, and
/// never moves a permanent fact, driven over the real protocol. Asking for `permanent` is in
/// `FactKeepWireTests` (ADR 0048).
@Suite struct FactScopeWireTests {
    /// A thread whose model records a permanent entity for each `name=value` in a prompt of the form
    /// `propose name=value;name=value`, as distillation would, and otherwise just replies.
    actor ProposingThread: RespondingThread {
        /// The conversation.
        let agent: Agent

        init(agent: Agent) { self.agent = agent }

        func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply {
            var reply = try await agent.respond(to: prompt)
            guard prompt.hasPrefix("propose ") else { return reply }
            for pair in prompt.dropFirst(8).split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                agent.record(
                    FactBook.Assertion(
                        identity: FactIdentity(scope: .permanent, subject: "entity", name: parts[0]), source: .model,
                        value: parts[1], temporalClass: .permanent, method: .distilled, turn: agent.turns.current))
            }
            agent.refreshFacts()
            reply.facts = agent.factsChangedThisTurn
            return reply
        }

        func facts() async -> [Fact]? {
            agent.syncProposals()
            return agent.allFacts
        }

        func setFactScope(_ id: String, to target: FactTarget) async throws -> Fact {
            try agent.setFactScope(id, to: target, by: .caller)
        }

        func keepAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact {
            try agent.keepAsked(shown, request: request)
        }

        func dropAsked(_ shown: PendingApprovals.ProposedFact, request: String) async throws -> Fact {
            try agent.dropAsked(shown, request: request)
        }
    }

    /// A connected client and server over threads that propose facts.
    static func connected(
        session: (MemoryAuditSink) throws -> Session = { try scratchSession(dependencies: .testing(sink: $0)) }
    ) async throws -> (client: Client, server: WispServer, sink: MemoryAuditSink) {
        let sink = MemoryAuditSink()
        let session = try session(sink)
        let server = WispServer(session: session) { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: .none, model: model)
            let agent = try thread.openAgent(
                on: ResolvedModel(
                    selection: .system, custom: ScriptedModel(steps: Array(repeating: .say("ok"), count: 6))))
            return OpenThread(
                thread: ProposingThread(agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: "wire-test", version: "0", capabilities: .init())
        _ = try await client.connect(transport: transports.client)
        return (client, server, sink)
    }

    /// A connected client and server over threads that propose facts.
    private func connected() async throws -> (client: Client, server: WispServer, sink: MemoryAuditSink) {
        try await Self.connected()
    }

    /// A resource's JSON.
    static func read(_ client: Client, _ uri: String) async throws -> [String: Value] {
        let text = try await client.readResource(uri: uri).first?.text ?? ""
        return try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
    }

    /// A resource's JSON.
    private func read(_ client: Client, _ uri: String) async throws -> [String: Value] {
        let text = try await client.readResource(uri: uri).first?.text ?? ""
        return try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
    }

    @Test func respondListsTheFactsTheTurnRecordedAndSetFactScopeMovesThem() async throws {
        let pair = try await connected()
        let quiet = try await call(pair.client, "respond", ["prompt": "hello", "thread_id": "git"])
        #expect(quiet.structuredContent?.objectValue?["facts"] == .array([]))
        let result = try await call(
            pair.client, "respond", ["prompt": "propose release codename=BLUE HERON;team=Platform", "thread_id": "git"])
        let facts = try #require(result.structuredContent?.objectValue?["facts"]?.arrayValue)
        let first = try #require(facts.first?.objectValue)
        #expect(facts.count == 2 && first["id"] == "c1" && first["scope"] == "thread" && first["proposed"] == true)
        #expect(first["subject"] == "entity" && first["name"] == "release codename" && first["value"] == "BLUE HERON")
        #expect(first["source"] == "model" && first["uri"] == "wisp://threads/git/facts/c1")
        // A proposal moved to `thread` stops being proposed, in place.
        let kept = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "thread"])
        #expect(kept.isError == false)
        let keptFact = try #require(kept.structuredContent?.objectValue?["fact"]?.objectValue)
        #expect(keptFact["id"] == "c1" && keptFact["proposed"] == false && keptFact["scope"] == "thread")
        // Moved to the session, it is a session fact with a new id, and the thread's copy is superseded.
        let shared = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c2", "scope": "session"])
        #expect(shared.isError == false)
        let sessionFact = try #require(shared.structuredContent?.objectValue?["fact"]?.objectValue)
        #expect(sessionFact["id"] == "s1" && sessionFact["scope"] == "session" && sessionFact["proposed"] == false)
        #expect(sessionFact["uri"] == "wisp://session/facts")
        #expect(shared.structuredContent?.objectValue?["from"] == "c2")
        let machine = try await read(pair.client, "wisp://session/facts")
        #expect(machine["facts"]?.arrayValue?.first?.objectValue?["value"] == "Platform")
        #expect(try await read(pair.client, "wisp://facts/proposed")["total"] == 0)
        let own = try await read(pair.client, "wisp://threads/git/facts/c2")
        #expect(own["fact"]?.objectValue?["supersededBy"] == "s1")
        // A session fact comes back to a thread by naming the thread.
        let back = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "s1", "scope": "thread"])
        #expect(back.structuredContent?.objectValue?["fact"]?.objectValue?["id"] == "c3")
        // Each move was audited as the caller's.
        let changes = pair.sink.events.filter { $0.kind == .factScopeChanged }
        #expect(changes.map { $0.details["by"] } == ["caller", "caller", "caller"])
        #expect(changes.map { $0.details["to"] } == ["thread", "session", "thread"])
        #expect(changes.map { $0.details["from"] } == ["thread", "thread", "session"])
        for event in pair.sink.events where event.kind == .factScopeChanged {
            #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind)))
        }
    }

    @Test func aPermanentFactIsNeverMovedAndMistakesAreToolErrors() async throws {
        let pair = try await connected()
        _ = try await call(pair.client, "respond", ["prompt": "propose team=Platform", "thread_id": "git"])
        for arguments in [
            ["thread_id": "git", "fact_id": "p1", "scope": "thread"],
            ["thread_id": "git", "fact_id": "p1", "scope": "session"],
        ] as [[String: Value]] {
            do {
                _ = try await call(pair.client, "set_fact_scope", arguments)
                Issue.record("\(arguments) was accepted")
            } catch let error as MCPError {
                #expect("\(error)".contains("the person's"), "\(error)")
            }
        }
        #expect(pair.server.session.permanentFacts.facts.isEmpty)
        for (arguments, message) in [
            (["thread_id": "nope", "fact_id": "c1", "scope": "thread"], "no open thread nope"),
            (["thread_id": "git", "fact_id": "c9", "scope": "thread"], "no current fact c9"),
            (["thread_id": "git", "fact_id": "s9", "scope": "session"], "no current fact s9"),
        ] as [([String: Value], String)] {
            let result = try await call(pair.client, "set_fact_scope", arguments)
            #expect(result.isError == true)
            #expect(
                result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined().contains(
                    message))
        }
        // Moving a fact to the scope it is in, when it is not a proposal, is refused as well.
        _ = try await call(pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "thread"])
        let again = try await call(
            pair.client, "set_fact_scope", ["thread_id": "git", "fact_id": "c1", "scope": "thread"])
        #expect(again.isError == true)
    }
}
