import Foundation
import Synchronization

/// Where a chat face's Ctrl-C goes while a command the person typed runs (ADR 0049, amended 2026-10-09) or a model's
/// turn is under way (amended 2026-10-11): `ChatLoop` arms it with the command's `CommandStop`, or the turn's
/// `TurnStop`, for as long as it runs, and the face calls `press()` on Ctrl-C (the terminal chat's SIGINT) or on an
/// `interrupt` line (`wisp chat --json`). The first press stops it, a later one kills what it has running; with
/// nothing armed the face does what Ctrl-C did before, which in the terminal chat is to quit.
public final class ChatInterrupt: Sendable {
    /// What a press did.
    public enum Press: Sendable, Equatable {
        /// No command was running: the face's own Ctrl-C applies.
        case idle
        /// The command running, `line`, was asked to stop: SIGTERM, then SIGKILL after `CommandStop.grace`.
        case stopping(String)
        /// The command running, `line`, had been asked to stop already and was killed now.
        case killing(String)
        /// The model's turn was asked to stop: its request cancelled, a command it started sent SIGTERM.
        case stoppingTurn
        /// The turn had been asked to stop already; what it still had running was killed now.
        case killingTurn
    }

    /// The command running and its stop, while one runs.
    private let armed = Mutex<(line: String, stop: CommandStop, pressed: @Sendable (Press) -> Void)?>(nil)
    /// The model's turn under way and its stop, while one runs.
    private let turn = Mutex<(stop: TurnStop, pressed: @Sendable (Press) -> Void)?>(nil)

    /// The note the terminal chat writes on the first press during a model's turn.
    public static let stoppingTurnNote = "stopping the turn; \(ChatActivity.stoppingHint)"

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

    /// Ctrl-C: stops the command running, or kills it when it was asked to stop before; else stops the model's turn,
    /// or kills what it has running when it was asked to stop before.
    ///
    /// - Returns: What it did.
    @discardableResult
    public func press() -> Press {
        if let running = armed.withLock({ $0 }) {
            let press: Press = running.stop.request() == .stop ? .stopping(running.line) : .killing(running.line)
            running.pressed(press)
            return press
        }
        guard let turn = turn.withLock({ $0 }) else { return .idle }
        let press: Press = turn.stop.request() == .stop ? .stoppingTurn : .killingTurn
        turn.pressed(press)
        return press
    }

    /// Kills the command running now, and what the turn under way has running, if anything: the face is going away
    /// (its input closed, or it quits), and nothing outlives it.
    public func kill() {
        armed.withLock { $0 }?.stop.kill()
        turn.withLock { $0 }?.stop.kill()
    }

    /// Arms the interrupt for a model's turn, stopped by `stop`, until `disarmTurn()`.
    ///
    /// - Parameters:
    ///   - stop: The turn's stop.
    ///   - pressed: Told of each press while armed, after the stop was asked, such as to show it is stopping.
    func armTurn(_ stop: TurnStop, pressed: @escaping @Sendable (Press) -> Void = { _ in }) {
        turn.withLock { $0 = (stop, pressed) }
    }

    /// The turn has ended: Ctrl-C is the face's own again.
    func disarmTurn() {
        turn.withLock { $0 = nil }
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
