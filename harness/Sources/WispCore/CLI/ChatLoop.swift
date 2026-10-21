import Foundation
import FoundationModels
import Synchronization

/// The edges of one turn: a message to the model and everything it does to answer it.
public enum ChatTurn: Equatable, Sendable {
    /// The message has gone to the model; `turn` is the number its audit events carry.
    case start(turn: Int)
    /// The reply is complete, or the turn failed with the error noted before this. `tokens` is what the
    /// turn's requests used, when the model reports it; `facts` are the ones the turn recorded or changed;
    /// `ran` is what the turn ran, from its audit events (`TurnToolSummary`, ADR 0051), nil when there is
    /// nothing to show; `cited` names the entries the reply cites that the conversation does not hold
    /// (`CitedEntries`, ADR 0055), nil when there are none; `verified` is the line for a result claim the turn's
    /// calls do not support (`ReplyVerification`, ADR 0060), nil when there is none.
    case end(
        turn: Int, seconds: Double, failed: Bool, tokens: TurnTokens? = nil, facts: [Fact] = [], ran: String? = nil,
        cited: String? = nil, verified: String? = nil)

    /// The lines under a reply in the terminal chat, muted: what the turn ran, when there is a line for it
    /// (ADR 0051), the entries it cited that do not exist (ADR 0055), a claim its calls do not support (ADR 0060),
    /// and how long the turn took and, when the model reports them, the tokens it read (↓, pale yellow) and wrote
    /// (↑, pale blue). Nil for a turn's start.
    public func footer(style: Style) -> String? {
        guard case .end(_, let seconds, let failed, let tokens, _, let ran, let cited, let verified) = self else {
            return nil
        }
        var parts = [failed ? "failed after \(String(format: "%.1f", seconds)) s" : String(format: "%.1f s", seconds)]
        if let tokens {
            // No rate: the turn's time includes its commands and approvals, so tokens over it is not the
            // model's speed.
            parts.append(
                style.tokensIn("↓\(tokens.input.formatted())") + " " + style.tokensOut("↑\(tokens.output.formatted())"))
        }
        let notes = [ran, cited, verified].compactMap { $0 }.map { "  " + style.muted($0) + "\n" }.joined()
        return notes + "  "
            + parts.enumerated().map { $0.offset == 0 ? style.muted($0.element) : $0.element }
            .joined(separator: style.muted(" · "))
    }
}

/// The tokens one turn used, across every request its tool loop made.
public struct TurnTokens: Equatable, Sendable {
    /// Prompt tokens read, the transcript included each time.
    public var input: Int
    /// Tokens written.
    public var output: Int
    /// Of `input`, the tokens the runtime reused from its cache rather than processed again (Ollama reports none;
    /// MLX under wisp's executor reports the reused prefix).
    public var cached: Int = 0
    /// Of `output`, the tokens spent thinking, as the runtime counted them.
    public var reasoning: Int = 0

    /// Creates a count.
    public init(input: Int, output: Int, cached: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cached = cached
        self.reasoning = reasoning
    }

    /// The difference between two readings of a session's running totals, or nil when the model
    /// reported nothing.
    public static func between(_ before: TurnTokens, _ after: TurnTokens) -> TurnTokens? {
        let used = TurnTokens(
            input: max(0, after.input - before.input), output: max(0, after.output - before.output),
            cached: max(0, after.cached - before.cached), reasoning: max(0, after.reasoning - before.reasoning))
        return used.input == 0 && used.output == 0 ? nil : used
    }

    /// The count as `respond`'s receipt and the `response` audit event carry it.
    public var json: JSONValue {
        .object(["input": .int(input), "output": .int(output), "cached": .int(cached), "reasoning": .int(reasoning)])
    }

    /// The count `json` wrote, or nil when `value` is not one.
    ///
    /// - Parameter value: The JSON.
    public init?(json value: JSONValue?) {
        guard let object = value?.objectValue, let input = object["input"]?.intValue,
            let output = object["output"]?.intValue
        else { return nil }
        self.init(
            input: input, output: output, cached: object["cached"]?.intValue ?? 0,
            reasoning: object["reasoning"]?.intValue ?? 0)
    }
}

