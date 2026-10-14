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
/// `completions` (the answer to a `complete`), `notify` (a notification for the front end to post, only
/// when its `hello` declared `notify`), `withdrawn` (an approval or choice the front end was shown that no
/// longer waits: answered another way, or its wait lapsed), `exit`. A front end whose `hello` declares `approve-mcp` is also sent the
/// commands waiting for approval in `wisp mcp` servers, as `approval` lines with `source: "mcp"` (ADR 0046),
/// and one that declares `keep-facts` the facts their callers asked to keep, as `approval` lines with
/// `kind: "fact"`, answered `keep` or `drop` (ADR 0048). Inbound: `hello` (the first line, optional: the effects the
/// front end carries, ADR 0044), `message` (a chat line, slash commands included), `answer` (to an
/// approval, by id), `choose` (to a choice, by id; no value is no answer), and `complete` (the input line
/// and cursor to complete, by id; the cursor and the reply's `from` count Unicode scalars), `interrupt` (Ctrl-C
/// while a command the person typed runs: stop it, ADR 0049 amended 2026-10-09), and `output` (a page of a tool's
/// output whole, by its event's id, answered with a `view` of kind `output`, ADR 0050). A line of a type not listed
/// here is ignored and reported once on the diagnostics channel.
public enum ChatProtocol {
    /// What a front end declared in its `hello`: the host effects it carries (`approve`, `notify`), and
    /// who it is.
    public struct Hello: Equatable, Sendable {
        /// The effects, as sent; unknown ones are kept and ignored.
        public var effects: [String]
        /// The front end's name, such as `wisp-tui`.
        public var client: String?
        /// Its version.
        public var version: String?

        /// Creates a declaration.
        public init(effects: [String], client: String? = nil, version: String? = nil) {
            self.effects = effects
            self.client = client
            self.version = version
        }

        /// Whether it declared `effect`.
        public func declares(_ effect: String) -> Bool { effects.contains(effect) }
    }

