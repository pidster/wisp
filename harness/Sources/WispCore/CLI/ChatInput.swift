/// One line typed into `wisp chat`, parsed into a command or a message.
public enum ChatInput: Equatable, Sendable {
    /// End the session.
    case quit
    /// Show the command list.
    case help
    /// List the tools the model can call.
    case tools
    /// Save the transcript, under the given name or the session's default.
    case save(String?)
    /// Start a fresh session with the same instructions and tools.
    case new
    /// Report how many tokens the transcript occupies.
    case tokens
    /// Save the exact context the next request carries, as Markdown and JSON: `/inspect context`.
    case context
    /// Show wisp's own state (`config`, `status`, `approvals`, `audit`), as the model's `inspect` tool would.
    case inspect(String)
    /// Show the last tool result in full.
    case last
    /// Show a tool output in full: by store entry id, by (the start of) its `tool.result` event id, or the
    /// last one when nil.
    case show(String?)
    /// Show the model's context, `/inspect context <argument>`: `next` for the next request's, a turn
    /// number for the one composed at that turn's start, `turns` for the list of turns. The bare
    /// `/inspect context` is `context`, which saves the next request's context to files.
    case view(String?)
    /// Show the facts in force, `/inspect facts`; with `all` (`/inspect facts all`) their history too.
    case facts(all: Bool)
    /// Show the running summary of earlier turns, `/inspect summary`; with `all` its earlier versions too.
    case summary(all: Bool)
    /// Show the model's thinking (ADR 0053), `/inspect thinking`: every stretch the conversation kept, or with a turn
    /// number that turn's.
    case thinking(String?)
    /// State, move, or delete a fact: `/fact …`.
    case fact(FactRequest)
    /// Show the task and its history, or with text set it as the person: `/task [text]`.
    case task(String?)
    /// List the models the session could switch to, or turn some on or off (ADR 0056).
    case models(ModelsRequest)
    /// Switch the conversation to a model, or show the current one when nil.
    case model(String?)
    /// Show the recent model turns and classifier calls, with their timings.
    case stats
    /// List the lines typed this session, oldest first.
    case history
    /// Show or change `config.json`.
    case config(ConfigRequest)
    /// List standing approvals, or revoke one.
    case approvals(ApprovalsRequest)
    /// A command the person runs themselves (ADR 0049): a line that starts with `!`, with what follows it,
    /// trimmed; empty for a bare `!`, which runs nothing.
    case command(String)
    /// A message for the model.
    case message(String)
    /// A slash command that does not exist.
    case unknown(String)

