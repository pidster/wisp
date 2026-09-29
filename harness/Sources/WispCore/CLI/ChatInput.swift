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
    /// Save the exact context the next request carries, as Markdown and JSON.
    case context
    /// Show wisp's own state (`config`, `status`, `approvals`, `audit`), as the model's `inspect` tool would.
    case inspect(String)
    /// Show the last tool result in full.
    case last
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
        case "context": self = .context
        case "inspect": self = .inspect(argument ?? "status")
        case "status": self = .inspect("status")
        case "audit": self = .inspect(argument.map { "audit \($0)" } ?? "audit")
        case "approvals": self = .approvals(ApprovalsRequest(argument))
        case "last": self = .last
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
        /context         save the exact context the model sees next to ~/.wisp/context, as Markdown and JSON
        /status          show wisp's own state: model, tools, policy, session
        /approvals       list standing approvals; /approvals revoke [ID] removes one
        /audit           show the latest audit events of every session, MCP calls included
        /audit sessions  list the sessions in the audit log; /audit ID shows one session's events
        /last            show the last tool result in full
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
