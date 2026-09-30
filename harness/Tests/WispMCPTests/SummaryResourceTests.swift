import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// A thread's running summary over MCP (phase 4b of the layered-context proposal): the thread's facts
/// collection carries the current version as `summary`, and every version under `?all=true`.
@Suite struct SummaryResourceTests {
    @Test func theFactsCollectionCarriesTheSummaryAndItsVersions() async throws {
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
        let listing = try await json(server, "wisp://threads/t/facts")
        let summary = try #require(listing["summary"]?.objectValue)
        #expect(summary["version"] == 2 && summary["text"] == "Then it asked again." && summary["covered"] == 6)
        #expect(listing["summaries"] == nil)
        let all = try await json(server, "wisp://threads/t/facts?all=true")
        #expect(all["summaries"]?.arrayValue?.compactMap { $0.objectValue?["version"] } == [1, 2])
    }
}
