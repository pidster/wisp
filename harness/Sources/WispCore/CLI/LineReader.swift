import Darwin
import Dispatch
import Foundation

/// A line read from a descriptor that a stop and a deadline can end, which a blocking `readLine` cannot
/// ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md), section 6): plain chat's dialog for the
/// model's question waits for the person as long as they take, and Ctrl-C (the turn's `TurnStop`) or a
/// deadline, when one is set, ends the wait without leaving a thread blocked on standard input, which would
/// swallow the next line typed at the prompt.
///
/// The read polls the descriptor (`poll(2)`, `pollInterval` at a time) on a dispatch queue of its own, off
/// Swift's cooperative pool, and reads a line only once the descriptor is readable; on a terminal in canonical
/// mode that is when the person presses Enter, so the read itself returns at once.
public struct LineReader: Sendable {
    /// What a read ended with.
    public enum Read: Equatable, Sendable {
        /// A line, without its newline.
        case line(String)
        /// End of input.
        case end
        /// The stop was asked for before a line came.
        case stopped
        /// The deadline passed.
        case expired
    }

    /// The descriptor read.
    public let descriptor: Int32
    /// How long each poll waits before the stop and the deadline are checked.
    public let pollInterval: Duration
    /// Where the polling runs; serial, and given a thread of its own by libdispatch when it has work.
    private static let queue = DispatchQueue(label: "wisp.line-reader", qos: .userInteractive)

    /// Standard input.
    public static let standardInput = LineReader(descriptor: STDIN_FILENO)

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor.
    ///   - pollInterval: How often the stop and the deadline are checked; 100 ms by default.
    public init(descriptor: Int32, pollInterval: Duration = .milliseconds(100)) {
        self.descriptor = descriptor
        self.pollInterval = pollInterval
    }

    /// Reads one line, or ends when `stop` is asked for or `timeout` passes.
    ///
    /// - Parameters:
    ///   - stop: The turn's stop; nil never stops.
    ///   - timeout: The deadline; nil waits for the line.
    /// - Returns: What ended the read.
    public func read(stop: TurnStop?, within timeout: Duration?) async -> Read {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        let descriptor = descriptor
        let interval = pollInterval
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(
                    returning: Self.poll(descriptor, interval: interval, stop: stop, deadline: deadline))
            }
        }
    }

    /// Polls until the descriptor is readable, the stop is asked for, or the deadline passes; then reads a line.
    private static func poll(
        _ descriptor: Int32, interval: Duration, stop: TurnStop?, deadline: ContinuousClock.Instant?
    ) -> Read {
        let milliseconds = Int32(
            clamping: interval.components.seconds * 1000 + interval.components.attoseconds / 1_000_000_000_000_000)
        while true {
            if stop?.requested == true { return .stopped }
            if let deadline, ContinuousClock.now >= deadline { return .expired }
            var fds = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&fds, 1, max(1, milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                return .end
            }
            if ready == 0 { continue }
            if fds.revents & Int16(POLLIN) != 0 { return readLine(from: descriptor) }
            if fds.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return .end }
        }
    }

    /// Reads one line from `descriptor`, byte by byte up to the newline, so nothing past it is consumed.
    private static func readLine(from descriptor: Int32) -> Read {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                return bytes.isEmpty ? .end : .line(String(decoding: bytes, as: UTF8.self))
            }
            if count == 0 { return bytes.isEmpty ? .end : .line(String(decoding: bytes, as: UTF8.self)) }
            if byte == UInt8(ascii: "\n") {
                if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
                return .line(String(decoding: bytes, as: UTF8.self))
            }
            bytes.append(byte)
        }
    }
}