/// The `wisp chat` read-eval-print loop over an agent, with its input and output injected so the
/// whole loop runs in tests over a scripted model. The CLI supplies the terminal; tests supply lines.
///
/// Messages go to the model and stream to `io.write`; `/` lines are `ChatInput` commands. Replies
/// print to stdout, everything else is a note on stderr, so stdout stays clean for the replies. Tool
/// activity arrives through a `ChatEvents.Tap` attached to the conversation and is shown as it happens;
/// a `ChatStatus` line is drawn above each prompt.
public struct ChatLoop {
    /// Where the loop reads and writes.
    public struct IO {
        /// The next line, or nil at end of input.
        public var readLine: () -> String?
        /// A whole line of reply text to stdout.
        public var print: (String) -> Void
        /// A fragment of streamed reply text, no newline, flushed.
        public var write: (String) -> Void
        /// A status line for the user, kept off stdout. Sendable: tool events arrive from the tool loop.
        public var note: @Sendable (String) -> Void
        /// The prompt, on a fresh line, with the status above it; the IO renders the status.
        public var prompt: (ChatStatus) -> Void
        /// A turn's start and end, for a face that shows when the model is working; the terminal
        /// ignores them, since its prompt returning says as much.
        public var turn: (ChatTurn) -> Void
        /// Offers a choice and returns the answer, nil for none; nil here asks with a numbered list
        /// through `print` and `readLine`.
        public var choose: ((ChatChoice) async -> String?)?
        /// Shows a view whole, as a front end's panel does; nil prints its text through `print`.
        public var view: ((ChatView) -> Void)?
        /// Told the line as it was typed when it is a command the person runs (`!`, ADR 0049), before it runs; the
        /// terminal colours the line's prompt marker in the command colour, having no box to colour.
        public var command: (String) -> Void
        /// Shows an output `/show` or `/last` asks for the face's own way, its header with it: the terminal through
        /// its pager when standard output is a terminal, a front end in its expanded view (ADR 0050). Returns false
        /// when it did not, and the loop notes the header and prints the text; nil always prints.
        public var showOutput: ((ChatOutput) -> Bool)?
        /// Whether the loop sets each part of a turn apart with a blank line (`TurnParts`): the plain terminal chat's.
        /// A front end lays out its own scrollback, so `wisp chat --json` leaves it false.
        public var separatesParts: Bool

        /// Creates an IO.
        public init(
            readLine: @escaping () -> String?, print: @escaping (String) -> Void, write: @escaping (String) -> Void,
            note: @escaping @Sendable (String) -> Void, prompt: @escaping (ChatStatus) -> Void,
            turn: @escaping (ChatTurn) -> Void = { _ in }, choose: ((ChatChoice) async -> String?)? = nil,
            view: ((ChatView) -> Void)? = nil, command: @escaping (String) -> Void = { _ in },
            showOutput: ((ChatOutput) -> Bool)? = nil, separatesParts: Bool = false
        ) {
            self.separatesParts = separatesParts
            self.showOutput = showOutput
            self.choose = choose
            self.view = view
            self.command = command
            self.readLine = readLine
            self.print = print
            self.write = write
            self.note = note
            self.prompt = prompt
            self.turn = turn
        }
    }

