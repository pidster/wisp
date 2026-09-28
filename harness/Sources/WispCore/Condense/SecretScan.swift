import Foundation

/// Reports credentials and personal data in captured text without repeating them: the `scan_secrets`
/// MCP tool and `wisp scan`. A diff is scanned by its added lines and located by `path:line`, so it
/// suits a pre-commit check of `git diff --cached`. Rules always run; `thorough` adds the model's pass
/// over the rule-redacted text ([ADR 0031](../../../../docs/decisions/0031-secret-scanning-and-redaction.md)).
/// With personal data asked for, the personal-data classifier then flags the lines neither found anything
/// on ([ADR 0042](../../../../docs/decisions/0042-personal-data-classifier.md)).
public struct SecretScan: Sendable {
    /// Knobs for one scan.
    public struct Options: Equatable, Sendable {
        /// Which categories to report; secrets only by default, since a diff is full of email addresses.
        public var categories: Set<SecretScanner.Category>
        /// Whether the model sweeps the text after the rules.
        public var thorough: Bool
        /// Findings kept; the rest is reported as `more`.
        public var maxFindings: Int

        /// Creates options.
        public init(categories: Set<SecretScanner.Category> = [.secret], thorough: Bool = false, maxFindings: Int = 50)
        {
            self.categories = categories
            self.thorough = thorough
            self.maxFindings = maxFindings
        }
    }

    /// The result of a scan.
    public struct Report: Equatable, Sendable {
        /// What was scanned: a command or file, or nil for standard input.
        public var source: Triage.Source?
        /// Bytes scanned.
        public var bytes: Int
        /// Whether the text was read as a diff.
        public var diff: Bool
        /// Whether the model swept it too, and over how many chunks.
        public var chunks: Int?
        /// The 1-based chunks the model failed on, twice, where only the rules looked.
        public var failedChunks: [Int] = []
        /// What was found, in order.
        public var findings: [SecretScanner.Finding]
        /// Whether findings beyond the cap were dropped.
        public var more: Bool
        /// The personal-data classifier that judged the lines, `personal@<version>`, or why it could not;
        /// nil when personal data was not asked for.
        public var classifier: String? = nil

        /// The report as JSON, the shape the MCP tool returns (`docs/mcp.md`).
        public var json: JSONValue {
            [
                "source": Condensing.json(source), "bytes": .int(bytes), "diff": .bool(diff),
                "thorough": .bool(chunks != nil), "chunks": chunks.map { .int($0) } ?? .null, "more": .bool(more),
                "failedChunks": .array(failedChunks.map { .int($0) }),
                "classifier": classifier.map { .string($0) } ?? .null,
                "findings": .array(findings.map(\.json)),
            ]
        }

        /// The report as lines: a headline, then `location  kind  preview` per finding.
        public var rendered: String {
            let count = "\(findings.count)\(more ? "+" : "") finding\(findings.count == 1 ? "" : "s")"
            var head = "\(count) in \(bytes) bytes\(diff ? " of diff" : "")"
            if let chunks { head += "; model pass over \(chunks) chunk\(chunks == 1 ? "" : "s")" }
            head += SecretScan.failureNote(failedChunks)
            if let classifier, classifier.hasPrefix("unavailable") {
                head += "; personal-data classifier \(classifier)"
            }
            let rows = findings.map {
                [$0.location, $0.kind, $0.preview, $0.detector == "rule" ? "" : "(\($0.detector))"]
            }
            return ([head] + TextTable.render(header: ["LOCATION", "KIND", "PREVIEW", ""], rows: rows).dropFirst())
                .joined(separator: "\n")
        }

        /// Kinds found and how often, for the audit record.
        public var kinds: [String: Int] {
            findings.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
        }
    }

    /// The options in force.
    public let options: Options
    /// Judges a chunk for the model pass; nil when the scan is rules only.
    private let judge: Triage.Judge?
    /// Flags lines holding personal data, or why it cannot; used only when personal data is asked for.
    private let classifier: Result<PersonalDataClassifier, PersonalDataClassifier.Failure>?

    /// Creates a scan.
    ///
    /// - Parameters:
    ///   - options: Categories, the model pass, the cap.
    ///   - judge: A fresh model turn per chunk; required when `options.thorough`.
    ///   - classifier: The personal-data classifier (`PersonalDataClassifier.shipped`), or nil for none.
    public init(
        options: Options = Options(), judge: Triage.Judge? = nil,
        classifier: Result<PersonalDataClassifier, PersonalDataClassifier.Failure>? = nil
    ) {
        self.options = options
        self.judge = judge
        self.classifier = classifier
    }

