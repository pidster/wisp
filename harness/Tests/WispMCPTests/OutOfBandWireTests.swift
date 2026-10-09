import Foundation
import MCP
import Synchronization
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// Ids of the server's requests the client was told to drop (`notifications/cancelled`).
final class CancelledIDs: Sendable {
    /// Each id, as received.
    let ids = Mutex<[ID]>([])
}

/// Approval over MCP through another face (ADR 0046), driven over the real protocol: the server's own host
/// asks, a scripted model runs a command that needs approval, and the test answers as `wisp approvals` would.
@Suite(.timeLimit(.minutes(1))) struct OutOfBandWireTests {
    /// A server whose threads use its own host, a client with or without a dialog, and a directory to work in.
    private func connected(
        steps: [ScriptedModel.Step], elicitation: (@Sendable () async throws -> CreateElicitation.Result)? = nil,
        cancelled: CancelledIDs = .init()
    ) async throws -> (client: Client, server: WispServer, sink: MemoryAuditSink, channel: PendingApprovals) {
        let sink = MemoryAuditSink()
        let session = try scratchSession(dependencies: .testing(sink: sink))
        let server = WispServer(session: session) { session, host, id, instructions, tools, model in
            let thread = try session.thread(id: id, host: host, instructions: instructions, tools: tools, model: model)
            let agent = Agent(
                instructions: "x", tools: thread.tools,
                model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)), audit: thread.audit)
            return OpenThread(
                thread: ThreadActor(id: id, agent: agent), gate: thread.gate, audit: thread.audit,
                receipts: thread.receipts)
        }
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.serve(transport: transports.server)
        let client = Client(
            name: "wire-test", version: "0",
            capabilities: elicitation == nil ? .init() : .init(elicitation: .init(form: .init())))
        if let elicitation { _ = await client.withElicitationHandler { _ in try await elicitation() } }
        await client.onNotification(CancelledNotification.self) { message in
            if let id = message.params.requestId { cancelled.ids.withLock { $0.append(id) } }
        }
        _ = try await client.connect(transport: transports.client)
        return (client, server, sink, PendingApprovals(home: session.home))
    }

    /// A scratch directory and the steps that run a command needing approval in it.
    private func workspace() throws -> (URL, [ScriptedModel.Step]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-oob-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (
            dir,
            [
                .call(
                    name: "run_command",
                    arguments: #"{"command":"touch marker.txt && echo approved","workingDirectory":"\#(dir.path)"}"#),
                .say("{tool}"),
            ]
        )
    }

    /// Answers the first request filed in `channel` with `decision`, as `wisp approvals` does.
    private func answerWhenFiled(
        _ channel: PendingApprovals, _ decision: String
    ) -> Task<PendingApprovals.Request?, Never> {
        Task {
            for _ in 0..<500 {
                if let request = channel.waiting().first {
                    _ = try? channel.answer(request.id, decision: decision, via: "cli")
                    return request
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
    }

    @Test func aClientWithoutElicitationIsApprovedFromTheCommandLine() async throws {
        let (dir, steps) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = try await connected(steps: steps)
        let answering = answerWhenFiled(pair.channel, "once")
        let result = try await call(pair.client, "respond", ["prompt": .string("go"), "thread_id": .string("oob")])
        let request = try #require(await answering.value)
        #expect(request.thread == "oob" && request.client == "wire-test")
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("exit status: 0") && text.contains("approved"), "\(text)")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "marker.txt").path))
        let structured = try #require(result.structuredContent?.objectValue)
        #expect(structured["refusals"] == .array([]))
        // The caller learns that the person was notified, but nothing it can answer with.
        let notes = try #require(structured["notifications"]?.arrayValue)
        #expect(notes.count == 1)
        let note = try #require(notes.first?.objectValue)
        #expect(note["source"] == .string("approval") && note["outcome"] == .string("posted"))
        #expect(note["title"] == .string("wisp: approval needed") && note["time"]?.stringValue != nil)
        let thread = pair.sink.events.filter { $0.session == "oob" }.map(\.kind)
        #expect(
            thread.filter { $0.rawValue.hasPrefix("approval") || $0 == .notification } == [
                .approvalRequested, .approvalPending, .notification, .approvalSettled, .approvalDecided,
            ])
        let settled = pair.sink.events.last { $0.kind == .approvalSettled }
        #expect(settled?.details["via"] == "cli" && settled?.details["decision"] == "once")
        #expect(pair.channel.waiting().isEmpty)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func aDenialFromTheCommandLineIsARefusal() async throws {
        let (dir, steps) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = try await connected(steps: steps)
        let answering = answerWhenFiled(pair.channel, "no")
        let result = try await call(pair.client, "respond", ["prompt": .string("go"), "thread_id": .string("no")])
        _ = await answering.value
        let refusals = result.structuredContent?.objectValue?["refusals"]?.arrayValue ?? []
        #expect(refusals.first?.objectValue?["reason"] == .string("declined by the person (wisp approvals)"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "marker.txt").path))
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func withElicitationTheCommandLineCanAnswerFirstAndTheDialogIsWithdrawn() async throws {
        let (dir, steps) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancelled = CancelledIDs()
        // A dialog nobody answers in time, as when Claude Code's sticks.
        let pair = try await connected(
            steps: steps,
            elicitation: {
                try await Task.sleep(for: .seconds(3))  // long past the command line's answer
                return CreateElicitation.Result(action: .decline, content: nil)
            }, cancelled: cancelled)
        let answering = answerWhenFiled(pair.channel, "session")
        let result = try await call(pair.client, "respond", ["prompt": .string("go"), "thread_id": .string("both")])
        _ = await answering.value
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("exit status: 0"), "\(text)")
        let settled = pair.sink.events.last { $0.kind == .approvalSettled }
        #expect(settled?.details["via"] == "cli" && settled?.details["decision"] == "session")
        #expect(pair.sink.events.first { $0.kind == .approvalPending }?.details["alongside"] == "elicitation")
        // The client is told to drop the dialog.
        try await eventually("the dialog cancelled") { !cancelled.ids.withLock { $0.isEmpty } }
        #expect(cancelled.ids.withLock { $0.count } == 1)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func withElicitationTheDialogCanAnswerFirstAndTheRequestIsWithdrawn() async throws {
        let (dir, steps) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = try await connected(
            steps: steps,
            elicitation: { CreateElicitation.Result(action: .accept, content: ["scope": .string("once")]) })
        let result = try await call(pair.client, "respond", ["prompt": .string("go"), "thread_id": .string("dlg")])
        guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("exit status: 0"), "\(text)")
        let settled = pair.sink.events.last { $0.kind == .approvalSettled }
        #expect(settled?.details["via"] == "elicitation")
        #expect(pair.channel.waiting().isEmpty)
        await pair.client.disconnect()
        await pair.server.stop()
    }

    @Test func respondListsTheNotificationsATurnPosted() async throws {
        let pair = try await connected(steps: [
            .call(name: "notify", arguments: #"{"title":"Build","message":"The build passed."}"#), .say("told"),
        ])
        let result = try await call(pair.client, "respond", ["prompt": .string("tell me"), "thread_id": .string("n")])
        let notes = try #require(result.structuredContent?.objectValue?["notifications"]?.arrayValue)
        let note = try #require(notes.first?.objectValue)
        #expect(note["title"] == .string("Build") && note["body"] == .string("The build passed."))
        #expect(note["source"] == .string("model") && note["outcome"] == .string("posted"))
        #expect(["app", "osascript"].contains(note["route"]?.stringValue ?? ""), "\(note)")
        let quiet = try await call(pair.client, "respond", ["prompt": .string("again"), "thread_id": .string("n")])
        #expect(quiet.structuredContent?.objectValue?["notifications"] == .array([]))
        await pair.client.disconnect()
        await pair.server.stop()
    }
}
