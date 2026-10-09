import Foundation

/// A wait in a test that ran out: the condition it polled for never held within its bound. Thrown by `eventually`
/// and `firstValue`, so a test fails with where and what it waited for instead of hanging the whole run.
public struct WaitTimedOut: Error, CustomStringConvertible, Equatable {
    /// What was waited for, as the test named it.
    public let what: String
    /// How long the wait lasted.
    public let bound: Duration
    /// Where the wait was, as `file:line`.
    public let location: String

    /// The failure, for a person.
    public var description: String { "\(location): waited \(bound) for \(what), and it never came" }
}

/// The bound a test waits for something that should take milliseconds: long enough for a loaded Mac running the
/// suites in parallel, short enough that a lost answer fails the test well inside its one-minute time limit rather
/// than hanging the run. On 2026-10-09, with the gate's tests at 17 s beside other builds, a 100 ms timer waited
/// 12.2 s for a thread (TimeoutTests), so 10 s was not enough.
public let testWaitBound: Duration = .seconds(30)

/// Polls `condition` every `interval` until it holds, for up to `bound`.
///
/// - Parameters:
///   - bound: How long to wait before giving up.
///   - interval: The pause between polls.
///   - what: What is waited for, for the failure.
///   - file: Where the wait is; the caller's.
///   - line: The caller's line.
///   - condition: The condition; polled on the caller's task.
/// - Throws: `WaitTimedOut` when the bound passes first, or what `condition` throws.
nonisolated(nonsending) public func eventually(
    within bound: Duration = testWaitBound, every interval: Duration = .milliseconds(5), _ what: String = "a condition",
    file: String = #fileID, line: Int = #line, _ condition: () async throws -> Bool
) async throws {
    _ = try await firstValue(within: bound, every: interval, what, file: file, line: line) {
        try await condition() ? true : nil
    }
}

/// Polls `produce` every `interval` until it returns a value, for up to `bound`, and returns that value.
///
/// - Parameters:
///   - bound: How long to wait before giving up.
///   - interval: The pause between polls.
///   - what: What is waited for, for the failure.
///   - file: Where the wait is; the caller's.
///   - line: The caller's line.
///   - produce: Returns the value once it is there, nil until then; polled on the caller's task.
/// - Returns: The first value `produce` returned.
/// - Throws: `WaitTimedOut` when the bound passes first, or what `produce` or the sleep throws.
nonisolated(nonsending) public func firstValue<T>(
    within bound: Duration = testWaitBound, every interval: Duration = .milliseconds(5), _ what: String = "a value",
    file: String = #fileID, line: Int = #line, _ produce: () async throws -> T?
) async throws -> T {
    let clock = ContinuousClock()
    let deadline = clock.now + bound
    while true {
        if let value = try await produce() { return value }
        guard clock.now < deadline else { throw WaitTimedOut(what: what, bound: bound, location: "\(file):\(line)") }
        try await Task.sleep(for: interval)
    }
}
