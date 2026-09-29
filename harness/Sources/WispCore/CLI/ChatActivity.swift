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
    }

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

    /// A turn has begun: the message has gone to the model.
    public func begin(at time: Date = Date()) {
        set(State(doing: "waiting for the model", since: time, turnStarted: time, asking: false))
    }

    /// The turn has ended.
    public func end() {
        set(nil)
    }

    /// Follows one of the turn's audit events; events that change nothing are ignored.
    public func apply(_ event: AuditEvent, at time: Date = Date()) {
        guard var next = current else { return }
        switch event.kind {
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
    /// when that is not the whole turn, as `12 s · running git status (8 s)`.
    public static func line(_ state: State, now: Date = Date()) -> String {
        let turn = Int(now.timeIntervalSince(state.turnStarted).rounded(.down))
        let doing = Int(now.timeIntervalSince(state.since).rounded(.down))
        let part = state.since > state.turnStarted.addingTimeInterval(0.5) && doing != turn ? " (\(doing) s)" : ""
        return "\(turn) s · \(state.doing)\(part)"
    }

    private func set(_ new: State?) {
        let old = state.withLock { current in
            let old = current
            current = new
            return old
        }
        if old?.doing != new?.doing || (old == nil) != (new == nil) { changed.withLock { $0 }?(new) }
    }
}