    /// Scans `text`.
    ///
    /// - Parameters:
    ///   - text: What to scan.
    ///   - source: Where it came from, for the report and the prompt.
    /// - Returns: The report.
    /// - Throws: `CancellationError` when cancelled during the model pass; a chunk the model fails on is
    ///   reported in `failedChunks`, not thrown.
    public func run(_ text: String, from source: Triage.Source?) async throws -> Report {
        let diff = SecretScanner.looksLikeDiff(text)
        var findings: [SecretScanner.Finding]
        let scanned: String
        if diff {
            findings = SecretScanner.scanDiff(text, categories: options.categories)
            scanned = SecretScanner.added(in: text).map(\.text).joined(separator: "\n")
        } else {
            findings = SecretScanner.scan(text, categories: options.categories).map {
                SecretScanner.Finding(
                    kind: $0.kind, category: $0.category, location: Self.place(line: $0.line, in: source),
                    preview: SecretScanner.mask($0.value), detector: "rule")
            }
            scanned = text
        }
        var chunks: Int?
        var failed: [Int] = []
        if options.thorough, let judge {
            var redactor = Redactor()
            let redacted = redactor.apply(SecretScanner.scan(scanned), to: scanned)
            let sweep = try await ModelSweep(judge: judge).run(redacted, label: Condensing.label(source))
            chunks = sweep.chunks
            failed = sweep.failed
            for found in sweep.values {
                guard let category = ModelSweep.kinds[found.kind], options.categories.contains(category),
                    let location = Self.locate(found.value, in: text, diff: diff, source: source)
                else { continue }
                findings.append(
                    SecretScanner.Finding(
                        kind: found.kind, category: category, location: location,
                        preview: SecretScanner.mask(found.value), detector: "model"))
            }
        }
        var used: String?
        if options.categories.contains(.personal), let classifier {
            switch classifier {
            case .success(let model):
                used = model.reference
                findings += Self.classified(
                    text, diff: diff, source: source, by: model, skipping: Set(findings.map(\.location)))
            case .failure(let failure):
                used = "unavailable: \(failure)"
            }
        }
        let more = findings.count > options.maxFindings
        return Report(
            source: source, bytes: text.utf8.count, diff: diff, chunks: chunks, failedChunks: failed,
            findings: Array(findings.prefix(options.maxFindings)), more: more, classifier: used)
    }

    /// The lines of `text` (a diff's added lines) the classifier flags as personal data, apart from those
    /// at `skipping`, where a rule or the model already found something. A finding names the line, not a
    /// value: its preview is the masked line.
    static func classified(
        _ text: String, diff: Bool, source: Triage.Source?, by model: PersonalDataClassifier,
        skipping: Set<String>
    ) -> [SecretScanner.Finding] {
        let lines: [(location: String, text: String)] =
            diff
            ? SecretScanner.added(in: text).map { ("\($0.path):\($0.number)", $0.text) }
            : text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
                (place(line: $0.offset + 1, in: source), String($0.element))
            }
        return lines.filter { !skipping.contains($0.location) && model.flags($0.text) }.map {
            SecretScanner.Finding(
                kind: "personal-data", category: .personal, location: $0.location,
                preview: SecretScanner.mask($0.text.trimmingCharacters(in: .whitespaces)), detector: "classifier")
        }
    }

    /// What a report says about chunks the model failed on: nothing when there were none.
    static func failureNote(_ failed: [Int]) -> String {
        guard !failed.isEmpty else { return "" }
        let numbers = failed.map(String.init).joined(separator: ", ")
        return "; the model failed on chunk\(failed.count == 1 ? "" : "s") \(numbers), checked by rule only"
    }

    /// Where a value first appears: `path:line` among a diff's added lines, else as `place` says; nil
    /// when a diff adds no line holding it.
    static func locate(_ value: String, in text: String, diff: Bool, source: Triage.Source?) -> String? {
        if diff {
            return SecretScanner.added(in: text).first { $0.text.contains(value) }.map { "\($0.path):\($0.number)" }
        }
        guard let found = text.range(of: value) else { return nil }
        return place(line: text[..<found.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }, in: source)
    }

    /// A line of a scanned file as `path:line`, of anything else as `line N`.
    static func place(line: Int, in source: Triage.Source?) -> String {
        if case .path(let path) = source { return "\(path):\(line)" }
        return "line \(line)"
    }
}

/// Returns captured text with credentials and personal data replaced by numbered markers: the `redact`
/// MCP tool and `wisp redact`, for text on its way to an issue, a chat, or a cloud model. Rules always
/// run; `thorough` adds the model's pass for names, addresses, and identifiers the rules cannot see.
public struct Redaction: Sendable {
    /// Knobs for one redaction.
    public struct Options: Equatable, Sendable {
        /// Which categories to replace; both by default.
        public var categories: Set<SecretScanner.Category>
        /// Whether the model sweeps the text after the rules.
        public var thorough: Bool
        /// Bytes of redacted text returned; the rest is cut and flagged.
        public var maxOutputBytes: Int