    /// What the front end sends.
    public enum Inbound: Equatable, Sendable {
        /// The front end's declaration of the effects it carries.
        case hello(Hello)
        /// A chat input line.
        case message(String)
        /// An answer to an approval request: `once`, `session`, `project`, `always`, or `no`.
        case answer(id: String, decision: String)
        /// A request to complete the input line at a cursor, counted in Unicode scalars (`ChatCompletion`).
        case complete(id: String, text: String, cursor: Int?)
        /// Ctrl-C in the front end while a command the person typed runs: stop it, or kill it when it was asked
        /// to stop before (`ChatInterrupt`); with none running it does nothing.
        case interrupt
        /// A request for page `page` (from 1) of the output the event `id` recorded, whole (ADR 0050): of the audit
        /// `session` named, or the conversation's own when nil. Answered with a `view` of kind `output`.
        case output(id: String, session: String?, page: Int)
        /// A typed line of a type this version does not know: ignored, so a newer front end's line does not
        /// arrive as an empty message.
        case unknown(type: String)

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
            case "hello":
                self = .hello(
                    Hello(
                        effects: object["effects"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                        client: object["client"]?.stringValue, version: object["version"]?.stringValue))
            case "answer":
                self = .answer(id: object["id"]?.stringValue ?? "", decision: object["decision"]?.stringValue ?? "no")
            case "complete":
                self = .complete(
                    id: object["id"]?.stringValue ?? "", text: object["text"]?.stringValue ?? "",
                    cursor: object["cursor"]?.intValue)
            case "choose":
                // A choice with toggles is answered with the values left on (ADR 0056); a plain one with a value.
                let values = object["values"]?.arrayValue.map { $0.compactMap(\.stringValue) }
                self = .answer(
                    id: object["id"]?.stringValue ?? "",
                    decision: values.map(ChatChoice.answer(values:)) ?? object["value"]?.stringValue ?? "")
            case "message":
                self = .message(object["text"]?.stringValue ?? "")
            case "interrupt":
                self = .interrupt
            case "output":
                self = .output(
                    id: object["id"]?.stringValue ?? "", session: object["session"]?.stringValue,
                    page: object["page"]?.intValue ?? 1)
            default:
                self = .unknown(type: type)
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
    /// activity alike and a front end renders the raw fields only when it wants to. A `tool.result`, and a
    /// `command.typed` whose command printed something (ADR 0049), and a `model.reasoning` that ends a stretch of
    /// thinking (ADR 0053), with the thinking as its text, also carries `output`, the output for the
    /// front end to show (decision D12): its `id` (the event's,
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
        if let output = ChatEvents.shownText(of: event), event.kind == .toolResult || !output.isEmpty {
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

    /// The `view` line answering an `output` request, or showing an output `/show` or `/last` asks for: kind `output`,
    /// the event's `id` and `session` to ask for other pages by, `page` (from 1) of `pages`, `text` (that page,
    /// `ChatOutput.pageBytes` at most but for a line longer than a page; the pages joined are the output exactly),
    /// `header` (the line saying what it is, `ChatOutput.header`), `source` (`stored`, the whole from the output
    /// store; `returned`, nothing was held back; `not-kept`, held back with no store; `gone`, no longer in the
    /// store), and for `stored` the record's `bytes`, `lines`, `cut`, and `totalBytes`, else the returned text's
    /// `bytes` and `lines`. A page out of range has `pages` with no `text`, and an unknown id `pages` 0 and a header
    /// saying so.
    ///
    /// - Parameters:
    ///   - output: The output, or nil when the id names none.
    ///   - id: The event's id, as asked.
    ///   - session: The event's audit session.
    ///   - page: The page asked for.
    /// - Returns: The fields.
    public static func outputView(
        _ output: ChatOutput?, id: String, session: String?, page: Int
    )
        -> [String: JSONValue]
    {
        var fields: [String: JSONValue] = [
            "kind": "output", "id": .string(id), "session": session.map { .string($0) } ?? .null, "page": .int(page),
            "turn": .null, "turns": .int(0),
        ]
        guard let output else {
            fields["pages"] = .int(0)
            fields["text"] = ""
            fields["header"] = .string("no tool output \(id) here: the audit may be off, or the event rotated out")
            fields["source"] = "missing"
            return fields
        }
        fields["header"] = .string(output.header)
        fields["source"] = .string(output.sourceName)
        if case .stored(let kept) = output.whole {
            fields["bytes"] = .int(kept.bytes)
            fields["lines"] = .int(kept.lines)
            fields["cut"] = .bool(kept.cut)
            fields["totalBytes"] = .int(kept.totalBytes)
        } else {
            fields["bytes"] = .int(output.returned.utf8.count)
            fields["lines"] = .int(ChatOutput.lineCount(output.returned))
        }
        if let shown = output.page(page) {
            fields["pages"] = .int(shown.count)
            fields["text"] = .string(shown.text)
        } else {
            fields["pages"] = .int(output.page(1)?.count ?? 0)
        }
        return fields
    }

    /// The `activity` line's fields: what the turn under way is doing (`doing`, such as `running git
    /// status`), whether a person is being asked, and the seconds since the turn began; `doing` is null
    /// when the turn has ended. While the model thinks, `doing` is `thinking` and `thinking` is true (ADR 0053), for a
    /// front end that draws it its own way; the field is absent otherwise. While a command the person typed runs,
    /// `stoppable` is true (an `interrupt` line stops it), and once it was asked to stop, `stopping` is true instead
    /// (ADR 0049, amended 2026-10-09); both are absent otherwise. A front end times the rest itself.
    public static func activity(_ state: ChatActivity.State?) -> [String: JSONValue] {
        guard let state else { return ["doing": .null] }
        var fields: [String: JSONValue] = [
            "doing": .string(state.doing), "asking": .bool(state.asking),
            "turnSeconds": .double(state.since.timeIntervalSince(state.turnStarted)),
        ]
        if state.thinking { fields["thinking"] = true }
        if state.stoppable { fields["stoppable"] = true }
        if state.stopping { fields["stopping"] = true }
        return fields
    }

    /// The `turn` line's fields: `phase` `start` or `end`, the turn number, and at the end the seconds
    /// taken, the `outcome`, `ok` or `error`, `inputTokens` and `outputTokens` when the model reports them, and
    /// `facts` when the turn recorded or changed any (`FactReport.newFactsJSON`); the same facts are also sent as
    /// a `note` line, which is what a front end shows. `ran`, when present, is the line of what the turn ran, from
    /// its audit events (`TurnToolSummary`, ADR 0051), for the front end to show under the reply; it is sent
    /// nowhere else. `cited`, when present, is the line naming the entries the reply cites that the conversation
    /// does not hold (`CitedEntries`, ADR 0055), shown beside it; `verified`, when present, the line for a result
    /// claim the turn's calls do not support (`ReplyVerification`, ADR 0060), shown after it.
    public static func turn(_ mark: ChatTurn) -> [String: JSONValue] {
        switch mark {
        case .start(let turn):
            return ["phase": "start", "turn": .int(turn)]
        case .end(let turn, let seconds, let failed, let tokens, let facts, let ran, let cited, let verified):
            var fields: [String: JSONValue] = [
                "phase": "end", "turn": .int(turn), "seconds": .double(seconds), "outcome": failed ? "error" : "ok",
            ]
            if let tokens {
                fields["inputTokens"] = .int(tokens.input)
                fields["outputTokens"] = .int(tokens.output)
            }
            if !facts.isEmpty { fields["facts"] = FactReport.newFactsJSON(facts) }
            if let ran { fields["ran"] = .string(ran) }
            if let cited { fields["cited"] = .string(cited) }
            if let verified { fields["verified"] = .string(verified) }
            return fields
        }
    }

    /// The `choice` line's fields: its id, title, options, the current value, and whether typed text
    /// is taken. A choice with toggles (ADR 0056) adds `toggles` (true), `columns` (each `heading` and `drop`, the
    /// rank in which a narrow face drops it, 0 never), and on each option `cells` (one per column) and `on`; an action
    /// row (ADR 0059's "pull a model…") has `action` true and no `on`, and choosing it answers with its `value`. The
    /// model's question (ADR 0062) adds `kind` `question` and `thread`, and one relayed from a `wisp mcp` server
    /// `source` `mcp`, `client`, and `request` as well.
    public static func choice(id: String, _ choice: ChatChoice) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(id), "title": .string(choice.title), "current": choice.current.map { .string($0) } ?? .null,
            "acceptsText": .bool(choice.acceptsText),
            "options": .array(
                choice.options.map { option in
                    var fields: [String: JSONValue] = [
                        "value": .string(option.value), "label": .string(option.label),
                        "detail": .string(option.detail),
                    ]
                    if let on = option.on {
                        fields["on"] = .bool(on)
                        fields["cells"] = .array(option.cells.map { .string($0) })
                    }
                    if option.action { fields["action"] = true }
                    return .object(fields)
                }),
        ]
        if choice.toggles {
            fields["toggles"] = true
            fields["columns"] = .array(
                choice.columns.map { .object(["heading": .string($0.heading), "drop": .int($0.drop)]) })
        }
        if let kind = choice.kind { fields["kind"] = .string(kind) }
        if let origin = choice.origin {
            if let thread = origin.thread { fields["thread"] = .string(thread) }
            if let source = origin.source { fields["source"] = .string(source) }
            if let client = origin.client { fields["client"] = .string(client) }
            if let request = origin.request { fields["request"] = .string(request) }
        }
        return fields
    }

