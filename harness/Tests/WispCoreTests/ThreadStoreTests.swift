import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The thread store (ADR 0066): every thread saved under `threads/<id>/` with its start settings beside its record,
/// held by one process at a time, and swept `threads.keepDays` after its last use with its stored outputs.
@Suite struct ThreadStoreTests {
    /// A fresh home in the temporary directory.
    private func home() throws -> Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-threads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Home(root: root)
    }

    /// A store after one turn of a scripted agent, as a thread's record is after its first turn.
    private func record(prompt: String = "first") async throws -> ThreadRecord {
        let agent = Agent(
            instructions: "Run git.", tools: [],
            model: ResolvedModel(
                selection: .system,
                custom: ScriptedModel(steps: [
                    .say("one")
                ])), audit: AuditLog(session: "git-aaaaaaaa", sink: MemoryAuditSink()))
        _ = try await agent.respond(to: prompt)
        return agent.store
    }

    /// Settings with whole-second times, which `thread.json`'s ISO 8601 dates keep exactly.
    private func settings(
        _ id: String = "git", lastUsed: Date = Date(timeIntervalSince1970: 1_800_000_000)
    )
        -> ThreadStore.Settings
    {
        var settings = ThreadStore.Settings(
            id: id, owner: "claude-code", model: "ollama:granite4.1:8b", tools: ["run_command"],
            instructions: "Run git.", think: "false", commandTimeoutSeconds: 600, session: "\(id)-aaaaaaaa",
            now: lastUsed)
        settings.turns = 1
        return settings
    }

    /// The POSIX permissions of `url`.
    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func settingsAndRecordRoundTripInUserOnlyFiles() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let saved = settings()
        try store.save(saved, record: try await record())
        let loaded = try #require(try store.load("git"))
        #expect(loaded.settings == saved)
        #expect(loaded.transcript.contains { if case .prompt = $0 { true } else { false } })
        #expect(try store.record("git")?.entries.count == (try await record()).entries.count)
        #expect(store.all.map(\.id) == ["git"])
        // The directory and every file are the user's alone: a record holds tool output.
        #expect(try mode(store.directory(of: "git")) == 0o700)
        for file in ["thread.json", "record.json", "record.store"] {
            #expect(try mode(store.directory(of: "git").appending(path: file)) == 0o600, "\(file)")
        }
        // Settings alone, over the record already there, as a resume links its new session at once.
        try store.save(saved.reopened(as: "git-bbbbbbbb"), record: nil)
        #expect(try store.settings("git")?.sessions == ["git-aaaaaaaa", "git-bbbbbbbb"])
        #expect(try store.settings("git")?.reopened(as: "git-bbbbbbbb").sessions.count == 2, "a session is added once")
        #expect(
            saved.described == "model ollama:granite4.1:8b, tools run_command, instructions set, think false, "
                + "commandTimeoutSeconds 600")
        try store.delete("git")
        #expect(
            try store.load("git") == nil && !FileManager.default.fileExists(atPath: store.directory(of: "git").path))
    }

    @Test func aRecordWithoutSettingsIsNotResumableAndSettingsWithoutARecordSaySo() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        // A save cut short before its first thread.json: the record alone is not a saved thread.
        try store.ensure("torn")
        try store.records("torn").save(try await record(), as: ThreadStore.recordName)
        #expect(try store.load("torn") == nil)
        #expect(!store.all.contains { $0.id == "torn" } && store.ids.contains("torn"))
        // thread.json beside no record cannot be resumed, and says how to clear it.
        try store.save(settings("bare"), record: nil)
        #expect {
            try store.load("bare")
        } throws: { error in
            (error as? ThreadStore.Failure)?.description
                == "thread bare cannot be resumed: its record, record.json, is missing; close_thread bare deletes it, or delete threads/bare/ in wisp's home (~/.wisp by default)"
        }
    }

    @Test func aNewerFormatIsRefusedByVersionAndUnsafeIdsAreRefused() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        try store.ensure("next")
        try Data(#"{"version":2,"something":"else"}"#.utf8).write(
            to: store.directory(of: "next").appending(path: "thread.json"))
        #expect(throws: ThreadStore.Failure.version("next", 2)) { try store.settings("next") }
        try Data("not json".utf8).write(to: store.directory(of: "next").appending(path: "thread.json"))
        #expect(throws: ThreadStore.Failure.self) { try store.settings("next") }
        for id in ["..", ".", ".hidden", String(repeating: "a", count: 49), "a/b"] {
            #expect(!ThreadStore.isValid(id), "\(id)")
            #expect(throws: ThreadStore.Failure.invalidID(id)) { try store.delete(id) }
        }
        #expect(ThreadStore.isValid(String(repeating: "a", count: 48)) && ThreadStore.isValid("git.2"))
    }

    @Test func aThreadIsHeldByOneOpeningAtATime() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let first = try store.lock("git", owner: "claude-code")
        #expect(first.isHeld && store.holder(of: "git") == ThreadLock.Holder(pid: getpid(), owner: "claude-code"))
        // A second opening, as another process's would, is refused naming the holder.
        #expect(throws: ThreadStore.Failure.held("git", .init(pid: getpid(), owner: "claude-code"))) {
            try store.lock("git", owner: "codex")
        }
        #expect(
            ThreadStore.Failure.held("git", .init(pid: 4242, owner: "claude-code")).description
                == "thread git is open in another wisp (pid 4242, claude-code)")
        #expect(ThreadStore.Failure.held("git", nil).description == "thread git is open in another wisp")
        #expect(
            ThreadStore.Failure.held("git", .init(pid: 5, owner: nil)).description
                == "thread git is open in another wisp (pid 5)")
        #expect(
            ThreadStore.Failure.held("git", .init(pid: 0, owner: "codex")).description
                == "thread git is open in another wisp", "a holder whose pid the lock does not say adds nothing")
        first.release()
        first.release()
        #expect(!first.isHeld && store.holder(of: "git") == nil)
        let second = try store.lock("git", owner: "codex")
        #expect(store.holder(of: "git")?.owner == "codex")
        second.release()
        #expect(store.holder(of: "never") == nil)
    }

    @Test func theSweepDeletesThreadsUnusedForKeepDaysWithTheirOutputsAndSparesTheRest() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let now = Date()
        func output(_ session: String) throws {
            let directory = home.outputs.appending(path: session, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "3f9a2c1b")
            try Data(repeating: 0x61, count: 10).write(to: file)
            for url in [file, directory] {
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: url.path)
            }
        }
        var old = settings("old", lastUsed: now.addingTimeInterval(-40 * 86_400))
        old.sessions = ["old-aaaaaaaa"]
        var recent = settings("recent", lastUsed: now.addingTimeInterval(-2 * 86_400))
        recent.sessions = ["recent-aaaaaaaa"]
        var held = settings("held", lastUsed: now.addingTimeInterval(-40 * 86_400))
        held.sessions = ["held-aaaaaaaa"]
        for thread in [old, recent, held] {
            try store.save(thread, record: nil)
            try output(thread.sessions[0])
        }
        try output("loose-aaaaaaaa")
        let lock = try store.lock("held", owner: "claude-code")
        defer { lock.release() }
        #expect(ThreadSweep(home: home, days: 0, now: now).run().swept.isEmpty, "0 keeps every thread")
        let outcome = ThreadSweep(home: home, days: 30, now: now).run()
        #expect(outcome.swept.map(\.id) == ["old"] && outcome.swept.first?.outputBytes == 10)
        #expect(outcome.kept == ["recent-aaaaaaaa", "held-aaaaaaaa"], "a held thread is never swept")
        #expect(store.ids == ["held", "recent"])
        #expect(!FileManager.default.fileExists(atPath: home.outputs.appending(path: "old-aaaaaaaa").path))
        // The output sweep that follows spares a saved thread's outputs and takes the rest by age.
        let outputs = OutputSweep(home: home, days: 30, now: now).run(current: "now", keep: outcome.kept)
        #expect(outputs.removed == ["loose-aaaaaaaa"])
        #expect(Set(outcome.swept.first?.details.keys.map { $0 } ?? []) == AuditEvent.fields(for: .threadSwept))
    }

    /// Saves `count` threads named `t0`..., `t0` the oldest, each 40 days older than the last by one day, with a session.
    private func saveAged(_ count: Int, in store: ThreadStore, now: Date) throws {
        for index in 0..<count {
            var thread = settings("t\(index)", lastUsed: now.addingTimeInterval(-Double(60 - index) * 86_400))
            thread.sessions = ["t\(index)-aaaaaaaa"]
            try store.save(thread, record: nil)
        }
    }

    @Test func theSweepLeavesAThreadItCannotReadAndAgesOneWithoutSettingsByItsDirectory() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let now = Date()
        // A newer format is another wisp's to judge, however old.
        try store.ensure("next")
        try Data(#"{"version":2}"#.utf8).write(to: store.directory(of: "next").appending(path: "thread.json"))
        // A thread opened and never saved has no thread.json; its directory's age is its age.
        try store.ensure("unsaved")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * 86_400)],
            ofItemAtPath: store.directory(of: "unsaved").path)
        let outcome = ThreadSweep(home: home, days: 30, now: now).run()
        #expect(outcome.swept.map(\.id) == ["unsaved"])
        #expect(outcome.swept.first?.owner == nil && outcome.swept.first?.turns == 0)
        #expect(outcome.swept.first?.sessions == [] && outcome.swept.first?.details["owner"] == .null)
        #expect(store.ids == ["next"], "an unreadable thread.json is left alone")
    }

    @Test func theSweepDeletesAtMostItsLimitOldestFirstAndKeepsTheSessionsOfTheRest() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let now = Date()
        try saveAged(4, in: store, now: now)
        let outcome = ThreadSweep(home: home, days: 30, now: now).run(limit: 2)
        #expect(outcome.swept.map(\.id) == ["t0", "t1"], "oldest first")
        #expect(outcome.deferred == 2)
        #expect(outcome.kept == ["t2-aaaaaaaa", "t3-aaaaaaaa"], "what waits for a later start keeps its outputs")
        #expect(store.ids == ["t2", "t3"])
        #expect(ThreadSweep.removalLimit == 16 && ThreadSweep.deadline == .milliseconds(100))
    }

    @Test func theSweepStopsOnceItsDeadlineHasPassed() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let now = Date()
        try saveAged(3, in: store, now: now)
        let outcome = ThreadSweep(home: home, days: 30, now: now).run(deadline: .zero)
        #expect(outcome.swept.isEmpty && outcome.deferred == 3)
        #expect(outcome.kept == ["t0-aaaaaaaa", "t1-aaaaaaaa", "t2-aaaaaaaa"])
        #expect(store.ids == ["t0", "t1", "t2"])
        // A thread opened and never saved, old enough, waits too and has no sessions to keep.
        try store.ensure("unsaved")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * 86_400)],
            ofItemAtPath: store.directory(of: "unsaved").path)
        let later = ThreadSweep(home: home, days: 30, now: now).run(deadline: .zero)
        #expect(later.swept.isEmpty && later.deferred == 4 && later.kept.count == 3)
    }

    @Test func aThreadThatCannotBeDeletedIsKeptWithItsSessionsAndANoOutputSessionIsSkipped() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let now = Date()
        try saveAged(1, in: store, now: now)
        // A session that stored nothing and an unsafe session name are skipped without error.
        var thread = try #require(try store.settings("t0"))
        thread.sessions = ["t0-aaaaaaaa", "../escape"]
        try store.save(thread, record: nil)
        try store.ensure("unsaved")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * 86_400)],
            ofItemAtPath: store.directory(of: "unsaved").path)
        // With threads/ read-only the directory cannot be removed: the thread stays, and so do its outputs' sessions.
        let threads = store.directory(of: "t0").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: threads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: threads.path) }
        let outcome = ThreadSweep(home: home, days: 30, now: now).run()
        #expect(outcome.swept.isEmpty)
        #expect(outcome.kept == ["t0-aaaaaaaa", "../escape"])
        #expect(store.ids == ["t0", "unsaved"])
    }

    @Test func aSweptThreadsOutputsThatCannotBeRemovedDoNotStopItsDeletion() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ThreadStore(home: home)
        let now = Date()
        try saveAged(1, in: store, now: now)
        let directory = home.outputs.appending(path: "t0-aaaaaaaa", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 7).write(to: directory.appending(path: "3f9a2c1b"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.outputs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.outputs.path) }
        let outcome = ThreadSweep(home: home, days: 30, now: now).run()
        #expect(outcome.swept.map(\.id) == ["t0"] && outcome.swept.first?.outputBytes == 7)
        #expect(store.ids.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: directory.path), "the outputs stay for the output sweep's age rule")
    }

    @Test func sessionBeginSweepsAndAuditsEachThreadAndKeepDaysIsASetting() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try ThreadStore(home: home).save(
            settings("stale", lastUsed: Date().addingTimeInterval(-31 * 86_400)), record: nil)
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let swept = try #require(sink.events.first { $0.kind == .threadSwept })
        #expect(swept.details["thread"] == "stale" && swept.session == session.audit.session)
        #expect(sink.events.first?.kind == .sessionStart, "session.start stays the session's first event")
        #expect(Config().resolved.threadsKeepDays == 30)
        #expect(ConfigSettings.defaultValue("threads.keepDays") == .int(30))
        #expect(ConfigSettings.setting("threads.keepDays")?.kind == .integer(0...3650))
        let never = try ConfigEdit.set("threads.keepDays", to: "0", in: nil)
        #expect(try JSONDecoder().decode(Config.self, from: never.data).resolved.threadsKeepDays == 0)
        try Data(#"{"threads":{"keepDays":4000}}"#.utf8).write(to: home.configFile)
        #expect(throws: Session.Failure.self) { try Session.loadConfig(home: home) }
    }

    @Test func aResumedThreadsSessionStartNamesWhatItResumesAndCarriesFrom() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        _ = try session.thread(
            id: "git", host: session.host(approver: DenyingApprover(reason: "x")), tools: .none,
            auditSession: "git-bbbbbbbb",
            resume: "git", carriedFrom: ["git-aaaaaaaa"])
        let start = try #require(sink.events.last { $0.kind == .sessionStart })
        #expect(start.session == "git-bbbbbbbb" && start.details["resume"] == "git")
        #expect(start.details["carriedFrom"] == .array(["git-aaaaaaaa"]))
    }

    @Test func theFactsAPersonDroppedAreExportedAndRestored() {
        let keeper = FactKeeper(
            channel: PendingApprovals(home: Home(root: URL(filePath: "/nonexistent"))), notify: { _, _ in })
        let fact = PendingApprovals.ProposedFact(
            id: "c1", subject: "repo", name: "branch", value: "main", source: "tool")
        let dropped = ThreadStore.DroppedFact(
            fact: fact, request: "r1", asked: Date(timeIntervalSince1970: 1_800_000_000),
            settled: Date(timeIntervalSince1970: 1_800_000_060))
        #expect(keeper.droppedFacts(thread: "git").isEmpty)
        keeper.restoreDropped([dropped], thread: "git")
        #expect(keeper.droppedFacts(thread: "git") == [dropped])
        keeper.release(thread: "git")
        #expect(keeper.droppedFacts(thread: "git").isEmpty)
    }
}