        /// Creates options.
        public init(
            categories: Set<SecretScanner.Category> = Set(SecretScanner.Category.allCases), thorough: Bool = false,
            maxOutputBytes: Int = 32 << 10
        ) {
            self.categories = categories
            self.thorough = thorough
            self.maxOutputBytes = maxOutputBytes
        }
    }

    /// The result of a redaction.
    public struct Report: Equatable, Sendable {
        /// What was redacted: a command or file, or nil for standard input.
        public var source: Triage.Source?
        /// Bytes read.
        public var bytes: Int
        /// The redacted text, cut to the output cap.
        public var text: String
        /// Whether the redacted text was cut.
        public var truncated: Bool
        /// Occurrences replaced, per kind.
        public var counts: [String: Int]
        /// Chunks the model swept, or nil when the redaction was rules only.
        public var chunks: Int?
        /// The 1-based chunks the model failed on, twice, where only the rules redacted.
        public var failedChunks: [Int] = []

        /// The report as JSON, the shape the MCP tool returns (`docs/mcp.md`).
        public var json: JSONValue {
            [
                "source": Condensing.json(source), "bytes": .int(bytes), "text": .string(text),
                "truncated": .bool(truncated), "thorough": .bool(chunks != nil),
                "chunks": chunks.map { .int($0) } ?? .null, "failedChunks": .array(failedChunks.map { .int($0) }),
                "replaced": .object(counts.mapValues { .int($0) }),
            ]
        }

        /// One line saying what was replaced, for stderr or the head of the MCP text.
        public var summary: String {
            let total = counts.values.reduce(0, +)
            let kinds = counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ")
            var line = "redacted \(total) value\(total == 1 ? "" : "s")\(kinds.isEmpty ? "" : " (\(kinds))")"
            if let chunks { line += "; model pass over \(chunks) chunk\(chunks == 1 ? "" : "s")" }
            line += SecretScan.failureNote(failedChunks)
            if truncated { line += "; output cut to \(text.utf8.count) bytes" }
            return line
        }
    }

    /// The options in force.
    public let options: Options
    /// Judges a chunk for the model pass; nil when the redaction is rules only.
    private let judge: Triage.Judge?

    /// Creates a redaction.
    ///
    /// - Parameters:
    ///   - options: Categories, the model pass, the output cap.
    ///   - judge: A fresh model turn per chunk; required when `options.thorough`.
    public init(options: Options = Options(), judge: Triage.Judge? = nil) {
        self.options = options
        self.judge = judge
    }

    /// Redacts `text`.
    ///
    /// - Parameters:
    ///   - text: What to redact.
    ///   - source: Where it came from, for the report and the prompt.
    /// - Returns: The report.
    /// - Throws: `CancellationError` when cancelled during the model pass; a chunk the model fails on is
    ///   reported in `failedChunks`, not thrown.
    public func run(_ text: String, from source: Triage.Source?) async throws -> Report {
        var redactor = Redactor()
        var redacted = redactor.apply(SecretScanner.scan(text, categories: options.categories), to: text)
        var chunks: Int?
        var failed: [Int] = []
        if options.thorough, let judge {
            let sweep = try await ModelSweep(judge: judge).run(redacted, label: Condensing.label(source))
            chunks = sweep.chunks
            failed = sweep.failed
            let wanted = sweep.values.filter { ModelSweep.kinds[$0.kind].map(options.categories.contains) ?? false }
            redacted = redactor.apply(literals: wanted, to: redacted)
        }
        let truncated = redacted.utf8.count > options.maxOutputBytes
        let kept = truncated ? String(decoding: redacted.utf8.prefix(options.maxOutputBytes), as: UTF8.self) : redacted
        return Report(
            source: source, bytes: text.utf8.count, text: kept, truncated: truncated, counts: redactor.counts,
            chunks: chunks, failedChunks: failed)
    }
}

/// What the condensing tools share about where their input came from.
enum Condensing {
    /// A source as JSON: the command and directory, the path, or standard input.
    static func json(_ source: Triage.Source?) -> JSONValue {
        switch source {
        case .command(let line, let directory):
            ["command": .string(line), "workingDirectory": directory.map { .string($0) } ?? .null]
        case .path(let path): ["path": .string(path)]
        case nil: ["stdin": true]
        }
    }

    /// What to call a source in a prompt.
    static func label(_ source: Triage.Source?) -> String {
        source?.label ?? "text read from standard input"
    }
}