    /// Parses a raw line. Leading and trailing whitespace is ignored; a line
    /// starting with `!` is a command the person runs, one starting with `/` is a
    /// chat command, a bare `exit`, `quit`, or `q` ends the session, and anything
    /// else is a message, a `!` inside it included.
    public init(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!") {
            self = .command(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if ["exit", "quit", "q"].contains(trimmed.lowercased()) {
            self = .quit
            return
        }
        if ["help", "?"].contains(trimmed.lowercased()) {
            self = .help
            return
        }
        guard trimmed.hasPrefix("/") else {
            self = .message(trimmed)
            return
        }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        // The help's table is the only list of commands: a word with no entry is not a command.
        if let build = Self.helpEntries.first(where: { $0.names.contains(command) })?.command {
            self = build(argument)
        } else {
            self = .unknown(command)
        }
    }

    /// `/inspect`'s argument: a view of wisp's state, or of the model's context, facts, or summary.
    private static func inspect(_ argument: String?) -> ChatInput {
        guard let argument else { return .inspect("status") }
        let lowered = argument.lowercased()
        if lowered == "context" { return .context }
        if lowered == "facts" { return .facts(all: false) }
        if lowered == "facts all" { return .facts(all: true) }
        if lowered == "summary" { return .summary(all: false) }
        if lowered == "summary all" { return .summary(all: true) }
        if lowered == "thinking" { return .thinking(nil) }
        if lowered.hasPrefix("thinking ") {
            return .thinking(String(argument.dropFirst("thinking ".count)).trimmingCharacters(in: .whitespaces))
        }
        if lowered.hasPrefix("context ") {
            return .view(String(argument.dropFirst("context ".count)).trimmingCharacters(in: .whitespaces))
        }
        return .inspect(argument)
    }

    /// One line of `/help`: how a command is typed, what it does, and, for a line that names a command, the
    /// words that reach it and what each produces. The parser reads these, so a command exists only where it is
    /// listed.
    struct HelpEntry: Sendable {
        /// How it is typed, such as `/fact delete ID`.
        let usage: String
        /// What it does, short; `helpText` moves it under a usage too long for the column.
        let about: String
        /// The slash words (without the slash) that reach this command; empty for a line that only shows
        /// another command's form, such as `/fact delete ID`, which `/fact` parses.
        let names: [String]
        /// The command a word produces, given what followed it (trimmed, nil when nothing did); nil exactly
        /// when `names` is empty.
        let command: (@Sendable (String?) -> ChatInput)?

        /// A command: its words, and what they produce from the argument.
        init(
            usage: String, about: String, names: [String], command: @escaping @Sendable (String?) -> ChatInput
        ) {
            self.usage = usage
            self.about = about
            self.names = names
            self.command = command
        }

        /// A line that only shows another command's form.
        init(usage: String, about: String) {
            self.usage = usage
            self.about = about
            self.names = []
            self.command = nil
        }
    }

    /// Every command `/help` lists, in order. The one list `helpText` renders and the tests check against the
    /// parser in `init(line:)`, so a command cannot be parsed without being listed.
    static let helpEntries: [HelpEntry] = [
        HelpEntry(
            usage: "/help, /?", about: "this list (also a bare help or ?)", names: ["help", "?"],
            command: { _ in .help }),
        HelpEntry(
            usage: "!COMMAND",
            about:
                "run a shell command yourself, in the sandbox and without asking, with no time limit (Ctrl-C stops "
                + "it); the model is told next turn"),
        HelpEntry(
            usage: "/tools", about: "the tools the model can call", names: ["tools"],
            command: { _ in .tools }),
        HelpEntry(
            usage: "/tokens", about: "how much of the context window the conversation uses",
            names: ["tokens"], command: { _ in .tokens }),
        HelpEntry(
            usage: "/inspect [VIEW]",
            about:
                "wisp's own state: status (the default), config, approvals, audit, context, facts, summary, thinking",
            names: ["inspect"], command: inspect),
        HelpEntry(
            usage: "/status", about: "short for /inspect status: model, tools, policy, session", names: ["status"],
            command: { _ in .inspect("status") }),
        HelpEntry(
            usage: "/approvals [revoke [ID]]", about: "list standing approvals, or remove one", names: ["approvals"],
            command: { .approvals(ApprovalsRequest($0)) }),
        HelpEntry(
            usage: "/audit [sessions|ID]",
            about: "latest audit events of every session; sessions lists them, an ID shows one",
            names: ["audit"],
            command: { .inspect($0.map { "audit \($0)" } ?? "audit") }),
        HelpEntry(
            usage: "/inspect context", about: "save the exact context the next request carries to ~/.wisp/context"),
        HelpEntry(
            usage: "/inspect context next|N|turns",
            about: "show the next request's context, the one composed at turn N's start, or a row per turn"),
        HelpEntry(
            usage: "/inspect facts [all]",
            about: "the facts the model is given and proposals from other conversations; all adds history"),
        HelpEntry(
            usage: "/inspect summary [all]",
            about: "the running summary of earlier turns, with what it covers; all adds earlier versions"),
        HelpEntry(
            usage: "/inspect thinking [N]",
            about: "the model's thinking, kept for you and never sent back to it; N shows turn N's"),
        HelpEntry(
            usage: "/fact SUBJECT [NAME] = VALUE", about: "state a fact as you; it outranks a tool's and the model's",
            names: ["fact"], command: { .fact(FactRequest($0)) }),
        HelpEntry(
            usage: "/fact ID permanent|thread|session",
            about: "move a fact to that scope; ID is cN, sN, pN, or CONV/cN for another conversation's proposal"),
        HelpEntry(usage: "/fact delete ID", about: "delete a fact"),
        HelpEntry(
            usage: "/task [text]", about: "show the task and its history, or set it", names: ["task"],
            command: { .task($0) }),
        HelpEntry(
            usage: "/last", about: "the last tool result in full", names: ["last"], command: { _ in .last }),
        HelpEntry(
            usage: "/show [ID]",
            about: "a tool output or thinking in full: an entry number or an event-id prefix (4+ characters)",
            names: ["show"], command: { .show($0) }),
        HelpEntry(
            usage: "/models", about: "the models this Mac can run, with what wisp knows of each",
            names: ["models"], command: { .models(ModelsRequest($0)) }),
        HelpEntry(
            usage: "/models enable|disable NAME…",
            about: "turn models on or off: a disabled model is hidden from /model and refused; enabling an MLX "
                + "model checks what it can do"),
        HelpEntry(
            usage: "/models check NAME…",
            about: "ask an MLX model three short questions and record in config.json what it can do"),
        HelpEntry(
            usage: "/model [name]",
            about: "switch the conversation to a model, keeping the transcript; no name shows it",
            names: ["model"], command: { .model($0) }),
        HelpEntry(
            usage: "/stats", about: "timings of recent model turns and classifier calls",
            names: ["stats"], command: { _ in .stats }),
        HelpEntry(
            usage: "/history", about: "what you have typed this session", names: ["history"],
            command: { _ in .history }),
        HelpEntry(
            usage: "/config [list|get KEY|set KEY VALUE|unset KEY]", about: "show or change ~/.wisp/config.json",
            names: ["config"], command: { .config(ConfigRequest($0)) }),
        HelpEntry(
            usage: "/save [name]", about: "save the transcript to ~/.wisp/transcripts", names: ["save"],
            command: { .save($0) }),
        HelpEntry(
            usage: "/new", about: "start a fresh conversation with the same instructions and tools", names: ["new"],
            command: { _ in .new }),
        HelpEntry(
            usage: "/quit, /exit, /q", about: "exit (also a bare exit, quit, or q, and Ctrl-D)",
            names: ["quit", "exit", "q"], command: { _ in .quit }),
    ]

    /// The width of the usage column; a longer usage puts its description on the next line.
    private static let helpColumn = 28

    /// The keys `wisp-tui` adds to the chat, listed for its users only.
    private static let frontEndKeys = """

        In wisp-tui:
          !                           at the start of the line, command mode; Backspace there leaves it
          Ctrl-O                      the last tool output in full; again to close
          Ctrl-T                      the model's context in a panel
          Left, Right                 in that panel, the previous or next turn's context
          Up, Down                    recall what you typed
          Esc                         close the panel
        """

    /// The text shown for `/help`.
    ///
    /// - Parameter frontEnd: Whether the chat runs under `wisp-tui`, whose keys are listed after the commands.
    /// - Returns: One line per command in a column, the description on the next line for a usage that is too
    ///   long for it.
    public static func helpText(frontEnd: Bool = false) -> String {
        let lines = helpEntries.map { entry -> String in
            guard entry.usage.count < helpColumn else {
                return entry.usage + "\n" + String(repeating: " ", count: helpColumn) + entry.about
            }
            return entry.usage.padding(toLength: helpColumn, withPad: " ", startingAt: 0) + entry.about
        }
        return lines.joined(separator: "\n") + (frontEnd ? frontEndKeys : "")
    }

    /// The text shown for `/help` in the plain terminal chat.
    public static var helpText: String { helpText() }
}

/// What `/config` asks for.
public enum ConfigRequest: Equatable, Sendable {
    /// The effective configuration, as `/inspect config` shows it.
    case show
    /// The settings that can be changed, with their values.
    case list
    /// One setting's effective value; a missing path is chosen interactively.
    case get(String?)
    /// Set a setting; a missing path or value is chosen interactively.
    case set(path: String?, value: String?)
    /// Remove a setting so its default applies; a missing path is chosen interactively.
    case unset(String?)
    /// Anything else, with the word that was not understood.
    case unknown(String)

