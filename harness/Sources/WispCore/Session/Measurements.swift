import Foundation
import Synchronization

/// One measured result of a task the model performs: how many of the eval's cases passed, on which
/// model, when. Recorded by `scripts/check eval` into `Resources/measurements.json`, embedded at
/// build time, and published with the tool catalogue so a caller knows which delegations are
/// reliable ([ADR 0026](../../../../docs/decisions/0026-task-catalogue.md)). A measurement describes
/// an eval run on one Mac; it is not a certification.
public struct Measurement: Codable, Equatable, Sendable {
    /// The task, such as `triage`, `edit_file.replace`, `respond.schema`, `classifier.system-model`.
    public var task: String
    /// The model's tool the task exercises, when it is one; matches `ToolDescription.name`.
    public var tool: String?
    /// The model the eval ran on, as a `ModelSelection` spelling.
    public var model: String
    /// The day of the run, `YYYY-MM-DD`.
    public var date: String
    /// Cases that passed.
    public var passed: Int
    /// Cases in the eval.
    public var total: Int
    /// What a case is and what counted as a pass, in one sentence.
    public var notes: String
    /// The largest input among the cases, in bytes, when the task routes by input size: the result is
    /// evidence for inputs up to this size and no further ([ADR 0037](../../../../docs/decisions/0037-routing-by-input-size.md)).
    public var maxInputBytes: Int?
    /// The median time per case in milliseconds, when speed is part of what is measured, as it is for
    /// a classifier that runs on every command ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md)).
    public var p50Milliseconds: Double?
    /// The 95th-percentile time per case in milliseconds, beside `p50Milliseconds`.
    public var p95Milliseconds: Double?

    /// Creates a measurement dated today.
    public init(
        task: String, tool: String? = nil, model: String, passed: Int, total: Int, notes: String,
        maxInputBytes: Int? = nil, p50Milliseconds: Double? = nil, p95Milliseconds: Double? = nil
    ) {
        self.task = task
        self.tool = tool
        self.model = model
        self.maxInputBytes = maxInputBytes
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        self.passed = passed
        self.total = total
        self.notes = notes
    }

    /// `passed/total` and the rate.
    public var summary: String {
        let rate = total > 0 ? Int((Double(passed) / Double(total) * 100).rounded()) : 0
        let speed = p50Milliseconds.map { p50 in
            String(format: ", p50 %.2f ms, p95 %.2f ms", p50, p95Milliseconds ?? p50)
        }
        return "\(passed)/\(total) (\(rate)%)\(speed ?? "")"
    }
}

/// The embedded measurements and how eval runs record new ones.
public enum Measurements {
    /// Every measurement shipped in this build, from `Resources/measurements.json`.
    public static let embedded: [Measurement] = decode(MeasurementsText.text) ?? []

    /// The environment variable naming the file eval runs record into.
    public static let recordVariable = "WISP_EVAL_RECORD"

    /// Decodes a JSON array of measurements.
    public static func decode(_ text: String) -> [Measurement]? {
        try? JSONDecoder().decode([Measurement].self, from: Data(text.utf8))
    }

    /// The measurements as pretty JSON, sorted by task, then model, then input size.
    public static func encode(_ measurements: [Measurement]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sorted = measurements.sorted {
            ($0.task, $0.model, $0.maxInputBytes ?? 0) < ($1.task, $1.model, $1.maxInputBytes ?? 0)
        }
        guard let data = try? encoder.encode(sorted) else { return "[]" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// `existing` with `new` replacing any measurement of the same task, model, and input size.
    public static func merge(_ existing: [Measurement], with new: Measurement) -> [Measurement] {
        existing.filter { $0.task != new.task || $0.model != new.model || $0.maxInputBytes != new.maxInputBytes }
            + [new]
    }

    /// Why a measurement was not recorded.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The record file exists but is not a JSON array of measurements; it is left as it is.
        case undecodable(String)

        /// What went wrong, for a person.
        public var description: String {
            switch self {
            case .undecodable(let path):
                "\(path) is not a JSON array of measurements; left untouched, fix or remove it and rerun"
            }
        }
    }

    /// Serialises the read-merge-write of a record file within this process: the eval suites run in parallel,
    /// and two reports interleaving would each write the file without the other's measurement.
    private static let recordLock = Mutex(())

    /// Prints the measurement and, when `WISP_EVAL_RECORD` (or `path`) names a file, merges it into
    /// that file. Eval tests call this so a run leaves its numbers behind.
    ///
    /// The merge holds a lock for the process and an advisory `flock` on the file's directory for other
    /// processes, and replaces the file atomically, so concurrent reports all land and a reader never sees half a
    /// file. A file that exists but does not decode is refused, not overwritten: a measurement must never cost
    /// the ones already recorded.
    ///
    /// - Parameters:
    ///   - measurement: What was measured.
    ///   - path: The record file; defaults to the environment variable, nil records nothing.
    /// - Throws: `Failure.undecodable` for a record file that does not decode, or a file error.
    public static func report(
        _ measurement: Measurement, to path: String? = ProcessInfo.processInfo.environment[recordVariable]
    ) throws {
        print("measured: \(measurement.task) on \(measurement.model): \(measurement.summary)")
        guard let path, !path.isEmpty else { return }
        do {
            try record(measurement, at: URL(fileURLWithPath: path))
        } catch {
            print("measured: \(measurement.task) on \(measurement.model): not recorded: \(error)")
            throw error
        }
    }

    /// Merges `measurement` into the record file at `url`, under both locks.
    ///
    /// - Parameters:
    ///   - measurement: What was measured.
    ///   - url: The record file; created when missing.
    /// - Throws: `Failure.undecodable`, or a file error.
    static func record(_ measurement: Measurement, at url: URL) throws {
        try recordLock.withLock { _ in
            try withDirectoryLock(url.deletingLastPathComponent()) {
                let existing: [Measurement]
                if FileManager.default.fileExists(atPath: url.path) {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    if text.allSatisfy(\.isWhitespace) {
                        existing = []
                    } else if let decoded = decode(text) {
                        existing = decoded
                    } else {
                        throw Failure.undecodable(url.path)
                    }
                } else {
                    existing = []
                }
                try Data(encode(merge(existing, with: measurement)).utf8).write(to: url, options: .atomic)
            }
        }
    }

    /// Runs `body` holding an exclusive advisory lock (`flock`) on `directory`, so eval processes recording into
    /// the same file take turns. The directory is locked rather than the file because an atomic write replaces
    /// the file, and a lock on the old one would no longer exclude anyone. When the directory cannot be opened
    /// the body runs anyway, and its own write reports the problem.
    ///
    /// - Parameters:
    ///   - directory: The record file's directory.
    ///   - body: The read-merge-write.
    /// - Throws: Whatever `body` throws.
    private static func withDirectoryLock(_ directory: URL, _ body: () throws -> Void) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        _ = flock(descriptor, LOCK_EX)
        defer { _ = flock(descriptor, LOCK_UN) }
        try body()
    }

    /// The measurements for one tool, by name.
    public static func forTool(_ name: String, in measurements: [Measurement] = embedded) -> [Measurement] {
        measurements.filter { $0.tool == name }
    }
}
