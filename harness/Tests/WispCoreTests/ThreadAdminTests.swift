import Foundation
import Testing

@testable import WispCore

/// `wisp threads` (ADR 0066, phase 3): the store listed and shown, a thread deleted with the stored outputs no other
/// thread names, and handed to another owner, both refused while a process holds it; the policy refusing the two to
/// wisp's model; and the doctor's report of the store.
@Suite struct ThreadAdminTests {
    /// A fresh home in the temporary directory.
    private func home() throws -> Home {
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-thread-admin-\(UUID().uuidString)"))
        try home.ensure()
        return home
    }

    /// Saves thread `id`, owned by `owner`, with `sessions`, last used at `lastUsed`, and no record.
    private func save(
        _ id: String, in home: Home, owner: String = "codex", sessions: [String]? = nil,
        lastUsed: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws {
        var settings = ThreadStore.Settings(
            id: id, owner: owner, model: "ollama:granite4.1:8b", tools: ["run_command"],
            instructions: "Run git.\nOnly git.", think: "false", commandTimeoutSeconds: 600, session: "\(id)-aaaaaaaa",
            now: lastUsed)
        if let sessions { settings.sessions = sessions }
        settings.turns = 3
        settings.state = .saved
        try ThreadStore(home: home).save(settings, record: nil)
    }

    /// Writes `bytes` bytes of stored output under audit session `session`.
    private func output(_ session: String, bytes: Int, in home: Home) throws {
        let directory = home.outputs.appending(path: session, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: directory.appending(path: "out-1.txt"))
    }

    @Test func listAndShowReadTheStoreAndNameWhoHoldsAThread() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try save("git", in: home, lastUsed: Date(timeIntervalSince1970: 1_800_000_000))
        try save("old", in: home, lastUsed: Date(timeIntervalSince1970: 1_700_000_000))
        try output("git-aaaaaaaa", bytes: 1_000, in: home)
        let admin = ThreadAdmin(home: home)
        let lock = try admin.store.lock("git", owner: "claude-code")
        defer { lock.release() }
        #expect(admin.list.map(\.id) == ["git", "old"])
        #expect(admin.list.first?.state == "open elsewhere" && admin.list.first?.holder?.owner == "claude-code")
        #expect(admin.list.last?.state == "saved" && admin.list.last?.holder == nil)
        let details = try admin.show("git", keepDays: 30)
        #expect(details.outputBytes == 1_000 && details.bytes > 0 && details.holder?.pid == getpid())
        #expect(details.sweepsAfter == Date(timeIntervalSince1970: 1_800_000_000 + 30 * 86_400))
        #expect(try admin.show("git", keepDays: 0).sweepsAfter == nil)
        let lines = ThreadAdmin.lines(details, keepDays: 30)
        #expect(lines.first == "thread git")
        #expect(lines.contains { $0.hasPrefix("  owner ") && $0.hasSuffix("codex") })
        #expect(lines.contains { $0.contains("command limit") && $0.hasSuffix("600 s") })
        #expect(lines.contains { $0.contains("state") && $0.contains("open elsewhere (pid \(getpid()), claude-code)") })
        #expect(lines.contains { $0.contains("unless used again (threads.keepDays 30)") })
        #expect(lines.suffix(3) == ["  instructions:", "    Run git.", "    Only git."])
        #expect(
            ThreadAdmin.lines(try admin.show("old", keepDays: 0), keepDays: 0).contains {
                $0.hasSuffix("never (threads.keepDays 0)")
            })
        #expect(throws: ThreadAdmin.Failure.notFound("nope")) { try admin.show("nope", keepDays: 30) }
        #expect(ThreadAdmin.bytes(0) == "none")
    }

    @Test func deleteRemovesTheThreadAndOnlyTheOutputsNoOtherThreadNames() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        // A chat's /new carries its session into the next thread: both name "shared".
        try save("first", in: home, owner: "chat", sessions: ["first-aaaaaaaa", "shared"])
        try save("second", in: home, owner: "chat", sessions: ["shared"])
        try output("first-aaaaaaaa", bytes: 500, in: home)
        try output("shared", bytes: 700, in: home)
        let admin = ThreadAdmin(home: home)
        let deleted = try admin.delete("first")
        #expect(deleted.outputSessions == ["first-aaaaaaaa"] && deleted.outputBytes == 500)
        #expect(deleted.owner == "chat" && deleted.turns == 3 && deleted.sessions == ["first-aaaaaaaa", "shared"])
        #expect(Set(deleted.details.keys) == AuditEvent.fields(for: .threadDeleted))
        #expect(
            try admin.store.settings("first") == nil
                && !FileManager.default.fileExists(
                    atPath: admin.store.directory(of: "first").path)
        )
        #expect(FileManager.default.fileExists(atPath: home.outputs.appending(path: "shared").path))
        #expect(!FileManager.default.fileExists(atPath: home.outputs.appending(path: "first-aaaaaaaa").path))
        #expect(throws: ThreadAdmin.Failure.notFound("first")) { try admin.delete("first") }
        #expect(throws: ThreadStore.Failure.invalidID("../x")) { try admin.delete("../x") }
    }

    @Test func aThreadThatCannotBeReadIsDeletedWithoutOutputs() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let admin = ThreadAdmin(home: home)
        try admin.store.ensure("bad")
        try Data("{nope".utf8).write(to: admin.store.directory(of: "bad").appending(path: "thread.json"))
        #expect(admin.store.unreadable == ["bad"] && admin.list.isEmpty)
        let deleted = try admin.delete("bad")
        #expect(deleted.owner == nil && deleted.sessions.isEmpty && admin.store.ids.isEmpty)
    }

    @Test func handGivesTheThreadToAnotherOwnerAndKeepsTheRest() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try save("git", in: home)
        let admin = ThreadAdmin(home: home)
        let before = try #require(try admin.store.settings("git"))
        let handed = try #require(try admin.hand("git", to: "claude-code"))
        #expect(handed == ThreadAdmin.Handed(id: "git", from: "codex", to: "claude-code"))
        #expect(Set(handed.details.keys) == AuditEvent.fields(for: .threadHanded))
        var after = try #require(try admin.store.settings("git"))
        #expect(after.owner == "claude-code")
        after.owner = before.owner
        #expect(after == before)
        #expect(try admin.hand("git", to: "claude-code") == nil)
        for owner in ["", " codex", "co\ndex", String(repeating: "x", count: 65)] {
            #expect(throws: ThreadAdmin.Failure.invalidOwner(owner)) { try admin.hand("git", to: owner) }
        }
        #expect(throws: ThreadAdmin.Failure.notFound("nope")) { try admin.hand("nope", to: "codex") }
    }

    @Test func deleteAndHandAreRefusedWhileAProcessHoldsTheThread() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try save("git", in: home)
        let admin = ThreadAdmin(home: home)
        let lock = try admin.store.lock("git", owner: "claude-code")
        let holder = ThreadLock.Holder(pid: getpid(), owner: "claude-code")
        #expect(throws: ThreadStore.Failure.held("git", holder)) { try admin.delete("git") }
        #expect(throws: ThreadStore.Failure.held("git", holder)) { try admin.hand("git", to: "chat") }
        #expect(
            "\(ThreadStore.Failure.held("git", holder))"
                == "thread git is open in another wisp (pid \(getpid()), claude-code)")
        lock.release()
        #expect(try admin.hand("git", to: "chat")?.to == "chat")
        #expect(try admin.delete("git").id == "git")
    }

    @Test func theModelIsRefusedDeletingOrHandingAThread() {
        let policy = CommandPolicy.default
        #expect(policy.check("wisp threads delete git") != .allowed)
        #expect(policy.check("wisp threads delete --yes git") != .allowed)
        #expect(policy.check("wisp threads hand git codex") != .allowed)
        #expect(policy.check("echo x; 'wisp' \"threads\" hand git codex") != .allowed)
        #expect(policy.check("/opt/homebrew/bin/wisp threads delete git") != .allowed)
        #expect(policy.check("wisp threads") == .allowed)
        #expect(policy.check("wisp threads list --json") == .allowed)
        #expect(policy.check("wisp threads show git") == .allowed)
    }

    @Test func anOwnersRefusalNamesTheCommandThatHandsTheThreadOver() {
        #expect(
            "\(ThreadStore.Failure.owned("o", owner: "codex", client: "claude-code"))"
                == "thread o belongs to codex, and this client is claude-code; choose another thread_id, or the person "
                + "gives it to you with wisp threads hand o claude-code")
    }

    @Test func theDoctorReportsTheStoreAndWarnsOfAThreadItCannotRead() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let doctor = Doctor(home: home, probes: .init(systemModel: { nil }, configuredModel: { _, _, _ in nil }))
        #expect(doctor.threads() == Doctor.Finding(name: "threads", ok: true, detail: "none saved"))
        try save("old", in: home, lastUsed: Date(timeIntervalSince1970: 1_000_000_000))
        try save("new", in: home, lastUsed: Date())
        let lock = try ThreadStore(home: home).lock("new", owner: "codex")
        defer { lock.release() }
        let finding = doctor.threads()
        #expect(finding.ok && finding.detail.hasPrefix("2 saved, "), "\(finding.detail)")
        #expect(finding.detail.contains("open: new (pid \(getpid()), codex)"))
        #expect(finding.detail.contains("the next sweep deletes 1 (threads.keepDays 30)"), "\(finding.detail)")
        let store = ThreadStore(home: home)
        try store.ensure("bad")
        try Data("{nope".utf8).write(to: store.directory(of: "bad").appending(path: "thread.json"))
        let warned = doctor.threads()
        #expect(!warned.ok && warned.detail.contains("1 cannot be read here: bad; wisp threads show ID says why"))
    }
}