    /// Asks the front end a choice and waits for its `choose` answer, bounded by `timeout`; silence, an
    /// empty value, or a lapsed wait is no answer.
    public static func ask(
        _ choice: ChatChoice, router: LineRouter, timeout: Duration?, send: @Sendable (String) -> Void
    ) async -> String? {
        let id = ShortID.make()
        send(encode("choice", Self.choice(id: id, choice)))
        do {
            let answer = try await Timeout.run(timeout) { await router.answer(for: id) }
            return answer.isEmpty ? nil : answer
        } catch {
            withdraw(id, router: router, send: send)
            return nil
        }
    }

    /// Gives up on a question the front end was shown (an approval or a choice) whose wait lapsed: its waiter
    /// is dropped, so a late answer goes nowhere, and the front end is sent `withdrawn` so it closes the
    /// dialog or picker rather than take an answer nobody reads.
    ///
    /// - Parameters:
    ///   - id: The question's protocol id.
    ///   - router: Where its answer would have arrived.
    ///   - send: Writes one protocol line.
    static func withdraw(_ id: String, router: LineRouter, send: @Sendable (String) -> Void) {
        router.withdraw(id)
        send(encode("withdrawn", ["id": .string(id)]))
    }

    /// The `completions` line's fields.
    public static func completions(id: String, _ result: ChatCompletion.Result) -> [String: JSONValue] {
        ["id": .string(id), "from": .int(result.from), "candidates": .array(result.candidates.map { .string($0) })]
    }

