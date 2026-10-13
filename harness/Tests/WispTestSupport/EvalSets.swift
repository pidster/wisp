import Foundation
import WispCore

/// The case sets of three model evaluations, `edit_file`, `system_info`, and `draft_change`, read from
/// `harness/Evals/Tests/ModelEvalTests/Fixtures`. The evaluations (`harness/Evals`) run them on a model; the gate's
/// `EvalSetsTests` checks, without one, that they load, are well formed, have unique ids, match their declared counts,
/// and that every `edit_file` case is solved by exactly the calls its prompt asks for. They live here, in
/// `WispTestSupport`, so both can read them (docs/measurements.md, "The case sets").
public enum EvalSets {
    /// `harness/Evals/Tests/ModelEvalTests/Fixtures`, found from this source file's place in the repository.
    public static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Evals/Tests/ModelEvalTests/Fixtures")
    }

    /// Reads and decodes one fixture file.
    ///
    /// - Parameters:
    ///   - type: The set's type.
    ///   - name: The file's name in `fixturesDirectory`.
    /// - Returns: The set.
    /// - Throws: A file or decoding error.
    static func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: fixturesDirectory.appending(path: name)))
    }

    /// Whether `term` begins a word of `text`, ignoring case: it occurs where `text` starts or after a character
    /// that is neither a letter nor a digit. `fix` is found in "Fix paging" and "hot-fix", not in "prefix"; `retry`
    /// is found in "retrying". The draft rubric's matching.
    ///
    /// - Parameters:
    ///   - term: The word or phrase, as the rubric spells it.
    ///   - text: The text searched, such as a commit subject.
    /// - Returns: True when a match begins a word.
    public static func beginsWord(_ term: String, in text: String) -> Bool {
        let haystack = text.lowercased()
        let needle = term.lowercased()
        guard !needle.isEmpty else { return false }
        return haystack.ranges(of: needle).contains { range in
            guard range.lowerBound > haystack.startIndex else { return true }
            let previous = haystack[haystack.index(before: range.lowerBound)]
            return !previous.isLetter && !previous.isNumber
        }
    }
}

// MARK: - edit_file

extension EvalSets {
    /// `edit_file`'s cases (`edit_file.json`): a file, the calls a right answer makes, and the file as it must end
    /// up. Two measurements share the file: `replace` (text changes, floored) and `whitespace` (only a line's
    /// whitespace changes).
    public struct EditFile: Decodable, Sendable {
        /// The number of cases each task declares, checked against the cases.
        public let declared: [String: Int]
        /// How many cases of each task the release's eval runs, a fixed seeded subset (`EvalSample`).
        public let release: [String: Int]
        /// The cases, in file order.
        public let cases: [Case]

        /// The set, read from `edit_file.json`.
        ///
        /// - Returns: The set.
        /// - Throws: A file or decoding error.
        public static func load() throws -> EditFile { try EvalSets.load(EditFile.self, "edit_file.json") }

        /// The cases of one task.
        ///
        /// - Parameter task: `replace` or `whitespace`.
        /// - Returns: The cases, in file order.
        public func cases(_ task: String) -> [Case] { cases.filter { $0.task == task } }

        /// One `edit_file` call the prompt asks for, and the line it is meant for.
        public struct Edit: Decodable, Sendable {
            /// The line edited: the number the model should find for `target` or `locate`, or the number the prompt
            /// gives (a stale one, with `find`). Nil for a replacement by `find` alone.
            public let line: Int?
            /// The line's whole text, which the prompt names so the model finds its number.
            public let target: String?
            /// A description of the line, for a line `target` cannot name (an empty one).
            public let locate: String?
            /// The text the edit expects: with `line`, the text that line must contain; without, the text replaced.
            public let find: String?
            /// The new line, or the replacement for `find`.
            public let content: String

            /// The edit as `FileWriter` takes it, to check a case without a model.
            public var writerEdit: FileWriter.Edit {
                if let line { return .replaceLine(line, content: content, expecting: find) }
                return .replace(find: find ?? "", replacement: content)
            }

