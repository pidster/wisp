import Foundation

/// A command labelled with the risk level the approval gate should give it: a training example for
/// a specialised classifier, or a case to measure one against.
public struct RiskExample: Equatable, Sendable {
    /// The command line.
    public var command: String
    /// The level it should be rated.
    public var level: RiskLevel

    /// Creates an example.
    ///
    /// - Parameters:
    ///   - command: The command line.
    ///   - level: The level it should be rated.
    public init(command: String, level: RiskLevel) {
        self.command = command
        self.level = level
    }
}

/// Labelled commands in wisp's text format: one per line, `level<TAB>command`, with `#` comments and
/// blank lines ignored ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md)).
///
/// The format of the sets under `training/` and of `Resources/risk-examples.tsv`, which
/// `scripts/check classifier-default` copies from `training/risk/train.tsv`.
public enum RiskExamples {
    /// A line that is not a labelled command.
    public struct Problem: Error, CustomStringConvertible, Equatable {
        /// The 1-based line number.
        public var line: Int
        /// What is wrong with it.
        public var reason: String

        /// Human-readable explanation.
        public var description: String { "line \(line): \(reason)" }
    }

    /// The examples shipped with wisp, from `Resources/risk-examples.tsv`: what `wisp classifier
    /// train` learns from when given nothing else. Kept apart from the eval set that measures it.
    public static let bundled: [RiskExample] = (try? parse(RiskExamplesText.text)) ?? []

    /// Parses labelled lines.
    ///
    /// - Parameter text: The file's text.
    /// - Returns: The examples, in order.
    /// - Throws: `Problem` for the first line that has no tab, an unknown level, or no command.
    public static func parse(_ text: String) throws -> [RiskExample] {
        var examples: [RiskExample] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            // Spaces and a carriage return around the line go; a tab is the separator, so it stays. A
            // U+200B, which training files put inside secret-looking values so scanners do not take the
            // file for a leak, is removed, so no classifier learns it.
            let line = raw.replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \r"))
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let tab = line.firstIndex(of: "\t") else {
                throw Problem(line: index + 1, reason: "expected level<TAB>command")
            }
            let label = String(line[..<tab])
            guard let level = RiskLevel(rawValue: label) else {
                throw Problem(line: index + 1, reason: "unknown level '\(label)'; use safe, moderate, or dangerous")
            }
            let command = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw Problem(line: index + 1, reason: "no command after the level") }
            examples.append(RiskExample(command: command, level: level))
        }
        return examples
    }

    /// What the audit log yielded for training.
    public struct Harvest: Equatable, Sendable {
        /// One example per distinct command, in the order each was first seen, labelled by its latest verdict.
        public var examples: [RiskExample]
        /// Model verdicts read, repeats included.
        public var verdicts: Int
        /// Verdicts left out because the model could not judge and the level was a fallback.
        public var fallbacks: Int
        /// Examples raised to `moderate` because a person refused the command.
        public var raised: Int
        /// Examples with a secret or personal value replaced before training.
        public var redacted: Int
    }

    /// Labelled commands from the audit log: the on-device model's verdicts on the commands this Mac
    /// actually ran, so a fast classifier can learn what the slow one decided (ADR 0038).
    ///
    /// Only verdicts the model took part in count (`sources` includes `model`), and not its fallbacks.
    /// Each distinct command keeps its latest verdict. A command a person refused is raised to at least
    /// `moderate`: a refusal says it should not run unasked, never that it was harmless. Secrets and
    /// personal data are replaced by markers first, since a trained model keeps the words it learned.
    ///
    /// - Parameter events: Audit events in time order.
    /// - Returns: The examples and what was left out.
    public static func fromAudit(_ events: [AuditEvent]) -> Harvest {
        let refused = Set(
            events.filter { $0.kind == .approvalDecided && $0.details["decision"]?.stringValue == "denied" }
                .map { refusalKey($0) })
        var harvest = Harvest(examples: [], verdicts: 0, fallbacks: 0, raised: 0, redacted: 0)
        var byCommand: [String: (index: Int, example: RiskExample, raised: Bool, redacted: Bool)] = [:]
        for event in events where event.kind == .classifierVerdict {
            let details = event.details
            guard let sources = details["sources"]?.arrayValue, sources.contains("model"),
                let command = details["command"]?.stringValue, let label = details["level"]?.stringValue,
                var level = RiskLevel(rawValue: label)
            else { continue }
            harvest.verdicts += 1
            if details["metadata"]?.objectValue?[RiskAssessment.failureKey] != nil {
                harvest.fallbacks += 1
                continue
            }
            let wasRefused = refused.contains(refusalKey(event)) && level < .moderate
            if wasRefused { level = .moderate }
            var redactor = Redactor()
            let clean = redactor.apply(SecretScanner.scan(command), to: command)
            let key = CoreMLRiskClassifier.Contract.preprocess(clean, version: "1")
            let index = byCommand[key]?.index ?? byCommand.count
            byCommand[key] = (index, RiskExample(command: clean, level: level), wasRefused, clean != command)
        }
        let kept = byCommand.values.sorted { $0.index < $1.index }
        harvest.examples = kept.map(\.example)
        harvest.raised = kept.filter(\.raised).count
        harvest.redacted = kept.filter(\.redacted).count
        return harvest
    }

    /// The command a verdict or a refusal is about, in its session and turn.
    ///
    /// A refusal raises only the verdicts on the same command in the same turn, not every use of it.
    ///
    /// - Parameter event: A `classifier.verdict` or `approval.decided` event.
    /// - Returns: The key.
    private static func refusalKey(_ event: AuditEvent) -> String {
        "\(event.session)|\(event.turn ?? -1)|\(event.details["command"]?.stringValue ?? "")"
    }

    /// `base` with `additions` merged in: an addition for a command already in `base` replaces it.
    ///
    /// Commands are compared as contract 1 preprocesses them, so spacing alone does not make two commands
    /// different.
    ///
    /// - Parameters:
    ///   - base: The examples to start from.
    ///   - additions: The examples that win.
    /// - Returns: `base` without the replaced commands, then `additions`.
    public static func merged(_ base: [RiskExample], with additions: [RiskExample]) -> [RiskExample] {
        let key = { (example: RiskExample) in CoreMLRiskClassifier.Contract.preprocess(example.command, version: "1") }
        let replaced = Set(additions.map(key))
        return base.filter { !replaced.contains(key($0)) } + additions
    }

    /// Reads and parses a file of labelled lines.
    ///
    /// - Parameter url: The file.
    /// - Returns: The examples.
    /// - Throws: A read error, or `Problem`.
    public static func load(_ url: URL) throws -> [RiskExample] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
