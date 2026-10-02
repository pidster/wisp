import Synchronization

/// Produces `wisp watch`'s triggers, and applies the settle period to the file changes among them: a burst
/// of changes becomes one `.change`, sent once no change has arrived for `settle` (a trailing debounce)
/// ([ADR 0033](../../../../docs/decisions/0033-watch-mode.md), amended 2026-10-02). FSEvents gathers
/// changes over a fixed 0.5 s, so a long burst (a checkout, a formatter, save-all) can otherwise start a run
/// part-way through it, which fails and then passes. `.start` and `.interval` are never delayed.
///
/// `Watcher` stays free of time; the time is here, behind a `Clock`, so tests run it with a scripted one.
public final class TriggerSettler<C: Clock & Sendable>: Sendable where C.Duration == Duration {
    /// Where the triggers go.
    private let continuation: AsyncStream<Watcher.Trigger>.Continuation
    /// How long the changes must be quiet; zero sends each at once.
    private let settle: Duration
    /// The clock the quiet period is measured on.
    private let clock: C
    /// The task that will send the next `.change`, replaced by each change that arrives before it does.
    private let pending = Mutex<Task<Void, Never>?>(nil)

    /// Creates a settler.
    ///
    /// - Parameters:
    ///   - settle: The quiet period; zero or less passes every change straight through.
    ///   - clock: The clock to measure it on (`ContinuousClock` in production).
    ///   - continuation: The stream the triggers are sent to.
    public init(settle: Duration, clock: C, continuation: AsyncStream<Watcher.Trigger>.Continuation) {
        self.settle = settle
        self.clock = clock
        self.continuation = continuation
    }

    /// Sends `.start`, the first run, at once.
    public func start() {
        continuation.yield(.start)
    }

    /// Sends `.interval` at once; the interval is not a burst.
    public func interval() {
        continuation.yield(.interval)
    }

    /// Notes a file change: `.change` is sent once no further change arrives for the settle period, or at
    /// once when it is zero.
    public func fileChanged() {
        guard settle > .zero else {
            continuation.yield(.change)
            return
        }
        pending.withLock { task in
            task?.cancel()
            task = Task { [clock, settle, continuation] in
                do {
                    try await clock.sleep(for: settle)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                continuation.yield(.change)
            }
        }
    }

    /// Drops a change still settling and ends the stream.
    public func finish() {
        pending.withLock { $0?.cancel() }
        continuation.finish()
    }
}