    /// What the loop can find out beyond the agent: the status line's facts and the inspect views.
    public struct Context: Sendable {
        /// The working directory shown in the status line.
        public var directory: String
        /// The approval mode, from `ChatStatus.approvalMode`.
        public var approval: String
        /// Reads the version control, branch, and changes of a directory; the CLI passes `VersionControl.read`.
        public var vcs: @Sendable (String) -> VersionControl.Summary
        /// Told when a read off the prompt's path finds the version control changed since the status line was drawn,
        /// for a face that can redraw it (`VersionControlWatch`); nil leaves it to the next prompt.
        public var vcsChanged: (@Sendable (VersionControl.Summary) -> Void)?
        /// Answers `/inspect <what>`; nil makes the command unavailable.
        public var inspect: (@Sendable (String) async -> String)?
        /// A banner line for the start of the session.
        public var banner: String?
        /// The model actions `/models` and `/model` take, as the chat's (`ModelActions`, face `chat`; ADR 0059): the
        /// listing, turning models on and off, checking them, pulling, trusting, and the switch's check. Nil makes
        /// `/models` unavailable; `/model` then switches without the check `openModel` makes anyway.
        public var models: ModelActions?
        /// The terminal's width for a table, or nil when unknown, which aligns it without wrapping.
        public var width: @Sendable () -> Int?
        /// Notes shown once after the banner, such as the model chat fell back to (ADR 0056).
        public var notices: [String]
        /// Opens an agent on another model continuing the thread's record, for `/model`; nil makes it
        /// unavailable.
        public var openModel: (@Sendable (ModelSelection, ThreadRecord) throws -> Agent)?
        /// Opens an agent on a saved thread, for `/resume`: given the thread, locked, and the model and thinking the
        /// chat runs with now, which a chat's own thread takes and an agent's ignores for its own. Nil makes `/resume`
        /// unavailable.
        public var openThread: (@Sendable (ChatThread.Opening, ModelSelection, OllamaThink?) throws -> Agent)?
        /// The session's call store, for `/stats`; nil makes the command unavailable.
        public var stats: CallStats?
        /// The `config.json` that `/config set` and `unset` change; nil makes them unavailable.
        public var configFile: URL?
        /// The session's standing approvals, for `/approvals revoke`; nil makes it unavailable. The
        /// session's own store, so a revocation takes effect in this session at once.
        public var approvalStore: ApprovalStore?
        /// The answers a setting offers beyond its kind's own (the models this Mac can run, the Core ML
        /// models on disk); nil offers only those.
        public var configOptions: (@Sendable (ConfigSettings.Setting) async -> [ChatChoice.Option])?
        /// What the turn under way is doing, for the face's live line; nil shows none.
        public var activity: ChatActivity?
        /// Lines of each tool's output shown under its note before the rest is folded
        /// (`Config.Resolved.shownOutputLines`); 0 shows the note alone.
        public var shownOutputLines: Int
        /// Where the face's Ctrl-C goes while a command the person typed runs, which has no timeout (ADR 0049,
        /// amended 2026-10-09); nil leaves such a command to run to its end.
        public var interrupt: ChatInterrupt?
        /// The output stores' directory (`Home.outputs`), where `/show` and `/last` find the whole of an output the
        /// model was given only part of (ADR 0050); nil when the audit is off, so nothing is stored.
        public var outputs: URL?
        /// The requests waiting in `wisp mcp` servers, noted before each prompt and answered with
        /// `/approvals approve|deny` and `/facts keep|drop` (ADR 0046, note of 2026-10-12); nil shows none, as in
        /// `wisp-tui`, which has its own dialog for them.
        public var pending: ChatPending?

        /// Creates a context.
        public init(
            directory: String, approval: String,
            vcs: @escaping @Sendable (String) -> VersionControl.Summary = { _ in VersionControl.Summary() },
            vcsChanged: (@Sendable (VersionControl.Summary) -> Void)? = nil,
            inspect: (@Sendable (String) async -> String)? = nil, banner: String? = nil,
            models: ModelActions? = nil,
            width: @escaping @Sendable () -> Int? = { nil }, notices: [String] = [],
            openModel: (@Sendable (ModelSelection, ThreadRecord) throws -> Agent)? = nil,
            openThread: (@Sendable (ChatThread.Opening, ModelSelection, OllamaThink?) throws -> Agent)? = nil,
            stats: CallStats? = nil,
            configFile: URL? = nil,
            configOptions: (@Sendable (ConfigSettings.Setting) async -> [ChatChoice.Option])? = nil,
            approvalStore: ApprovalStore? = nil, activity: ChatActivity? = nil,
            shownOutputLines: Int = Config().resolved.shownOutputLines, interrupt: ChatInterrupt? = nil,
            outputs: URL? = nil, pending: ChatPending? = nil
        ) {
            self.outputs = outputs
            self.pending = pending
            self.interrupt = interrupt
            self.shownOutputLines = shownOutputLines
            self.approvalStore = approvalStore
            self.activity = activity
            self.configFile = configFile
            self.configOptions = configOptions
            self.directory = directory
            self.approval = approval
            self.vcs = vcs
            self.vcsChanged = vcsChanged
            self.inspect = inspect
            self.banner = banner
            self.models = models
            self.width = width
            self.notices = notices
            self.openModel = openModel
            self.openThread = openThread
            self.stats = stats
        }
    }

