import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// A thread's running summary over MCP (phase 4b of the layered-context proposal): its own resource,
/// `wisp://threads/{thread_id}/summary`, carries the current version as `summary`, and every version under
/// `?all=true`; the thread's facts resource holds facts only.
@Suite struct SummaryResourceTests {
    @Test func theSummaryResourceCarriesTheSummaryAndItsVersions() async throws {
        let session = try scratchSession()
        let server = WispServer(session: session) { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model)
            let agent = try thread.openAgent(
                on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
            for (version, text) in [(1, "The caller asked for a count."), (2, "Then it asked again.")] {
                agent.store.summarise(
                    RunningSummary(
                        version: version, text: text, covered: version * 3, turns: [1], entries: [2], audit: [],
                        through: 3, recorded: Date(timeIntervalSince1970: 0), turn: 1, model: "system"))
            }
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "thread_id": "t"]))
        let read = try await json(server, "wisp://threads/t/summary")
        let summary = try #require(read["summary"]?.objectValue)
        #expect(summary["version"] == 2 && summary["text"] == "Then it asked again." && summary["covered"] == 6)
        #expect(read["thread_id"] == "t" && read["versions"] == 2 && read["summaries"] == nil)
        let all = try await json(server, "wisp://threads/t/summary?all=true")
        #expect(all["summaries"]?.arrayValue?.compactMap { $0.objectValue?["version"] } == [1, 2])
        // The facts resource no longer carries it, and the thread's resource points at both.
        let facts = try await json(server, "wisp://threads/t/facts?all=true")
        #expect(facts["summary"] == nil && facts["summaries"] == nil)
        let thread = try await json(server, "wisp://threads/t")
        #expect(thread["resources"]?.objectValue?["summary"] == "wisp://threads/t/summary")
        #expect(ToolCatalog.resourceTemplates.contains { $0.uriTemplate == ToolCatalog.summaryTemplate })
        // Unknown threads fail as the facts resource does.
        await #expect(throws: MCPError.self) { _ = try await server.read(.init(uri: "wisp://threads/none/summary")) }
    }

    @Test func aThreadWithoutASummaryYetReadsNull() async throws {
        let session = try scratchSession()
        let server = WispServer(session: session) { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model)
            let agent = try thread.openAgent(
                on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
        _ = try await server.call(.init(name: "respond", arguments: ["prompt": "hi", "thread_id": "t"]))
        let read = try await json(server, "wisp://threads/t/summary")
        #expect(read["summary"] == .null && read["versions"] == 0)
    }
}