    /// Parses what follows `/config`.
    public init(_ argument: String?) {
        let parts = (argument ?? "").split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(
            String.init)
        switch parts.first {
        case nil, "show": self = .show
        case "list": self = .list
        case "get": self = .get(parts.count > 1 ? parts[1] : nil)
        case "set": self = .set(path: parts.count > 1 ? parts[1] : nil, value: parts.count > 2 ? parts[2] : nil)
        case "unset": self = .unset(parts.count > 1 ? parts[1] : nil)
        case let word?: self = .unknown(word)
        }
    }
}

/// What `/approvals` asks for.
public enum ApprovalsRequest: Equatable, Sendable {
    /// The standing approvals.
    case list
    /// Revoke one by id; a missing id is chosen interactively.
    case revoke(String?)
    /// Anything else, with the word that was not understood.
    case unknown(String)

    /// Parses what follows `/approvals`.
    public init(_ argument: String?) {
        let parts = (argument ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch parts.first {
        case nil, "list": self = .list
        case "revoke": self = .revoke(parts.count > 1 ? parts[1] : nil)
        case let word?: self = .unknown(word)
        }
    }
}

/// What `/models` asks for (ADR 0056).
public enum ModelsRequest: Equatable, Sendable {
    /// The listing: a table, or in a front end with choices a picker to turn models on and off.
    case list
    /// Turn these models on.
    case enable([String])
    /// Turn these models off.
    case disable([String])
    /// Check what these models can do and record it (ADR 0056, refined 2026-10-04).
    case check([String])
    /// Anything else, with the word that was not understood, or `enable`, `disable`, or `check` with no name.
    case unknown(String)