    /// The `notify` line's fields: the notification as `Notifier` bounded it, for the front end to post.
    public static func notify(_ message: Notifier.Message) -> [String: JSONValue] {
        [
            "title": .string(message.title), "subtitle": message.subtitle.map { .string($0) } ?? .null,
            "body": .string(message.body), "sound": .bool(message.sound),
        ]
    }

    /// The `approval` line's fields; `outsideSandbox` (true) for a line the model asked to run outside the sandbox,
    /// which is approved once or not at all (ADR 0064).
    public static func approval(id: String, _ request: ApprovalRequest) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(id), "command": .string(request.command), "line": .string(request.line),
            "pattern": .string(request.pattern), "directory": .string(request.workingDirectory),
            "level": .string(request.assessment.level.rawValue),
            "reasons": .array(request.assessment.reasons.map { .string($0) }),
        ]
        if request.outsideSandbox { fields["outsideSandbox"] = true }
        return fields
    }

    /// The `approval` line for a request waiting in a `wisp mcp` server: the usual fields, with `source`
    /// `mcp`, the `thread` and `client` it came from, and the pending request's id. A fact to keep (ADR 0048)
    /// has `kind` `fact` and the `fact` (`id`, `subject`, `name`, `value`, `source`); its `command` and `line`
    /// are the fact as one line, so a front end that shows only those still names it, and it is answered
    /// `keep` or `drop`.
    public static func approval(id: String, pending request: PendingApprovals.Request) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(id), "command": .string(request.subject),
            "line": .string(request.kind == .fact ? request.subject : request.line),
            "pattern": .string(request.pattern), "directory": .string(request.directory),
            "level": .string(request.level.rawValue), "reasons": .array(request.reasons.map { .string($0) }),
            "source": .string("mcp"), "thread": request.thread.map { .string($0) } ?? .null,
            "client": request.client.map { .string($0) } ?? .null, "request": .string(request.id),
        ]
        if request.outsideSandbox == true { fields["outsideSandbox"] = true }
        if request.kind == .fact, let fact = request.fact {
            fields["kind"] = .string(request.kind.rawValue)
            fields["fact"] = .object([
                "id": .string(fact.id), "subject": .string(fact.subject), "name": .string(fact.name),
                "value": .string(fact.value), "source": .string(fact.source),
            ])
        }
        return fields
    }
}

/// Routes the front end's lines: messages queue for the chat loop, answers resume whoever is waiting
/// for that approval. Fed from a reader thread; read by the loop and by `JSONApprover`.
public final class LineRouter: Sendable {
    private struct State {
        var messages: [String] = []
        var closed = false
        var waiting: [String: CheckedContinuation<String?, Never>] = [:]
        /// Answers that arrived before their waiter registered (a relay shows a request, then starts waiting),
        /// oldest first, at most `LineRouter.earlyLimit`: an answer for an id nobody ever waits for is not kept
        /// for ever.
        var early: [(id: String, decision: String)] = []
        /// Ids withdrawn, newest last, at most `LineRouter.tombstoneLimit`: a waiter that registers after its id
        /// was withdrawn gets nil at once instead of waiting for ever, and a late answer is dropped.
        var withdrawn: [String] = []

        /// Keeps an early answer, dropping the oldest beyond the bound.
        mutating func keepEarly(_ id: String, _ decision: String) {
            early.removeAll { $0.id == id }
            early.append((id, decision))
            if early.count > LineRouter.earlyLimit { early.removeFirst(early.count - LineRouter.earlyLimit) }
        }