            /// The instruction for this call, after "use".
            ///
            /// - Parameter path: The file's path.
            /// - Returns: The instruction, such as "edit_file with mode replace on /x, with line set to …".
            func instruction(path: String) -> String {
                let content = content.isEmpty ? "an empty content" : "content `\(content)`"
                let start = "edit_file with mode replace on \(path), with"
                if let target {
                    return "\(start) line set to the number read_file showed for `\(target)` and \(content)"
                }
                if let locate { return "\(start) line set to the number read_file showed for \(locate) and \(content)" }
                if let line { return "\(start) line \(line), find `\(find ?? "")`, and \(content)" }
                return "\(start) find set to `\(find ?? "")`, no line, and \(content)"
            }
        }

        /// One case.
        public struct Case: Decodable, Sendable {
            /// Unique within the set.
            public let id: String
            /// `replace` or `whitespace`: which measurement it belongs to.
            public let task: String
            /// The edit's shape, such as `single`, `range`, `stale`, or `crlf`; the release's subset is spread over
            /// the shapes.
            public let shape: String
            /// The file's name, unique within the set.
            public let file: String
            /// Whether the prompt has the model read the file first.
            public let read: Bool
            /// What the prompt says before the instructions, such as where a stale number came from.
            public let note: String?
            /// The calls a right answer makes, in order.
            public let edits: [Edit]
            /// The file before.
            public let before: String
            /// The file after a right answer; a pass is the file ending up exactly so.
            public let after: String

            /// The prompt the model is given for the file at `path`. A case with one edit by `target`, read first,
            /// is worded exactly as `edit_file.replace` was before 0.23.0.
            ///
            /// - Parameter path: The file's path.
            /// - Returns: The prompt.
            public func prompt(path: String) -> String {
                var sentences: [String] = []
                if let note { sentences.append(note) }
                if read { sentences.append("Use read_file to read \(path).") }
                for (index, edit) in edits.enumerated() {
                    let lead = index == 0 && !read ? "Without reading the file again, use" : "Then use"
                    sentences.append("\(lead) \(edit.instruction(path: path)).")
                }
                sentences.append("Report the tool results verbatim.")
                return sentences.joined(separator: " ")
            }
        }
    }
}

// MARK: - system_info

extension EvalSets {
    /// `system_info`'s questions (`system_info.json`): plain questions about the Mac and the calls a careful
    /// operator accepts.
    public struct SystemInfo: Decodable, Sendable {
        /// The number of questions, checked against the cases.
        public let declared: Int
        /// How many the release's eval asks, a fixed seeded subset.
        public let release: Int
        /// The questions, in file order.
        public let cases: [Case]

        /// The set, read from `system_info.json`.
        ///
        /// - Returns: The set.
        /// - Throws: A file or decoding error.
        public static func load() throws -> SystemInfo { try EvalSets.load(SystemInfo.self, "system_info.json") }

        /// A call a careful operator accepts.
        public struct Accept: Decodable, Sendable {
            /// The topic.
            public let topic: String
            /// For `ports` the port, for `process` the name: the call's must contain it, ignoring case.
            public let target: String?
            /// For `folderSizes` the folder: the call's path must contain it, ignoring case.
            public let path: String?

            /// An accepted call.
            ///
            /// - Parameters:
            ///   - topic: The topic.
            ///   - target: The port or process name, if one must be named.
            ///   - path: The folder, if one must be named.
            public init(topic: String, target: String?, path: String?) {
                self.topic = topic
                self.target = target
                self.path = path
            }

            /// Whether a call with these arguments is this one.
            ///
            /// - Parameters:
            ///   - topic: The call's topic.
            ///   - target: The call's port, as text, or process name.
            ///   - path: The call's folder.
            /// - Returns: True when the topic is this one's and every given part is contained.
            public func matches(topic: String, target: String?, path: String?) -> Bool {
                topic == self.topic
                    && (self.target.map { target?.localizedCaseInsensitiveContains($0) == true } ?? true)
                    && (self.path.map { path?.localizedCaseInsensitiveContains($0) == true } ?? true)
            }
        }

        /// One question.
        public struct Case: Decodable, Sendable {
            /// Unique within the set.
            public let id: String
            /// The question, which never names the tool.
            public let question: String
            /// The calls that pass; more than one only for an ambiguous question.
            public let accept: [Accept]
            /// Whether more than one topic answers it fairly.
            public let ambiguous: Bool?
            /// Why an ambiguous question accepts what it does.
            public let note: String?

            /// The topic the release's subset is spread over: the first accepted.
            public var stratum: String { accept.first?.topic ?? "" }
        }
    }
}