    /// Parses what follows `/models`.
    public init(_ argument: String?) {
        let parts = (argument ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        switch parts.first {
        case nil, "list": self = .list
        case "enable" where parts.count > 1: self = .enable(Array(parts.dropFirst()))
        case "disable" where parts.count > 1: self = .disable(Array(parts.dropFirst()))
        case "check" where parts.count > 1: self = .check(Array(parts.dropFirst()))
        case let word?: self = .unknown(word)
        }
    }
}

/// What `/fact` asks for.
public enum FactRequest: Equatable, Sendable {
    /// State a fact as the person: `/fact SUBJECT [NAME] = VALUE`.
    case state(subject: String, name: String, value: String)
    /// Delete a fact by id.
    case delete(String?)
    /// Move a fact to a scope: `/fact ID permanent|thread|session`.
    case move(String, FactTarget)
    /// Anything else: show how to use it.
    case usage

    /// How to use `/fact`.
    public static let usageText =
        "usage: /fact SUBJECT [NAME] = VALUE, /fact ID permanent|thread|session, or /fact delete ID"

    /// Parses what follows `/fact`.
    public init(_ argument: String?) {
        let text = (argument ?? "").trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch words.first?.lowercased() {
        case nil:
            self = .usage
        case "delete" where words.count <= 2:
            self = .delete(words.count > 1 ? words[1] : nil)
        case _? where words.count == 2 && FactTarget(rawValue: words[1].lowercased()) != nil:
            self = .move(words[0], FactTarget(rawValue: words[1].lowercased()) ?? .thread)
        default:
            guard let equals = text.firstIndex(of: "=") else {
                self = .usage
                return
            }
            let about = text[..<equals].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let subject = about.first, !value.isEmpty else {
                self = .usage
                return
            }
            self = .state(subject: subject, name: about.dropFirst().joined(separator: " "), value: value)
        }
    }
}
