import Dispatch
import Synchronization

/// Runs a short async operation to completion from synchronous code.
///
/// `ModelSelection.resolve` is synchronous because agents are created synchronously (the MCP thread
/// store builds a thread inside one actor step), while checking a runtime or loading an asset is
/// async. This is the one bridge; use it only for local, bounded work such as a tags request or a
/// tokenizer load, never for generation.
///
/// The caller's thread waits, and callers are usually on Swift's cooperative pool, which has one thread per core
/// and does not grow when one blocks. So the operation never runs there: it runs on a task executor of its own
/// (`Executor`), whose serial queue libdispatch backs with a thread of its own, and makes progress however many
/// pool threads are blocked. Before 0.22.0 it ran on the pool, and under the gate's parallel tests a dozen callers
/// blocked in this bridge waited for operations that could not get a pool thread, holding every `Task.sleep` timer
/// in the process off for tens of seconds (docs/design.md, "Concurrency").
public enum Blocking {
    /// Runs `operation` on a task executor off the cooperative pool and waits for its result.
    ///
    /// - Throws: Whatever `operation` throws.
    public static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let slot = Slot<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(executorPreference: Executor()) {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            slot.result.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        guard let result = slot.result.withLock({ $0 }) else { throw Failure.noResult }
        return try result.get()
    }

    /// Why a blocking run produced nothing; cannot happen unless the task was lost.
    public enum Failure: Error, CustomStringConvertible {
        /// The task finished without storing a result.
        case noResult

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .noResult: "blocking operation produced no result"
            }
        }
    }

    /// A one-shot result slot.
    private final class Slot<T: Sendable>: Sendable {
        let result = Mutex<Result<T, any Error>?>(nil)
    }

    /// Runs one bridged operation's jobs on a serial queue of its own. As the task's executor preference it is where
    /// the operation's nonisolated code runs and resumes, so the operation needs no cooperative thread; code isolated
    /// to an actor still runs on that actor.
    final class Executor: TaskExecutor {
        /// The queue the jobs run on; a serial queue made without a target gets a thread of its own when it has work.
        private let queue = DispatchQueue(label: "wisp.blocking", qos: .userInitiated)

        /// Runs `job` on the queue.
        ///
        /// - Parameter job: The job.
        func enqueue(_ job: consuming ExecutorJob) {
            let unowned = UnownedJob(job)
            queue.async { [self] in unowned.runSynchronously(on: asUnownedTaskExecutor()) }
        }
    }
}
