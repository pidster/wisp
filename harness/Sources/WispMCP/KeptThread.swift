import Foundation
import FoundationModels
import Synchronization
import WispCore

/// What the server opens a `respond` thread with, handed to its `ThreadFactory`: the start settings, the audit session
/// of this opening, and, when the thread is resumed from the store, what was saved (ADR 0066).
public struct ThreadStart: Sendable {
    /// The `thread_id`.
    public var id: String
    /// The caller's instructions (layer 3); nil takes the session's.
    public var instructions: String?
    /// The tools; `.all` takes the session's.
    public var tools: ToolSelection
    /// The model; nil takes the session's.
    public var model: ModelSelection?
    /// The thinking its turns ask of the model; nil for the model's default.
    public var think: OllamaThink?
    /// Its own limit for `run_command`, in seconds; nil for the operator's default (ADR 0063).
    public var commandTimeout: Int?
    /// The audit session its events carry: `<thread_id>-<suffix>`, one per opening.
    public var auditSession: String
    /// The saved thread this opening resumes; nil for a new thread.
    public var resumed: ThreadStore.Saved?

    /// Creates a start.
    ///
    /// - Parameters:
    ///   - id: The `thread_id`.
    ///   - instructions: The caller's instructions.
    ///   - tools: The tools.
    ///   - model: The model.
    ///   - think: The thinking.
    ///   - commandTimeout: The command limit.
    ///   - auditSession: The audit session; a fresh one for `id` when nil.
    ///   - resumed: What is resumed.
    public init(
        id: String, instructions: String? = nil, tools: ToolSelection = .all, model: ModelSelection? = nil,
        think: OllamaThink? = nil, commandTimeout: Int? = nil, auditSession: String? = nil,
        resumed: ThreadStore.Saved? = nil
    ) {
        self.id = id
        self.instructions = instructions
        self.tools = tools
        self.model = model
        self.think = think
        self.commandTimeout = commandTimeout
        self.auditSession = auditSession ?? ThreadDirectory.auditSession(for: id)
        self.resumed = resumed
    }

    /// The start of a saved thread: its own settings, and what was saved.
    ///
    /// - Parameter saved: The saved thread.
    /// - Throws: `ModelSelection.Failure` when the saved model no longer parses.
    init(resuming saved: ThreadStore.Saved) throws {
        let settings = saved.settings
        self.init(
            id: settings.id, instructions: settings.instructions,
            tools: settings.tools.isEmpty ? .none : .named(settings.tools),
            model: try ModelSelection(parsing: settings.model), think: settings.think.flatMap(OllamaThink.init),
            commandTimeout: settings.commandTimeoutSeconds, resumed: saved)
    }

    /// Opens the thread on `session` as the server's own factory does: the conversation `Session.thread` sets up, its
    /// `session.start` naming what it resumes and the sessions it had before, and an agent over the saved record when
    /// there is one. Tests that need no model build their own agent over the returned thread instead.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - host: The face's effects.
    /// - Returns: The conversation, ready to open.
    /// - Throws: `Session.Failure.unknownTools`.
    public func thread(on session: Session, host: SessionHost) throws -> WispThread {
        try session.thread(
            id: id, host: host, instructions: instructions, tools: tools, model: model, think: think,
            auditSession: auditSession, commandTimeout: commandTimeout, resume: resumed.map { _ in id },
            carriedFrom: resumed?.settings.sessions ?? [])
    }
}

/// A `respond` thread's place in the thread store while this server holds it (ADR 0066): its lock, so no other
/// process opens it, and its `thread.json` as this opening keeps it. The server saves through it after every turn,
/// inside the thread's `TurnQueue`, and when the thread is evicted or its client goes; `close_thread` deletes it.
///
/// A `final class` with a `Mutex`: every operation is a short synchronous critical section.
public final class KeptThread: Sendable {
    /// The store.
    let store: ThreadStore
    /// The thread's lock, held for as long as the server holds the thread.
    let lock: ThreadLock
    /// `thread.json` as this opening keeps it.
    private let current: Mutex<ThreadStore.Settings>
    /// Turns the thread had before this opening.
    let earlierTurns: Int
    /// When a resumed thread was last saved before this opening; nil for a new thread.
    let savedAt: Date?

    /// Holds a thread opened or resumed now.
    ///
    /// - Parameters:
    ///   - store: The store.
    ///   - lock: Its lock, taken.
    ///   - settings: Its `thread.json`, with this opening's session in it.
    ///   - savedAt: When a resumed thread was last saved; nil for a new one.
    init(store: ThreadStore, lock: ThreadLock, settings: ThreadStore.Settings, savedAt: Date?) {
        self.store = store
        self.lock = lock
        current = Mutex(settings)
        earlierTurns = settings.turns
        self.savedAt = savedAt
    }

    /// Whether this opening resumed a saved thread.
    var resumed: Bool { savedAt != nil }

    /// The thread's id.
    var id: String { settings.id }

    /// `thread.json` as it stands.
    var settings: ThreadStore.Settings { current.withLock { $0 } }

    /// Turns over every opening, after `turns` in this one.
    ///
    /// - Parameter turns: This opening's turns.
    /// - Returns: The total.
    func total(_ turns: Int) -> Int { earlierTurns + turns }

    /// Saves the thread: its record when the thread can give one, and `thread.json` with the turns, the time, the
    /// dropped facts, and `state`. A thread that gives no record (one a test builds without an agent) writes nothing,
    /// so it is never resumable. A failure to write is logged, never thrown: a turn is not failed for it.
    ///
    /// - Parameters:
    ///   - record: The thread's store, or nil.
    ///   - turns: This opening's turns.
    ///   - dropped: The facts the person dropped for it.
    ///   - state: `open` while the server holds it, `saved` when it lets it go.
    ///   - now: The time.
    func save(
        record: ThreadRecord?, turns: Int, dropped: [ThreadStore.DroppedFact], state: ThreadStore.State,
        now: Date = Date()
    ) {
        guard let record else { return }
        let settings = current.withLock { settings in
            settings.turns = earlierTurns + turns
            settings.lastUsed = now
            settings.droppedFacts = dropped
            settings.state = state
            return settings
        }
        do {
            try store.save(settings, record: record)
        } catch {
            Diagnostics.mcp.error("could not save thread \(settings.id): \(error)")
        }
    }

    /// Lets the thread go: releases its lock, so another process may resume it.
    func release() { lock.release() }

    /// Deletes the thread from the store and releases its lock: `close_thread`.
    ///
    /// - Throws: The file system's error; the lock is released either way.
    func delete() throws {
        defer { lock.release() }
        try store.delete(id)
    }
}

/// Why the server refused to open a thread with the settings a call gave (ADR 0066, D5).
enum ThreadRefusal: Error, CustomStringConvertible, Equatable {
    /// The call's start settings differ from the thread's: its id, its settings described, the names that differ,
    /// and whether the thread is live in this server or saved.
    case settings(String, String, differing: [String], live: Bool)

    /// Human-readable explanation.
    var description: String {
        switch self {
        case .settings(let id, let described, let differing, let live):
            "\(id) \(live ? "is open" : "was saved") with \(described); these settings differ: "
                + "\(differing.joined(separator: ", ")). Leave them out to continue it, or choose another thread_id"
        }
    }
}
