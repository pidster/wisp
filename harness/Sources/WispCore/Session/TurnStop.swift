import Foundation
import Synchronization

/// Stops a model's turn when the person asks: Ctrl-C in the terminal chat, an `interrupt` line from a front end
/// ([ADR 0049](../../../../docs/decisions/0049-commands-typed-in-chat.md), amended 2026-10-11). `ChatLoop` makes one per
/// turn and `Agent` binds it as a task local around the turn's requests, as it binds the turn's `ReasoningObserver`;
/// what the turn has under way attaches to it while it runs:
///
/// - a request to a local runtime (`RequestStop`): its connection is cancelled, so the executor ends at once;
/// - a `run_command` the model started (`CommandRunner`): its process group is sent SIGTERM, and SIGKILL after
///   `CommandStop.grace`, as a typed command is; a second request kills it at once;
/// - the turn itself: an executor checks before it sends (`check()`), and a streamed reply is checked at each
///   snapshot, so a runtime that cannot be cancelled mid-request (Apple's) stops at its next words.
///
/// The first request is `.stop`, every later one `.kill`, as for `CommandStop`. A request made before something
/// attaches reaches it as it attaches.
public final class TurnStop: Sendable {
    /// Why a turn ended early.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The person stopped it.
        case stopped

        /// Human-readable explanation.
        public var description: String { "stopped by you" }
    }

    /// The stop of the turn under way, bound by `Agent` around its requests; nil outside a stoppable turn.
    @TaskLocal public static var current: TurnStop?

    /// The requests so far, and who acts on them, by the token `attach` gave.
    private let state = Mutex<(requests: Int, next: Int, handlers: [Int: @Sendable (CommandStop.Request) -> Void])>(
        (0, 0, [:]))

    /// Creates a stop nobody has asked for.
    public init() {}

    /// Whether a stop has been asked for.
    public var requested: Bool { requests > 0 }

    /// How many times a stop has been asked for: 0, 1 (stop), or more (kill).
    public var requests: Int { state.withLock { $0.requests } }

    /// Asks the turn to stop: the first request is `.stop`, every later one `.kill`. Everything attached is told.
    ///
    /// - Returns: What was asked.
    @discardableResult
    public func request() -> CommandStop.Request {
        let (request, handlers) = state.withLock { state in
            state.requests += 1
            return (state.requests == 1 ? CommandStop.Request.stop : .kill, Array(state.handlers.values))
        }
        for handler in handlers { handler(request) }
        return request
    }

    /// Asks everything the turn has under way to end now, whatever was asked before: the face is going away.
    public func kill() {
        let handlers = state.withLock { state in
            state.requests = max(state.requests, 2)
            return Array(state.handlers.values)
        }
        for handler in handlers { handler(.kill) }
    }

    /// Throws when a stop has been asked for: an executor calls this before it sends a request.
    ///
    /// - Throws: `Failure.stopped`.
    public func check() throws {
        if requested { throw Failure.stopped }
    }

    /// Returns once a stop has been asked for, or the waiting task is cancelled.
    public func stopped() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = attach { _ in continuation.yield() }
        defer { detach(token) }
        for await _ in stream { break }
    }

    /// Attaches `handler` until `detach`; a stop already asked for is acted on at once.
    ///
    /// - Parameter handler: Ends what it stands for: cancels a connection, signals a process group.
    /// - Returns: The token `detach` takes.
    public func attach(_ handler: @escaping @Sendable (CommandStop.Request) -> Void) -> Int {
        let (token, requests) = state.withLock { state in
            state.next += 1
            state.handlers[state.next] = handler
            return (state.next, state.requests)
        }
        if requests > 0 { handler(requests == 1 ? .stop : .kill) }
        return token
    }

    /// Detaches what `attach` attached: it has ended.
    ///
    /// - Parameter token: The token `attach` gave.
    public func detach(_ token: Int) {
        _ = state.withLock { $0.handlers.removeValue(forKey: token) }
    }
}

/// Cancels one request's connection when the turn it belongs to is stopped (`TurnStop`): passed as the task's
/// delegate, it attaches as the task is created, so a stop reaches a request still waiting for its first byte.
final class RequestStop: NSObject, URLSessionTaskDelegate, Sendable {
    /// The turn's stop, if the request runs inside a stoppable turn.
    private let stop: TurnStop?
    /// The token of the attached handler, once the task exists.
    private let token = Mutex<Int?>(nil)

    /// Creates one for the turn under way.
    ///
    /// - Parameter stop: The turn's stop; the task local by default.
    init(_ stop: TurnStop? = TurnStop.current) {
        self.stop = stop
    }

    /// Attaches a handler that cancels `task`.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - task: The request's task.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard let stop else { return }
        let attached = stop.attach { _ in task.cancel() }
        token.withLock { $0 = attached }
    }

    /// The request has ended: a later stop reaches nothing through it.
    func end() {
        guard let attached = token.withLock({ $0 }) else { return }
        stop?.detach(attached)
    }
}
