import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// A puller whose repository is planned from memory and never fetched: the request is refused before then.
private struct PlanOnlyPuller: ModelPuller {
    func repository(_ text: String) throws -> (repository: String, name: String) {
        (text, String(text.split(separator: "/").last ?? ""))
    }

    func prepare(
        _ text: String, session: Session, notice: @escaping @Sendable (String) -> Void
    ) async throws
        -> PreparedPull
    {
        let (repository, name) = try repository(text)
        return PreparedPull(
            summary: PullSummary(
                repository: repository, name: name, revision: "r", licence: nil, files: 1, bytes: 10, missing: 1,
                remaining: 10, destination: "/m/\(name)", snapshot: "/h/\(name)", replacesDirectory: false, reused: 0,
                seeded: 0, lines: []),
            fetch: { _, _ in
                Issue.record("a refused pull fetched")
                return 0
            },
            link: { _ in ("created", "") })
    }
}

/// The `models` tool under `wisp mcp` (ADR 0059): reachable only through `respond`, on a thread whose `tools` name it,
/// and its questions put as every command's are; with no one to answer (no elicitation, no out-of-band channel), a pull
/// is refused.
@Suite(.timeLimit(.minutes(1))) struct ModelsToolWireTests {
    @Test func aPullThroughRespondWithNobodyToAskIsRefused() async throws {
        let sink = MemoryAuditSink()
        var dependencies = Session.Dependencies.testing(sink: sink)
        dependencies.puller = PlanOnlyPuller()
        let session = try scratchSession(dependencies: dependencies, config: #"{"approval": {"outOfBand": false}}"#)
        defer { try? FileManager.default.removeItem(at: session.home.root) }
        let steps: [ScriptedModel.Step] = [
            .call(name: "models", arguments: #"{"action":"pull","name":"ornith-ai/q"}"#), .say("{tool}"),
        ]
        let server = WispServer(session: session) { session, host, id, instructions, tools, model, _ in
            let thread = try session.thread(id: id, host: host, instructions: instructions, tools: tools, model: model)
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(name: "wire-test", version: "0", capabilities: .init())
        _ = try await client.connect(transport: transports.client)
        // There is no models tool of the server's own: only respond reaches it.
        let listed = try await client.send(ListTools.request(.init()))
        #expect(!(try await listed.value).tools.contains { $0.name == "models" })
        let result = try await call(
            client, "respond", ["prompt": "pull ornith-ai/q", "thread_id": "m", "tools": ["models"]])
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("no text")
            return
        }
        #expect(text.hasPrefix("error: not approved: "), "\(text)")
        let decided = try #require(sink.events.last { $0.kind == .approvalDecided })
        #expect(decided.details["command"] == "models pull ornith-ai/q" && decided.session == "m")
        #expect(sink.events.last { $0.kind == .modelPull }?.details["outcome"] == "declined")
        #expect(session.modelPulls.all.isEmpty)
        await client.disconnect()
        await server.stop()
    }
}
