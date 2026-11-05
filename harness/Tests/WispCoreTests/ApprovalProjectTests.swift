import Foundation
import Testing

@testable import WispCore

/// The project a remembered approval applies in (ADR 0085): the repository, with its subdirectories and worktrees,
/// trusting only what git accepts, so a planted `.git` entry never borrows another project's approvals.
@Suite struct ApprovalProjectTests {
    /// A fresh folder under the temporary directory, links resolved.
    private let root: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-project-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }()

    /// Makes `path` under the root a directory and returns it.
    private func folder(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `text` to `path` under the root.
    private func write(_ text: String, _ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A repository at `repo` and a worktree of it at `tree`, laid out as `git worktree add` lays them out.
    private func worktree(_ tree: String, of repo: String, name: String = "w") throws {
        _ = try folder("\(repo)/.git/worktrees/\(name)")
        _ = try folder(tree)
        try write("gitdir: \(root.path)/\(repo)/.git/worktrees/\(name)\n", "\(tree)/.git")
        try write("../..\n", "\(repo)/.git/worktrees/\(name)/commondir")
        try write("\(root.path)/\(tree)/.git\n", "\(repo)/.git/worktrees/\(name)/gitdir")
    }

    @Test func aRepositoryHoldsItsSubdirectoriesAndWorktrees() throws {
        let common = try folder("repo/.git").path
        #expect(ApprovalProject.of(try folder("repo").path) == common)
        #expect(ApprovalProject.of(try folder("repo/harness/Sources").path) == common)
        try worktree("trees/agent", of: "repo")
        #expect(ApprovalProject.of(try folder("trees/agent/docs").path) == common)
        #expect(ApprovalProject.shown(common) == root.appending(path: "repo").path)
        // Outside a repository the project is the directory itself.
        let plain = try folder("plain/inner").path
        #expect(ApprovalProject.of(plain) == plain && ApprovalProject.shown(plain) == plain)
    }

    @Test func aPlantedGitFileIsAProjectOfItsOwn() throws {
        _ = try folder("repo/.git")
        try worktree("trees/real", of: "repo")
        // A file naming the repository's worktree folder, which points back at another file: not this one's.
        let planted = try folder("tmp/planted")
        try write("gitdir: \(root.path)/repo/.git/worktrees/w\n", "tmp/planted/.git")
        #expect(ApprovalProject.of(planted.path) == planted.path)
        // A file naming the repository's own git directory, as a submodule's names its module.
        let direct = try folder("tmp/direct")
        try write("gitdir: \(root.path)/repo/.git\n", "tmp/direct/.git")
        #expect(ApprovalProject.of(direct.appending(path: "sub").path) == direct.path)
        // A folder that points back but sits outside worktrees/, with a commondir naming the repository.
        _ = try folder("repo/.git/elsewhere")
        try write("../\n", "repo/.git/elsewhere/commondir")
        try write("\(root.path)/tmp/odd/.git\n", "repo/.git/elsewhere/gitdir")
        let odd = try folder("tmp/odd")
        try write("gitdir: \(root.path)/repo/.git/elsewhere\n", "tmp/odd/.git")
        #expect(ApprovalProject.of(odd.path) == odd.path)
        // Text that is not a gitdir line at all.
        let junk = try folder("tmp/junk")
        try write("not a gitdir\n", "tmp/junk/.git")
        #expect(ApprovalProject.of(junk.path) == junk.path)
    }

    @Test func aLinkedGitDirectoryIsNotFollowed() throws {
        _ = try folder("repo/.git")
        let linked = try folder("tmp/linked")
        try FileManager.default.createSymbolicLink(
            at: linked.appending(path: ".git"), withDestinationURL: root.appending(path: "repo/.git"))
        #expect(ApprovalProject.of(linked.path) == linked.path)
    }

    @Test func aGrantInOneWorktreeCoversTheRepositoryAndAlwaysNeverExpires() async throws {
        _ = try folder("repo/.git")
        try worktree("trees/agent", of: "repo")
        let store = ApprovalStore(url: nil, lifetime: .seconds(3600))
        let tree = try folder("trees/agent").path
        let always = try await store.grant(
            pattern: "git push *", directory: tree, scope: .always, level: .moderate, source: "mcp")
        #expect(always.expiresAt == nil && always.isLive(at: .distantFuture))
        let days = try await store.grant(
            pattern: "git commit *", directory: tree, scope: .project, level: .moderate, source: "mcp")
        #expect(days.expiresAt != nil && !days.isLive(at: Date().addingTimeInterval(7200)))
        let main = try folder("repo/harness").path
        #expect(await store.find(pattern: "git push *", directory: main, level: .moderate)?.id == always.id)
        #expect(await store.find(pattern: "git commit *", directory: main, level: .moderate)?.id == days.id)
        // Not in another project, and not for a verdict above the level it was granted at.
        #expect(await store.find(pattern: "git push *", directory: try folder("plain").path) == nil)
        #expect(await store.find(pattern: "git push *", directory: main, level: .dangerous) == nil)
        #expect(store.days == 0)
        #expect(ApprovalStore(url: nil).days == 30)
    }

    @Test func entriesFromBeforeKeepTheirDirectoryAndAnyDirectoryEntriesStop() throws {
        _ = try folder("repo/.git")
        let now = Date()
        let old = ApprovalStore.Entry(
            id: "a1", pattern: "git add *", workingDirectory: try folder("repo").path, project: nil, scope: .project,
            level: .moderate, grantedAt: now, expiresAt: now.addingTimeInterval(60), source: "mcp")
        // Recorded with its directory only: its project is read from that directory.
        #expect(old.covers(pattern: "git add *", project: ApprovalProject.of(try folder("repo/docs").path), now: now))
        let anywhere = ApprovalStore.Entry(
            id: "a2", pattern: "git add *", workingDirectory: nil, project: nil, scope: .always, level: .moderate,
            grantedAt: now, expiresAt: now.addingTimeInterval(60), source: "mcp")
        #expect(!anywhere.isLive(at: now))
        #expect(!anywhere.covers(pattern: "git add *", project: "/anywhere", now: now))
    }

    @Test func theFrontEndIsToldHowManyDaysAndWhichProject() throws {
        let repo = try folder("repo")
        _ = try folder("repo/.git")
        let request = ApprovalRequest(
            command: "git push", pattern: "git push *", workingDirectory: try folder("repo/docs").path,
            assessment: RiskAssessment(level: .moderate, reasons: [], sources: []), days: 7)
        let line = ChatProtocol.approval(id: "a", request)
        #expect(line["days"] == .int(7) && line["project"] == .string(repo.path))
        var outside = request
        outside.kind = .outsideSandbox
        #expect(ChatProtocol.approval(id: "a", outside)["days"] == nil)
    }

    @Test func everyFaceNamesHowLongOnly() {
        #expect(
            ApprovalScope.allCases.map { $0.label(days: 30) } == ["This turn", "This session", "30 days", "Always"])
        #expect(ApprovalScope.project.label(days: 1) == "1 day")
    }
}
