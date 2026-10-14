import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// `run_command`'s `outsideSandbox` through MCP `respond` (ADR 0064): with no way to ask the person (no elicitation,
/// `approval.outOfBand` off), the request is refused with text the model reads, and nothing runs.
@Suite struct RespondOutsideSandboxTests {
    @Test func withNoWayToAskThePersonTheModelIsToldWhy() async throws {
        let sink = MemoryAuditSink()
        let session = try scratchSession(
            dependencies: .testing(sink: sink), config: #"{"approval":{"outOfBand":false}}"#)
        let server = WispServer(session: session) { session, host, id, instructions, tools, model, _, commandTimeout in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model,
                commandTimeout: commandTimeout)
            let script = ScriptedModel(steps: [
                .call(name: "run_command", arguments: #"{"command":"echo hi","outsideSandbox":true}"#), .say("done"),
            ])
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: script))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
        defer { try? FileManager.default.removeItem(at: server.session.home.root) }
        let result = try await server.call(
            .init(name: "respond", arguments: ["prompt": "go", "thread_id": "out", "tools": ["run_command"]]))
        #expect(result.isError == false, "\(result.content)")
        let output = sink.events.first { $0.kind == .toolResult && $0.session == "out" }?.details["output"]
        let text = output?.stringValue ?? ""
        if CommandRunner.isNestedSandbox {
            // Inside another sandbox the request changes nothing: a safe command runs, under that sandbox.
            #expect(text.contains("outsideSandbox changed nothing"), "\(text)")
        } else {
            #expect(text.hasPrefix("error: command not approved: running outside the sandbox"), "\(text)")
            #expect(text.contains("does not support elicitation"), "\(text)")
            #expect(!sink.events.contains { $0.kind == .commandOutcome && $0.session == "out" })
            let requested = sink.events.first { $0.kind == .approvalRequested && $0.session == "out" }
            #expect(requested?.details["outsideSandbox"] == true)
        }
    }
}
