import Foundation
import MCP
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// Approving a proposed permanent fact over MCP, through the client's elicitation (ADR 0044, amended
/// 2026-09-30; decisions D2 and D3 of the layered-context proposal), driven over the real protocol: the turn's
/// result comes back first, then one fieldless dialog per proposal; Accept admits it, Decline is remembered,
/// silence leaves it waiting, and a client without elicitation is never asked.
@Suite struct FactApprovalWireTests {
    /// A thread whose model proposes a permanent entity for each `name=value` in a prompt of the form
    /// `propose name=value;name=value`, as distillation would, and otherwise just replies.
    actor ProposingThread: RespondingThread {
        /// The conversation.
        let agent: Agent

        init(agent: Agent) { self.agent = agent }

        func respond(to prompt: String, schema: OutputSchema?) async throws -> Agent.Reply {
            let reply = try await agent.respond(to: prompt)
            guard prompt.hasPrefix("propose ") else { return reply }
            for pair in prompt.dropFirst(8).split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                agent.record(
                    FactBook.Assertion(
                        identity: FactIdentity(scope: .permanent, subject: "entity", name: parts[0]), source: .model,
                        value: parts[1], temporalClass: .permanent, method: .distilled,
                        detail: "the person said, turn \(agent.turns.current)", turn: agent.turns.current))
            }
            agent.refreshFacts()
            return reply
        }

