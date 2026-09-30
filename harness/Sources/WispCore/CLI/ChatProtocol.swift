import Foundation
import Synchronization

/// The headless chat: `wisp chat --json` speaks JSON Lines on stdin and stdout so another program can
/// be the face (the `wisp-tui` terminal front end, an editor, a GUI), while the session, tools, gate,
/// and audit stay in this process. One object per line; unknown types are ignored, and a line that is
/// not JSON is taken as a typed message so the protocol can be driven by hand.
///
/// Outbound (to the front end): `note` (the banner and other notices), `status`, `output` (a whole line,
/// as `/help` prints), `delta` (streamed reply text), `turn` (`start`/`end`), `event` (an audit event of
/// the conversation, raw, with the line the terminal chat would show for it as `text`), `approval` (a
/// request the front end must answer), `choice` (a question a chat command asks, such as `/config set`),
/// `completions` (the answer to a `complete`), `exit`. Inbound: `message` (a chat line, slash commands
/// included), `answer` (to an approval, by id), `choose` (to a choice, by id; no value is no answer), and
/// `complete` (the input line and cursor to complete, by id).
public enum ChatProtocol {
    /// What the front end sends.
    public enum Inbound: Equatable, Sendable {
        /// A chat input line.
        case message(String)
        /// An answer to an approval request: `once`, `session`, `project`, `always`, or `no`.
        case answer(id: String, decision: String)
        /// A request to complete the input line at a character index.
        case complete(id: String, text: String, cursor: Int?)

        /// Parses one line; text that is not a typed JSON object is a message.
        public init(line: String) {
            guard let data = line.data(using: .utf8),
                let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
                let type = object["type"]?.stringValue
            else {
                self = .message(line)
                return
            }
            switch type {
            case "answer":
                self = .answer(id: object["id"]?.stringValue ?? "", decision: object["decision"]?.stringValue ?? "no")
            case "complete":
                self = .complete(
                    id: object["id"]?.stringValue ?? "", text: object["text"]?.stringValue ?? "",
                    cursor: object["cursor"]?.intValue)
            case "choose":
                self = .answer(id: object["id"]?.stringValue ?? "", decision: object["value"]?.stringValue ?? "")
            default:
                self = .message(object["text"]?.stringValue ?? "")
            }
        }
    }

