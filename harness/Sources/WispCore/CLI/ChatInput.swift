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
    /// State, move, or delete a fact: `/fact …`.
    case fact(FactRequest)
    /// Show the task and its history, or with text set it as the person: `/task [text]`.
    case task(String?)
    /// List the models the session could switch to.
    case models
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
    /// A message for the model.
    case message(String)
    /// A slash command that does not exist.
    case unknown(String)

    /// Parses a raw line. Leading and trailing whitespace is ignored; a line
    /// starting with `/` is a command, a bare `exit`, `quit`, or `q` ends the
    /// session, and anything else is a message.
    public init(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        switch command {
        case "quit", "exit", "q": self = .quit
        case "help", "?": self = .help
        case "tools": self = .tools
        case "save": self = .save(argument)
        case "new": self = .new
        case "tokens": self = .tokens
        case "inspect" where argument?.lowercased() == "context": self = .context
        case "inspect" where argument?.lowercased() == "facts": self = .facts(all: false)
        case "inspect" where argument?.lowercased() == "facts all": self = .facts(all: true)
        case "inspect" where argument?.lowercased().hasPrefix("context ") == true:
            self = .view(
                String(argument?.dropFirst("context ".count) ?? "").trimmingCharacters(in: .whitespaces))
        case "inspect": self = .inspect(argument ?? "status")
        case "status": self = .inspect("status")
        case "audit": self = .inspect(argument.map { "audit \($0)" } ?? "audit")
        case "approvals": self = .approvals(ApprovalsRequest(argument))
        case "last": self = .last
        case "show": self = .show(argument)
        case "fact": self = .fact(FactRequest(argument))
        case "task": self = .task(argument)
        case "models": self = .models
        case "model": self = .model(argument)
        case "stats": self = .stats
        case "history": self = .history
        case "config": self = .config(ConfigRequest(argument))
        default: self = .unknown(command)
        }
    }

    /// One line of `/help`: how a command is typed, what it does, and the words the parser accepts for it.
    struct HelpEntry: Equatable, Sendable {
        /// How it is typed, such as `/fact delete ID`.
        let usage: String
        /// What it does, short; `helpText` moves it under a usage too long for the column.
        let about: String
        /// The slash words (without the slash) that reach this command.
        let names: [String]
    }

    /// Every command `/help` lists, in order. The one list `helpText` renders and the tests check against the
    /// parser in `init(line:)`, so a command cannot be parsed without being listed.
    static let helpEntries: [HelpEntry] = [
        HelpEntry(usage: "/help, /?", about: "this list (also a bare help or ?)", names: ["help", "?"]),
        HelpEntry(usage: "/tools", about: "the tools the model can call", names: ["tools"]),
        HelpEntry(usage: "/tokens", about: "how much of the context window the conversation uses", names: ["tokens"]),
        HelpEntry(
            usage: "/inspect [VIEW]",
            about: "wisp's own state: status (the default), config, approvals, audit, context, facts",
            names: ["inspect"]),
        HelpEntry(
            usage: "/status", about: "short for /inspect status: model, tools, policy, session", names: ["status"]),
        HelpEntry(
            usage: "/approvals [revoke [ID]]", about: "list standing approvals, or remove one", names: ["approvals"]),
        HelpEntry(
            usage: "/audit [sessions|ID]",
            about: "latest audit events of every session; sessions lists them, an ID shows one",
            names: ["audit"]),
        HelpEntry(
            usage: "/inspect context", about: "save the exact context the next request carries to ~/.wisp/context",
            names: []),
        HelpEntry(
            usage: "/inspect context next|N|turns",
            about: "show the next request's context, the one composed at turn N's start, or a row per turn",
            names: []),
        HelpEntry(
            usage: "/inspect facts [all]",
            about: "the facts the model is given, the running summary of earlier turns, and proposals from other "
                + "conversations; all adds history",
            names: []),
        HelpEntry(
            usage: "/fact SUBJECT [NAME] = VALUE", about: "state a fact as you; it outranks a tool's and the model's",
            names: ["fact"]),
        HelpEntry(
            usage: "/fact ID permanent|thread|session",
            about: "move a fact to that scope; ID is cN, sN, pN, or CONV/cN for another conversation's proposal",
            names: []),
        HelpEntry(usage: "/fact delete ID", about: "delete a fact", names: []),
        HelpEntry(usage: "/task [text]", about: "show the task and its history, or set it", names: ["task"]),
        HelpEntry(
            usage: "/last", about: "the last tool result in full", names: ["last"]),
        HelpEntry(
            usage: "/show [ID]", about: "a tool output in full: an entry number or an event-id prefix (4+ characters)",
            names: ["show"]),
        HelpEntry(usage: "/models", about: "the models this Mac can run for this conversation", names: ["models"]),
        HelpEntry(
            usage: "/model [name]",
            about: "switch the conversation to a model, keeping the transcript; no name shows it",
            names: ["model"]),
        HelpEntry(usage: "/stats", about: "timings of recent model turns and classifier calls", names: ["stats"]),
        HelpEntry(usage: "/history", about: "what you have typed this session", names: ["history"]),
        HelpEntry(
            usage: "/config [list|get KEY|set KEY VALUE|unset KEY]", about: "show or change ~/.wisp/config.json",
            names: ["config"]),
        HelpEntry(usage: "/save [name]", about: "save the transcript to ~/.wisp/transcripts", names: ["save"]),
        HelpEntry(
            usage: "/new", about: "start a fresh conversation with the same instructions and tools", names: ["new"]),
        HelpEntry(
            usage: "/quit, /exit, /q", about: "exit (also a bare exit, quit, or q, and Ctrl-D)",
            names: ["quit", "exit", "q"]),
    ]

    /// The width of the usage column; a longer usage puts its description on the next line.
    private static let helpColumn = 28

    /// The keys `wisp-tui` adds to the chat, listed for its users only.
    private static let frontEndKeys = """

        In wisp-tui:
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
