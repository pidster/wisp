import Foundation
import FoundationModels

/// The edges of one turn: a message to the model and everything it does to answer it.
public enum ChatTurn: Equatable, Sendable {
    /// The message has gone to the model; `turn` is the number its audit events carry.
    case start(turn: Int)
    /// The reply is complete, or the turn failed with the error noted before this. `tokens` is what the
    /// turn's requests used, when the model reports it.
    case end(turn: Int, seconds: Double, failed: Bool, tokens: TurnTokens? = nil)

    /// The line under a reply in the terminal chat: how long the turn took and, when the model reports
    /// them, the tokens it read (↓, pale yellow) and wrote (↑, pale blue). Nil for a turn's start.
    public func footer(style: Style) -> String? {
        guard case .end(_, let seconds, let failed, let tokens) = self else { return nil }
        var parts = [failed ? "failed after \(String(format: "%.1f", seconds)) s" : String(format: "%.1f s", seconds)]
        if let tokens {
            // No rate: the turn's time includes its commands and approvals, so tokens over it is not the
            // model's speed.
            parts.append(
                style.tokensIn("↓\(tokens.input.formatted())") + " " + style.tokensOut("↑\(tokens.output.formatted())"))
        }
        return "  "
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

    /// Creates a count.
    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    /// The difference between two readings of a session's running totals, or nil when the model
    /// reported nothing.
    public static func between(_ before: TurnTokens, _ after: TurnTokens) -> TurnTokens? {
        let used = TurnTokens(input: max(0, after.input - before.input), output: max(0, after.output - before.output))
        return used.input == 0 && used.output == 0 ? nil : used
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

        /// Creates an IO.
        public init(
            readLine: @escaping () -> String?, print: @escaping (String) -> Void, write: @escaping (String) -> Void,
            note: @escaping @Sendable (String) -> Void, prompt: @escaping (ChatStatus) -> Void,
            turn: @escaping (ChatTurn) -> Void = { _ in }, choose: ((ChatChoice) async -> String?)? = nil,
            view: ((ChatView) -> Void)? = nil
        ) {
            self.choose = choose
            self.view = view
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
        /// Reads the git branch and changes of a directory; the CLI passes `GitState.read`.
        public var git: @Sendable (String) -> GitState.Summary
        /// Answers `/inspect <what>`; nil makes the command unavailable.
        public var inspect: (@Sendable (String) async -> String)?
        /// A banner line for the start of the session.
        public var banner: String?
        /// Lists the models `/models` offers: those that can serve a conversation on the given current
        /// model with the given tools; nil makes the command unavailable.
        public var models: (@Sendable (ModelSelection, [any Tool]) async -> [String])?
        /// Opens an agent on another model continuing the conversation's store, for `/model`; nil makes it
        /// unavailable.
        public var openModel: (@Sendable (ModelSelection, ConversationStore) throws -> Agent)?
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

        /// Creates a context.
        public init(
            directory: String, approval: String,
            git: @escaping @Sendable (String) -> GitState.Summary = { _ in GitState.Summary() },
            inspect: (@Sendable (String) async -> String)? = nil, banner: String? = nil,
            models: (@Sendable (ModelSelection, [any Tool]) async -> [String])? = nil,
            openModel: (@Sendable (ModelSelection, ConversationStore) throws -> Agent)? = nil, stats: CallStats? = nil,
            configFile: URL? = nil,
            configOptions: (@Sendable (ConfigSettings.Setting) async -> [ChatChoice.Option])? = nil,
            approvalStore: ApprovalStore? = nil, activity: ChatActivity? = nil,
            shownOutputLines: Int = Config().resolved.shownOutputLines
        ) {
            self.shownOutputLines = shownOutputLines
            self.approvalStore = approvalStore
            self.activity = activity
            self.configFile = configFile
            self.configOptions = configOptions
            self.directory = directory
            self.approval = approval
            self.git = git
            self.inspect = inspect
            self.banner = banner
            self.models = models
            self.openModel = openModel
            self.stats = stats
        }
    }

    /// The conversation; replaced by `/model`, which resumes the transcript on another model.
    public private(set) var agent: Agent
    /// Where `/save` and the exit save go.
    public let store: TranscriptStore
    /// The name the transcript saves under on exit and for a bare `/save`; nil saves nothing on exit.
    public private(set) var saveName: String?
    /// The tap the conversation was opened with; its events are rendered as they arrive.
    public let tap: ChatEvents.Tap
    /// The styling in force.
    public let style: Style
    /// The lines typed this session, oldest first, for `/history`: blank lines and a line repeating
    /// the one before it are not added, and only the latest `historyLimit` are kept.
    public private(set) var history: [String] = []
    /// How many lines `history` keeps.
    public static let historyLimit = 100
    let context: Context
    let io: IO

    /// Creates a loop over `agent`.
    ///
    /// - Parameters:
    ///   - agent: The conversation, already resumed if it should be, opened with `tap` observing.
    ///   - store: Where transcripts are saved.
    ///   - saveName: The default name for `/save` and the save on exit; nil for none.
    ///   - tap: The sink the conversation's events reach; the loop sets its handler.
    ///   - context: Directory, approval mode, git reader, inspect views, banner.
    ///   - style: Styling; `.plain` when piped.
    ///   - io: Input and output.
    public init(
        agent: Agent, store: TranscriptStore, saveName: String?, tap: ChatEvents.Tap = ChatEvents.Tap(),
        context: Context, style: Style = .plain, io: IO
    ) {
        self.agent = agent
        self.store = store
        self.saveName = saveName
        self.tap = tap
        self.context = context
        self.style = style
        self.io = io
        let note = io.note
        let activity = context.activity
        let shown = context.shownOutputLines
        tap.onEvent { event in
            activity?.apply(event)
            if let line = ChatEvents.render(event, style: style) { note(line) }
            if let output = ChatEvents.shownOutput(event, lines: shown, style: style) { note(output) }
        }
    }

    /// The status line for the next prompt.
    public func status() async -> ChatStatus {
        let git = context.git(context.directory)
        var used: Double?
        if let size = agent.contextSize, size > 0, let tokens = try? await agent.contextTokens() {
            used = min(1, Double(tokens) / Double(size))
        }
        return ChatStatus(
            model: agent.model.selection.description, directory: ChatStatus.abbreviated(context.directory),
            branch: git.branch, dirty: git.dirty, added: git.added, removed: git.removed, approval: context.approval,
            contextUsed: used)
    }

    /// Adds a typed line to `history`, trimmed, unless it is blank or repeats the line before it.
    private mutating func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != history.last else { return }
        history.append(trimmed)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// Runs until `/quit` or end of input, then saves the transcript under `saveName` if there is one.
    ///
    /// - Throws: Only the exit save can throw; everything inside the loop is reported as a note.
    public mutating func run() async throws {
        if let banner = context.banner { io.note(style.bold(banner)) }
        observeWorkplace()
        io.note(style.muted("/help for commands, /quit or Ctrl-D to exit."))
        loop: while true {
            io.prompt(await status())
            guard let line = io.readLine() else { break loop }
            remember(line)
            switch ChatInput(line: line) {
            case .quit:
                break loop
            case .help:
                io.print(ChatInput.helpText)
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
                io.print(tap.lastToolOutput ?? "no tool has run yet")
            case .show(let argument):
                if let output = ChatEvents.output(argument, in: agent.store, last: tap.lastToolOutput) {
                    io.print(output)
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
            case .facts(let all):
                let view = ChatView(
                    kind: .facts, turn: nil, turns: agent.turns.current,
                    text: FactReport.markdown(agent.allFacts, all: all))
                if let show = io.view { show(view) } else { io.print(view.text) }
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
            case .models:
                guard let models = context.models else {
                    io.note("models are not listed here")
                    continue
                }
                for line in await models(agent.model.selection, agent.tools) { io.print(line) }
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
                io.print("model: \(agent.model.selection) (\(agent.model.capabilityNames.joined(separator: ", ")))")
            case .model(let name?):
                guard let openModel = context.openModel else {
                    io.note("the model cannot be switched here")
                    continue
                }
                do {
                    let selection = try ModelSelection(parsing: name)
                    agent = try openModel(selection, agent.store)
                    io.note(style.muted("model: \(selection); the transcript continues"))
                } catch {
                    io.note(style.ember("error: \(error)"))
                }
            case .tokens:
                do {
                    let tokens = try await agent.contextTokens().map(String.init) ?? "unknown"
                    io.print(
                        "\(tokens) tokens in \(agent.transcript.turnCount) turn\(agent.transcript.turnCount == 1 ? "" : "s"); "
                            + "condensed \(agent.condensations) time\(agent.condensations == 1 ? "" : "s")"
                    )
                } catch {
                    io.note("error: \(error)")
                }
            case .save(let name):
                guard let name = name ?? saveName else {
                    io.note("usage: /save <name>")
                    continue
                }
                do {
                    try store.save(agent.store, as: name)
                    saveName = name
                    io.note("saved '\(name)'")
                } catch {
                    io.note("error: \(error)")
                }
            case .new:
                agent.reset()
                observeWorkplace()
                io.note("new conversation")
            case .config(let request):
                await config(request)
            case .unknown(let command):
                io.note("unknown command /\(command); /help lists commands")
            case .message(let text):
                guard !text.isEmpty else { continue }
                // The agent advances the clock as the prompt arrives, so this is the number the turn's
                // audit events carry.
                let number = agent.turns.current + 1
                let started = Date()
                let before = agent.tokensUsed
                io.turn(.start(turn: number))
                context.activity?.begin()
                var failed = false
                do {
                    _ = try await agent.stream(text) { io.write($0) }
                    io.print("")
                } catch {
                    failed = true
                    io.print("")
                    io.note(style.ember("error: \(error)"))
                }
                context.activity?.end()
                io.turn(
                    .end(
                        turn: number, seconds: Date().timeIntervalSince(started), failed: failed,
                        tokens: .between(before, agent.tokensUsed)))
            }
        }
        if let saveName {
            try store.save(agent.store, as: saveName)
            io.note("saved '\(saveName)'")
        }
    }
}
