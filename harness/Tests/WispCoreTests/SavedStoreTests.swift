import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Saving a thread's record beside its transcript, and resuming with the links intact.
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
        _ saved: TranscriptStore.Saved, linked: Bool = true, steps: [ScriptedModel.Step] = [.say("resumed")]
    )
        -> (Agent, ScriptedModel)
    {
        let model = ScriptedModel(steps: steps)
        let agent = Agent(
            transcript: saved.transcript, tools: [],
            model: ResolvedModel(selection: .system, custom: model, contextSize: 10_000),
            links: linked ? saved.links : nil)
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
        let saved = try store.loadThread("chat")
        let links = saved.links
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
        let again = try store.loadThread("again").links
        #expect(again.sessions == links.sessions && again.entries.map(\.sources) == links.entries.map(\.sources))
        #expect(again.entries.map(\.origin).allSatisfy { $0 != .turn })
    }

    @Test func theFirstRequestAfterResumeIsWhatALinklessResumeSends() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        let linked = try store.loadThread("chat")
        var requests: [Data] = []
        for withLinks in [true, false] {
            let saved = linked
            let (resumed, model) = resume(saved, linked: withLinks)
            _ = try await resumed.respond(to: "after resume")
            let first = try #require(model.script.requests.withLock { $0.first })
            requests.append(try Self.withoutIDs(first.transcript))
            // The request carries the saved entries, then the new prompt.
            #expect(Array(first.transcript).dropLast().map(\.id) == Array(saved.transcript).map(\.id))
        }
        #expect(requests[0] == requests[1])
    }

    @Test func aSaveWithoutLinksCannotBeResumed() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        // Saving the transcript alone drops links a previous save left.
        try store.save(agent.transcript, as: "chat")
        #expect(!FileManager.default.fileExists(atPath: try store.linksURL(for: "chat").path))
        #expect(throws: TranscriptStore.Failure.notResumable("chat")) { try store.loadThread("chat") }
        // The transcript itself still loads, and lists.
        #expect(try store.load("chat").map(\.id) == agent.transcript.map(\.id))
        #expect(try store.list() == ["chat"])
        #expect(
            TranscriptStore.Failure.notResumable("chat").description
                == "transcript 'chat' was saved by an older wisp and cannot be resumed; start a new conversation")
        #expect(throws: TranscriptStore.Failure.notFound("nope")) { try store.loadThread("nope") }
    }

    @Test func aStoreHoldingTheModelsThinkingSavesAndResumes() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let model = ScriptedModel(
            steps: [.think("Is 91 prime? 7 times 13."), .say("No."), .say("ok")],
            capabilities: [.toolCalling, .guidedGeneration, .reasoning])
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model, contextSize: 10_000))
        _ = try await agent.respond(to: "Is 91 prime?")
        #expect(agent.store.holdsReasoning)
        try store.save(agent.store, as: "chat")
        // Nothing staged is left beside the pair.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["chat.json", "chat.store"])
        let saved = try store.loadThread("chat")
        let (resumed, _) = resume(saved)
        let thought = try #require(resumed.store.entries.first { $0.kind == .reasoning })
        #expect(ThreadRecord.text(of: thought.value) == "Is 91 prime? 7 times 13." && thought.origin == .resumed)
        #expect(resumed.store.entries.map(\.kind) == agent.store.entries.map(\.kind))
        // Still never composed into a request.
        #expect(!resumed.transcript.contains { if case .reasoning = $0 { true } else { false } })
    }

    @Test func aCorruptOrMismatchedStoreFileCannotBeResumed() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let agent = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(agent.store, as: "chat")
        let links = try store.linksURL(for: "chat")
        let good = try Data(contentsOf: links)
        // Not JSON at all.
        try Data("{ nope".utf8).write(to: links)
        // Each cause is said apart (it was always "saved by an older wisp").
        do {
            _ = try store.loadThread("chat")
            Issue.record("a corrupt store resumed")
        } catch let failure as TranscriptStore.Failure {
            guard case .unreadableStore("chat", _) = failure else {
                Issue.record("\(failure)")
                return
            }
            #expect(failure.description.contains("its store, chat.store, cannot be read"))
        }
        // Links of another conversation: valid JSON that names entries the transcript does not have.
        let other = try await condensedAgent(sink: MemoryAuditSink())
        try store.save(other.store, as: "other")
        try Data(contentsOf: store.linksURL(for: "other")).write(to: links)
        #expect(throws: TranscriptStore.Failure.mismatchedStore("chat")) { try store.loadThread("chat") }
        #expect(TranscriptStore.Failure.mismatchedStore("chat").description.contains("does not match it"))
        // A future version this build cannot read.
        var future = try JSONDecoder().decode(ThreadRecord.Snapshot.self, from: good)
        future.version = 99
        try JSONEncoder().encode(future).write(to: links)
        #expect(throws: TranscriptStore.Failure.storeVersion("chat", version: 99)) { try store.loadThread("chat") }
        // The agent itself also carries the transcript alone when handed links that do not match.
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
