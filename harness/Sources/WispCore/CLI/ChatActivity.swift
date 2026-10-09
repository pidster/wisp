import Foundation
import Synchronization

/// What a chat turn is doing while it runs, for a live "working" line: waiting for the model, running a
/// command, waiting for an approval. `ChatLoop` feeds it the turn's edges and its audit events; each
/// face draws it its own way, the terminal chat on a line it redraws, `wisp chat --json` as `activity`
/// lines for `wisp-tui`'s status line.
public final class ChatActivity: Sendable {
    /// The turn under way.
    public struct State: Equatable, Sendable {
        /// What it is doing, such as `running git status`.
        public var doing: String
        /// Since when it has been doing that.
        public var since: Date
        /// When the turn began.
        public var turnStarted: Date
        /// Whether a person is being asked, in which case the dialog is on screen and the line is not.
        public var asking: Bool
        /// Whether the model is thinking (ADR 0053): a face may draw it its own way, as `wisp-tui`'s thought bubble.
        public var thinking = false
        /// Whether the person can stop it with Ctrl-C: a command they typed, which has no timeout (ADR 0049,
        /// amended 2026-10-09).
        public var stoppable = false
        /// Whether the person has asked it to stop and it has not ended yet: a second Ctrl-C quits.
        public var stopping = false
    }

    /// What the line for a stoppable activity ends with.
    public static let stopHint = "Ctrl-C stops it"
    /// What the line for an activity being stopped ends with.
    public static let stoppingHint = "Ctrl-C again quits"

    private let state = Mutex<State?>(nil)
    private let changed = Mutex<(@Sendable (State?) -> Void)?>(nil)

    /// Creates an idle activity.
    public init() {}

    /// Calls `handle` each time what the turn is doing changes, and with nil when it ends.
    public func onChange(_ handle: @escaping @Sendable (State?) -> Void) {
        changed.withLock { $0 = handle }
    }

    /// The turn under way, or nil between turns.
    public var current: State? { state.withLock { $0 } }

    /// What the activity says while the model thinks.
    public static let thinking = "thinking"

    /// A turn has begun: the message has gone to the model; or, with `doing`, something else is under way that
    /// the face should show as work, such as a command the person typed (`running git status`), `stoppable` when
    /// Ctrl-C stops it.
    public func begin(doing: String = "waiting for the model", stoppable: Bool = false, at time: Date = Date()) {
        set(State(doing: doing, since: time, turnStarted: time, asking: false, stoppable: stoppable))
    }

    /// The person asked the stoppable activity under way to stop: it now says `doing`, such as `stopping git
    /// status`, until it ends. Nothing changes when what is under way is not stoppable.
    ///
    /// - Parameters:
    ///   - doing: What it says now.
    ///   - time: When.
    public func stopping(_ doing: String, at time: Date = Date()) {
        guard var next = current, next.stoppable else { return }
        next.doing = doing
        next.stoppable = false
        next.stopping = true
        next.since = time
        set(next)
    }

    /// The turn has ended.
    public func end() {
        set(nil)
    }

    /// Follows one of the turn's audit events; events that change nothing are ignored.
    public func apply(_ event: AuditEvent, at time: Date = Date()) {
        // A command the person typed has no turn: its own events change nothing it shows.
        guard var next = current, !next.stoppable, !next.stopping else { return }
        next.thinking = false
        switch event.kind {
        case .modelReasoning:
            let started = event.details["phase"]?.stringValue == "start"
            next.doing = started ? Self.thinking : "waiting for the model"
            next.thinking = started
            next.asking = false
        case .toolCall:
            let line = ChatEvents.render(event, style: .plain) ?? "⚙ a tool"
            let call = line.hasPrefix("⚙ ") ? String(line.dropFirst(2)) : line
            next.doing = call.hasPrefix("run_command ") ? "running " + call.dropFirst("run_command ".count) : call
            next.asking = false
        case .approvalRequested:
            next.doing = "waiting for your approval"
            next.asking = true
        case .toolResult, .commandOutcome, .approvalDecided, .error:
            next.doing = "waiting for the model"
            next.asking = false
        case .condensation:
            next.doing = "condensing the context"
            next.asking = false
        default:
            return
        }
        next.since = time
        set(next)
    }

    /// The line a face shows for `state` at `now`: the turn's time, what it is doing, and for how long
    /// when that is not the whole turn, as `12 s · running git status (8 s)`; a stoppable one ends with how to
    /// stop it, `12 s · running ollama pull … · Ctrl-C stops it`.
    public static func line(_ state: State, now: Date = Date()) -> String {
        let turn = Int(now.timeIntervalSince(state.turnStarted).rounded(.down))
        let doing = Int(now.timeIntervalSince(state.since).rounded(.down))
        let part = state.since > state.turnStarted.addingTimeInterval(0.5) && doing != turn ? " (\(doing) s)" : ""
        let hint = state.stopping ? " · " + stoppingHint : state.stoppable ? " · " + stopHint : ""
        return "\(turn) s · \(state.doing)\(part)" + hint
    }

    private func set(_ new: State?) {
        let old = state.withLock { current in
            let old = current
            current = new
            return old
        }
        if old?.doing != new?.doing || old?.thinking != new?.thinking || old?.stoppable != new?.stoppable
            || old?.stopping != new?.stopping || (old == nil) != (new == nil)
        {
            changed.withLock { $0 }?(new)
        }
    }
}
