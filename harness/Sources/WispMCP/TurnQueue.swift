import Foundation

/// Serialises one thread's turns in the order they arrive.
///
/// `ThreadActor` alone does not: an actor is reentrant, so a second `respond` on the same `thread_id` would
/// enter the same `Agent` while the first waits on the model or an approval, and the server's reads after
/// a turn (the turn number, the gate's refusals, the receipt's events) would see the other turn's. Every
/// `respond` holds the queue from setting the task to folding the receipt, so each caller gets its own
/// turn's results, first come first served. Closing the thread (or evicting it) waits for the turn under
/// way to finish, refuses those still queued, and refuses any that arrive later, so `session.end` is the
/// thread's last event.
public actor TurnQueue {
    /// Why a turn could not start.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The thread was closed or evicted before the turn's place came.
        case closed

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .closed: "the thread was closed while this call waited for the turn before it"
            }
        }
    }

    /// Whether a turn holds the queue.
    private var busy = false
    /// Turns waiting their place, oldest first; resumed with true to run, false when the thread closed.
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    /// Whoever waits for the queue to empty after closing it.
    private var drained: [CheckedContinuation<Void, Never>] = []
    /// Whether the thread is closed: no turn starts any more.
    private var closed = false

    /// Creates an empty queue.
    public init() {}

    /// Whether a turn holds the queue now.
    public var isBusy: Bool { busy }

    /// Waits for this turn's place; every call that returns must be matched by `release()`.
    ///
    /// - Throws: `Failure.closed` when the thread is closed, before or while waiting.
    public func acquire() async throws(Failure) {
        guard !closed else { throw .closed }
        guard busy else {
            busy = true
            return
        }
        let granted = await withCheckedContinuation { waiting.append($0) }
        guard granted else { throw .closed }
    }

    /// Ends the turn holding the queue, handing it to the next in line.
    public func release() {
        if !waiting.isEmpty {
            waiting.removeFirst().resume(returning: true)  // the queue stays busy, now with the next turn
            return
        }
        busy = false
        for waiter in drained { waiter.resume() }
        drained = []
    }

    /// Closes the queue: turns still waiting are refused, and this returns once the turn under way, if any,
    /// has ended.
    public func close() async {
        closed = true
        for waiter in waiting { waiter.resume(returning: false) }
        waiting = []
        guard busy else { return }
        await withCheckedContinuation { drained.append($0) }
    }

    /// Runs `body` as one turn: after the turns ahead of it, and before the ones behind.
    ///
    /// - Parameter body: The turn.
    /// - Returns: What `body` returns.
    /// - Throws: `Failure.closed`, or whatever `body` throws.
    public nonisolated func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