// MARK: - draft_change

extension EvalSets {
    /// `draft_change`'s diffs (`drafts.json`) in three size bands, with the rubric a commit subject is held to.
    public struct Drafts: Decodable, Sendable {
        /// The number of diffs each band declares, checked against the cases.
        public let declared: [String: Int]
        /// How many diffs of each band the release's eval drafts, a fixed seeded subset.
        public let release: [String: Int]
        /// The diffs, in file order.
        public let cases: [Case]

        /// The bands, smallest first.
        public static let bands = ["small", "medium", "large"]

        /// The set, read from `drafts.json`.
        ///
        /// - Returns: The set.
        /// - Throws: A file or decoding error.
        public static func load() throws -> Drafts { try EvalSets.load(Drafts.self, "drafts.json") }

        /// The diffs of one band.
        ///
        /// - Parameter band: `small`, `medium`, or `large`.
        /// - Returns: The diffs, in file order.
        public func cases(_ band: String) -> [Case] { cases.filter { $0.band == band } }

        /// What a subject was judged.
        public enum Verdict: Equatable, Sendable {
            /// A `must` term and no `mustNot` term.
            case pass
            /// No `must` term: the subject does not name the gist.
            case missing
            /// A `mustNot` term: the subject says something the change does not do.
            case forbidden(String)
        }

        /// One diff and its rubric.
        public struct Case: Decodable, Sendable {
            /// Unique within the set: a short name, or the commit's abbreviated hash for a real one.
            public let id: String
            /// `small`, `medium`, or `large`.
            public let band: String
            /// The diff's file, relative to the fixtures directory.
            public let file: String
            /// What the change does, in a sentence: what the rubric's terms were chosen from.
            public let gist: String
            /// Terms, any one of which a right subject has (each beginning a word).
            public let must: [String]
            /// Terms none of which a right subject has: what would misdescribe the change.
            public let mustNot: [String]

            /// The diff's text.
            ///
            /// - Returns: The diff.
            /// - Throws: A file error.
            public func diff() throws -> String {
                try String(contentsOf: EvalSets.fixturesDirectory.appending(path: file), encoding: .utf8)
            }

            /// Judges a drafted subject by the rubric: a `mustNot` term fails it first, then it needs a `must` term.
            ///
            /// - Parameter subject: The subject.
            /// - Returns: The verdict.
            public func judge(_ subject: String) -> Verdict {
                if let term = mustNot.first(where: { EvalSets.beginsWord($0, in: subject) }) { return .forbidden(term) }
                return must.contains { EvalSets.beginsWord($0, in: subject) } ? .pass : .missing
            }
        }
    }
}

// MARK: - Sampling and floors

/// A fixed, seeded subset of a case set, so the release's eval runs fewer cases than the whole set and the same ones
/// every time. Cases are grouped by a stratum (an edit's shape, a question's topic), each group is ordered by an FNV-1a
/// hash of the seed and the case's id, and the groups are taken from in turn, so the subset is spread over every
/// stratum it has room for; the subset keeps the set's order.
public enum EvalSample {
    /// The seed of the release's subsets. Changing it draws other subsets; the floors do not depend on it.
    public static let releaseSeed = "wisp-eval-0.23.0"

    /// The subset.
    ///
    /// - Parameters:
    ///   - items: The whole set.
    ///   - count: How many to take; the whole set when it has no more.
    ///   - seed: The seed.
    ///   - id: Each case's unique id.
    ///   - stratum: Each case's group.
    /// - Returns: `count` cases, in the set's order.
    public static func subset<T>(
        _ items: [T], count: Int, seed: String = releaseSeed, id: (T) -> String, stratum: (T) -> String
    ) -> [T] {
        guard count < items.count else { return items }
        let indexed = Array(items.enumerated())
        var groups = Dictionary(grouping: indexed) { stratum($0.element) }.mapValues { group in
            group.sorted { hash("\(seed)\u{0}\(id($0.element))") < hash("\(seed)\u{0}\(id($1.element))") }
        }
        let order = groups.keys.sorted()
        var chosen: [Int] = []
        while chosen.count < count {
            for key in order where chosen.count < count {
                guard let next = groups[key]?.first else { continue }
                groups[key]?.removeFirst()
                chosen.append(next.offset)
            }
        }
        return chosen.sorted().map { items[$0] }
    }