        /// Takes the early answer for `id`, if one arrived.
        mutating func takeEarly(_ id: String) -> String? {
            guard let index = early.firstIndex(where: { $0.id == id }) else { return nil }
            return early.remove(at: index).decision
        }

        /// Remembers that `id` was withdrawn, dropping the oldest tombstone beyond the bound.
        mutating func tombstone(_ id: String) {
            guard !withdrawn.contains(id) else { return }
            withdrawn.append(id)
            if withdrawn.count > LineRouter.tombstoneLimit {
                withdrawn.removeFirst(withdrawn.count - LineRouter.tombstoneLimit)
            }
        }
    }

    /// How many answers for ids nobody waits for yet are kept.
    static let earlyLimit = 32
    /// How many withdrawn ids are remembered.
    static let tombstoneLimit = 256

    private let state = Mutex(State())
    private let available = DispatchSemaphore(value: 0)
    private let completer = Mutex<(@Sendable (String, String, Int?) -> Void)?>(nil)
    private let interrupter = Mutex<(@Sendable () -> Void)?>(nil)
    private let outputs = Mutex<(@Sendable (String, String?, Int) -> Void)?>(nil)
    private let declared = Mutex<ChatProtocol.Hello?>(nil)
    private let greeted = Mutex<(@Sendable (ChatProtocol.Hello) -> Void)?>(nil)
    /// The unknown line types already reported, so each is reported once (at most 32 of them).
    private let unknownTypes = Mutex<Set<String>>([])

    /// What the front end declared in its `hello`; nil when it sent none, which keeps today's behaviour:
    /// approvals over the protocol, notifications posted by wisp.
    public var hello: ChatProtocol.Hello? { declared.withLock { $0 } }

    /// Whether the front end's `hello` declared `effect`; false when it sent no `hello`.
    public func declares(_ effect: String) -> Bool { hello?.declares(effect) ?? false }

    /// Sets what is told of a `hello` when it arrives, such as the audit.
    public func onHello(_ handle: @escaping @Sendable (ChatProtocol.Hello) -> Void) {
        greeted.withLock { $0 = handle }
    }

    /// Sets what answers `complete` requests: called with the id, the text, and the cursor, off the
    /// chat loop, which may be waiting for input meanwhile.
    public func onComplete(_ handle: @escaping @Sendable (String, String, Int?) -> Void) {
        completer.withLock { $0 = handle }
    }

    /// Sets what an `interrupt` line does, off the chat loop, which is waiting on the command meanwhile.
    public func onInterrupt(_ handle: @escaping @Sendable () -> Void) {
        interrupter.withLock { $0 = handle }
    }

    /// Sets what answers `output` requests: called with the event id, the session, and the page, off the chat loop.
    public func onOutput(_ handle: @escaping @Sendable (String, String?, Int) -> Void) {
        outputs.withLock { $0 = handle }
    }

    /// Creates an empty router.
    public init() {}

