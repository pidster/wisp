import Foundation
import Synchronization

/// Where a chat face's Ctrl-C goes while a command the person typed runs (ADR 0049, amended 2026-10-09): `ChatLoop`
/// arms it with the command's `CommandStop` for as long as the command runs, and the face calls `press()` on Ctrl-C
/// (the terminal chat's SIGINT) or on an `interrupt` line (`wisp chat --json`). The first press stops the command,
/// a later one kills it; with nothing armed the face does what Ctrl-C did before, which in the terminal chat is to
/// quit.
public final class ChatInterrupt: Sendable {
    /// What a press did.
    public enum Press: Sendable, Equatable {
        /// No command was running: the face's own Ctrl-C applies.
        case idle
        /// The command running, `line`, was asked to stop: SIGTERM, then SIGKILL after `CommandStop.grace`.
        case stopping(String)
        /// The command running, `line`, had been asked to stop already and was killed now.
        case killing(String)
    }

    /// The command running and its stop, while one runs.
    private let armed = Mutex<(line: String, stop: CommandStop, pressed: @Sendable (Press) -> Void)?>(nil)

    /// The note the terminal chat writes on the first press: `stopping ollama pull …; Ctrl-C again quits`.
    ///
    /// - Parameter line: The command being stopped.
    /// - Returns: The note, unstyled.
    public static func stoppingNote(_ line: String) -> String {
        "stopping \(ChatEvents.shortened(line)); \(ChatActivity.stoppingHint)"
    }

    /// Creates an interrupt with nothing armed.
    public init() {}

    /// The command line being run, while one is armed.
    public var running: String? { armed.withLock { $0?.line } }

    /// Ctrl-C: stops the command running, or kills it when it was asked to stop before.
    ///
    /// - Returns: What it did.
    @discardableResult
    public func press() -> Press {
        guard let running = armed.withLock({ $0 }) else { return .idle }
        let press: Press = running.stop.request() == .stop ? .stopping(running.line) : .killing(running.line)
        running.pressed(press)
        return press
    }

    /// Kills the command running now, if one is: the face is going away (its input closed, or it quits), and
    /// nothing a person typed outlives it.
    public func kill() {
        armed.withLock { $0 }?.stop.kill()
    }

    /// Arms the interrupt for `line`, running with `stop`, until `disarm()`.
    ///
    /// - Parameters:
    ///   - line: The command line.
    ///   - stop: Its stop.
    ///   - pressed: Told of each press while armed, after the stop was asked, such as to show it is stopping.
    func arm(_ line: String, stop: CommandStop, pressed: @escaping @Sendable (Press) -> Void = { _ in }) {
        armed.withLock { $0 = (line, stop, pressed) }
    }

    /// The command has ended: Ctrl-C is the face's own again.
    func disarm() {
        armed.withLock { $0 = nil }
    }
}
