import Foundation
import Testing

@testable import WispCore

/// Project approvals whose folder is gone: marked when listed, removed by `clearGone` only when still gone
/// (0.22.0). Every folder is made under the temporary directory.
@Suite struct GoneApprovalsTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-gone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aProjectApprovalWhoseFolderIsGoneIsMarked() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appending(path: "kept")
        let removed = root.appending(path: "worktree")
        let file = root.appending(path: "a-file")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        let store = ApprovalStore(url: root.appending(path: "approvals.json"))
        let live = try await store.grant(
            pattern: "git add *", directory: kept.path, scope: .project, level: .moderate, source: "t")
        let gone = try await store.grant(
            pattern: "git commit *", directory: removed.path, scope: .project, level: .moderate, source: "t")
        let notAFolder = try await store.grant(
            pattern: "ls *", directory: file.path, scope: .project, level: .moderate, source: "t")
        let anywhere = try await store.grant(
            pattern: "head *", directory: removed.path, scope: .always, level: .moderate, source: "t")
        try FileManager.default.removeItem(at: removed)

        let marks = Dictionary(uniqueKeysWithValues: await store.listing.map { ($0.entry.id, $0.isGone) })
        #expect(marks == [live.id: false, gone.id: true, notAFolder.id: true, anywhere.id: false])
    }

    @Test func clearingGoneApprovalsRemovesOnlyThoseStillGone() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appending(path: "kept")
        let gone = root.appending(path: "gone")
        let back = root.appending(path: "back")
        for folder in [kept, gone, back] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let store = ApprovalStore(url: root.appending(path: "approvals.json"))
        let live = try await store.grant(
            pattern: "git add *", directory: kept.path, scope: .project, level: .moderate, source: "t")
        let lost = try await store.grant(
            pattern: "git commit *", directory: gone.path, scope: .project, level: .moderate, source: "t")
        let returned = try await store.grant(
            pattern: "make *", directory: back.path, scope: .project, level: .moderate, source: "t")
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.removeItem(at: back)
        #expect(await store.listing.filter(\.isGone).count == 2)
        // A folder made again after the listing keeps its approvals: the store decides again when it clears.
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)

        let cleared = try await store.clearGone()
        #expect(cleared.map(\.id) == [lost.id])
        #expect(Set(await store.all.map(\.id)) == [live.id, returned.id])
        #expect(try await store.clearGone().isEmpty)
    }

    @Test func anExistingFolderOrAnAlwaysApprovalIsNotGone() {
        let entry = ApprovalStore.Entry(
            id: "x", pattern: "ls *", workingDirectory: "/", scope: .project, level: .moderate,
            grantedAt: Date(), expiresAt: Date().addingTimeInterval(60), source: "t")
        #expect(!ApprovalStore.isGone(entry))
        var always = entry
        always.scope = .always
        always.workingDirectory = nil
        #expect(!ApprovalStore.isGone(always))
    }

    @Test func theListingMarksGoneApprovals() {
        let entry = ApprovalStore.Entry(
            id: "ab12", pattern: "git commit *", workingDirectory: "/tmp/old", scope: .project, level: .moderate,
            grantedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 86400 * 30),
            source: "t")
        let piped = ListingLayout.approvals([entry], gone: ["ab12"], width: nil)
        #expect(piped.first?.hasSuffix("\t/tmp/old\tgit commit *\tgone") == true)
        #expect(ListingLayout.approvals([entry], width: nil).first?.hasSuffix("\tgit commit *") == true)
        let shown = ListingLayout.approvals([entry], gone: ["ab12"], width: 120)
        #expect(shown[1].contains("/tmp/old (gone)"))
        #expect(shown.last?.contains("wisp approvals clear --gone") == true)
        #expect(!ListingLayout.approvals([entry], width: 120).joined().contains("gone"))
    }
}
