import Foundation
import MCP
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// A thread factory whose threads run a `ScriptedModel` through the real `ConversationThread` and
/// `Agent`, so the server is tested over the same objects it uses in production, with no model. Each
/// new thread says its id, then "again", then "done".
func scriptedThreads(
    _ session: Session, _ approver: any Approver, _ id: String, _ instructions: String?, _ tools: ToolSelection,
    _ model: ModelSelection?
) throws -> OpenThread {
    let conversation = try session.conversation(
        id: id, approver: approver, instructions: instructions, tools: tools, model: model)
    let agent = Agent(
        instructions: conversation.prompting.rendered, tools: conversation.tools,
        model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("\(id):"), .say("again")])),
        audit: conversation.audit)
    return OpenThread(
        thread: ConversationThread(id: id, agent: agent), gate: conversation.gate, audit: conversation.audit,
        receipts: conversation.receipts)
}

/// A session over a scratch home, with a memory audit sink and a denying approver.
func scratchSession(
    entryPoint: EntryPoint = .mcp, dependencies: Session.Dependencies = .testing(), config: String? = nil
) throws -> Session {
    let root = FileManager.default.temporaryDirectory.appending(path: "wisp-mcp-tests-\(UUID().uuidString)")
    let home = Home(root: root)
    try home.ensure()
    if let config { try Data(config.utf8).write(to: home.configFile) }
    return try Session.begin(.init(entryPoint: entryPoint), home: home, dependencies: dependencies)
}

@Suite struct WispServerTests {
    let server: WispServer
    let fakeServer: WispServer

    init() throws {
        server = WispServer(session: try scratchSession())
        fakeServer = WispServer(session: try scratchSession(), makeThread: scriptedThreads)
    }

    @Test func respondUsesTheThreadFactoryAndReportsCreation() async throws {
        let first = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "thread_id": .string("t")]))
        #expect(first.isError == false)
        #expect(first.structuredContent?.objectValue?["created"] == .bool(true))
        #expect(first.structuredContent?.objectValue?["text"] == .string("t:"))
        let second = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("again"), "thread_id": .string("t")]))
        #expect(second.structuredContent?.objectValue?["created"] == .bool(false))
        #expect(second.structuredContent?.objectValue?["text"] == .string("again"))
        #expect(second.structuredContent?.objectValue?["receipt"]?.objectValue?["turn"] == .int(2))
    }

    @Test func threadsShareTheSessionsStoreAndSessionApprovals() async throws {
        struct Grant: Approver {
            func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .approved(.project) }
        }
        let session = try scratchSession()
        // Two threads opened from the same session share one store and one session-approval set.
        let first = try session.conversation(id: "a", approver: Grant())
        try await first.gate.clear(command: "touch a", workingDirectory: "/repo")
        #expect(await session.store.find(pattern: "touch *", directory: "/repo")?.source == "mcp")
        let second = try session.conversation(id: "b", approver: DenyingApprover(reason: "must not ask"))
        try await second.gate.clear(command: "touch b", workingDirectory: "/repo")
    }

    @Test func respondReportsAnEmptyRefusalListByDefault() async throws {
        let result = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "thread_id": .string("r")]))
        #expect(result.structuredContent?.objectValue?["refusals"] == .array([]))
    }

    @Test func settingsOnAnExistingThreadAreRefused() async throws {
        _ = try await fakeServer.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "thread_id": .string("u")]))
        let result = try await fakeServer.call(
            .init(
                name: "respond",
                arguments: ["prompt": .string("x"), "thread_id": .string("u"), "instructions": .string("new")]))
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("only when a thread is created"))
        let closed = try await fakeServer.call(.init(name: "close_thread", arguments: ["thread_id": .string("u")]))
        #expect(closed.isError == false)
    }

    @Test func unknownToolIsAProtocolError() async {
        await #expect(throws: MCPError.self) { try await server.call(.init(name: "nope", arguments: nil)) }
    }

    @Test func servesTheToolCatalogueAsResources() async throws {
        #expect(
            ToolCatalog.resources.map(\.uri) == [
                "wisp://tools", "wisp://tools.md", "wisp://config", "wisp://status", "wisp://threads",
                "wisp://approvals", "wisp://audit", "wisp://measurements",
            ])
        let json = try await server.read(.init(uri: "wisp://tools"))
        #expect(json.contents.first?.text?.contains("\"name\" : \"read_file\"") == true)
        #expect(json.contents.first?.mimeType == "application/json")
        let markdown = try await server.read(.init(uri: "wisp://tools.md"))
        #expect(markdown.contents.first?.text?.hasPrefix("# wisp tools") == true)
        let measured = try await server.read(.init(uri: "wisp://measurements"))
        #expect(measured.contents.first?.mimeType == "application/json")
        #expect(measured.contents.first?.text?.hasPrefix("[") == true)
        await #expect(throws: MCPError.self) { try await server.read(.init(uri: "wisp://nope")) }
    }

    @Test func closingUnknownThreadIsAToolError() async throws {
        let result = try await server.call(.init(name: "close_thread", arguments: ["thread_id": .string("nope")]))
        #expect(result.isError == true)
    }

    @Test func respondWithUnknownToolNameIsAToolError() async throws {
        let result = try await server.call(
            .init(name: "respond", arguments: ["prompt": .string("hi"), "tools": .array([.string("nope")])]))
        #expect(result.isError == true)
    }
}
