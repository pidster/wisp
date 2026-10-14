import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// `respond`'s `commandTimeoutSeconds` (ADR 0063): the thread's own limit for `run_command`, chosen when the thread
/// starts and refused on one that exists, as `model`, `tools`, and `instructions` are; clamped to
/// `commandMaxTimeoutSeconds`; and never reaching another thread.
@Suite struct RespondCommandTimeoutTests {
    /// A server with a 1-second default and a 5-second cap whose threads open as the real factory opens them, the
    /// thread's limit passed through, each on a scripted model that runs `command` once and then answers.
    private func server(command: String, sink: MemoryAuditSink) throws -> WispServer {
        let session = try scratchSession(
            dependencies: .testing(sink: sink), config: #"{"commandTimeoutSeconds":1,"commandMaxTimeoutSeconds":5}"#)
        return WispServer(session: session) { session, host, id, instructions, tools, model, _, commandTimeout in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model,
                commandTimeout: commandTimeout)
            let script = ScriptedModel(steps: [
                .call(name: "run_command", arguments: #"{"command":"\#(command)"}"#), .say("ran it"), .say("again"),
            ])
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: script))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
    }

    /// The `command.outcome` details recorded for thread `id`.
    private func outcomes(_ sink: MemoryAuditSink, thread id: String) -> [[String: JSONValue]] {
        sink.events.filter { $0.kind == .commandOutcome && $0.session == id }.map(\.details)
    }

    @Test func aThreadsLimitAppliesToItsCommandsAloneAndIsRefusedOnceItExists() async throws {
        let sink = MemoryAuditSink()
        let server = try server(command: "sleep 2; echo done", sink: sink)
        defer { try? FileManager.default.removeItem(at: server.session.home.root) }
        let long = try await server.call(
            .init(
                name: "respond",
                arguments: ["prompt": "go", "thread_id": "long", "tools": ["run_command"], "commandTimeoutSeconds": 4]))
        #expect(long.isError == false, "\(long.content)")
        let longOutcome = try #require(outcomes(sink, thread: "long").first)
        #expect(longOutcome["timedOut"] == false && longOutcome["timeoutSource"] == "thread")
        #expect(longOutcome["timeoutSeconds"] == 4)
        // Another thread keeps the operator's default and is killed at it.
        let short = try await server.call(
            .init(name: "respond", arguments: ["prompt": "go", "thread_id": "short", "tools": ["run_command"]]))
        #expect(short.isError == false, "\(short.content)")
        let shortOutcome = try #require(outcomes(sink, thread: "short").first)
        #expect(shortOutcome["timedOut"] == true && shortOutcome["timeoutSource"] == "default")
        #expect(shortOutcome["timeoutSeconds"] == 1)
        // The thread started with it says so in its session.start.
        let start = sink.events.first { $0.kind == .sessionStart && $0.session == "long" }
        #expect(start?.details["commandTimeoutSeconds"] == 4)
        // On a thread that exists it is refused, as model and tools are.
        let again = try await server.call(
            .init(name: "respond", arguments: ["prompt": "again", "thread_id": "long", "commandTimeoutSeconds": 3]))
        #expect(again.isError == true)
        #expect(
            again.content.description.contains("commandTimeoutSeconds apply only when a thread is created"),
            "\(again.content)")
    }

    @Test func aThreadsLimitAboveTheCapIsClampedToIt() async throws {
        let sink = MemoryAuditSink()
        let server = try server(command: "true", sink: sink)
        defer { try? FileManager.default.removeItem(at: server.session.home.root) }
        _ = try await server.call(
            .init(
                name: "respond",
                arguments: ["prompt": "go", "thread_id": "big", "tools": ["run_command"], "commandTimeoutSeconds": 900]
            ))
        let outcome = try #require(outcomes(sink, thread: "big").first)
        #expect(outcome["timeoutSeconds"] == 5 && outcome["timeoutClamped"] == true)
    }

    @Test func aLimitBelowOneOrNotANumberIsAnArgumentError() async throws {
        let server = try server(command: "true", sink: MemoryAuditSink())
        defer { try? FileManager.default.removeItem(at: server.session.home.root) }
        for bad: Value in [0, -1, "600", 2.5] {
            await #expect(throws: MCPError.self, "\(bad)") {
                try await server.call(
                    .init(name: "respond", arguments: ["prompt": "go", "commandTimeoutSeconds": bad]))
            }
        }
        #expect(
            try RespondRequest(arguments: ["prompt": "x", "commandTimeoutSeconds": 600]).commandTimeoutSeconds == 600)
        #expect(try RespondRequest(arguments: ["prompt": "x"]).commandTimeoutSeconds == nil)
        let properties = ToolCatalog.respond.inputSchema.objectValue?["properties"]?.objectValue
        #expect(properties?["commandTimeoutSeconds"]?.objectValue?["type"] == "integer")
    }
}
