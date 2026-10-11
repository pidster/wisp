import Foundation
import Synchronization

/// Notes wisp adds to a conversation between turns (ADR 0059): a background pull the model asked for has ended. Each is
/// kept for its conversation, by audit session (chat's own, an MCP `thread_id`), until the conversation's agent takes it
/// as its next turn begins and stores it as a notice (`ThreadRecord.Kind.notice`), so the model reads it with that
/// turn's request; a face that watches the conversation (chat) is told at once as well.
public final class ConversationNotices: Sendable {
    /// The notes waiting, and who is told, by conversation.
    private let state = Mutex<(waiting: [String: [String]], watchers: [String: @Sendable (String) -> Void])>(([:], [:]))

    /// The most notes kept for one conversation; an older one is dropped past it.
    static let limit = 16

    /// Creates an empty set.
    public init() {}

    /// Adds a note for `conversation` and tells its watcher.
    ///
    /// - Parameters:
    ///   - note: The text.
    ///   - conversation: The audit session of the conversation it is for.
    public func post(_ note: String, to conversation: String) {
        let watcher = state.withLock { state in
            state.waiting[conversation, default: []].append(note)
            if let count = state.waiting[conversation]?.count, count > Self.limit {
                state.waiting[conversation]?.removeFirst(count - Self.limit)
            }
            return state.watchers[conversation]
        }
        watcher?(note)
    }

    /// The notes waiting for `conversation`, oldest first, taken.
    ///
    /// - Parameter conversation: Its audit session.
    /// - Returns: The notes.
    public func take(for conversation: String) -> [String] {
        state.withLock { $0.waiting.removeValue(forKey: conversation) ?? [] }
    }

    /// Tells `watcher` of every note posted for `conversation` from now on, replacing an earlier watcher.
    ///
    /// - Parameters:
    ///   - conversation: Its audit session.
    ///   - watcher: Told each note.
    public func watch(_ conversation: String, _ watcher: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.watchers[conversation] = watcher }
    }
}

/// The pulls running in the background (ADR 0059): one the model asked for, once the person approved it, runs here
/// while the conversation goes on; at most one per repository. Each is a task that ends by itself, or when cancelled
/// (`/models cancel`, the session ending), keeping the part of the file it was fetching.
public final class ModelPulls: Sendable {
    /// One pull.
    public struct Running: Sendable {
        /// The repository.
        public var repository: String
        /// The conversation that asked for it, by audit session.
        public var conversation: String
        /// How far it has gone, once it has started fetching.
        public var progress: PullProgress?
        /// Its task.
        let task: Task<Void, Never>
    }

    /// The pulls running, by repository.
    private let running = Mutex<[String: Running]>([:])

    /// Creates an empty set.
    public init() {}

    /// The pulls running, by repository.
    public var all: [Running] { running.withLock { $0.values.sorted { $0.repository < $1.repository } } }

    /// Whether `repository` is being pulled.
    ///
    /// - Parameter repository: The repository.
    /// - Returns: Whether it is.
    public func isRunning(_ repository: String) -> Bool { running.withLock { $0[repository] != nil } }

    /// Starts `work` for `repository`, unless a pull of it is running already. `work` is told how to report its
    /// progress; the entry goes when `work` ends.
    ///
    /// - Parameters:
    ///   - repository: The repository.
    ///   - conversation: The conversation that asked for it.
    ///   - work: The pull.
    /// - Returns: Whether it started.
    @discardableResult
    public func start(
        _ repository: String, for conversation: String,
        work: @escaping @Sendable (_ progress: @escaping @Sendable (PullProgress) -> Void) async -> Void
    ) -> Bool {
        running.withLock { running in
            guard running[repository] == nil else { return false }
            // The task holds the set only while it runs.
            let task = Task {
                await work { progress in self.update(repository, progress) }
                self.finish(repository)
            }
            running[repository] = Running(repository: repository, conversation: conversation, task: task)
            return true
        }
    }

    /// Cancels the pull of `repository`, or every pull when nil.
    ///
    /// - Parameter repository: The repository; nil for all.
    /// - Returns: The repositories cancelled.
    @discardableResult
    public func cancel(_ repository: String? = nil) -> [String] {
        let cancelled = running.withLock { running in
            running.values.filter { repository == nil || $0.repository == repository }
        }
        for pull in cancelled { pull.task.cancel() }
        return cancelled.map(\.repository).sorted()
    }

    /// Waits for the pull of `repository` to end, if one runs.
    ///
    /// - Parameter repository: The repository.
    public func wait(for repository: String) async {
        let task = running.withLock { $0[repository]?.task }
        await task?.value
    }

    /// Records how far a pull has gone.
    private func update(_ repository: String, _ progress: PullProgress) {
        running.withLock { $0[repository]?.progress = progress }
    }

    /// Forgets a pull that has ended.
    private func finish(_ repository: String) {
        _ = running.withLock { $0.removeValue(forKey: repository) }
    }
}
