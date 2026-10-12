import Foundation

/// The sweep of the output store by age ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md),
/// 2026-10-12): a session's stored outputs, `output/<audit session>/` under wisp's home, are removed `days` after the
/// session's last use, at the start of a later session (`Session.begin`).
///
/// A session's **last use** is the newest modification time among its directory and the files in it. Every output
/// kept creates files in the directory (the output, its record, a spill), which moves the directory's own time; a
/// file still being written moves its own. Reading a stored output changes neither, so a session read but not
/// written for `days` is swept: its conversation ended or sat idle that long.
///
/// The sweep is bounded so that start-up never waits on a large store: one listing of `output/`, then at most
/// `removalLimit` sessions removed, oldest first, and no session examined once `deadline` has passed; what is left
/// waits for the next start. It touches only what wisp writes: a directory with a safe name (`SafeName`) holding only
/// regular files with safe names. Anything else under `output/` (a file, a link, a directory with a subdirectory or
/// an unexpected name in it) is left alone, and so is the current session. `days` 0 never sweeps.
struct OutputSweep: Sendable {
    /// Sessions removed at most per start.
    static let removalLimit = 16
    /// How long one start's sweep may examine sessions.
    static let deadline: Duration = .milliseconds(100)

    /// One session's directory in the store.
    struct Stored: Equatable, Sendable {
        /// The audit session it belongs to: the directory's name.
        var name: String
        /// The directory.
        var url: URL
        /// The newest modification time of the directory and its files.
        var lastUse: Date
        /// Bytes its files take.
        var bytes: Int
    }

    /// What the sweep did, for `session.start`'s `outputSweep`.
    struct Outcome: Equatable, Sendable {
        /// The sessions removed, oldest first.
        var removed: [String] = []
        /// Bytes their files took.
        var bytes = 0
        /// Sessions old enough to remove that the bound left for the next start.
        var deferred = 0

        /// Whether there is anything to record: a removal, or sessions left for later.
        var isEmpty: Bool { removed.isEmpty && deferred == 0 }

        /// The audit details.
        var details: JSONValue {
            .object([
                "removed": .array(removed.map { .string($0) }), "bytes": .int(bytes), "deferred": .int(deferred),
            ])
        }
    }

    /// The whole store as `doctor` reports it.
    struct Survey: Equatable, Sendable {
        /// wisp's sessions in it, oldest first.
        var sessions: [Stored] = []
        /// Entries under `output/` that are not wisp's, by name, left alone.
        var foreign: [String] = []
    }

    /// The store's root, `output/` under wisp's home.
    let root: URL
    /// Days after its last use a session is removed; 0 never.
    let days: Int
    /// The time ages are measured from.
    let now: Date

    /// A sweep of `home`'s store.
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - days: `context.outputDays`.
    ///   - now: The time ages are measured from.
    init(home: Home, days: Int, now: Date = Date()) {
        root = home.outputs
        self.days = days
        self.now = now
    }

    /// Sessions last used before this are removed; nil when nothing is.
    var cutoff: Date? { days > 0 ? now.addingTimeInterval(-Double(days) * 86_400) : nil }

    /// Removes the sessions last used more than `days` ago, other than `current`, within the bound.
    ///
    /// - Parameters:
    ///   - current: The session starting now, never removed.
    ///   - limit: The most sessions removed.
    ///   - deadline: How long sessions may be examined.
    /// - Returns: What was removed and what was left for later.
    func run(
        current: String, limit: Int = OutputSweep.removalLimit, deadline: Duration = OutputSweep.deadline
    ) -> Outcome {
        guard let cutoff else { return Outcome() }
        let clock = ContinuousClock()
        let start = clock.now
        var outcome = Outcome()
        // The directory's own time is in the listing; a session written to since the cutoff is not examined further.
        let candidates = topLevel().filter { $0.name != current && $0.time < cutoff }.sorted { $0.time < $1.time }
        for (index, candidate) in candidates.enumerated() {
            guard outcome.removed.count < limit, clock.now - start < deadline else {
                outcome.deferred = candidates.count - index
                break
            }
            guard let stored = examine(candidate.name), stored.lastUse < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: stored.url)
                outcome.removed.append(stored.name)
                outcome.bytes += stored.bytes
            } catch {
                Diagnostics.tools.error("output store sweep could not remove \(stored.url.path): \(error)")
            }
        }
        return outcome
    }

    /// Every session in the store, and what is not wisp's; unbounded, for `doctor`.
    ///
    /// - Returns: The survey.
    func survey() -> Survey {
        var survey = Survey()
        for entry in topLevel(includingForeign: true) {
            if let stored = entry.isDirectory ? examine(entry.name) : nil {
                survey.sessions.append(stored)
            } else {
                survey.foreign.append(entry.name)
            }
        }
        survey.sessions.sort { $0.lastUse < $1.lastUse }
        survey.foreign.sort()
        return survey
    }

    /// The sessions a sweep now would remove, oldest first, ignoring the bound.
    ///
    /// - Parameter survey: The store.
    /// - Returns: The sessions last used before the cutoff.
    func due(in survey: Survey) -> [Stored] {
        guard let cutoff else { return [] }
        return survey.sessions.filter { $0.lastUse < cutoff }
    }

    /// One entry of `output/`.
    private struct Entry {
        /// Its name.
        var name: String
        /// Its modification time.
        var time: Date
        /// Whether it is a directory (not a link to one).
        var isDirectory: Bool
    }

    /// The entries of `output/` in one listing: the directories with safe names, or with `includingForeign` every
    /// entry.
    private func topLevel(includingForeign: Bool = false) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            let name = url.lastPathComponent
            guard includingForeign || (isDirectory && SafeName.isValid(name)) else { return nil }
            return Entry(name: name, time: values?.contentModificationDate ?? .distantPast, isDirectory: isDirectory)
        }
    }

    /// Session `name`'s directory, when it is wisp's: a safe name, holding only regular files with safe names.
    ///
    /// - Parameter name: The directory's name.
    /// - Returns: The session, or nil when the directory is not wisp's or cannot be read.
    private func examine(_ name: String) -> Stored? {
        guard SafeName.isValid(name) else { return nil }
        let url = root.appending(path: name, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let own = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        else { return nil }
        var lastUse = own
        var bytes = 0
        for file in files {
            guard SafeName.isValid(file.lastPathComponent), let values = try? file.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { return nil }
            if let time = values.contentModificationDate, time > lastUse { lastUse = time }
            bytes += values.fileSize ?? 0
        }
        return Stored(name: name, url: url, lastUse: lastUse, bytes: bytes)
    }
}
