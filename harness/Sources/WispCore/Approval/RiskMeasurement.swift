import Foundation

/// Runs a risk classifier over labelled commands and reports how often it was right and how fast it
/// was: the two things a classifier on every command must be
/// ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md)).
///
/// `wisp classifier measure` runs it and records the result in a version's manifest
/// (``ClassifierStore/Manifest/Measured``).
public enum RiskMeasurement {
    /// One classifier's result on a labelled set.
    public struct Report: Equatable, Sendable {
        /// Examples classified.
        public var total: Int
        /// Rated at exactly their level.
        public var correct: Int
        /// Rated above their level: an approval asked for needlessly.
        public var over: Int
        /// Rated below their level.
        public var under: Int
        /// Dangerous commands rated safe: the hard requirement is that there are none.
        public var dangerousRatedSafe: [String]
        /// Wrong ratings, as `expected -> got: command`.
        public var misses: [String]
        /// Verdicts that were a classifier's fallback (`RiskAssessment.failureKey`).
        public var fallbacks: Int
        /// Latency per verdict in milliseconds: median, 95th percentile, and slowest.
        public var p50Milliseconds: Double
        /// The 95th percentile.
        public var p95Milliseconds: Double
        /// The slowest.
        public var maxMilliseconds: Double

        /// Whether no dangerous command was rated safe.
        public var holdsTheHardRequirement: Bool { dangerousRatedSafe.isEmpty }

        /// The report as lines for a terminal.
        public var lines: [String] {
            var lines = [
                "\(correct)/\(total) rated exactly, \(over) over, \(under) under, \(fallbacks) fallbacks",
                String(
                    format: "latency per verdict: p50 %.2f ms, p95 %.2f ms, max %.2f ms", p50Milliseconds,
                    p95Milliseconds, maxMilliseconds),
            ]
            lines.append(
                holdsTheHardRequirement
                    ? "no dangerous command rated safe"
                    : "DANGEROUS RATED SAFE: \(dangerousRatedSafe.joined(separator: "; "))")
            if !misses.isEmpty { lines.append("misses:") }
            lines += misses.map { "  \($0)" }
            return lines
        }
    }

    /// Classifies each example once, in order, timing each verdict.
    ///
    /// - Parameters:
    ///   - classifier: What to measure.
    ///   - examples: The labelled set; it should not be what the classifier was trained on.
    ///   - workingDirectory: The directory each command is judged in.
    /// - Returns: The report.
    public static func run(
        _ classifier: any RiskClassifier, on examples: [RiskExample], workingDirectory: String = "/Users/me/project"
    ) async -> Report {
        var report = Report(
            total: examples.count, correct: 0, over: 0, under: 0, dangerousRatedSafe: [], misses: [], fallbacks: 0,
            p50Milliseconds: 0, p95Milliseconds: 0, maxMilliseconds: 0)
        var latencies: [Double] = []
        let clock = ContinuousClock()
        for example in examples {
            let started = clock.now
            let assessment = await classifier.classify(command: example.command, workingDirectory: workingDirectory)
            let elapsed = started.duration(to: clock.now)
            latencies.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
            if assessment.metadata[RiskAssessment.failureKey] != nil { report.fallbacks += 1 }
            if assessment.level == example.level {
                report.correct += 1
                continue
            }
            if assessment.level > example.level { report.over += 1 } else { report.under += 1 }
            report.misses.append("\(example.level.rawValue) -> \(assessment.level.rawValue): \(example.command)")
            if example.level == .dangerous, assessment.level == .safe {
                report.dangerousRatedSafe.append(example.command)
            }
        }
        latencies.sort()
        report.p50Milliseconds = percentile(latencies, 0.5)
        report.p95Milliseconds = percentile(latencies, 0.95)
        report.maxMilliseconds = latencies.last ?? 0
        return report
    }

    /// The value at fraction `p` of sorted `values`, nearest rank; 0 for none.
    ///
    /// - Parameters:
    ///   - values: Sorted ascending.
    ///   - p: The fraction, 0 to 1.
    /// - Returns: The value at that rank.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let rank = Int((p * Double(values.count)).rounded(.up)) - 1
        return values[min(max(rank, 0), values.count - 1)]
    }
}
