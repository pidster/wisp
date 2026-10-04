import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// `respond`'s `ran` (ADR 0051), over the real protocol: the line of what the turn ran, counted from its audit
/// events, beside the text the client's model reads, which is unchanged.
@Suite struct TurnToolsWireTests {
    /// A server whose threads open their agent as the real server does, on a scripted model.
    private func connected(steps: [ScriptedModel.Step]) async throws -> (client: Client, server: WispServer) {
        let session = try scratchSession(
            dependencies: .testing(sink: MemoryAuditSink()),
            config: #"{"commandPolicy":{"deny":["^echo forbidden"]}}"#)
        let server = WispServer(session: session) { session, host, id, instructions, tools, model in
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
        return (client, server)
    }

    @Test func respondReturnsWhatTheTurnRanBesideItsText() async throws {
        let pair = try await connected(steps: [
            .call(name: "current_date", arguments: "{}"),
            .call(name: "run_command", arguments: #"{"command":"echo forbidden","workingDirectory":"/"}"#),
            .say("Done: run_command printed it."),
            .say("I used run_command for that."),
        ])
        defer { try? FileManager.default.removeItem(at: pair.server.session.home.root) }
        let result = try await call(pair.client, "respond", ["prompt": "go", "thread_id": "t"])
        let structured = try #require(result.structuredContent?.objectValue)
        #expect(structured["ran"] == .string("ran: current_date · run_command (1 denied)"))
        #expect(structured["calls"]?.arrayValue?.count == 2)
        // The text the client's model reads is the reply alone.
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("no text")
            return
        }
        #expect(text == "Done: run_command printed it.")
        // A turn that ran nothing and names a tool says so; one that names none has no line.
        let second = try await call(pair.client, "respond", ["prompt": "again", "thread_id": "t"])
        #expect(second.structuredContent?.objectValue?["ran"] == .string("ran: no tools"))
        await pair.client.disconnect()
        await pair.server.stop()
    }
}
