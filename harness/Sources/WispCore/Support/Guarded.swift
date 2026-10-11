import Synchronization

/// A value behind a lock that closures share with the code that made them, such as a pull's last progress (ADR 0059).
/// A `Mutex` is non-copyable and never captured itself, so this holds one in a class, as `OutputBuffer` does.
public final class Guarded<Value: Sendable>: Sendable {
    /// The value.
    private let mutex: Mutex<Value>

    /// Creates the lock around `value`.
    ///
    /// - Parameter value: The first value.
    public init(_ value: Value) {
        mutex = Mutex(value)
    }

    /// The value now.
    public var value: Value { mutex.withLock { $0 } }

    /// Changes the value under the lock and returns what `body` returns.
    ///
    /// - Parameter body: The change.
    /// - Returns: What `body` returned.
    @discardableResult
    public func update<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { value in body(&value) }
    }
}
