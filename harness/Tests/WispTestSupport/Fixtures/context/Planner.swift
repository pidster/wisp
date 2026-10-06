import Foundation

/// Compares the scanned source entries with the destination manifest and decides,
/// path by path, what the apply phase must do. It returns a value and writes nothing.
struct Planner {
    /// Source entries from the scanner, in scan order.
    let entries: [Entry]
    /// What the last successful sync wrote to the destination.
    let manifest: Manifest
    /// The destination root, for conflict checks against the live tree.
    let destination: String
    /// Whether destination paths that vanished from the source may be removed.
    let allowDelete: Bool

    /// Builds the plan, sorted by path so the same inputs always give the same plan.
    func makePlan() -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for entry in entries {
            seen.insert(entry.path)
            let recorded = manifest.record(for: entry.path)
            if let recorded {
                if hasChanged(entry, since: recorded) {
                    if destinationEdited(entry.path, since: recorded) {
                        plan.conflicts.append(Conflict(path: entry.path, reason: .editedAtDestination))
                    } else {
                        plan.changes.append(Change(action: .update, path: entry.path, bytes: entry.size))
                    }
                } else {
                    plan.skipped += 1
                }
            } else {
                plan.changes.append(Change(action: .copy, path: entry.path, bytes: entry.size))
            }
        }
        for recorded in manifest.records where !seen.contains(recorded.path) {
            if allowDelete {
                plan.changes.append(Change(action: .delete, path: recorded.path, bytes: 0))
            } else {
                plan.kept.append(recorded.path)
            }
        }
        plan.changes.sort { $0.path < $1.path }
        plan.conflicts.sort { $0.path < $1.path }
        return plan
    }

    /// Size and modification time decide, or the SHA-256 digest when the scan has one.
    func hasChanged(_ entry: Entry, since recorded: Manifest.Record) -> Bool {
        if let digest = entry.digest, let previous = recorded.digest {
            return digest != previous
        }
        return entry.size != recorded.size || entry.modified != recorded.modified
    }

    /// A destination file whose modification time differs from the manifest's was
    /// changed by someone else since the last sync.
    func destinationEdited(_ path: String, since recorded: Manifest.Record) -> Bool {
        let url = URL(fileURLWithPath: destination).appending(path: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        return modified.map { $0 != recorded.modified } ?? false
    }
}

/// What the apply phase will do, and what it will leave alone.
struct Plan {
    /// Copies, updates, and deletions, sorted by path.
    var changes: [Change] = []
    /// Paths changed on both sides; never overwritten.
    var conflicts: [Conflict] = []
    /// Paths gone from the source but kept, because deletion was not allowed.
    var kept: [String] = []
    /// Paths already identical on both sides.
    var skipped = 0

    /// Bytes the apply phase expects to write.
    var bytesToWrite: Int { changes.reduce(0) { $0 + $1.bytes } }
}

/// One planned change.
struct Change: Equatable {
    enum Action: String { case copy, update, delete }
    var action: Action
    var path: String
    var bytes: Int
}

/// A path the planner refuses to touch.
struct Conflict: Equatable {
    enum Reason: String { case editedAtDestination = "edited at destination" }
    var path: String
    var reason: Reason
}
