import Foundation

/// The `harbour sync` command: scan the source, plan the changes against the
/// destination manifest, then apply the plan. It holds only parsed option values.
struct SyncCommand {
    /// Directory to read from.
    var source: String
    /// Directory to make match the source.
    var destination: String
    /// Remove destination paths that vanished from the source.
    var delete: Bool = false
    /// Globs of source paths to skip.
    var excludes: [String] = []
    /// Compare SHA-256 digests instead of size and mtime.
    var checksum: Bool = false
    /// Concurrent copies, 1 to 64.
    var jobs: Int = SyncCommand.defaultJobs
    /// Bytes per second across all workers, or nil for unlimited.
    var bandwidth: Int? = nil
    var verbose: Bool = false
    var quiet: Bool = false
    /// Manifest location, or nil for the destination default.
    var manifestPath: String? = nil
    /// Default worker count: the active processor count, capped at 8.
    static var defaultJobs: Int { min(ProcessInfo.processInfo.activeProcessorCount, 8) }
    /// Exit statuses documented in the design overview.
    enum Status: Int32 { case ok = 0, usage = 1, conflicts = 2, failures = 3 }
    /// Checks option combinations that the parser cannot reject on its own.
    func validate() throws {
        if verbose && quiet {
            throw UsageError("--verbose and --quiet cannot be combined")
        }
        if jobs < 1 || jobs > 64 {
            throw UsageError("--jobs must be between 1 and 64")
        }
        if let rate = bandwidth, rate <= 0 {
            throw UsageError("--bandwidth must be positive")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            throw UsageError("source is not a directory: \(source)")
        }
    }
    /// Runs the three phases and returns the process exit status.
    func run() throws -> Int32 {
        try validate()
        let scanner = Scanner(root: source, excludes: excludes, computeDigests: checksum)
        let entries = try scanner.scan()
        let manifestURL = URL(fileURLWithPath: manifestPath ?? destination + "/.harbour/manifest.json")
        let manifest = try Manifest.load(from: manifestURL)
        let planner = Planner(entries: entries, manifest: manifest, destination: destination, allowDelete: delete)
        let plan = planner.makePlan()
        let applier = Applier(jobs: jobs, bandwidth: bandwidth, verbose: verbose && !quiet)
        let result = try applier.apply(plan, updating: manifestURL)
        for conflict in plan.conflicts {
            FileHandle.standardError.write(Data("conflict: \(conflict.path)\n".utf8))
        }
        for failure in result.failures {
            FileHandle.standardError.write(Data("failed: \(failure.path): \(failure.reason)\n".utf8))
        }
        if !quiet {
            print(
                "copied \(result.copied), updated \(result.updated), deleted \(result.deleted), "
                    + "skipped \(plan.skipped), conflicts \(plan.conflicts.count)")
        }
        if !result.failures.isEmpty {
            return Status.failures.rawValue
        } else if !plan.conflicts.isEmpty {
            return Status.conflicts.rawValue
        } else {
            return Status.ok.rawValue
        }
    }
}

/// An invalid command line; reported with exit status 1.
struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