    /// Takes one line from the front end.
    public func receive(_ line: String) {
        switch ChatProtocol.Inbound(line: line) {
        case .hello(let hello):
            declared.withLock { $0 = hello }
            greeted.withLock { $0 }?(hello)
        case .message(let text):
            state.withLock { $0.messages.append(text) }
            available.signal()
        case .complete(let id, let text, let cursor):
            completer.withLock { $0 }?(id, text, cursor)
        case .interrupt:
            interrupter.withLock { $0 }?()
        case .output(let id, let session, let page):
            outputs.withLock { $0 }?(id, session, page)
        case .unknown(let type):
            // Said once per type, on the diagnostics channel: stdout is the protocol.
            let first = unknownTypes.withLock { seen in
                guard seen.count < 32 else { return false }
                return seen.insert(type).inserted
            }
            if first { Diagnostics.chat.error("ignoring front-end lines of unknown type \(type)") }
        case .answer(let id, let decision):
            let waiter = state.withLock { state -> CheckedContinuation<String?, Never>? in
                if let waiter = state.waiting.removeValue(forKey: id) { return waiter }
                if !state.withdrawn.contains(id) { state.keepEarly(id, decision) }  // a withdrawn id's answer is late
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

    /// The decision for approval `id`, waiting for the front end's answer; a withdrawn approval is `no`.
    public func answer(for id: String) async -> String {
        await answerUnlessWithdrawn(for: id) ?? "no"
    }

    /// The decision for approval `id`, waiting for the front end's answer, or nil once `withdraw(id)` is called,
    /// before or while it waits.
    public func answerUnlessWithdrawn(for id: String) async -> String? {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> String?? in
                if state.withdrawn.contains(id) { return .some(nil) }
                if let decision = state.takeEarly(id) { return .some(decision) }
                state.waiting[id] = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }
    }

    /// Stops waiting for an answer to approval `id`: whoever waits gets nil, a wait that starts later gets nil
    /// at once, and a later answer is dropped.
    public func withdraw(_ id: String) {
        let waiter = state.withLock { state -> CheckedContinuation<String?, Never>? in
            _ = state.takeEarly(id)
            state.tombstone(id)
            return state.waiting.removeValue(forKey: id)
        }
        waiter?.resume(returning: nil)
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

    /// Sends the request and maps the answer; silence within the timeout is unanswered, and the front end is
    /// sent `withdrawn` for it, so it closes the dialog. A front end whose
    /// `hello` did not declare `approve` cannot ask, so the request is denied without being sent.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        if router.hello != nil, !router.declares("approve") {
            return .denied("the front end declared no approve effect in its hello")
        }
        let id = ShortID.make()
        send(ChatProtocol.encode("approval", ChatProtocol.approval(id: id, request)))
        let router = router
        do {
            let decision = try await Timeout.run(timeout) { await router.answer(for: id) }
            return TerminalApprover.parse(decision)
        } catch Timeout.Failure.elapsed(let waited) {
            ChatProtocol.withdraw(id, router: router, send: send)
            return .unanswered(waited)
        } catch {
            ChatProtocol.withdraw(id, router: router, send: send)
            return .denied("approval request failed: \(error)")
        }
    }
}

/// Asks the model's question through the protocol ([ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md)):
/// a `choice` line with `kind` `question` (the options, then `none of these`; typed text for a free-text question),
/// answered by `choose`. Waits as long as the person takes unless a deadline is set (`inquiry.timeoutSeconds`), and
/// the turn's stop (`interrupt`, Ctrl-C in `wisp-tui`) withdraws it; a lapsed or withdrawn question is sent
/// `withdrawn`, so the front end closes the picker.
public struct JSONAsker: Asker {
    private let router: LineRouter
    private let send: @Sendable (String) -> Void

    /// Creates an asker.
    ///
    /// - Parameters:
    ///   - router: Where answers arrive.
    ///   - send: Writes one protocol line to the front end.
    public init(router: LineRouter, send: @escaping @Sendable (String) -> Void) {
        self.router = router
        self.send = send
    }

    /// The protocol.
    public var ways: [String] { ["json"] }

    /// Sends the choice and maps the answer: no value or an empty one declines, `none of these` is none, an option
    /// is chosen, and for a free-text question anything else is the answer.
    public func ask(_ question: Question, box: InquiryBox, audit: AuditLog?) async -> Question.Reply {
        let id = ShortID.make()
        send(ChatProtocol.encode("choice", ChatProtocol.choice(id: id, question.choice)))
        let router = router
        let send = send
        let stop = TurnStop.current
        // A stop asked for while the question waits drops its waiter, so the wait ends at once; the front end is then
        // sent `withdrawn`, so it closes the picker.
        let stopping = stop.map { stop in
            Task {
                await stop.stopped()
                router.withdraw(id)
            }
        }
        defer { stopping?.cancel() }
        do {
            let answer = try await Timeout.run(question.timeout) { await router.answerUnlessWithdrawn(for: id) }
            if stop?.requested == true {
                ChatProtocol.withdraw(id, router: router, send: send)
                return Question.Reply(.stopped)
            }
            guard let answer, !answer.isEmpty else { return Question.Reply(.declined, via: "json") }
            return Question.Reply(question.outcome(typed: answer) ?? .declined, via: "json")
        } catch {
            ChatProtocol.withdraw(id, router: router, send: send)
            if stop?.requested == true { return Question.Reply(.stopped) }
            return Question.Reply(.unanswered(question.timeout ?? .zero))
        }
    }
}
