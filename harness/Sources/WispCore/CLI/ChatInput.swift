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

    /// The text shown for `/help`.
    public static let helpText = """
        /help            show this list
        /tools           list the tools the model can call
        /tokens          show how much of the context window the conversation uses
        /inspect context save the exact context the model sees next to ~/.wisp/context, as Markdown and JSON
        /inspect context next|N   show the context the next request carries, or the one composed at turn N's start
        /inspect context turns    list the turns with what changed at each
        /inspect facts [all]      list the facts the model is given, with their sources; all adds their history
        /fact SUBJECT [NAME] = VALUE   state a fact as you, which outranks a tool's and the model's
        /fact ID permanent|thread|session   move a fact to that scope; permanent keeps it in ~/.wisp/facts.json
        /fact delete ID  delete a fact
        /task [text]     show the task and its history, or set it
        /status          show wisp's own state: model, tools, policy, session
        /approvals       list standing approvals; /approvals revoke [ID] removes one
        /audit           show the latest audit events of every session, MCP calls included
        /audit sessions  list the sessions in the audit log; /audit ID shows one session's events
        /last            show the last tool result in full
        /show ID         show a tool output in full, by its entry id or the id its fold line gives
        /models          list the models this Mac can run for this conversation
        /model [name]    switch the conversation to a model, keeping the transcript; no name shows the current one
        /stats           show timings of recent model turns and classifier calls
        /history         list what you have typed this session (Up and Down recall it in wisp-tui)
        /config          show the config; /config list shows the settings you can change
        /config get KEY  show one setting's value and whether it is set or the default
        /config set KEY VALUE, /config unset KEY   change ~/.wisp/config.json; leave out a part to choose it
        /save [name]     save the transcript to ~/.wisp/transcripts
        /new             start a fresh conversation with the same instructions and tools
        /quit            exit (also /exit, a bare exit or quit, Ctrl-D)
        """
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