    /// The conversation; replaced by `/model`, which resumes the transcript on another model.
    public private(set) var agent: Agent
    /// The conversation's thread in the thread store, saved after every turn and held while the chat runs (ADR 0066,
    /// D11); nil keeps nothing, as in tests that do not look at it.
    public let thread: ChatThread?
    /// The tap the conversation was opened with; its events are rendered as they arrive.
    public let tap: ChatEvents.Tap
    /// The styling in force.
    public let style: Style
    /// The lines typed this session, oldest first, for `/history`: blank lines and a line repeating
    /// the one before it are not added, and only the latest `historyLimit` are kept.
    public private(set) var history: [String] = []
    /// How many lines `history` keeps.
    public static let historyLimit = 100
    /// The thinking `/think` chose this session, by model (`ModelSelection.description`): applied to the conversation
    /// whenever that model is in use, since the saved default it also writes is read only as a session starts.
    var thinkChoices: [String: OllamaThink] = [:]
    /// The directory's version control, read off the prompt's path.
    let vcsWatch: VersionControlWatch
    /// Which part of the turn on screen came last, for the blank line between parts (`IO.separatesParts`).
    let parts = TurnParts()
    let context: Context
    let io: IO

    /// Creates a loop over `agent`.
    ///
    /// - Parameters:
    ///   - agent: The conversation, already resumed if it should be, opened with `tap` observing.
    ///   - thread: Its thread in the thread store, opened and locked; nil saves nothing.
    ///   - tap: The sink the conversation's events reach; the loop sets its handler.
    ///   - context: Directory, approval mode, version control reader, inspect views, banner.
    ///   - style: Styling; `.plain` when piped.
    ///   - io: Input and output.
    public init(
        agent: Agent, thread: ChatThread? = nil, tap: ChatEvents.Tap = ChatEvents.Tap(), context: Context,
        style: Style = .plain, io: IO
    ) {
        self.agent = agent
        self.thread = thread
        self.tap = tap
        self.context = context
        vcsWatch = VersionControlWatch(directory: context.directory, read: context.vcs, changed: context.vcsChanged)
        self.style = style
        self.io = io
        let note = io.note
        let activity = context.activity
        let shown = context.shownOutputLines
        let parts = io.separatesParts ? parts : nil
        tap.onEvent { event in
            activity?.apply(event)
            if let line = ChatEvents.render(event, style: style, shownLines: shown) {
                if parts?.enter(.tool, starting: ChatEvents.startsPart(event)) == true { note("") }
                note(line)
            }
            if let output = ChatEvents.shownOutput(event, lines: shown, style: style) { note(output) }
        }
        // A note for this conversation, such as a background pull's end (ADR 0059), is shown as it arrives; the model
        // reads it with the next turn. `/model` keeps the conversation, and so the watch.
        if let conversation = agent.audit?.session {
            agent.notices?.watch(conversation) { note(style.muted($0)) }
        }
    }

    /// The status line for the next prompt, with the version control as last read (`VersionControlWatch`).
    public func status() async -> ChatStatus {
        let vcs = await vcsWatch.latest() ?? VersionControl.Summary()
        var used: Double?
        if let size = agent.contextSize, size > 0, let tokens = try? await agent.contextTokens() {
            used = min(1, Double(tokens) / Double(size))
        }
        return ChatStatus(
            model: agent.model.selection.description, directory: ChatStatus.abbreviated(context.directory),
            vcs: vcs.system?.rawValue, branch: vcs.branch, dirty: vcs.dirty, added: vcs.added, removed: vcs.removed,
            approval: context.approval,
            contextUsed: used, thinking: Self.thinkingShown(agent.model, chosen: agent.thinking))
    }

