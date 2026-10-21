import Foundation

/// The retention sweep of the thread store ([ADR 0066](../../../../docs/decisions/0066-one-thread-store.md), D4 and
/// D10): a saved thread unused for `threads.keepDays` is deleted at the start of a later session (`Session.begin`),
/// with the stored outputs of every audit session it has had, since its outputs are kept while it is and go with it.
///
/// A thread's last use is its `thread.json`'s `lastUsed`; a directory without one (a thread opened and never saved)
/// is aged by its own modification time. A thread another process holds is never swept, however old. The sweep is
/// bounded as the output store's is: at most `removalLimit` threads a start, oldest first, and none examined once
/// `deadline` has passed; what is left waits for the next start. Reading every `thread.json` is not bounded, since the
/// output sweep that follows needs the sessions of every thread kept. `days` 0 never sweeps.
struct ThreadSweep: Sendable {
    /// Threads deleted at most per start.
    static let removalLimit = 16
    /// How long one start's sweep may spend deleting.
    static let deadline: Duration = .milliseconds(100)

    /// One thread the sweep deleted.
    struct Swept: Equatable, Sendable {
        /// Its id.
        var id: String
        /// Its owner; nil when it had no settings.
        var owner: String?
        /// When it was last used.
        var lastUsed: Date
        /// Turns it had.
        var turns: Int
        /// The audit sessions it had, whose stored outputs went with it.
        var sessions: [String]
        /// Bytes its stored outputs took.
        var outputBytes: Int

        /// The audit details of `thread.swept`.
        var details: [String: JSONValue] {
            [
                "thread": .string(id), "owner": owner.map { .string($0) } ?? .null,
                "lastUsed": .string(lastUsed.ISO8601Format()), "turns": .int(turns),
                "sessions": .array(sessions.map { .string($0) }), "outputBytes": .int(outputBytes),
            ]
        }
    }

    /// What the sweep did.
    struct Outcome: Equatable, Sendable {
        /// The threads deleted, oldest first.
        var swept: [Swept] = []
        /// Threads old enough to delete that the bound left for a later start.
        var deferred = 0
        /// The audit sessions of every thread still kept, whose stored outputs the output sweep leaves alone.
        var kept: Set<String> = []
    }

    /// The store.
    let store: ThreadStore
    /// The output store's root, `output/` under wisp's home.
    let outputs: URL
    /// Days after its last use a thread is deleted; 0 never.
    let days: Int
    /// The time ages are measured from.
    let now: Date

    /// A sweep of `home`'s thread store.
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - days: `threads.keepDays`.
    ///   - now: The time ages are measured from.
    init(home: Home, days: Int, now: Date = Date()) {
        store = ThreadStore(home: home)
        outputs = home.outputs
        self.days = days
        self.now = now
    }

    /// Threads last used before this are deleted; nil when none is.
    var cutoff: Date? { days > 0 ? now.addingTimeInterval(-Double(days) * 86_400) : nil }

    /// One thread directory as the sweep sees it.
    private struct Candidate {
        /// Its id.
        var id: String
        /// Its settings, when it has some that read.
        var settings: ThreadStore.Settings?
        /// When it was last used.
        var lastUsed: Date
    }

    /// Deletes the threads last used more than `days` ago that no process holds, within the bound, and reports the
    /// sessions of those kept.
    ///
    /// - Parameters:
    ///   - limit: The most threads deleted.
    ///   - deadline: How long deleting may take.
    /// - Returns: What was deleted, what was left for later, and the sessions kept.
    func run(limit: Int = ThreadSweep.removalLimit, deadline: Duration = ThreadSweep.deadline) -> Outcome {
        var outcome = Outcome()
        var due: [Candidate] = []
        for id in store.ids {
            let settings: ThreadStore.Settings?
            do {
                settings = try store.settings(id)
            } catch {
                // A thread.json this build cannot read is another wisp's to judge: left alone, its sessions unknown.
                continue
            }
            let lastUsed = settings?.lastUsed ?? modified(store.directory(of: id))
            let candidate = Candidate(id: id, settings: settings, lastUsed: lastUsed)
            if let cutoff, lastUsed < cutoff {
                due.append(candidate)
            } else {
                outcome.kept.formUnion(settings?.sessions ?? [])
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let ordered = due.sorted(by: { $0.lastUsed < $1.lastUsed })
        for (index, candidate) in ordered.enumerated() {
            guard outcome.swept.count < limit, clock.now - start < deadline else {
                outcome.deferred = due.count - index
                for kept in due.sorted(by: { $0.lastUsed < $1.lastUsed }).dropFirst(index) {
                    outcome.kept.formUnion(kept.settings?.sessions ?? [])
                }
                break
            }
            // A session another thread still names keeps its outputs: a chat's `/new` carries its session into the
            // next thread, which may be kept, or due later in this sweep and left by the bound.
            let named = outcome.kept.union(ordered.dropFirst(index + 1).flatMap { $0.settings?.sessions ?? [] })
            if let swept = sweep(candidate, sparing: named) {
                outcome.swept.append(swept)
            } else {
                outcome.kept.formUnion(candidate.settings?.sessions ?? [])
            }
        }
        return outcome
    }

    /// Deletes one thread and the outputs of its sessions not in `sparing`, holding its lock meanwhile; nil when
    /// another process holds it or it could not be deleted.
    ///
    /// - Parameters:
    ///   - candidate: The thread.
    ///   - sparing: Sessions another thread names, whose outputs stay.
    /// - Returns: What was deleted, or nil.
    private func sweep(_ candidate: Candidate, sparing: Set<String>) -> Swept? {
        guard let lock = try? store.lock(candidate.id, owner: "sweep") else { return nil }
        defer { lock.release() }
        let sessions = candidate.settings?.sessions ?? []
        var bytes = 0
        for session in sessions where SafeName.isValid(session) && !sparing.contains(session) {
            let directory = outputs.appending(path: session, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            bytes += size(of: directory)
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Diagnostics.tools.error("thread sweep could not remove \(directory.path): \(error)")
            }
        }
        do {
            try store.delete(candidate.id)
        } catch {
            Diagnostics.tools.error("thread sweep could not remove thread \(candidate.id): \(error)")
            return nil
        }
        return Swept(
            id: candidate.id, owner: candidate.settings?.owner, lastUsed: candidate.lastUsed,
            turns: candidate.settings?.turns ?? 0, sessions: sessions, outputBytes: bytes)
    }

    /// The modification time of `url`, or the distant past when it cannot be read.
    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The bytes the regular files directly in `directory` take.
    private func size(of directory: URL) -> Int {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
