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

    /// The entry point of a further conversation opened under this one.
    public var thread: EntryPoint {
        self == .mcp ? .mcpThread : self
    }
}