    /// Adds a typed line to `history`, trimmed, unless it is blank or repeats the line before it.
    private mutating func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != history.last else { return }
        history.append(trimmed)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// Runs until `/quit` or end of input, saving the thread after every turn and command the person runs, then saves
    /// it as `saved` and lets it go (ADR 0066, D11).
    ///
    /// - Throws: Only the exit save can throw; everything inside the loop is reported as a note.
    public mutating func run() async throws {
        if let banner = context.banner { io.note(style.bold(banner)) }
        for notice in context.notices { io.note(style.ember(notice)) }
        await observeWorkplace()
        io.note(style.muted("/help for commands, /quit or Ctrl-D to exit."))
        loop: while true {
            notePending()
            io.prompt(await status())
            // Read again once the line is drawn, so the answer, sent when it differs, comes after this status.
            vcsWatch.refresh()
            guard let line = io.readLine() else { break loop }
            remember(line)
            switch ChatInput(line: line) {
            case .quit:
                break loop
            case .help(let word):
                io.print(ChatInput.helpText(frontEnd: io.view != nil, matching: word))
            case .tools:
                let width = agent.tools.map(\.name.count).max() ?? 0
                for tool in agent.tools {
                    let name = tool.name.padding(toLength: width, withPad: " ", startingAt: 0)
                    io.print("\(style.bold(name))  \(ChatEvents.firstSentence(of: tool.description))")
                }
            case .context:
                guard let archive = agent.archive else {
                    io.note("the context is not saved here: audit.enabled is false")
                    continue
                }
                do {
                    let transcript = agent.transcript
                    let file = try archive.save(transcript, label: "turn\(agent.turns.current)")
                    let tokens =
                        (try? await agent.contextTokens()).flatMap { $0 }.map { "\($0.formatted()) tokens, " } ?? ""
                    io.note(
                        "saved the context the next request carries: \(ChatStatus.abbreviated(file.path)) "
                            + "(\(tokens)\(transcript.turnCount) turn\(transcript.turnCount == 1 ? "" : "s")), and the JSON beside it"
                    )
                } catch {
                    io.note(style.ember("error: \(error)"))
                }
            case .inspect(let what):
                await view(what)
            case .approvals(let request):
                await approvals(request)
            case .last:
                guard let output = shownOutput(nil) else {
                    io.print("no tool has run yet")
                    continue
                }
                show(output)
            case .show(let argument):
                if let output = shownOutput(argument) {
                    show(output)
                } else {
                    io.note(argument == nil ? "no tool has run yet" : "no tool output \(argument ?? "")")
                }
            case .view(let argument):
                switch ChatView.context(argument, of: agent) {
                case .success(let view):
                    if let show = io.view { show(view) } else { io.print(view.text) }
                case .failure(let failure):
                    io.note(failure.description)
                }
            case .thinking(let argument):
                switch ChatView.thinking(argument, of: agent) {
                case .success(let view):
                    if let show = io.view { show(view) } else { io.print(view.text) }
                case .failure(let failure):
                    io.note(failure.description)
                }
            case .facts(let all):
                let view = ChatView(
                    kind: .facts, turn: nil, turns: agent.turns.current,
                    text: FactReport.markdown(agent.allFacts, all: all, elsewhere: agent.proposalsElsewhere))
                if let show = io.view { show(view) } else { io.print(view.text) }
            case .summary(let all):
                let view = ChatView(
                    kind: .summary, turn: nil, turns: agent.turns.current,
                    text: FactReport.summaryMarkdown(agent.store.summaries, all: all))
                if let show = io.view { show(view) } else { io.print(view.text) }
            case .pendingFacts(let request):
                await pendingFacts(request)
            case .questions(let request):
                await questions(request)
            case .fact(let request):
                fact(request)
            case .task(nil):
                io.print(FactReport.task(agent.taskHistory))
            case .task(let text?):
                do {
                    let fact = try agent.setTask(text)
                    io.note("task set (\(fact.id)); /task shows it and its history")
                } catch {
                    io.note(style.ember("error: \(error)"))
                }
            case .models(let request):
                await models(request)
            case .stats:
                guard let stats = context.stats else {
                    io.note("stats are not kept here")
                    continue
                }
                for line in stats.report() { io.print(line) }
            case .history:
                let width = String(history.count).count
                for (index, line) in history.enumerated() {
                    io.print("\(String(repeating: " ", count: width - String(index + 1).count))\(index + 1)  \(line)")
                }
            case .model(nil):
                await showModel()
            case .model(let name?):
                switchModel(to: name)
            case .think(let argument):
                await think(argument)
            case .tokens:
                do {
                    let tokens = try await agent.contextTokens().map(String.init) ?? "unknown"
                    io.print(
                        "\(tokens) tokens in \(agent.turnCount) turn\(agent.turnCount == 1 ? "" : "s"); "
                            + "condensed \(agent.condensations) time\(agent.condensations == 1 ? "" : "s")"
                    )
                } catch {
                    io.note("error: \(error)")
                }
            case .save(let name):
                save(as: name)
            case .threads:
                await threads()
            case .resume(let id):
                guard let id else {
                    await threads()
                    continue
                }
                resume(id)
            case .new:
                let record = agent.store
                agent.reset()
                await observeWorkplace()
                io.note(renewThread(after: record).map { "new conversation, thread \($0)" } ?? "new conversation")
            case .config(let request):
                await config(request)
            case .unknown(let command):
                io.note("unknown command /\(command); /help lists commands")
            case .command(let command, let outsideSandbox):
                await run(typed: command, outsideSandbox: outsideSandbox, as: line)
                saveThread()
            case .message(let text):
                guard !text.isEmpty else { continue }
                // The agent advances the clock as the prompt arrives, so this is the number the turn's
                // audit events carry.
                let number = agent.turns.current + 1
                let started = Date()
                let before = agent.tokensUsed
                io.turn(.start(turn: number))
                parts.reset()
                // Ctrl-C stops the turn: its request, and a command the model started (ADR 0049, amended 2026-10-11).
                let stop = TurnStop()
                let activity = context.activity
                activity?.begin(stoppable: context.interrupt != nil, turn: true)
                context.interrupt?.armTurn(stop) { _ in activity?.stopping("stopping the turn") }
                var failed = false
                var reply: Agent.Reply?
                do {
                    reply = try await agent.stream(text, stop: context.interrupt == nil ? nil : stop) { delta in
                        if io.separatesParts, parts.enter(.reply, starting: true) { io.note("") }
                        io.write(delta)
                    }
                    io.print("")
                } catch TurnStop.Failure.stopped {
                    failed = true
                    io.print("")
                    io.note(style.muted(TurnStop.Failure.stopped.description))
                } catch {
                    failed = true
                    io.print("")
                    io.note(style.ember("error: \(error)"))
                }
                context.interrupt?.disarmTurn()
                context.activity?.end()
                if io.separatesParts, parts.enter(.footer, starting: true) { io.note("") }
                io.turn(
                    .end(
                        turn: number, seconds: Date().timeIntervalSince(started), failed: failed,
                        tokens: .between(before, agent.tokensUsed), facts: reply?.facts ?? [], ran: reply?.ran,
                        cited: reply?.cited, verified: reply?.verified))
                if let note = FactReport.newFacts(reply?.facts ?? []) { io.note(style.muted(note)) }
                saveThread(turn: true)
            }
        }
        try thread?.finish(record: agent.store, model: agent.model.selection.description, think: agent.thinking?.text)
    }

