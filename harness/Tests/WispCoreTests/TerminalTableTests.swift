import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct TerminalTableTests {
    @Test func widthComesFromTheIoctlThenColumnsThenEighty() {
        #expect(TerminalTable.width(ioctlWidth: 120, environment: ["COLUMNS": "100"]) == 120)
        #expect(TerminalTable.width(ioctlWidth: nil, environment: ["COLUMNS": "100"]) == 100)
        #expect(TerminalTable.width(ioctlWidth: 0, environment: ["COLUMNS": "junk"]) == 80)
        #expect(TerminalTable.width(ioctlWidth: nil, environment: [:]) == 80)
    }

    @Test func detectionIsNilWhenNotATerminal() {
        #expect(TerminalTable.detectWidth(isTerminal: false, ioctlWidth: 120, environment: [:]) == nil)
        #expect(TerminalTable.detectWidth(isTerminal: true, ioctlWidth: 120, environment: [:]) == 120)
        #expect(TerminalTable.detectWidth(isTerminal: true, ioctlWidth: nil, environment: ["COLUMNS": "60"]) == 60)
    }

    @Test func wrapBreaksAtSpacesAndSplitsALongWord() {
        #expect(TerminalTable.wrap("one two  three four", width: 9) == ["one two", "three", "four"])
        #expect(TerminalTable.wrap("", width: 9) == [""])
        #expect(TerminalTable.wrap("ab abcdefghij", width: 4) == ["ab", "abcd", "efgh", "ij"])
    }

    @Test func columnsAlignAndTheLastWrapsUnderItself() {
        let lines = TerminalTable.render(
            rows: [["a", "bb", "alpha beta gamma delta"], ["ccc", "d", "x"]], indent: 2, width: 33)
        #expect(
            lines == [
                "  a    bb  alpha beta gamma",
                "           delta",
                "  ccc  d   x",
            ])
    }

    @Test func aHeaderIsAlignedWithTheRows() {
        let lines = TerminalTable.render(header: ["NAME", "WHAT"], rows: [["x", "y"]], width: 80)
        #expect(lines == ["NAME  WHAT", "x     y"])
    }

    @Test func aNarrowTerminalKeepsAUsableWrapColumn() {
        let lines = TerminalTable.render(rows: [["name", "one two three four five six seven"]], width: 10)
        #expect(lines.allSatisfy { $0.count <= 6 + TerminalTable.minimumWrap })
        #expect(lines.count > 1 && lines[1].hasPrefix("      "))
    }

    @Test func toolsPipedStayTabSeparated() {
        let tools = [(name: "a", description: "Does a."), (name: "bb", description: "Does b.")]
        #expect(ListingLayout.tools(tools, width: nil) == ["a\tDoes a.", "bb\tDoes b."])
    }

    @Test func toolsOnATerminalAreASectionLikeHelp() {
        let tools = [
            (name: "a", description: "Does a."), (name: "run_command", description: "word " + "long ".repeated(8)),
        ]
        let lines = ListingLayout.tools(tools, width: 50)
        #expect(lines.first == "TOOLS:")
        #expect(lines[1] == "  a            Does a.")
        #expect(lines[2].hasPrefix("  run_command  word long"))
        #expect(lines[3].hasPrefix(String(repeating: " ", count: 15)))
        #expect(lines.allSatisfy { $0.count <= 48 })
        #expect(lines.contains(""))
        #expect(lines.last?.hasPrefix("  ") == true && lines.last?.contains("prompts.") == true)
        let note = lines.drop { $0 != "" }.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.joined(
            separator: " ")
        #expect(note == "See 'wisp tools --markdown' (or --json) for parameters and example prompts.")
        let wide = ListingLayout.tools(tools, width: 120)
        #expect(wide[2] == "  run_command  " + "word " + "long ".repeated(8).dropLast())
        #expect(!lines.contains { $0.contains("\t") })
    }

    private func entry(_ id: String, scope: ApprovalScope, directory: String?, pattern: String) -> ApprovalStore.Entry {
        ApprovalStore.Entry(
            id: id, pattern: pattern, workingDirectory: directory, scope: scope, level: .moderate,
            grantedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 86400 * 30),
            source: "test")
    }

    @Test func approvalsPipedStayTabSeparated() {
        let entries = [entry("ab12", scope: .project, directory: "/tmp/x", pattern: "git push *")]
        let expires = entries[0].expiresAt.formatted(date: .abbreviated, time: .omitted)
        #expect(
            ListingLayout.approvals(entries, width: nil) == ["ab12\tproject\texpires \(expires)\t/tmp/x\tgit push *"])
        let always = [entry("cd34", scope: .always, directory: nil, pattern: "head *")]
        #expect(ListingLayout.approvals(always, width: nil).first?.contains("\tany directory\thead *") == true)
    }

    @Test func approvalsOnATerminalAlignUnderAHeader() {
        let entries = [
            entry("ab12", scope: .project, directory: "/tmp/a/very/long/working/directory", pattern: "git push *"),
            entry("cd34", scope: .always, directory: nil, pattern: "head *"),
        ]
        let lines = ListingLayout.approvals(entries, width: 100)
        #expect(lines.count == 3 && lines[0].hasPrefix("ID    SCOPE    EXPIRES"))
        let pattern = lines[0].distance(from: lines[0].startIndex, to: lines[0].range(of: "PATTERN")!.lowerBound)
        #expect(
            lines[1].distance(from: lines[1].startIndex, to: lines[1].range(of: "git push *")!.lowerBound) == pattern)
        #expect(lines[2].distance(from: lines[2].startIndex, to: lines[2].range(of: "head *")!.lowerBound) == pattern)
        #expect(!lines.contains { $0.contains("\t") })
        // The terminal's expiry is the bare date; the piped form keeps its "expires" word.
        #expect(!lines.joined().contains("expires "))
        #expect(lines[1].contains("Jan 31, 1970") || lines[1].contains("31 Jan 1970") || lines[1].contains("1970"))
    }
}

extension String {
    fileprivate func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