    /// The 64-bit FNV-1a hash of `text`'s UTF-8 bytes: stable across runs and machines, unlike `Hasher`.
    ///
    /// - Parameter text: The text.
    /// - Returns: The hash.
    public static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
}

/// The release's floors, set from statistics rather than by eye: with `n` cases each passed independently at the
/// configured model's historical rate `p`, the floor is the largest `k` for which a run scoring below `k` has a chance
/// of at most `risk` (1%), so a release stops on chance alone at most one time in a hundred. A floor of 0 asserts
/// nothing. The rates and the arithmetic are in docs/measurements.md, "The floors".
public enum EvalFloor {
    /// A historical pass rate: cases passed of cases run, over the runs it was measured from.
    public struct Rate: Sendable, Equatable {
        /// Cases passed.
        public let passed: Int
        /// Cases run.
        public let total: Int
        /// The rate.
        public var value: Double { total > 0 ? Double(passed) / Double(total) : 0 }
    }

    /// The configured model's rates over the six eval runs saved from 2026-10-04 to 2026-10-12 and the full-set run of 2026-10-12 (the
    /// summaries under `harness/Evals/.build/evals`, docs/measurements.md, "The floors").
    public enum Historical {
        /// `edit_file.replace`: 16, 19, 25, 18, 16, and 21 of 30, and 61 of 86 on the 2026-10-12 full set.
        public static let editFileReplace = Rate(passed: 176, total: 266)
        /// `edit_file.whitespace`: 11, 10, 12, 11, and 12 of 12 (five runs), and 20 of 24 on the 2026-10-12 full set.
        public static let editFileWhitespace = Rate(passed: 76, total: 84)
        /// `system_info.topic`, on the 54-case set only (re-set on 2026-10-13: the 16-case set it replaced was easier,
        /// 84 of 96, and pooling it in set the floor above what the set scores): 43, 36, and 39 of 54 on the full set,
        /// and 17, 19, 16, and 15 of 24 on the release's subset, from 2026-10-12 to 2026-10-13.
        public static let systemInfo = Rate(passed: 185, total: 258)
        /// `draft_change.commit`, small diffs: 9, 10, 8, 6, 7, and 8 of 10, and 21 of 30 on the 2026-10-12 full set.
        public static let draftSmall = Rate(passed: 69, total: 90)
        /// `draft_change.commit`, medium diffs: 1, 1, 2, 1, 1, and 1 of 2, and 4 of 8 on the 2026-10-12 full set.
        public static let draftMedium = Rate(passed: 11, total: 20)
        /// `draft_change.commit`, large diffs: 1 of 2 in each run, and 3 of 6 on the 2026-10-12 full set.
        public static let draftLarge = Rate(passed: 9, total: 18)
    }

    /// The default chance of a release stopping on chance alone.
    public static let risk = 0.01

    /// The floor for `cases` cases at `rate`.
    ///
    /// - Parameters:
    ///   - cases: The cases run.
    ///   - rate: The historical pass rate.
    ///   - risk: The chance allowed of scoring below the floor by chance alone.
    /// - Returns: The least number of cases a run must pass, 0 when none can be asked for.
    public static func minimum(cases: Int, rate: Double, risk: Double = risk) -> Int {
        var floor = 0
        while floor < cases, chanceBelow(floor + 1, cases: cases, rate: rate) <= risk { floor += 1 }
        return floor
    }

    /// The chance of passing fewer than `passed` of `cases` at `rate`: the binomial distribution's lower tail.
    ///
    /// - Parameters:
    ///   - passed: The score.
    ///   - cases: The cases run.
    ///   - rate: Each case's chance of passing.
    /// - Returns: P(X < passed) for X ~ Binomial(cases, rate).
    public static func chanceBelow(_ passed: Int, cases: Int, rate: Double) -> Double {
        guard passed > 0 else { return 0 }
        guard rate < 1 else { return passed > cases ? 1 : 0 }
        guard rate > 0 else { return 1 }
        var term = pow(1 - rate, Double(cases))
        var total = 0.0
        for score in 0..<min(passed, cases + 1) {
            total += term
            term *= Double(cases - score) / Double(score + 1) * rate / (1 - rate)
        }
        return min(total, 1)
    }
}
