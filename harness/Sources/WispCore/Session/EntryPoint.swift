/// Which face of wisp a session belongs to. Recorded on `session.start` and on standing approvals,
/// and the closed set `docs/logging.md` documents.
public enum EntryPoint: String, Sendable, Codable, CaseIterable {
    /// `wisp respond`: one prompt, one reply.
    case respond
    /// `wisp chat`: the interactive REPL.
    case chat
    /// `wisp mcp`: the server session that owns every thread.
    case mcp
    /// One MCP `thread_id`, a conversation under an `mcp` session.
    case mcpThread = "mcp-thread"
    /// `wisp notify`, a person posting a notification.
    case notify
    /// `wisp scan`, a scan for credentials and personal data.
    case scan
    /// `wisp redact`, text redacted on its way somewhere else.
    case redact
    /// `wisp watch`, a command rerun as files change.
    case watch
    /// `wisp draft`, a commit message or PR drafted from a diff.
    case draft
    /// `wisp config set` or `unset`, a setting changed from the command line.
    case config
    /// `wisp classifier`, a risk classifier trained or measured.
    case classifier
    /// `wisp approvals pending`, `approve`, or `deny`: the person answering a command waiting under `wisp mcp`.
    case approvals
    /// `wisp facts pending`, `keep`, or `drop`: the person answering a caller's request to keep a permanent fact.
    case facts
    /// `wisp questions pending`, `answer`, or `decline`: the person answering the model's question (ADR 0062).
    case questions
    /// `wisp models pull`: the person fetching a model (ADR 0052).
    case models
    /// `wisp threads delete` or `hand`: the person changing the thread store (ADR 0066, phase 3).
    case threads
    /// `wisp update`, or the Finder dialog's check and update (ADR 0074).
    case update
    /// `wisp llamacpp serve`: wisp's own llama.cpp server starting, as its LaunchAgent runs it (ADR 0082).
    case llamacpp

    /// The entry point of a further conversation opened under this one.
    public var thread: EntryPoint {
        self == .mcp ? .mcpThread : self
    }
}
