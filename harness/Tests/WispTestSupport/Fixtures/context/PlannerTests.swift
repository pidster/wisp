import XCTest

@testable import Harbour

/// The planner's decisions, each from a hand-built scan and manifest. No test
/// touches a real destination except the conflict test, which writes one file
/// into a temporary directory to give it a newer modification time.
final class PlannerTests: XCTestCase {
    let then = Date(timeIntervalSince1970: 1_700_000_000)
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func entry(_ path: String, size: Int = 10, modified: Date? = nil) -> Entry {
        Entry(path: path, kind: .file, size: size, modified: modified ?? then, digest: nil)
    }

    func record(_ path: String, size: Int = 10) -> Manifest.Record {
        Manifest.Record(path: path, size: size, modified: then, digest: nil)
    }

    func planner(_ entries: [Entry], _ records: [Manifest.Record], delete: Bool = false) -> Planner {
        Planner(entries: entries, manifest: Manifest(records: records), destination: root.path, allowDelete: delete)
    }

    func testNewFileIsCopied() {
        let plan = planner([entry("a.txt")], []).makePlan()
        XCTAssertEqual(plan.changes, [Change(action: .copy, path: "a.txt", bytes: 10)])
    }

    func testChangedSizeIsUpdated() {
        let plan = planner([entry("a.txt", size: 12)], [record("a.txt")]).makePlan()
        XCTAssertEqual(plan.changes.map(\.action), [.update])
    }

    func testUnchangedFileIsSkipped() {
        let plan = planner([entry("a.txt")], [record("a.txt")]).makePlan()
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertEqual(plan.skipped, 1)
    }

    func testVanishedFileIsKeptWithoutDelete() {
        let plan = planner([], [record("old.txt")]).makePlan()
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertEqual(plan.kept, ["old.txt"])
    }

    func testVanishedFileIsDeletedWithDelete() {
        let plan = planner([], [record("old.txt")], delete: true).makePlan()
        XCTAssertEqual(plan.changes, [Change(action: .delete, path: "old.txt", bytes: 0)])
    }

    func testChangesAreSortedByPath() {
        let plan = planner([entry("b.txt"), entry("a.txt")], []).makePlan()
        XCTAssertEqual(plan.changes.map(\.path), ["a.txt", "b.txt"])
    }

    func testConflictWhenDestinationEdited() throws {
        let file = root.appending(path: "a.txt")
        try Data("edited by hand".utf8).write(to: file)
        let plan = planner([entry("a.txt", size: 12)], [record("a.txt")]).makePlan()
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertTrue(plan.changes.isEmpty)
    }

    func testBytesToWriteCountsCopiesAndUpdates() {
        let plan = planner([entry("a.txt", size: 5), entry("b.txt", size: 7)], [record("b.txt", size: 3)]).makePlan()
        XCTAssertEqual(plan.bytesToWrite, 12)
    }
}