    /// The output `/show <argument>` asks for (`ChatEvents.outputEntry`), or with no argument the last tool result,
    /// as the person's views show it (`ChatOutput`): the whole from the output store when the model was given part of
    /// it and the store still holds it. Nil when there is none.
    ///
    /// - Parameter argument: What follows `/show`; nil for `/last` and a bare `/show`.
    /// - Returns: The output, or nil.
    func shownOutput(_ argument: String?) -> ChatOutput? {
        let entry: ThreadRecord.Entry?
        if let argument, !argument.isEmpty {
            entry = ChatEvents.outputEntry(argument, in: agent.store)
        } else if let event = tap.lastToolEvent {
            return ChatOutput.resolve(
                returned: event.details["output"]?.stringValue ?? "", event: event, outputs: context.outputs)
        } else {
            entry = agent.store.entries.last { [.toolOutput, .command].contains($0.kind) }
        }
        guard let entry else { return nil }
        let reference = entry.sources.first
        return ChatOutput.resolve(
            returned: ThreadRecord.text(of: entry.value), event: reference.flatMap { agent.audit?.event($0) },
            session: reference?.session, outputs: context.outputs)
    }

    /// Shows an output whole: the face's own way when it has one (`IO.showOutput`), with Ctrl-C left to a pager
    /// while it runs; otherwise its header as a note and its text printed.
    ///
    /// - Parameter output: The output.
    private func show(_ output: ChatOutput) {
        if let face = io.showOutput {
            let shown = context.interrupt.map { interrupt in interrupt.whilePaging { face(output) } } ?? face(output)
            if shown { return }
        }
        io.note(style.muted(output.header))
        io.print(output.text)
    }