        func facts() async -> [Fact]? {
            agent.syncProposals()
            return agent.allFacts
        }
    }

    /// What the client was asked and how it answered.
    final class Dialogs: Sendable {
        let asked = Mutex<[CreateElicitation.Parameters.FormParameters]>([])
        var count: Int { asked.withLock { $0.count } }
        var last: CreateElicitation.Parameters.FormParameters? { asked.withLock { $0.last } }
    }

    /// A connected client, with elicitation answered by `answer` when given, and the server over a session
    /// whose approval wait is `timeoutSeconds`.
    private func connected(
        answer: (@Sendable () async throws -> CreateElicitation.Result.Action)?, timeoutSeconds: Int = 30
    ) async throws -> (client: Client, server: WispServer, sink: MemoryAuditSink, dialogs: Dialogs) {
        let sink = MemoryAuditSink()
        let session = try scratchSession(
            dependencies: .testing(sink: sink), config: #"{"approval": {"timeoutSeconds": \#(timeoutSeconds)}}"#)
        let server = WispServer(session: session) { session, approver, id, instructions, tools, model in
            let conversation = try session.conversation(
                id: id, approver: approver, instructions: instructions, tools: .none, model: model)
            let agent = try conversation.openAgent(
                on: ResolvedModel(
                    selection: .system, custom: ScriptedModel(steps: Array(repeating: .say("ok"), count: 4))))
            return OpenThread(
                thread: ProposingThread(agent: agent), gate: conversation.gate, audit: conversation.audit,
                receipts: conversation.receipts, relay: conversation.relay)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let dialogs = Dialogs()
        let client: Client
        if let answer {
            client = Client(name: "wire-test", version: "0", capabilities: .init(elicitation: .init(form: .init())))
            _ = await client.withElicitationHandler { parameters in
                if case .form(let form) = parameters { dialogs.asked.withLock { $0.append(form) } }
                return CreateElicitation.Result(action: try await answer(), content: nil)
            }
        } else {
            client = Client(name: "wire-test", version: "0", capabilities: .init())
        }
        _ = try await client.connect(transport: transports.client)
        return (client, server, sink, dialogs)
    }

    /// A resource's JSON.
    private func read(_ client: Client, _ uri: String) async throws -> [String: Value] {
        let text = try await client.readResource(uri: uri).first?.text ?? ""
        return try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
    }

    @Test func acceptAdmitsTheFactAfterTheTurnHasReturnedInAFieldlessDialog() async throws {
        let pair = try await connected(answer: { .accept })
        let result = try await call(
            pair.client, "respond", ["prompt": "propose release codename=BLUE HERON", "thread_id": "git"])
        #expect(result.isError != true)
        await pair.server.factAsks.settled()
        #expect(pair.dialogs.count == 1)
        let form = try #require(pair.dialogs.last)
        #expect(
            form.message.hasPrefix(
                "Keep as a permanent fact? release codename: BLUE HERON (proposed by the model, from the person's "
                    + "words in turn 1)"))
        #expect(
            form.message.contains("Conversation: git (fact c1)")
                && form.message.contains("No answer within 30 seconds leaves it waiting in wisp://facts/proposed."))
        #expect(form.requestedSchema.title == "wisp: keep as a permanent fact?")
        #expect(form.requestedSchema.properties.isEmpty)
        // Admitted as approved by the person, listed under wisp://facts, and no longer proposed.
        let kept = try await read(pair.client, "wisp://facts")
        let fact = try #require(kept["facts"]?.arrayValue?.first?.objectValue)
        #expect(fact["id"] == "p1" && fact["value"] == "BLUE HERON" && fact["approved"] != nil)
        #expect(fact["uri"] == "wisp://facts/p1")
        #expect(try await read(pair.client, "wisp://facts/proposed")["total"] == 0)
        // The thread's own copy is superseded by it.
        let own = try await read(pair.client, "wisp://threads/git/facts/c1")
        #expect(own["fact"]?.objectValue?["supersededBy"] == "p1")
        let kinds = pair.sink.events.map(\.kind)
        #expect(kinds.contains(.factApprovalAsked) && kinds.contains(.factApproved))
        let decided = try #require(pair.sink.events.first { $0.kind == .factApprovalDecided })
        #expect(
            decided.session == "git" && decided.details["decision"] == "approved" && decided.details["admitted"] == "p1"
        )
        // The same value proposed again is already kept, so nothing is asked.
        _ = try await call(
            pair.client, "respond", ["prompt": "propose release codename=Blue Heron", "thread_id": "t2"])
        await pair.server.factAsks.settled()
        #expect(pair.dialogs.count == 1)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func declineLeavesTheProposalWithTheThreadAndIsNotAskedAgain() async throws {
        let pair = try await connected(answer: { .decline })
        _ = try await call(
            pair.client, "respond", ["prompt": "propose codename=BLUE HERON;team=Platform", "thread_id": "a"])
        await pair.server.factAsks.settled()
        // One question per proposal, one after the other.
        let titles = pair.dialogs.asked.withLock { $0.map(\.requestedSchema.title) }
        #expect(titles == ["wisp: keep as a permanent fact? (1 of 2)", "wisp: keep as a permanent fact? (2 of 2)"])
        #expect(try await read(pair.client, "wisp://facts")["total"] == 0)
        #expect(try await read(pair.client, "wisp://facts/proposed")["total"] == 0)
        let own = try await read(pair.client, "wisp://threads/a/facts")
        #expect(own["facts"]?.arrayValue?.compactMap { $0.objectValue?["proposed"] } == [true, true])
        // Another thread proposing the same value is not asked about; a new value is.
        _ = try await call(pair.client, "respond", ["prompt": "propose codename=blue heron", "thread_id": "b"])
        await pair.server.factAsks.settled()
        #expect(pair.dialogs.count == 2)
        let waiting = try #require(try await read(pair.client, "wisp://facts/proposed")["facts"]?.arrayValue)
        #expect(waiting.compactMap { $0.objectValue?["reference"] } == ["b/c1"])
        #expect(waiting.first?.objectValue?["asked"] == false)
        _ = try await call(pair.client, "respond", ["prompt": "propose codename=GREY HERON", "thread_id": "b"])
        await pair.server.factAsks.settled()
        #expect(pair.dialogs.count == 3)
        #expect(
            pair.sink.events.filter { $0.kind == .factApprovalDecided }.map { $0.details["decision"] } == [
                "declined", "declined", "declined",
            ])
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func noAnswerWithinTheWaitLeavesTheProposalWaitingAndTheTurnNeverWaits() async throws {
        let pair = try await connected(
            answer: {
                try await Task.sleep(for: .seconds(2))
                return .accept
            }, timeoutSeconds: 1)
        _ = try await call(pair.client, "respond", ["prompt": "propose codename=BLUE HERON", "thread_id": "slow"])
        // The result came back before the dialog was answered.
        #expect(!pair.sink.events.contains { $0.kind == .factApprovalDecided })
        await pair.server.factAsks.settled()
        let decided = try #require(pair.sink.events.first { $0.kind == .factApprovalDecided })
        #expect(decided.details["decision"] == "timed-out" && decided.details["admitted"] == nil)
        let waiting = try await read(pair.client, "wisp://facts/proposed")
        #expect(waiting["total"] == 1 && waiting["facts"]?.arrayValue?.first?.objectValue?["asked"] == true)
        #expect(try await read(pair.client, "wisp://facts")["total"] == 0)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func theLedgerKnowsWhichResponsesWereWritten() async {
        let ledger = ResponseLedger()
        for message in [
            #"{"jsonrpc":"2.0","id":7,"result":{}}"#, #"{"jsonrpc":"2.0","id":"a","error":{"code":1}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"elicitation/create"}"#, #"{"jsonrpc":"2.0","id":true,"result":{}}"#,
            "not json",
        ] {
            ledger.record(Data(message.utf8))
        }
        #expect(ledger.hasSent("n:7") && ledger.hasSent("s:a") && !ledger.hasSent("n:8") && !ledger.hasSent("n:1"))
        #expect(ResponseLedger.key(.number(7)) == "n:7" && ResponseLedger.key(.string("a")) == "s:a")
        // Outside a request handler there is nothing to wait for; a response never written is waited for no
        // longer than the limit.
        #expect(ResponseLedger.currentRequest() == nil)
        await ledger.waitForResponse(to: nil, atMost: .seconds(60))
        await ledger.waitForResponse(to: "n:99", atMost: .milliseconds(20))
        for number in 0..<(ResponseLedger.capacity + 1) {
            ledger.record(Data(#"{"id":\#(number + 100),"result":{}}"#.utf8))
        }
        #expect(!ledger.hasSent("n:7") && ledger.hasSent("n:\(ResponseLedger.capacity + 100)"))
    }

    @Test func aClientWithoutElicitationIsNotAskedAndTheProposalWaits() async throws {
        let pair = try await connected(answer: nil)
        _ = try await call(pair.client, "respond", ["prompt": "propose codename=BLUE HERON", "thread_id": "plain"])
        await pair.server.factAsks.settled()
        #expect(!pair.sink.events.contains { $0.kind == .factApprovalAsked })
        let waiting = try await read(pair.client, "wisp://facts/proposed")
        let row = try #require(waiting["facts"]?.arrayValue?.first?.objectValue)
        #expect(row["reference"] == "plain/c1" && row["thread_id"] == "plain" && row["asked"] == false)
        #expect(row["uri"] == "wisp://threads/plain/facts/c1" && row["proposed"] == true)
        await pair.client.disconnect()
        await pair.server.stop()
    }
}