    /// One line to the front end.
    public static func encode(_ type: String, _ fields: [String: JSONValue] = [:]) -> String {
        var object = fields
        object["type"] = .string(type)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The `status` line's fields.
    public static func status(_ status: ChatStatus) -> [String: JSONValue] {
        [
            "model": .string(status.model), "directory": .string(status.directory),
            "branch": status.branch.map { .string($0) } ?? .null, "dirty": status.dirty.map { .bool($0) } ?? .null,
            "added": status.added.map { .int($0) } ?? .null, "removed": status.removed.map { .int($0) } ?? .null,
            "approval": .string(status.approval), "contextUsed": status.contextUsed.map { .double($0) } ?? .null,
        ]
    }

    /// The `event` line's fields: the audit event's kind, call, turn, and details, and `text`, the
    /// unstyled line the terminal chat shows for it (null when it shows none), so every face words tool
    /// activity alike and a front end renders the raw fields only when it wants to. A `tool.result` also
    /// carries `output`, the tool's output for the front end to show (decision D12): its `id` (the event's,
    /// which `/show` takes), `text` (up to `Paging.pageBytes`), `lines`, `bytes`, `truncated` when `text` is
    /// shorter than the output, and `shownLines`, how many lines the terminal chat shows before it folds.
    ///
    /// - Parameters:
    ///   - event: The audit event.
    ///   - shownLines: The fold size (`Config.Resolved.shownOutputLines`).
    /// - Returns: The fields.
    public static func event(
        _ event: AuditEvent, shownLines: Int = Config().resolved.shownOutputLines
    )
        -> [String: JSONValue]
    {
        var fields: [String: JSONValue] = [
            "kind": .string(event.kind.rawValue), "call": event.call.map { .string($0) } ?? .null,
            "turn": event.turn.map { .int($0) } ?? .null, "details": .object(event.details),
            "text": ChatEvents.render(event, style: .plain).map { .string($0) } ?? .null,
        ]
        if event.kind == .toolResult, let output = event.details["output"]?.stringValue {
            let text = Paging.page(output, number: 1)?.text ?? ""
            var lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
            if output.hasSuffix("\n") { lines -= 1 }
            fields["output"] = .object([
                "id": event.id.map { .string($0) } ?? .null, "text": .string(text), "lines": .int(lines),
                "bytes": .int(output.utf8.count), "truncated": .bool(text.utf8.count < output.utf8.count),
                "shownLines": .int(shownLines),
            ])
        }
        return fields
    }

    /// The `view` line's fields: a view a chat command shows whole (`/inspect context next`, `N`, or `turns`), for a front end that shows
    /// it in a panel of its own rather than in the transcript.
    public static func view(_ view: ChatView) -> [String: JSONValue] {
        [
            "kind": .string(view.kind.rawValue), "turn": view.turn.map { .int($0) } ?? .null,
            "turns": .int(view.turns), "text": .string(view.text),
        ]
    }

    /// The `activity` line's fields: what the turn under way is doing (`doing`, such as `running git
    /// status`), whether a person is being asked, and the seconds since the turn began; `doing` is null
    /// when the turn has ended. A front end times the rest itself.
    public static func activity(_ state: ChatActivity.State?) -> [String: JSONValue] {
        guard let state else { return ["doing": .null] }
        return [
            "doing": .string(state.doing), "asking": .bool(state.asking),
            "turnSeconds": .double(state.since.timeIntervalSince(state.turnStarted)),
        ]
    }

    /// The `turn` line's fields: `phase` `start` or `end`, the turn number, and at the end the seconds
    /// taken, the `outcome`, `ok` or `error`, and `inputTokens` and `outputTokens` when the model reports them.
    public static func turn(_ mark: ChatTurn) -> [String: JSONValue] {
        switch mark {
        case .start(let turn):
            return ["phase": "start", "turn": .int(turn)]
        case .end(let turn, let seconds, let failed, let tokens):
            var fields: [String: JSONValue] = [
                "phase": "end", "turn": .int(turn), "seconds": .double(seconds), "outcome": failed ? "error" : "ok",
            ]
            if let tokens {
                fields["inputTokens"] = .int(tokens.input)
                fields["outputTokens"] = .int(tokens.output)
            }
            return fields
        }
    }

    /// The `choice` line's fields: its id, title, options, the current value, and whether typed text
    /// is taken.
    public static func choice(id: String, _ choice: ChatChoice) -> [String: JSONValue] {
        [
            "id": .string(id), "title": .string(choice.title), "current": choice.current.map { .string($0) } ?? .null,
            "acceptsText": .bool(choice.acceptsText),
            "options": .array(
                choice.options.map {
                    .object(["value": .string($0.value), "label": .string($0.label), "detail": .string($0.detail)])
                }),
        ]
    }

    /// Asks the front end a choice and waits for its `choose` answer, bounded by `timeout`; silence, an
    /// empty value, or a lapsed wait is no answer.
    public static func ask(
        _ choice: ChatChoice, router: LineRouter, timeout: Duration?, send: @Sendable (String) -> Void
    ) async -> String? {
        let id = ShortID.make()
        send(encode("choice", Self.choice(id: id, choice)))
        let answer = try? await Timeout.run(timeout) { await router.answer(for: id) }
        return answer.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The `completions` line's fields.
    public static func completions(id: String, _ result: ChatCompletion.Result) -> [String: JSONValue] {
        ["id": .string(id), "from": .int(result.from), "candidates": .array(result.candidates.map { .string($0) })]
    }

    /// The `approval` line's fields.
    public static func approval(id: String, _ request: ApprovalRequest) -> [String: JSONValue] {
        [
            "id": .string(id), "command": .string(request.command), "line": .string(request.line),
            "pattern": .string(request.pattern), "directory": .string(request.workingDirectory),
            "level": .string(request.assessment.level.rawValue),
            "reasons": .array(request.assessment.reasons.map { .string($0) }),
        ]
    }
}

/// Routes the front end's lines: messages queue for the chat loop, answers resume whoever is waiting
/// for that approval. Fed from a reader thread; read by the loop and by `JSONApprover`.
public final class LineRouter: Sendable {
    private struct State {
        var messages: [String] = []
        var closed = false
        var waiting: [String: CheckedContinuation<String, Never>] = [:]
        var early: [String: String] = [:]
    }
    private let state = Mutex(State())
    private let available = DispatchSemaphore(value: 0)
    private let completer = Mutex<(@Sendable (String, String, Int?) -> Void)?>(nil)

    /// Sets what answers `complete` requests: called with the id, the text, and the cursor, off the
    /// chat loop, which may be waiting for input meanwhile.
    public func onComplete(_ handle: @escaping @Sendable (String, String, Int?) -> Void) {
        completer.withLock { $0 = handle }
    }

    /// Creates an empty router.
    public init() {}

    /// Takes one line from the front end.
    public func receive(_ line: String) {
        switch ChatProtocol.Inbound(line: line) {
        case .message(let text):
            state.withLock { $0.messages.append(text) }
            available.signal()
        case .complete(let id, let text, let cursor):
            completer.withLock { $0 }?(id, text, cursor)
        case .answer(let id, let decision):
            let waiter = state.withLock { state -> CheckedContinuation<String, Never>? in
                if let waiter = state.waiting.removeValue(forKey: id) { return waiter }
                state.early[id] = decision
                return nil
            }
            waiter?.resume(returning: decision)
        }
    }

    /// Marks the input closed; `nextMessage` returns nil once the queue drains.
    public func close() {
        state.withLock { $0.closed = true }
        available.signal()
    }

    /// The next message, blocking until one arrives; nil after `close` when none are queued.
    public func nextMessage() -> String? {
        while true {
            available.wait()
            let next: String?? = state.withLock { state in
                if !state.messages.isEmpty { return .some(state.messages.removeFirst()) }
                return state.closed ? .some(nil) : nil
            }
            if let next { return next }
        }
    }

    /// The decision for approval `id`, waiting for the front end's answer.
    public func answer(for id: String) async -> String {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> String? in
                if let decision = state.early.removeValue(forKey: id) { return decision }
                state.waiting[id] = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }
    }
}

/// Asks the front end through the protocol and waits for its answer, bounded by `timeout`.
public struct JSONApprover: Approver {
    private let router: LineRouter
    private let send: @Sendable (String) -> Void
    private let timeout: Duration?

    /// Creates an approver.
    ///
    /// - Parameters:
    ///   - router: Where answers arrive.
    ///   - timeout: How long to wait; nil waits forever.
    ///   - send: Writes one protocol line to the front end.
    public init(router: LineRouter, timeout: Duration?, send: @escaping @Sendable (String) -> Void) {
        self.router = router
        self.timeout = timeout
        self.send = send
    }

    /// Sends the request and maps the answer; silence within the timeout is unanswered.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        let id = ShortID.make()
        send(ChatProtocol.encode("approval", ChatProtocol.approval(id: id, request)))
        let router = router
        do {
            let decision = try await Timeout.run(timeout) { await router.answer(for: id) }
            return TerminalApprover.parse(decision)
        } catch Timeout.Failure.elapsed(let waited) {
            return .unanswered(waited)
        } catch {
            return .denied("approval request failed: \(error)")
        }
    }
}