    /// Runs a command the person typed after `!` (ADR 0049) in the conversation's directory, without a model
    /// turn. What it printed, a policy's refusal, and a sandbox's are shown by its audit events as they arrive
    /// through the tap, as a tool's are; this adds the activity while it runs and the facts it gave.
    ///
    /// The command has no timeout (amended 2026-10-09): while it runs, the face's Ctrl-C reaches it through
    /// `Context.interrupt`, which stops it (SIGTERM to its process group, SIGKILL after `CommandStop.grace`), and
    /// the activity says so; its `command.outcome` line then reads `↳ exit -15 (stopped by you)` and the chat goes
    /// on.
    ///
    /// A line typed after `!!` (ADR 0064, amended 2026-10-14) runs outside the sandbox; its `policy.decision` arrives
    /// through the tap before it starts and says so (`ChatEvents.render`), as it says when the request changed nothing
    /// or was turned off, and the activity reads `running … outside the sandbox`.
    ///
    /// - Parameters:
    ///   - command: The command line, without the `!` or `!!`; empty runs nothing.
    ///   - outsideSandbox: Whether it was typed after `!!`.
    ///   - line: The line as typed, for the face's marker.
    private func run(typed command: String, outsideSandbox: Bool = false, as line: String) async {
        guard !command.isEmpty else {
            let example = outsideSandbox ? "!! brew upgrade" : "! git status"
            io.note(
                style.muted("nothing to run: type a command after \(outsideSandbox ? "!!" : "!"), as in \(example)"))
            return
        }
        io.command(line)
        let shortened = ChatEvents.shortened(command) + (outsideSandbox ? " outside the sandbox" : "")
        let stop = CommandStop()
        let activity = context.activity
        let interrupt = context.interrupt
        activity?.begin(doing: "running " + shortened, stoppable: interrupt != nil)
        interrupt?.arm(command, stop: stop) { _ in activity?.stopping("stopping " + shortened) }
        let typed = await agent.runTyped(command, in: context.directory, stop: stop, outsideSandbox: outsideSandbox)
        interrupt?.disarm()
        activity?.end()
        switch typed.result {
        case .unavailable:
            io.note(style.ember("commands cannot be run here: this conversation has no command runner"))
        case .ran, .refused:
            if let note = FactReport.newFacts(typed.facts) { io.note(style.muted(note)) }
        }
    }

    /// `/resume ID`, here since only this file sets `agent`: the thread open now saved and let go, and `id` opened in
    /// its place as `wisp chat --resume ID` opens one (`ChatThread.find`): an agent's thread with its own model, tools,
    /// thinking, and command limit, any other on the chat's model and thinking. Refused with the reason, the thread
    /// open now kept, for the thread already open, one another process holds, and one that cannot be resumed.
    ///
    /// - Parameter id: The thread's id, or a transcript's name.
    mutating func resume(_ id: String) {
        guard let thread, let openThread = context.openThread else {
            io.note("threads cannot be switched here")
            return
        }
        guard id != thread.id else {
            io.note("thread \(id) is the one open here")
            return
        }
        let opening: ChatThread.Opening
        do {
            opening = try ChatThread.find(id, store: thread.store, transcripts: thread.transcripts)
        } catch {
            io.note(style.ember("error: \(error)"))
            return
        }
        let resumed: Agent
        do {
            resumed = try openThread(opening, agent.model.selection, agent.thinking)
        } catch {
            opening.abandon(in: thread.store)
            io.note(style.ember("error: \(error)"))
            return
        }
        let left = thread.id
        let leaving = thread.resume(
            opening, leaving: agent.store, model: agent.model.selection.description, think: agent.thinking?.text,
            tools: resumed.tools.map(\.name), instructions: nil, opened: resumed.model.selection.description,
            thinking: resumed.thinking?.text)
        if let leaving { io.note(style.ember("error: could not save thread \(left): \(leaving)")) }
        agent = resumed
        if !thread.isAgents, let choice = thinkChoices[agent.model.selection.description] { agent.thinking = choice }
        agent.audit?.record(
            .sessionStart,
            details: AuditEvent.Details.sessionResumed(
                tools: agent.tools.map(\.name), model: agent.model.selection, resume: id,
                carriedFrom: opening.carriedFrom))
        if opening.saved != nil { saveThread() }
        io.note(
            opening.announcement(transcripts: ChatStatus.abbreviated(thread.transcripts?.directory.path ?? ""))
                .map { "\($0); \(left) is saved" } ?? "opened thread \(thread.id); \(left) is saved")
    }

