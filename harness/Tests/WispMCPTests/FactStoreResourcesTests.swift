import Foundation
import MCP
import Testing
import WispTestSupport

@testable import WispCore
@testable import WispMCP

/// Where each store's facts are served (decided 2026-09-30): a resource lives under what owns it, and a bare
/// path is a collection. `wisp://facts` and `wisp://facts/{fact_id}` for the shared store,
/// `wisp://facts/proposed` for proposals awaiting the person, `wisp://session/facts` for the session's, and
/// `wisp://threads/{thread_id}/facts` for a thread's own only.
@Suite struct FactStoreResourcesTests {
    /// A server whose threads keep facts, opened as the faces open them, over a scripted model.
    private func server() throws -> WispServer {
        WispServer(session: try scratchSession()) { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: .none, model: model)
            let agent = try thread.openAgent(
                on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok"), .say("ok")])))
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts, relay: thread.relay)
        }
    }

    /// An assertion by the person about `subject` `name`.
    private func stated(_ scope: FactScope, _ subject: String, _ name: String, _ value: String) -> FactBook.Assertion {
        FactBook.Assertion(
            identity: FactIdentity(scope: scope, subject: subject, name: name), source: .person, value: value,
            temporalClass: scope == .permanent ? .permanent : .ephemeral, method: .stated)
    }

    @Test func eachStoreIsServedUnderWhatOwnsIt() async throws {
        let server = try server()
        let permanent = server.session.permanentFacts
        try permanent.record(stated(.permanent, "entity", "codename", "BLUE HERON"))
        try permanent.record(stated(.permanent, "entity", "codename", "GREY HERON"))
        try server.session.sessionFacts.record(stated(.session, "service", "port 8080", "listening"))
        _ = try await server.call(
            .init(name: "respond", arguments: ["prompt": "hi", "thread_id": "t", "task": "ship"]))
        // The shared store: current by default, every version with all=true, each with its URI.
        let kept = try await json(server, "wisp://facts")
        let row = try #require(kept["facts"]?.arrayValue?.first?.objectValue)
        #expect(
            kept["total"] == 1 && row["id"] == "p2" && row["uri"] == "wisp://facts/p2" && row["scope"] == "permanent")
        #expect(try await json(server, "wisp://facts?all=true")["total"] == 2)
        let history = try await json(server, "wisp://facts/p2")
        #expect(history["fact"]?.objectValue?["value"] == "GREY HERON")
        #expect(history["history"]?.arrayValue?.compactMap { $0.objectValue?["id"] } == ["p1", "p2"])
        // `proposed` is a collection, never taken for a fact id; a fact id there starts with p.
        let proposed = try await json(server, "wisp://facts/proposed")
        #expect(proposed["total"] == 0 && proposed["facts"] == [])
        #expect(WispServer.isPermanentFactID("p12") && !WispServer.isPermanentFactID("proposed"))
        #expect(!WispServer.isPermanentFactID("p") && !WispServer.isPermanentFactID("c1"))
        #expect(!WispServer.isPermanentFactID("p١"))
        for uri in [
            "wisp://facts/c1", "wisp://facts/p9", "wisp://facts/p1/x", "wisp://facts?page=2", "wisp://facts?page=0",
            "wisp://session/facts/s1", "wisp://session", "wisp://session/facts?page=2",
        ] {
            await #expect(throws: MCPError.self, "\(uri)") { _ = try await server.read(.init(uri: uri)) }
        }
        await #expect(throws: MCPError.self) { _ = try await server.read(.init(uri: "wisp://facts/c1")) }
        do {
            _ = try await server.read(.init(uri: "wisp://facts/s1"))
        } catch let error as MCPError {
            #expect("\(error)".contains("wisp://session/facts"))
        }
        // The session's: the machine now, shared by every thread.
        let machine = try await json(server, "wisp://session/facts")
        let port = try #require(machine["facts"]?.arrayValue?.first?.objectValue)
        #expect(machine["total"] == 1 && port["id"] == "s1" && port["uri"] == nil && port["class"] == "ephemeral")
        #expect(try await json(server, "wisp://session/facts?all=true")["total"] == 1)
        // A thread's collection holds only its own facts; the others point to where they moved.
        let own = try await json(server, "wisp://threads/t/facts")
        #expect(own["facts"]?.arrayValue?.compactMap { $0.objectValue?["id"] } == ["c1"])
        #expect(own["facts"]?.arrayValue?.allSatisfy { $0.objectValue?["scope"] == "thread" } == true)
        for (uri, pointer) in [
            ("wisp://threads/t/facts/p2", "wisp://facts/p2"), ("wisp://threads/t/facts/s1", "wisp://session/facts"),
        ] {
            do {
                _ = try await server.read(.init(uri: uri))
                Issue.record("\(uri) was served")
            } catch let error as MCPError {
                #expect("\(error)".contains(pointer), "\(error)")
            }
        }
        // The summary links every store.
        let links = try #require(try await json(server, "wisp://threads/t")["resources"]?.objectValue)
        #expect(links["facts"] == "wisp://threads/t/facts" && links["sessionFacts"] == "wisp://session/facts")
        #expect(links["permanentFacts"] == "wisp://facts" && links["proposedFacts"] == "wisp://facts/proposed")
        #expect(ToolCatalog.resourceTemplates.contains { $0.uriTemplate == ToolCatalog.permanentFactTemplate })
    }

    @Test func theSharedStoreIsPagedAndTheNextPageKeepsAll() async throws {
        let server = try server()
        for number in 1...51 {
            try server.session.permanentFacts.record(stated(.permanent, "entity", "name \(number)", "v"))
        }
        try server.session.permanentFacts.record(stated(.permanent, "entity", "name 1", "w"))
        let first = try await json(server, "wisp://facts")
        #expect(first["pages"] == 2 && first["next"] == "wisp://facts?page=2" && first["total"] == 51)
        #expect(try await json(server, "wisp://facts?page=2")["facts"]?.arrayValue?.count == 1)
        let all = try await json(server, "wisp://facts?all=true")
        #expect(all["total"] == 52 && all["next"] == "wisp://facts?all=true&page=2")
        #expect(try await json(server, "wisp://facts?all=true&page=2")["facts"]?.arrayValue?.count == 2)
    }
}
