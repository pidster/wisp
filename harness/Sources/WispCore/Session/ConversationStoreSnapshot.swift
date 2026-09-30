import Foundation
import FoundationModels

extension ConversationStore {
    /// The store as saved beside a transcript (`TranscriptStore.save(_:as:)`): every entry's kind, origin,
    /// turn, state, audit references, cuts, time, and the turns it was dropped or referenced from, in store
    /// order, so a resumed conversation keeps its entries connected to the events that recorded them and
    /// composes its tool outputs as the saving session last did.
    ///
    /// An active entry's content is the saved transcript's entry with the same framework id, so the
    /// snapshot repeats none of it. A dropped entry is not in the transcript, so the snapshot holds it, as
    /// a one-entry transcript (the framework's `Transcript.Entry` is not itself `Codable`).
    public struct Snapshot: Codable, Sendable, Equatable {
        /// The format this build reads and writes.
        static let currentVersion = 1

        /// One entry's link data.
        public struct Record: Codable, Sendable, Equatable {
            /// The entry's position in the store.
            public var id: Int
            /// The framework's entry id: how an active entry is found in the transcript.
            public var entryID: String
            /// What it is.
            public var kind: Kind
            /// Where it came from.
            public var origin: Origin
            /// The turn that produced it, in the session that recorded it.
            public var turn: Int?
            /// Whether requests carry it.
            public var active: Bool
            /// The `context.condensation` event that dropped it, when audited.
            public var droppedBy: AuditReference?
            /// The audit events that recorded it.
            public var sources: [AuditReference]
            /// A dropped entry itself, as a one-entry transcript; nil for an active one.
            public var dropped: Transcript?
            /// The reply's cut presentational text; nil when it has none, so a snapshot without cuts reads
            /// and writes as before.
            public var cuts: [Cut]? = nil
            /// When it was recorded; nil when unknown.
            public var time: Date? = nil
            /// The saving session's turn during which a condensation dropped it; nil when active or unknown.
            public var droppedAt: Int? = nil
            /// The saving session's turn from which a tool output was sent as a reference; nil when it was
            /// still sent whole.
            public var referencedAt: Int? = nil
        }

        /// The format version, so a future build can tell a snapshot it cannot read.
        public var version: Int
        /// Every entry, in store order.
        public var entries: [Record]
        /// The conversation's facts; nil in a snapshot saved before facts, or without any.
        public var facts: FactBook? = nil

        /// The sessions whose audit events the entries refer to (their `sources`, and the condensations
        /// that dropped them), sorted and distinct: where to look for what a resumed conversation carries.
        public var sessions: [String] {
            var found: Set<String> = []
            for record in entries {
                for reference in record.sources + (record.droppedBy.map { [$0] } ?? []) where !reference.session.isEmpty
                {
                    found.insert(reference.session)
                }
            }
            return found.sorted()
        }

        /// The store rebuilt over `transcript`, or nil when this snapshot is not the store of that
        /// transcript: another version, entry positions out of order, active entries that are not the
        /// transcript's entries in order (by id and kind), or a dropped entry that does not decode to
        /// itself. A restored entry's origin is `resumed` where it was a turn's, since that turn belongs to
        /// the session that saved it. Its `droppedAt` and `referencedAt` become 0 where they were set: both
        /// happened before the resuming session's first turn, whose numbers start again.
        ///
        /// - Parameter transcript: The saved transcript, or the session's view of it.
        /// - Returns: The rebuilt store, or nil when the snapshot does not match.
        func restored(over transcript: Transcript) -> ConversationStore? {
            guard version == Self.currentVersion else { return nil }
            let live = Array(transcript)
            var next = 0
            var seen: Set<String> = []
            var rebuilt: [ConversationStore.Entry] = []
            for (index, record) in entries.enumerated() {
                guard record.id == index + 1, seen.insert(record.entryID).inserted else { return nil }
                let value: Transcript.Entry
                if record.active {
                    guard next < live.count, live[next].id == record.entryID else { return nil }
                    value = live[next]
                    next += 1
                } else {
                    guard let held = record.dropped, held.count == 1, let entry = held.first,
                        entry.id == record.entryID
                    else { return nil }
                    value = entry
                }
                guard Kind(value) == record.kind else { return nil }
                rebuilt.append(
                    ConversationStore.Entry(
                        id: record.id, kind: record.kind, origin: record.origin == .turn ? .resumed : record.origin,
                        turn: record.turn, sources: record.sources,
                        state: record.active ? .active : .dropped(by: record.droppedBy), value: value,
                        cuts: record.cuts ?? [], time: record.time,
                        droppedAt: record.active ? nil : 0, referencedAt: record.referencedAt.map { _ in 0 }))
            }
            guard next == live.count else { return nil }
            var store = ConversationStore(entries: rebuilt)
            if let facts, facts.scope == .conversation { store.facts = facts }
            return store
        }
    }

    /// The store's link data, for saving beside its active transcript.
    public var snapshot: Snapshot {
        Snapshot(
            version: Snapshot.currentVersion,
            entries: entries.map { entry in
                let active = entry.state == .active
                var droppedBy: AuditReference?
                if case .dropped(let by) = entry.state { droppedBy = by }
                return Snapshot.Record(
                    id: entry.id, entryID: entry.value.id, kind: entry.kind, origin: entry.origin, turn: entry.turn,
                    active: active, droppedBy: droppedBy, sources: entry.sources,
                    dropped: active ? nil : Transcript(entries: [entry.value]),
                    cuts: entry.cuts.isEmpty ? nil : entry.cuts, time: entry.time, droppedAt: entry.droppedAt,
                    referencedAt: entry.referencedAt)
            }, facts: facts.facts.isEmpty ? nil : facts)
    }
}
