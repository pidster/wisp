import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Saving a conversation's store beside its transcript, and resuming with the links intact.
@Suite struct SavedStoreTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-saved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An agent that has run three turns and condensed once, so its store holds active and dropped entries.
    private func condensedAgent(sink: MemoryAuditSink) async throws -> Agent {
        let model = ScriptedModel(steps: [.say("one"), .say("two"), .say("three")])
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 60),
            contextPolicy: .condense(keepTurns: 1), audit: AuditLog(session: "first", sink: sink))
        _ = try await agent.respond(to: "first")
        _ = try await agent.respond(to: "second")
        _ = try await agent.respond(to: "a long prompt that is long enough to pass the budget of the window")
        #expect(agent.store.entries.contains { $0.state != .active })
        return agent
    }

    private func resume(
        _ saved: TranscriptStore.Saved, steps: [ScriptedModel.Step] = [.say("resumed")]
    )
        -> (Agent, ScriptedModel)
    {
        let model = ScriptedModel(steps: steps)
        let agent = Agent(
            transcript: saved.transcript, tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 10_000), links: saved.links)
        return (agent, model)
    }

    /// A transcript as canonical JSON with the framework's entry ids left out, since the new prompt's is
    /// minted per request.
    private static func withoutIDs(_ transcript: Transcript) throws -> Data {
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object["id"] = nil
                return object.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript))
        return try JSONSerialization.data(withJSONObject: strip(json), options: [.sortedKeys])
    }

    @Test func aSavedStoreResumesWithItsSourcesAndDroppedEntries() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        let saved = try store.loadConversation("chat")
        let links = try #require(saved.links)
        let (resumed, _) = resume(saved)
        // Every entry keeps its id, kind, turn, state, and sources; a turn's entries become `resumed`.
        #expect(resumed.store.entries.count == agent.store.entries.count)
        for (before, after) in zip(agent.store.entries, resumed.store.entries) {
            #expect(before.id == after.id && before.kind == after.kind && before.turn == after.turn)
            #expect(before.sources == after.sources && before.state == after.state)
            #expect(before.value.id == after.value.id)
            #expect(after.origin == (before.origin == .turn ? .resumed : before.origin))
        }
        #expect(resumed.store.entries.contains { $0.origin == .resumed && !$0.sources.isEmpty })
        #expect(resumed.store.entries.contains { $0.state != .active })
        #expect(links.sessions == ["first"])
        // The active view is exactly the saved transcript.
        #expect(resumed.transcript.map(\.id) == saved.transcript.map(\.id))
        // Saved again, the links are the same.
        try store.save(resumed.store, as: "again")
        let again = try #require(try store.loadConversation("again").links)
        #expect(again.sessions == links.sessions && again.entries.map(\.sources) == links.entries.map(\.sources))
        #expect(again.entries.map(\.origin).allSatisfy { $0 != .turn })
    }

    @Test func theFirstRequestAfterResumeIsWhatALinklessResumeSends() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        let linked = try store.loadConversation("chat")
        #expect(linked.links != nil)
        let bare = TranscriptStore.Saved(transcript: linked.transcript, links: nil)
        var requests: [Data] = []
        for saved in [linked, bare] {
            let (resumed, model) = resume(saved)
            _ = try await resumed.respond(to: "after resume")
            let first = try #require(model.script.requests.withLock { $0.first })
            requests.append(try Self.withoutIDs(first.transcript))
            // The request carries the saved entries, then the new prompt.
            #expect(Array(first.transcript).dropLast().map(\.id) == Array(saved.transcript).map(\.id))
        }
        #expect(requests[0] == requests[1])
    }

    @Test func aBareSaveLoadsCarriedWithoutSources() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        // Saving the transcript alone drops links a previous save left.
        try store.save(agent.transcript, as: "chat")
        #expect(!FileManager.default.fileExists(atPath: try store.linksURL(for: "chat").path))
        let saved = try store.loadConversation("chat")
        #expect(saved.links == nil)
        let (resumed, _) = resume(saved)
        #expect(resumed.store.entries.count == agent.transcript.count)
        #expect(resumed.store.entries.allSatisfy { $0.origin == .carried && $0.sources.isEmpty && $0.state == .active })
        #expect(try store.list() == ["chat"])
    }

    @Test func aCorruptOrMismatchedStoreFileFallsBack() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        let links = try store.linksURL(for: "chat")
        let good = try Data(contentsOf: links)
        // Not JSON at all.
        try Data("{ nope".utf8).write(to: links)
        #expect(try store.loadConversation("chat").links == nil)
        // Links of another conversation: valid JSON that names entries the transcript does not have.
        let other = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(other.store, as: "other")
        try Data(contentsOf: store.linksURL(for: "other")).write(to: links)
        let mismatched = try store.loadConversation("chat")
        #expect(mismatched.links == nil && mismatched.transcript.map(\.id) == agent.transcript.map(\.id))
        // A future version this build cannot read.
        var future = try JSONDecoder().decode(ConversationStore.Snapshot.self, from: good)
        future.version = 99
        try JSONEncoder().encode(future).write(to: links)
        #expect(try store.loadConversation("chat").links == nil)
        // The agent itself also falls back when handed links that do not match.
        let (resumed, _) = resume(TranscriptStore.Saved(transcript: agent.transcript, links: future))
        #expect(resumed.store.entries.allSatisfy { $0.origin == .carried })
    }

    @Test func linksAreWrittenBesideTheTranscriptForTheUserOnly() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        for file in [try store.url(for: "chat"), try store.linksURL(for: "chat")] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o600 && file.deletingLastPathComponent().path == dir.path)
        }
        // The transcript file is what `save(_ transcript:)` writes.
        let plain = TranscriptStore(directory: dir)
        try plain.save(agent.transcript, as: "plain")
        #expect(try Data(contentsOf: plain.url(for: "plain")) == Data(contentsOf: plain.url(for: "chat")))
        #expect(try store.load("chat").map(\.id) == agent.transcript.map(\.id))
        #expect(try store.list() == ["chat", "plain"])
    }

    @Test func sessionStartOnResumeNamesTheSessionsTheCarriedEntriesComeFrom() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir)
        try home.ensure()
        let sink = MemoryAuditSink()
        let request = Session.Request(entryPoint: .chat, resume: "chat", carriedFrom: ["a1", "b2"])
        _ = try Session.begin(request, home: home, dependencies: .testing(sink: sink))
        let start = try #require(sink.events.first { $0.kind == .sessionStart })
        #expect(start.details["carriedFrom"] == .array([.string("a1"), .string("b2")]))
        // Without links the field is absent.
        let plain = MemoryAuditSink()
        _ = try Session.begin(
            .init(entryPoint: .chat, resume: "chat"), home: home, dependencies: .testing(sink: plain))
        #expect(plain.events.first { $0.kind == .sessionStart }?.details["carriedFrom"] == nil)
    }
}