    /// `/model NAME`, here since only this file sets `agent`: the conversation moved to `name` through the chat's model actions, which refuse a disabled model,
    /// its transcript carried over; refused with the reason, nothing changed, when it cannot be.
    ///
    /// - Parameter name: The model, as `--model` spells it.
    mutating func switchModel(to name: String) {
        if let refusal = agentsThreadRefusal("model") {
            io.note(refusal)
            return
        }
        guard let openModel = context.openModel else {
            io.note("the model cannot be switched here")
            return
        }
        do {
            let selection = try context.models?.switchTarget(name) ?? ModelSelection(parsing: name)
            agent = try openModel(selection, agent.store)
            agent.thinking = thinkChoices[selection.description]
            io.note(style.muted("model: \(selection); the transcript continues"))
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }

    /// What the terminal writes to colour the prompt marker of a typed command's line in the command colour once
    /// the line has been read: up over the rows the prompt and the line took, the marker again, and back down.
    /// Nil when the terminal's width is unknown or the style has no colour, where it writes nothing. A line typed after
    /// `!!`, to run outside the sandbox, takes the outside colour instead (ADR 0064, amended 2026-10-14).
    ///
    /// - Parameters:
    ///   - line: The line as typed.
    ///   - width: The terminal's width in columns.
    ///   - style: Styling.
    /// - Returns: The escape sequence and marker, or nil.
    public static func commandMarker(for line: String, width: Int?, style: Style) -> String? {
        guard let width, width > 0, style.command("›") != "›" else { return nil }
        let rows = max(1, (2 + line.count + width - 1) / width)
        let outside = line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!!")
        let marker = outside ? style.outside("›") : style.command("›")
        return "\u{1B}[\(rows)A\r" + marker + "\u{1B}[\(rows)B\r"
    }
}

/// The parts of a turn as the plain chat shows them, so it can set each apart from the one before with a blank line:
/// a stretch of thinking or a tool call with its result and output, the reply, and the footer with `ran:`. Nothing
/// comes before the first part after the prompt, the line typed already sets it apart. Tool events arrive from the tool
/// loop, so the state is behind a lock.
final class TurnParts: Sendable {
    /// A part of a turn.
    enum Part: Equatable, Sendable {
        /// Thinking, or a tool call with what follows it.
        case tool
        /// The model's reply.
        case reply
        /// The turn's footer: what it ran, its time, and its tokens.
        case footer
    }

    /// The part shown last since the prompt, nil before any.
    private let current = Mutex<Part?>(nil)

    /// Forgets the parts shown, as a new turn starts.
    func reset() { current.withLock { $0 = nil } }

    /// Notes that a line of `part` is about to be shown, and says whether a blank line goes before it: when the line
    /// is `starting` a part, something was shown since the prompt, and the line begins another part than the last,
    /// or another tool call or stretch of thinking.
    ///
    /// - Parameters:
    ///   - part: The part the line belongs to.
    ///   - starting: Whether the line begins a part (`⚙`, `∴`, the reply's first text, the footer) rather than
    ///     continuing one (`↳`, an output's lines).
    /// - Returns: Whether to show a blank line first.
    func enter(_ part: Part, starting: Bool) -> Bool {
        current.withLock { current in
            defer { current = part }
            guard let previous = current, starting else { return false }
            return part == .tool || part != previous
        }
    }
}
