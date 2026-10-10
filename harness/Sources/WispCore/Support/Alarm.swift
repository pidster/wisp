import Dispatch
import Synchronization

/// A one-shot timer that fires on a dispatch queue of its own, never on Swift's cooperative pool.
///
/// A `Task.sleep` deadline needs a free cooperative thread to run when it expires, so code that blocks those
/// threads (a synchronous bridge such as `Blocking.run`, a framework call that waits on a semaphore) holds it off;
/// measured 2026-10-10, a 200 ms command watchdog fired after 30 s under the gate's parallel tests. A bound that
/// must hold whatever else the process is doing (the command watchdog, `Timeout.run`) uses an alarm instead: the
/// action runs on a serial queue, which libdispatch gives a thread of its own when it has work.
final class Alarm: Sendable {
    /// Where every alarm's action runs; serial, so the actions must be short (a signal, a resume).
    private static let queue = DispatchQueue(label: "wisp.alarm", qos: .userInitiated)

    /// The action until it runs or the alarm is cancelled; nil after either, so a cancelled alarm with a long
    /// delay holds nothing the action captured.
    private let action: Mutex<(@Sendable () -> Void)?>

    /// Schedules `action` to run once, `delay` from now, unless the alarm is cancelled first.
    ///
    /// - Parameters:
    ///   - delay: How long from now; a negative one fires at once.
    ///   - action: What to do; it runs on the alarm queue and must not block.
    init(after delay: Duration, _ action: @escaping @Sendable () -> Void) {
        self.action = Mutex(action)
        Self.queue.asyncAfter(deadline: .now() + Self.interval(delay)) { [self] in
            let pending = self.action.withLock { action in
                defer { action = nil }
                return action
            }
            pending?()
        }
    }

    /// Stops the action if it has not run yet; does nothing after it has.
    func cancel() {
        action.withLock { $0 = nil }
    }

    /// `duration` as a dispatch interval, clamped to between zero and about a century, so a huge bound
    /// cannot overflow the nanosecond count.
    ///
    /// - Parameter duration: The duration.
    /// - Returns: The interval.
    static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let century: Int64 = 100 * 365 * 24 * 3600
        guard seconds >= 0 else { return .nanoseconds(0) }
        guard seconds < century else { return .seconds(Int(century)) }
        return .nanoseconds(Int(seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }
}
