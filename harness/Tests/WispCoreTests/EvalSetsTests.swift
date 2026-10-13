import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The model evaluations' case sets for `edit_file`, `system_info`, and `draft_change` (`EvalSets`), checked without a
/// model: they load, have unique ids, match their declared counts and the sizes 0.23.0 set, are well formed, and
/// carry no secret; every `edit_file` case is solved by exactly the calls its prompt asks for, applied with the real
/// `FileWriter`. Also the release's seeded subsets and the floors' arithmetic (docs/measurements.md, "The floors").
struct EvalSetsTests {
    // MARK: edit_file

    @Test func editFileCasesLoadWithUniqueIdsAndTheirDeclaredCounts() throws {
        let set = try EvalSets.EditFile.load()
        let ids = set.cases.map(\.id)
        #expect(Set(ids).count == ids.count, "repeated ids")
        let files = set.cases.map(\.file)
        #expect(Set(files).count == files.count, "repeated file names")
        #expect(Set(set.cases.map(\.task)) == ["replace", "whitespace"])
        for task in ["replace", "whitespace"] {
            let count = set.cases(task).count
            #expect(set.declared[task] == count, "\(task): declared \(set.declared[task] ?? -1), found \(count)")
            let release = set.release[task] ?? 0
            #expect(release > 0 && release <= count, "\(task): release \(release) of \(count)")
        }
        #expect(set.cases.count >= 90, "\(set.cases.count) cases, fewer than 90")
        let shapes = Set(set.cases("replace").map(\.shape))
        let wanted: Set = [
            "single", "medium-file", "large-file", "near-duplicate", "range", "delete", "insert", "unicode", "crlf",
            "stale",
        ]
        #expect(wanted.isSubset(of: shapes), "missing shapes: \(wanted.subtracting(shapes))")
        // CRLF files are edited both ways: by line number since 2026-10-12, when line edits learned CRLF, and by find.
        let crlf = set.cases("replace").filter { $0.shape == "crlf" }.flatMap(\.edits)
        #expect(crlf.contains { $0.line != nil } && crlf.contains { $0.line == nil }, "CRLF by line and by find")
        #expect(set.cases("whitespace").contains { $0.shape == "trailing-whitespace" })
    }

