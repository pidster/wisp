import Foundation
import Synchronization

/// Bounded waits. The safe default for anything that asks a human: an unanswered question is
/// not an answer, so callers turn `Failure.elapsed` into a denial.
public enum Timeout {
    /// Why a bounded wait ended without a result.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nothing arrived within the duration.
        case elapsed(Duration)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .elapsed(let duration): "no answer within \(duration)"
            }
        }
    }

    /// Runs `operation` and gives up after `duration`, cancelling it.
    ///
    /// The wait is bounded whatever the operation does: it is cancelled at the deadline, and if it
    /// ignores cancellation (an MCP request in flight does) it keeps running on its own with its
    /// eventual result discarded, rather than holding the caller. A task group would wait for it
    /// (measured 2026-09-21: "no answer within 600 s" refusals returned after 11 to 56 minutes,
    /// when the client finally answered).
    ///
    /// - Throws: `Failure.elapsed` on timeout, or whatever `operation` throws.
    public static func run<T: Sendable>(
        _ duration: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let settled = Mutex(false)
        /// Whether this caller is the first to settle; only the first may resume.
        @Sendable func claim() -> Bool {
            settled.withLock {
                let was = $0; $0 = true; return !was
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The deadline is an `Alarm`, not a `Task.sleep`, so blocked cooperative threads cannot hold it off; the
            // alarm is cancelled when the operation settles first, so a long bound leaves nothing waiting behind it.
            let work = Task {
                do {
                    let value = try await operation()
                    if claim() { continuation.resume(returning: value) }
                } catch {
                    if claim() { continuation.resume(throwing: error) }
                }
            }
            let alarm = Alarm(after: duration) {
                if claim() {
                    work.cancel()
                    continuation.resume(throwing: Failure.elapsed(duration))
                }
            }
            Task {
                await work.value
                alarm.cancel()
            }
        }
    }

    /// `run` when `duration` is set; runs `operation` unbounded when it is nil.
    public static func run<T: Sendable>(
        _ duration: Duration?, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let duration else { return try await operation() }
        return try await run(duration, operation)
    }
}
