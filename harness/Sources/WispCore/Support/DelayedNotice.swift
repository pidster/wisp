import Synchronization

/// Posts a notice a while after something starts waiting, unless it has settled by then: "notify after N s unless
/// settled". The approval banner under `wisp mcp` uses it, so that a request the client's dialog answers at once
/// posts no banner ([ADR 0046](../../../../docs/decisions/0046-approval-and-notifications-over-mcp.md), amended
/// 2026-10-12); anything else that tells the person about a wait another face may answer first can too.
///
/// The delay is an `Alarm`, never a `Task.sleep` on the cooperative pool (`docs/design.md`, "Concurrency"), and
/// nothing waits on it. When it fires, the notice is posted on a task of its own, since posting may start a
/// process; a zero or negative delay posts at once, on the caller's thread, as before there was a delay. Each
/// notice is posted at most once: whichever of the alarm, `postNow`, and `settle` comes first decides, under a
/// lock.
final class DelayedNotice: Sendable {
    /// What became of the notice.
    enum Outcome: String, Sendable, Equatable {
        /// Not yet posted, and not settled.
        case waiting
        /// Posted (or handed to its poster), by the alarm or `postNow`.
        case posted
        /// The wait settled first; nothing was posted, and nothing will be.
        case skipped
    }

    /// The notice's state: the outcome, the poster until it is used or dropped, and the alarm while it is set.
    private struct State {
        var outcome = Outcome.waiting
        var post: (@Sendable () -> Void)?
        var alarm: Alarm?
    }

    /// The state, behind the lock.
    private let state: Mutex<State>

    /// Schedules `post` to run `delay` from now, unless the notice is settled first.
    ///
    /// - Parameters:
    ///   - delay: How long the wait may go on before the notice is posted; zero or less posts at once, before
    ///     this returns.
    ///   - post: Posts the notice; it may block briefly (a notification starts a process), so a delayed one runs
    ///     on a task of its own.
    init(after delay: Duration, post: @escaping @Sendable () -> Void) {
        state = Mutex(State(post: post))
        guard delay > .zero else {
            postNow()
            return
        }
        let alarm = Alarm(after: delay) { [self] in
            guard let post = claim() else { return }
            Task { post() }
        }
        // The alarm may have fired already on a tiny delay; then the state no longer wants it.
        state.withLock { state in
            if state.outcome == .waiting { state.alarm = alarm } else { alarm.cancel() }
        }
    }

    /// What became of the notice so far.
    var outcome: Outcome { state.withLock { $0.outcome } }

    /// Posts the notice now, on the caller's thread, unless it has been posted or settled; for when nobody else
    /// will show the wait (the client's dialog could not be sent).
    func postNow() {
        claim()?()
    }

    /// Ends the wait: a notice not yet posted never will be.
    ///
    /// - Returns: `posted` when it had been posted, `skipped` when this stopped it.
    @discardableResult
    func settle() -> Outcome {
        let (outcome, alarm) = state.withLock { state -> (Outcome, Alarm?) in
            if state.outcome == .waiting {
                state.outcome = .skipped
                state.post = nil
            }
            defer { state.alarm = nil }
            return (state.outcome, state.alarm)
        }
        alarm?.cancel()
        return outcome
    }

    /// Marks the notice posted and hands back its poster, when it is still waiting; nil otherwise.
    private func claim() -> (@Sendable () -> Void)? {
        let (post, alarm) = state.withLock { state -> ((@Sendable () -> Void)?, Alarm?) in
            guard state.outcome == .waiting else { return (nil, nil) }
            state.outcome = .posted
            defer {
                state.post = nil
                state.alarm = nil
            }
            return (state.post, state.alarm)
        }
        alarm?.cancel()
        return post
    }
}