    @Test func everyEditFileCaseIsSolvedByExactlyTheCallsItsPromptAsksFor() throws {
        let set = try EvalSets.EditFile.load()
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-eval-sets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: nil, protected: [])
        for item in set.cases {
            // Each case fits one read_file page at the smallest budget, numbered lines included.
            #expect(item.before.utf8.count <= 3000, "\(item.id): \(item.before.utf8.count) bytes")
            #expect(Self.lines(item.before).count <= 120, "\(item.id): over 120 lines")
            #expect(!item.edits.isEmpty, "\(item.id): no edits")
            let file = dir.appending(path: item.file)
            try Data(item.before.utf8).write(to: file)
            let prompt = item.prompt(path: file.path)
            #expect(prompt.contains(file.path) && prompt.hasSuffix("Report the tool results verbatim."), "\(item.id)")
            var text = item.before
            for edit in item.edits {
                for part in [edit.target, edit.find, edit.content, edit.locate].compactMap({ $0 }) {
                    // Backticks delimit the prompt's texts; the locate phrase is the one place it uses its own.
                    #expect(part == edit.locate || !part.contains("`"), "\(item.id): a backtick in \(part)")
                }
                #expect(edit.content.isEmpty || prompt.contains(edit.content), "\(item.id): lacks \(edit.content)")
                Self.checkLine(edit, in: text, case: item.id)
                _ = try writer.apply(edit.writerEdit, to: file.path)
                text = try String(contentsOf: file, encoding: .utf8)
            }
            #expect(text == item.after, "\(item.id): the calls leave \(text.debugDescription)")
        }
    }

    /// Checks that `edit` is aimed where its case says: a named line is that line and the only one with its text, a
    /// located line is empty, a stale number is wrong and `find` is on exactly one other line, and a replacement by
    /// `find` alone matches once with no whitespace at either end of `find` or the replacement.
    ///
    /// - Parameters:
    ///   - edit: The edit.
    ///   - text: The file as the edit finds it.
    ///   - id: The case, for the messages.
    private static func checkLine(_ edit: EvalSets.EditFile.Edit, in text: String, case id: String) {
        let lines = Self.lines(text)
        guard let line = edit.line else {
            let find = edit.find ?? ""
            #expect(text.ranges(of: find).count == 1, "\(id): find matches \(text.ranges(of: find).count) times")
            for part in [find, edit.content] where !part.isEmpty {
                #expect(part.trimmingCharacters(in: .whitespaces) == part, "\(id): whitespace at an end of \(part)")
            }
            return
        }
        #expect(line >= 1 && line <= lines.count, "\(id): line \(line) of \(lines.count)")
        guard line >= 1, line <= lines.count else { return }
        if let target = edit.target {
            #expect(lines[line - 1] == target, "\(id): line \(line) is \(lines[line - 1].debugDescription)")
            #expect(lines.filter { $0 == target }.count == 1, "\(id): \(target) is on several lines")
        } else if edit.locate != nil {
            #expect(lines[line - 1].isEmpty, "\(id): the located line \(line) is not empty")
        } else if let find = edit.find {
            #expect(!lines[line - 1].contains(find), "\(id): line \(line) is not stale")
            #expect(lines.filter { $0.contains(find) }.count == 1, "\(id): find is not on exactly one line")
        } else {
            Issue.record("\(id): a line edit with neither target, locate, nor find")
        }
    }

    /// The lines of a file as `read_file` numbers them (`TextLines`): split at any line ending, `\r\n` included,
    /// with no line after a final one.
    ///
    /// - Parameter text: The file.
    /// - Returns: The lines.
    private static func lines(_ text: String) -> [String] {
        let lines = TextLines(Array(text.utf8))
        return (0..<lines.count).map(lines.text)
    }

    @Test func whitespaceCasesChangeOnlyALinesWhitespace() throws {
        let set = try EvalSets.EditFile.load()
        for item in set.cases("whitespace") {
            let before = Self.lines(item.before)
            let after = Self.lines(item.after)
            #expect(before.count == after.count, "\(item.id)")
            let changed = zip(before, after).filter { $0 != $1 }
            #expect(changed.count == 1, "\(item.id): \(changed.count) lines changed")
            for (old, new) in changed {
                #expect(
                    old.trimmingCharacters(in: .whitespaces) == new.trimmingCharacters(in: .whitespaces), "\(item.id)")
            }
        }
    }

    @Test func theOriginalCasesKeepTheirPromptWordForWord() throws {
        let set = try EvalSets.EditFile.load()
        let original = try #require(set.cases.first { $0.id == "b-py" })
        #expect(
            original.prompt(path: "/x/b.py")
                == "Use read_file to read /x/b.py. Then use edit_file with mode replace on /x/b.py, with line set to the "
                + "number read_file showed for `    return 1` and content `    return 10`. Report the tool results "
                + "verbatim.")
        let stale = try #require(set.cases.first { $0.id == "stale-py" })
        #expect(stale.prompt(path: "/x/jobs.py").contains("Without reading the file again, use edit_file"))
        #expect(stale.prompt(path: "/x/jobs.py").contains("line 3, find `INTERVAL = 30`, and content `INTERVAL = 60`"))
    }

    // MARK: system_info

    @Test func systemInfoQuestionsAreWellFormedAndCoverEveryTopic() throws {
        let set = try EvalSets.SystemInfo.load()
        #expect(set.declared == set.cases.count, "declared \(set.declared), found \(set.cases.count)")
        #expect(set.cases.count >= 48)
        #expect(set.release > 0 && set.release <= set.cases.count)
        #expect(Set(set.cases.map(\.id)).count == set.cases.count, "repeated ids")
        #expect(Set(set.cases.map(\.question)).count == set.cases.count, "repeated questions")
        let topics = Set(SystemTopic.allCases.map(\.rawValue))
        for item in set.cases {
            #expect(!item.accept.isEmpty, "\(item.id): accepts nothing")
            #expect(!item.question.localizedCaseInsensitiveContains("system_info"), "\(item.id) names the tool")
            let ambiguous = item.ambiguous == true
            #expect(ambiguous == (item.accept.count > 1), "\(item.id): ambiguous is \(ambiguous)")
            if ambiguous { #expect(item.note?.isEmpty == false, "\(item.id): no note says why") }
            for accept in item.accept {
                #expect(topics.contains(accept.topic), "\(item.id): no topic \(accept.topic)")
                if let target = accept.target {
                    #expect(["ports", "process"].contains(accept.topic), "\(item.id): a target for \(accept.topic)")
                    if accept.topic == "ports" { #expect(Int(target).map { (1...65535).contains($0) } == true) }
                }
                if accept.topic == "process" { #expect(accept.target != nil, "\(item.id): process without a name") }
                if accept.path != nil { #expect(accept.topic == "folderSizes", "\(item.id): a path for a topic") }
            }
        }
        for topic in topics {
            let count = set.cases.filter { $0.stratum == topic }.count
            #expect(count >= 4, "\(topic): \(count) questions")
        }
    }

    @Test func aSystemInfoCallMatchesByTopicTargetAndPath() {
        let accept = EvalSets.SystemInfo.Accept(topic: "folderSizes", target: nil, path: "Downloads")
        #expect(accept.matches(topic: "folderSizes", target: nil, path: "~/downloads"))
        #expect(!accept.matches(topic: "folderSizes", target: nil, path: nil))
        #expect(!accept.matches(topic: "freeSpace", target: nil, path: "~/Downloads"))
        let port = EvalSets.SystemInfo.Accept(topic: "ports", target: "11434", path: nil)
        #expect(port.matches(topic: "ports", target: "11434", path: nil))
        #expect(!port.matches(topic: "ports", target: nil, path: nil))
    }

    // MARK: draft_change

    @Test func draftDiffsLoadWellFormedInTheirBandsWithACheckableRubric() throws {
        let set = try EvalSets.Drafts.load()
        #expect(Set(set.cases.map(\.id)).count == set.cases.count, "repeated ids")
        #expect(Set(set.cases.map(\.file)).count == set.cases.count, "a diff used twice")
        let minimum = ["small": 30, "medium": 8, "large": 6]
        let sizes = ["small": 1...2048, "medium": 4096...16384, "large": 24576...57344]
        for band in EvalSets.Drafts.bands {
            let cases = set.cases(band)
            #expect(set.declared[band] == cases.count, "\(band): declared \(set.declared[band] ?? -1), \(cases.count)")
            #expect(cases.count >= minimum[band] ?? 0, "\(band): \(cases.count)")
            #expect((1...cases.count).contains(set.release[band] ?? 0), "\(band): release \(set.release[band] ?? 0)")
            for item in cases {
                let diff = try item.diff()
                #expect(sizes[band]?.contains(diff.utf8.count) == true, "\(item.id): \(diff.utf8.count) B in \(band)")
                #expect(Self.diffProblems(diff).isEmpty, "\(item.id): \(Self.diffProblems(diff))")
                #expect(!item.gist.isEmpty && !item.must.isEmpty && !item.mustNot.isEmpty, "\(item.id): rubric")
                // A must term holding a mustNot term could never pass.
                for term in item.must {
                    let clash = item.mustNot.filter { EvalSets.beginsWord($0, in: term) }
                    #expect(clash.isEmpty, "\(item.id): \(term) holds \(clash)")
                    #expect(item.judge(term) == .pass, "\(item.id): \(term) alone does not pass")
                }
            }
        }
        #expect(Set(set.cases.map(\.band)) == Set(EvalSets.Drafts.bands))
    }

    /// What is wrong with a unified diff: no file or hunk, or a hunk whose lines do not match its header's counts.
    ///
    /// - Parameter diff: The diff.
    /// - Returns: The problems; empty for a well-formed diff.
    private static func diffProblems(_ diff: String) -> [String] {
        var problems: [String] = []
        var files = 0
        var hunks = 0
        var changes = 0
        var old = 0
        var new = 0
        for line in diff.components(separatedBy: "\n") {
            if old > 0 || new > 0 {
                switch line.first {
                case " ":
                    old -= 1
                    new -= 1
                case "-":
                    old -= 1
                    changes += 1
                case "+":
                    new -= 1
                    changes += 1
                case "\\":
                    break
                default:
                    problems.append("a hunk ends early at \(line.prefix(40).debugDescription)")
                    old = 0
                    new = 0
                }
                continue
            }
            if line.hasPrefix("diff --git ") { files += 1 }
            if line.hasPrefix("@@ ") {
                hunks += 1
                let ranges = line.split(separator: " ").dropFirst().prefix(2).map { range in
                    let parts = range.dropFirst().split(separator: ",")
                    return parts.count > 1 ? Int(parts[1]) ?? -1 : 1
                }
                guard ranges.count == 2, ranges.allSatisfy({ $0 >= 0 }) else {
                    problems.append("a bad hunk header \(line)")
                    continue
                }
                (old, new) = (ranges[0], ranges[1])
            }
        }
        if old != 0 || new != 0 { problems.append("the last hunk is short") }
        if files == 0 || hunks == 0 || changes == 0 {
            problems.append("\(files) files, \(hunks) hunks, \(changes) changes")
        }
        return problems
    }

    @Test func theRubricMatchesTermsThatBeginAWord() throws {
        #expect(EvalSets.beginsWord("fix", in: "Fix paging"))
        #expect(EvalSets.beginsWord("fix", in: "Apply a hot-fix"))
        #expect(!EvalSets.beginsWord("fix", in: "Add a prefix"))
        #expect(EvalSets.beginsWord("retry", in: "Keep retrying uploads"))
        #expect(EvalSets.beginsWord(".env", in: "Ignore .env files"))
        #expect(!EvalSets.beginsWord("", in: "anything"))
        let retry = try #require(try EvalSets.Drafts.load().cases.first { $0.id == "retry" })
        #expect(retry.judge("Retry failed uploads twice") == .pass)
        #expect(retry.judge("Retry uploads after a timeout") == .forbidden("timeout"))
        #expect(retry.judge("Update the uploader") == .missing)
    }

    // MARK: Every set

    @Test func noFixtureCarriesASecret() throws {
        var texts: [(String, String)] = []
        for item in try EvalSets.EditFile.load().cases { texts += [(item.id, item.before), (item.id, item.after)] }
        for item in try EvalSets.SystemInfo.load().cases { texts.append((item.id, item.question)) }
        for item in try EvalSets.Drafts.load().cases { texts.append((item.id, try item.diff())) }
        for (id, text) in texts {
            let found = SecretScanner.scan(text, categories: [.secret])
            #expect(found.isEmpty, "\(id): \(found.map(\.kind))")
        }
    }

    // MARK: Sampling and floors

    @Test func theReleaseSubsetIsFixedSpreadOverStrataAndInTheSetsOrder() throws {
        let set = try EvalSets.EditFile.load()
        let replace = set.cases("replace")
        let count = set.release["replace"] ?? 0
        let first = EvalSample.subset(replace, count: count, id: \.id, stratum: \.shape)
        let again = EvalSample.subset(replace, count: count, id: \.id, stratum: \.shape)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.count == count)
        #expect(Set(first.map(\.shape)) == Set(replace.map(\.shape)), "a shape left out")
        let positions = first.compactMap { item in replace.firstIndex { $0.id == item.id } }
        #expect(positions == positions.sorted())
        let other = EvalSample.subset(replace, count: count, seed: "another", id: \.id, stratum: \.shape)
        #expect(other.map(\.id) != first.map(\.id))
        #expect(EvalSample.subset(replace, count: replace.count + 1, id: \.id, stratum: \.shape).count == replace.count)
        let questions = try EvalSets.SystemInfo.load()
        let asked = EvalSample.subset(questions.cases, count: questions.release, id: \.id, stratum: \.stratum)
        #expect(Set(asked.map(\.stratum)) == Set(SystemTopic.allCases.map(\.rawValue)))
        // FNV-1a's published value for "a".
        #expect(EvalSample.hash("a") == 0xaf63_dc4c_8601_ec8c)
    }

    @Test func theBinomialTailAndTheFloorsAreRight() {
        #expect(abs(EvalFloor.chanceBelow(1, cases: 10, rate: 0.5) - 0.000_976_562_5) < 1e-12)
        #expect(abs(EvalFloor.chanceBelow(2, cases: 10, rate: 0.5) - 0.010_742_187_5) < 1e-12)
        #expect(EvalFloor.chanceBelow(0, cases: 10, rate: 0.5) == 0)
        #expect(abs(EvalFloor.chanceBelow(11, cases: 10, rate: 0.5) - 1) < 1e-12)
        #expect(EvalFloor.minimum(cases: 10, rate: 0.5) == 1)
        #expect(EvalFloor.minimum(cases: 10, rate: 1) == 10)
        #expect(EvalFloor.minimum(cases: 10, rate: 0) == 0)
    }

    /// The floors docs/measurements.md states, for the whole sets and the release's subsets, from the historical
    /// rates: the documentation and the code cannot drift apart.
    @Test(arguments: [
        (EvalFloor.Historical.editFileReplace, 86, 47), (EvalFloor.Historical.editFileReplace, 36, 17),
        (EvalFloor.Historical.editFileWhitespace, 24, 18), (EvalFloor.Historical.editFileWhitespace, 8, 5),
        (EvalFloor.Historical.systemInfo, 54, 31), (EvalFloor.Historical.systemInfo, 24, 12),
        (EvalFloor.Historical.draftSmall, 30, 17), (EvalFloor.Historical.draftSmall, 12, 6),
        (EvalFloor.Historical.draftMedium, 8, 1), (EvalFloor.Historical.draftMedium, 4, 0),
        (EvalFloor.Historical.draftLarge, 6, 0), (EvalFloor.Historical.draftLarge, 2, 0),
    ])
    func theDocumentedFloors(rate: EvalFloor.Rate, cases: Int, floor: Int) {
        #expect(EvalFloor.minimum(cases: cases, rate: rate.value) == floor)
    }
}
