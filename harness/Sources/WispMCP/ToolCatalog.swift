import Foundation
import MCP
import WispCore

/// The tools wisp advertises to MCP clients, with their JSON Schemas.
///
/// These are deliberately few: each schema costs the caller context, and the
/// on-device model behind `respond` has a small window of its own.
public enum ToolCatalog {
    /// Runs a task on the on-device model, with wisp's own tools available to it.
    public static let respond = Tool(
        name: "respond",
        description:
            "Run a task on this Mac's on-device Apple Foundation Model (or Apple's Private Cloud Compute with "
            + "model: private-cloud, or a local Ollama model with model: ollama:<name>). The on-device model is small with a context window "
            + "of about 8k tokens, so keep prompts short and delegate only self-contained tasks such as "
            + "summarising a passage, classifying text, or driving a build or test through its own run_command tool. "
            + "Omit thread_id to start a new conversation; the result's structuredContent.thread_id continues it. "
            + "Read the resource wisp://tools for the tools the model can use and how to prompt for them.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("The task for the model."),
                ]),
                "thread_id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Conversation to continue. Omit to start a new one (an id is generated), or supply an unused "
                            + "id to start one under that name. instructions and tools apply only when a thread starts."
                    ),
                ]),
                "instructions": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Instructions for this thread, added under wisp's own system prompt. Only when a thread "
                            + "starts."),
                ]),
                "tools": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Names of wisp tools the model may call. Omit to allow all registered tools; an empty "
                            + "array gives a text-only thread, which any model can run."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model for a new thread: system (on device, default), private-cloud (Apple Private Cloud "
                            + "Compute; data leaves the Mac), or ollama:<name> (a local Ollama model). Only when a "
                            + "thread starts."),
                ]),
                "task": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The thread's task, in a sentence: kept as a fact and shown to the model next to each "
                            + "request. Given when a thread starts or later to revise it; wisp://threads/{thread_id}/facts "
                            + "shows it."),
                ]),
                "schema": .object([
                    "type": .string("object"),
                    "description": .string(
                        "JSON Schema for this reply: an object with typed properties (string with enum, integer, "
                            + "number, boolean, array of one type, nested objects; required marks the rest optional). "
                            + "The reply is JSON of that shape, also in structuredContent.output. Per call."),
                ]),
            ]),
            "required": .array([.string("prompt")]),
        ]),
        annotations: .init(title: "Respond on device", readOnlyHint: false, openWorldHint: false)
    )

    /// Runs or reads build/test output on this Mac and returns only the failures.
    public static let triage = Tool(
        name: "triage",
        description:
            "Run a build or test command on this Mac (or read an output file already here) and return only "
            + "its failures as a structured list: kind, location, message. The raw output stays on this Mac; "
            + "the on-device model reads it in chunks. Give exactly one of command or path.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line to run with /bin/sh -c under wisp's policy, sandbox, and approval, "
                            + "such as: swift test 2>&1"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of an output file on this Mac to triage instead."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model to judge the chunks with; as for respond. Default: the configured one."),
                ]),
                "max_findings": .object([
                    "type": .string("integer"),
                    "description": .string("Findings to return at most (default 20); more is flagged."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Triage build or test output", readOnlyHint: false, openWorldHint: false)
    )

    /// Summarises a diff on this Mac: files, one line each, and review flags.
    public static let summariseDiff = Tool(
        name: "summarise_diff",
        description:
            "Run a command that prints a unified diff on this Mac (such as git diff), or read a diff file already "
            + "here, and return a per-file summary: path, change kind, lines added and removed, one line on what "
            + "changed, plus flags for deleted tests, secrets, binary or generated content. The diff stays on this "
            + "Mac; the on-device model reads it in chunks. Give exactly one of command or path.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line that prints a unified diff, run with /bin/sh -c under wisp's policy, "
                            + "sandbox, and approval, such as: git diff HEAD~3"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of a diff file on this Mac to summarise instead."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model to judge the chunks with; as for respond. Default: the configured one."),
                ]),
                "max_files": .object([
                    "type": .string("integer"),
                    "description": .string("Files to list at most (default 40); the rest are counted in more."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Summarise a diff", readOnlyHint: false, openWorldHint: false)
    )

    /// Scans command output or a file on this Mac for credentials and personal data, reporting them masked.
    public static let scanSecrets = Tool(
        name: "scan_secrets",
        description:
            "Scan a command's output (such as git diff --cached before a commit) or a file on this Mac for "
            + "credentials, and optionally personal data, by rule. Returns kind, location (path:line for a diff's "
            + "added lines), and a masked preview; values never leave this Mac. Give exactly one of command or path.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line whose output to scan, run with /bin/sh -c under wisp's policy, sandbox, "
                            + "and approval, such as: git diff --cached"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of a file on this Mac to scan instead."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model for the thorough pass; as for respond. Default: the configured one."),
                ]),
                "thorough": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Also have the on-device model look for what rules cannot recognise: names, addresses, "
                            + "customer numbers, unusual credentials. Slower: about 2 s per 4 KiB. Default false."),
                ]),
                "personal": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Report personal data too: emails, phone and card numbers, IPs. Default false."),
                ]),
                "max_findings": .object([
                    "type": .string("integer"),
                    "description": .string("Findings to return at most (default 50); more is flagged."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Scan for secrets", readOnlyHint: false, openWorldHint: false)
    )

    /// Returns command output or a file with credentials and personal data replaced by markers.
    public static let redact = Tool(
        name: "redact",
        description:
            "Return a command's output or a file on this Mac with credentials and personal data replaced by "
            + "numbered markers such as [REDACTED:email#1], so you can read a log, crash report, or data file "
            + "without its secrets. Rules always run; thorough adds the on-device model. Give exactly one of "
            + "command or path.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line whose output to redact, run with /bin/sh -c under wisp's policy, sandbox, "
                            + "and approval, such as: tail -500 app.log"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of a file on this Mac to redact instead."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Model for the thorough pass; as for respond. Default: the configured one."),
                ]),
                "thorough": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Also have the on-device model look for what rules cannot recognise: names, addresses, "
                            + "customer numbers, unusual credentials. Slower: about 2 s per 4 KiB. Default false."),
                ]),
                "secrets_only": .object([
                    "type": .string("boolean"),
                    "description": .string("Replace credentials only and keep personal data. Default false."),
                ]),
                "max_bytes": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Bytes of redacted text to return at most (default 32768); more is flagged."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Redact secrets and personal data", readOnlyHint: false, openWorldHint: false)
    )

    /// Condenses a log or a crash report on this Mac to its distinct messages, without a model.
    public static let condenseLog = Tool(
        name: "condense_log",
        description:
            "Condense a log on this Mac (an app log, CI output, or the unified log) to its distinct messages: lines "
            + "grouped by template with timestamps and ids removed, ranked by severity then count, with line ranges "
            + "and first and last timestamps. For the unified log give last (such as 10m), optionally with process "
            + "or subsystem; /usr/bin/log refuses to run in the sandbox. A macOS crash report (.ips) comes back as "
            + "the process, exception, and faulting thread's frames. No model; up to 8 MiB. Give exactly one of "
            + "command, path, or last.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line whose output to read, run with /bin/sh -c under wisp's policy, sandbox, "
                            + "and approval, such as: tail -20000 app.log"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of a file on this Mac to read instead."),
                ]),
                "last": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Read this Mac's unified log for this long back instead: 90s, 10m, 2h (at most 24h)."),
                ]),
                "process": .object([
                    "type": .string("string"),
                    "description": .string("With last: only this process, by name, such as Safari."),
                ]),
                "subsystem": .object([
                    "type": .string("string"),
                    "description": .string("With last: only subsystems starting with this, such as com.apple.network."),
                ]),
                "max_groups": .object([
                    "type": .string("integer"),
                    "description": .string("Message groups to return at most (default 30); more is flagged."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Condense a log", readOnlyHint: false, openWorldHint: false)
    )

    /// Outlines a JSON document or JSON Lines on this Mac without its data.
    public static let jsonShape = Tool(
        name: "json_shape",
        description:
            "Describe the structure of a JSON document or JSON Lines file on this Mac, or a command's JSON output, "
            + "without its data: each key's types, optional keys, array lengths, number ranges, and short string "
            + "examples with secrets and personal data redacted. Arrays of records merge into one outline. No model; "
            + "up to 16 MiB. Give exactly one of command or path.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Shell command line whose output to read, run with /bin/sh -c under wisp's policy, sandbox, "
                            + "and approval, such as: curl -s https://api.example.com/items"),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory to run the command in. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of a file on this Mac to read instead."),
                ]),
                "max_depth": .object([
                    "type": .string("integer"),
                    "description": .string("Levels of nesting to describe (default 8)."),
                ]),
                "examples": .object([
                    "type": .string("boolean"),
                    "description": .string("Show a short, redacted example for strings. Default true."),
                ]),
            ]),
            "required": .array([]),
        ]),
        annotations: .init(title: "Outline JSON", readOnlyHint: false, openWorldHint: false)
    )

    /// The `command` and `working_directory` or `path` properties every capturing condenser shares.
    static func sourceProperties(example: String) -> [String: Value] {
        [
            "command": .object([
                "type": .string("string"),
                "description": .string(
                    "Shell command line whose output to read, run with /bin/sh -c under wisp's policy, sandbox, "
                        + "and approval, such as: \(example)"),
            ]),
            "working_directory": .object([
                "type": .string("string"),
                "description": .string("Absolute directory to run the command in. Default: wisp's."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string("Absolute path of a file on this Mac to read instead."),
            ]),
        ]
    }

    /// Reduces a dependency audit to what needs action.
    public static let dependencyAudit = Tool(
        name: "dependency_audit",
        description:
            "Reduce a dependency audit on this Mac to what needs action: npm audit --json, cargo audit --json, or "
            + "pip-audit -f json, as one line per advisory with package, version, severity, id, title, and the fix, "
            + "most severe and fixable first, plus cargo's unmaintained and yanked crates. No model. Give exactly one "
            + "of command or path; the audit exiting non-zero because it found something is expected.",
        inputSchema: .object([
            "type": .string("object"), "properties": .object(sourceProperties(example: "npm audit --json")),
            "required": .array([]),
        ]),
        annotations: .init(title: "Condense a dependency audit", readOnlyHint: false, openWorldHint: false)
    )

    /// Finds flaky tests by comparing runs.
    public static let flakyTests = Tool(
        name: "flaky_tests",
        description:
            "Find flaky tests by comparing two or more runs of a test suite on this Mac: tests that passed in some "
            + "runs and failed in others, and tests that failed in every run. Reads swift test, XCTest, cargo test, "
            + "pytest -rA, and go test -v output. No model. Give paths of saved runs, or a command and how many "
            + "times to run it.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(
                sourceProperties(example: "swift test --filter ParserTests").filter { $0.key != "path" }.merging([
                    "paths": .object([
                        "type": .string("array"), "items": .object(["type": .string("string")]),
                        "description": .string("Absolute paths of two or more saved runs' output."),
                    ]),
                    "runs": .object([
                        "type": .string("integer"),
                        "description": .string("With command: times to run it, 2 to 10 (default 3)."),
                    ]),
                ]) { $1 }),
            "required": .array([]),
        ]),
        annotations: .init(title: "Find flaky tests", readOnlyHint: false, openWorldHint: false)
    )

    /// Reduces a profile to its hot paths.
    public static let hotPaths = Tool(
        name: "hot_paths",
        description:
            "Reduce a profile on this Mac to where the time goes: folded stacks (frame;frame;frame count, from "
            + "stackcollapse-perf, py-spy record -f raw, cargo flamegraph, or pprof -raw) read into the functions "
            + "with the most self time and the heaviest call paths, as shares of all samples. No model. Give exactly "
            + "one of command or path.",
        inputSchema: .object([
            "type": .string("object"), "properties": .object(sourceProperties(example: "cat profile.folded")),
            "required": .array([]),
        ]),
        annotations: .init(title: "Find hot paths", readOnlyHint: false, openWorldHint: false)
    )

    /// Drafts a commit message, a pull request description, or a changelog line from a diff.
    public static let draftChange = Tool(
        name: "draft_change",
        description:
            "Draft a commit message, a pull request description, or a changelog line from a diff on this Mac "
            + "(default: git diff --cached). The on-device model summarises the diff per file, then writes from "
            + "that summary; the subject is kept under 72 characters and the commit body ends with a line for the "
            + "reason, which a diff cannot give. Review and edit before use.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("commit"), .string("pr"), .string("changelog")]),
                    "description": .string("What to draft."),
                ]),
                "command": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Command that prints the diff, run under wisp's policy, sandbox, and approval. Default: "
                            + "git diff --cached."),
                ]),
                "working_directory": .object([
                    "type": .string("string"),
                    "description": .string("Absolute directory of the repository. Default: wisp's."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of a diff file on this Mac to use instead."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string("Model to write with; as for respond. Default: the configured one."),
                ]),
            ]),
            "required": .array([.string("kind")]),
        ]),
        annotations: .init(title: "Draft a commit message or PR", readOnlyHint: false, openWorldHint: false)
    )

    /// Ends a conversation thread and frees its model session.
    public static let closeThread = Tool(
        name: "close_thread",
        description: "End a respond conversation thread and free its model session.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "thread_id": .object([
                    "type": .string("string"),
                    "description": .string("The thread to close."),
                ])
            ]),
            "required": .array([.string("thread_id")]),
        ]),
        annotations: .init(title: "Close thread", readOnlyHint: false, idempotentHint: false, openWorldHint: false)
    )

    /// Every tool, in the order clients see them.
    public static var all: [Tool] {
        [
            respond, triage, summariseDiff, draftChange, scanSecrets, redact, condenseLog, jsonShape, dependencyAudit,
            flakyTests, hotPaths, closeThread,
        ]
    }

    /// URI of the JSON resource describing the model's tools.
    public static let toolsResourceURI = "wisp://tools"
    /// URI of the Markdown resource describing the model's tools.
    public static let toolsMarkdownResourceURI = "wisp://tools.md"
    /// URI of the effective configuration.
    public static let configResourceURI = "wisp://config"
    /// URI of the server's status: session, threads, approvals in force.
    public static let statusResourceURI = "wisp://status"
    /// URI of the standing approvals.
    public static let approvalsResourceURI = "wisp://approvals"
    /// URI of the most recent audit events across every session.
    public static let auditResourceURI = "wisp://audit"
    /// URI of the measurements: what the eval harness found each delegated task achieves.
    public static let measurementsResourceURI = "wisp://measurements"
    /// Template for the audit events of one session that is not a `respond` thread (the server's own, a
    /// condensing tool's, a CLI run's); a thread's are under `threadAuditTemplate`.
    public static let auditTemplate = "wisp://audit/{session}"
    /// URI of the server's `respond` threads, open or not.
    public static let threadsResourceURI = "wisp://threads"
    /// Template for one thread's summary.
    public static let threadTemplate = "wisp://threads/{thread_id}"
    /// Template for a thread's tool calls.
    public static let threadOutputListTemplate = "wisp://threads/{thread_id}/output"
    /// Template for one tool call's output in a thread, by the `id` a `respond` result's `calls` give it.
    public static let outputTemplate = "wisp://threads/{thread_id}/output/{id}"
    /// Template for a thread's audit events.
    public static let threadAuditTemplate = "wisp://threads/{thread_id}/audit"

    /// The URI of thread `id`'s summary; its other resources are under it.
    public static func threadURI(_ id: String) -> String { "\(threadsResourceURI)/\(id)" }

    /// The URI of the output with audit event `id` in `thread`.
    public static func outputURI(thread: String, id: String) -> String { "\(threadURI(thread))/output/\(id)" }

    /// Template for a thread's turns, with what changed in the model's context at each.
    public static let contextListTemplate = "wisp://threads/{thread_id}/context"
    /// Template for the context composed at the start of one turn.
    public static let contextTurnTemplate = "wisp://threads/{thread_id}/context/{turn}"
    /// Template for the context the thread's next request carries.
    public static let contextNextTemplate = "wisp://threads/{thread_id}/context/next"

    /// Template for a thread's own facts.
    public static let factsTemplate = "wisp://threads/{thread_id}/facts"
    /// Template for one of a thread's facts, with its history.
    public static let factTemplate = "wisp://threads/{thread_id}/facts/{fact_id}"
    /// URI of the permanent facts in the shared store.
    public static let factsResourceURI = "wisp://facts"
    /// Template for one permanent fact, with its history.
    public static let permanentFactTemplate = "wisp://facts/{fact_id}"
    /// URI of the permanent facts proposed in the server's conversations, awaiting the person.
    public static let proposedFactsResourceURI = "wisp://facts/proposed"
    /// URI of the session's ephemeral facts, shared by every thread of the server.
    public static let sessionFactsResourceURI = "wisp://session/facts"

    /// The resources wisp advertises.
    public static let resources: [Resource] = [
        Resource(
            name: "wisp tools", uri: toolsResourceURI, title: "Tools the on-device model can use",
            description:
                "Name, description, JSON Schema arguments, limits, and an example respond prompt for each tool. "
                + "Generated from the same types the model sees.",
            mimeType: "application/json"),
        Resource(
            name: "wisp tools (Markdown)", uri: toolsMarkdownResourceURI, title: "How to prompt for wisp's tools",
            description: "The same catalogue as readable Markdown with prompting rules.", mimeType: "text/markdown"),
        Resource(
            name: "wisp config", uri: configResourceURI, title: "Effective configuration",
            description: "Every setting with defaults applied, the model, the policy, and where the files are.",
            mimeType: "application/json"),
        Resource(
            name: "wisp status", uri: statusResourceURI, title: "Server status",
            description: "The server session, how many threads are open (wisp://threads lists them), and "
                + "approvals in force.",
            mimeType: "application/json"),
        Resource(
            name: "wisp threads", uri: threadsResourceURI, title: "The server's respond threads",
            description:
                "Each thread's id, model, turns, when it was created and last active, whether it is open, and its "
                + "URI; most recently active first, paged with ?page=N.",
            mimeType: "application/json"),
        Resource(
            name: "wisp approvals", uri: approvalsResourceURI, title: "Standing command approvals",
            description: "Project and always approvals with pattern, directory, scope, expiry, and source.",
            mimeType: "application/json"),
        Resource(
            name: "wisp audit", uri: auditResourceURI, title: "Recent audit events",
            description:
                "The last 100 audit events across every session, as JSON Lines; the full log is in the audit file.",
            mimeType: "application/x-ndjson"),
        Resource(
            name: "wisp permanent facts", uri: factsResourceURI, title: "Permanent facts, kept across sessions",
            description:
                "The facts in the shared store (~/.wisp/facts.json), which only the person admits: each with its "
                + "source, value, when it was approved, and its URI; ?all=true adds superseded and deleted versions; "
                + "paged with ?page=N.",
            mimeType: "application/json"),
        Resource(
            name: "wisp proposed facts", uri: proposedFactsResourceURI,
            title: "Permanent facts proposed in any thread, awaiting the person",
            description:
                "Facts a tool or the model proposed as permanent in any conversation of this server, not yet approved "
                + "or declined, each with its thread and whether the person was asked; paged with ?page=N.",
            mimeType: "application/json"),
        Resource(
            name: "wisp session facts", uri: sessionFactsResourceURI,
            title: "The session's facts about the machine now",
            description:
                "Ephemeral facts (a listening port, the machine) shared by every thread of this server and gone "
                + "with it; ?all=true adds superseded versions; paged with ?page=N.",
            mimeType: "application/json"),
        Resource(
            name: "wisp measurements", uri: measurementsResourceURI, title: "What each delegated task achieved",
            description:
                "Eval results per task and model (passed/total, date, what a pass is), recorded by scripts/check "
                + "eval and shipped with this build; a caller reads them to know which delegations are reliable.",
            mimeType: "application/json"),
    ]

    /// Resource templates wisp advertises.
    public static let resourceTemplates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: auditTemplate, name: "wisp audit for one session",
            title: "Audit events of one session that is not a thread",
            description:
                "Every event of the given session id (the server's, a condensing tool's such as triage-<id>, a CLI "
                + "run's), as JSON Lines; a respond thread's are at wisp://threads/{thread_id}/audit.",
            mimeType: "application/x-ndjson"),
        Resource.Template(
            uriTemplate: threadTemplate, name: "wisp thread", title: "One respond thread",
            description:
                "The thread's model, tools, whether it has instructions, turns, whether it is open, and the URIs "
                + "of its context, output, and audit.",
            mimeType: "application/json"),
        Resource.Template(
            uriTemplate: threadOutputListTemplate, name: "wisp thread tool calls",
            title: "A thread's tool calls",
            description:
                "Each call's turn, tool, arguments or command, exit status, size, and its output's URI, from the "
                + "audit log; paged with ?page=N.",
            mimeType: "application/json"),
        Resource.Template(
            uriTemplate: outputTemplate, name: "wisp tool output",
            title: "One tool call's output in a respond thread",
            description:
                "The output a tool returned, verbatim from the audit log, by the id a respond result's calls give "
                + "it; the result names this URI as outputURI when the output was too large to inline.",
            mimeType: "text/plain"),
        Resource.Template(
            uriTemplate: threadAuditTemplate, name: "wisp thread audit", title: "Audit events of one respond thread",
            description: "Every event of the thread, as JSON Lines, for reconstructing what a delegated task did.",
            mimeType: "application/x-ndjson"),
        Resource.Template(
            uriTemplate: contextListTemplate, name: "wisp thread context turns",
            title: "The turns of a thread's model context",
            description:
                "Each turn with its time, the start of its prompt, the tokens composed for it, what changed since "
                + "the turn before (condensed, cut, referenced), and its URI; paged with ?page=N.",
            mimeType: "application/json"),
        Resource.Template(
            uriTemplate: contextTurnTemplate, name: "wisp thread context at a turn",
            title: "The model's context at the start of one turn",
            description:
                "The context wisp composed for the turn, entry by entry under its store id, with the turn's own "
                + "entries marked; composed from the thread's store, at no model cost. Paged with ?page=N.",
            mimeType: "text/markdown"),
        Resource.Template(
            uriTemplate: contextNextTemplate, name: "wisp thread next context",
            title: "The context the thread's next request carries",
            description:
                "What chat's /inspect context saves, for a thread: the next request's context, entry by entry.",
            mimeType: "text/markdown"),
        Resource.Template(
            uriTemplate: factsTemplate, name: "wisp thread facts",
            title: "A thread's own facts",
            description:
                "The thread's own facts (its task, the state of the work, its proposed permanent facts), each with "
                + "its source, class, value, any conflict, and its URI; ?all=true adds superseded and deleted "
                + "versions; paged with ?page=N. The session's are at wisp://session/facts, the permanent ones at "
                + "wisp://facts, and all of them as the model is given them at wisp://threads/{thread_id}/context/next.",
            mimeType: "application/json"),
        Resource.Template(
            uriTemplate: factTemplate, name: "wisp thread fact history",
            title: "One of a thread's facts and every version of what it is about",
            description: "The fact, and every version the thread holds of its subject and name, oldest first.",
            mimeType: "application/json"),
        Resource.Template(
            uriTemplate: permanentFactTemplate, name: "wisp permanent fact history",
            title: "One permanent fact and every version of what it is about",
            description:
                "The fact (an id starting with p), and every version the shared store holds of its subject and "
                + "name, oldest first.",
            mimeType: "application/json"),
    ]
}

/// Validates a client-supplied thread id: 1 to 64 characters from `[A-Za-z0-9._-]`.
///
/// - Throws: `MCPError.invalidParams` otherwise.
func validateThreadID(_ id: String) throws {
    guard SafeName.isValid(id) else { throw MCPError.invalidParams("'thread_id' must be \(SafeName.rule)") }
}

/// Decoded arguments for the `respond` tool.
public struct RespondRequest: Equatable, Sendable {
    /// The task for the model.
    public var prompt: String
    /// Optional session instructions; nil means the server default.
    public var instructions: String?
    /// Which wisp tools to enable; `.all` means the server's set.
    public var tools: ToolSelection
    /// Thread to continue or create; nil means start a new thread with a generated id.
    public var threadID: String?
    /// Model for a new thread; nil means the server default.
    public var model: ModelSelection?
    /// JSON Schema the reply must take, for this call only; nil means prose.
    public var schema: JSONValue?
    /// The thread's task, set or revised as the caller's assertion (D6); nil leaves it as it is.
    public var task: String?

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` if `prompt` is missing or a field has the wrong type.
    public init(arguments: [String: Value]?) throws {
        guard let prompt = arguments?["prompt"]?.stringValue, !prompt.isEmpty else {
            throw MCPError.invalidParams("'prompt' is required and must be a non-empty string")
        }
        self.prompt = prompt
        if let raw = arguments?["instructions"] {
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'instructions' must be a string") }
            instructions = text
        }
        if let raw = arguments?["tools"] {
            guard let items = raw.arrayValue else { throw MCPError.invalidParams("'tools' must be an array") }
            let names = try items.map {
                guard let name = $0.stringValue else { throw MCPError.invalidParams("'tools' items must be strings") }
                return name
            }
            tools = names.isEmpty ? ToolSelection.none : .named(names)
        } else {
            tools = .all
        }
        if let raw = arguments?["thread_id"] {
            guard let id = raw.stringValue else { throw MCPError.invalidParams("'thread_id' must be a string") }
            try validateThreadID(id)
            threadID = id
        }
        if let raw = arguments?["model"] {
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'model' must be a string") }
            do {
                model = try ModelSelection(parsing: text)
            } catch {
                throw MCPError.invalidParams("\(error)")
            }
        }
        if let raw = arguments?["task"] {
            guard let text = raw.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("'task' must be a non-empty string")
            }
            task = text
        }
        if let raw = arguments?["schema"] {
            guard raw.objectValue != nil else { throw MCPError.invalidParams("'schema' must be a JSON Schema object") }
            schema = JSONValue(raw)
        }
    }
}

/// The arguments every condensing tool shares: one source, an optional model.
public struct CondensingRequest: Equatable, Sendable {
    /// What to condense.
    public var source: Triage.Source
    /// Model for the judging turns; nil means the server default.
    public var model: ModelSelection?

    /// Decodes `command`/`working_directory` or `path`, and `model`.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` unless exactly one of `command` and `path` is a non-empty string.
    public init(arguments: [String: Value]?) throws {
        let command = arguments?["command"]
        let path = arguments?["path"]
        switch (command, path) {
        case (let command?, nil):
            guard let line = command.stringValue, !line.isEmpty else {
                throw MCPError.invalidParams("'command' must be a non-empty string")
            }
            var directory: String?
            if let raw = arguments?["working_directory"] {
                guard let text = raw.stringValue else {
                    throw MCPError.invalidParams("'working_directory' must be a string")
                }
                directory = text
            }
            source = .command(line, workingDirectory: directory)
        case (nil, let path?):
            guard let file = path.stringValue, !file.isEmpty else {
                throw MCPError.invalidParams("'path' must be a non-empty string")
            }
            source = .path(file)
        default:
            throw MCPError.invalidParams("give exactly one of 'command' and 'path'")
        }
        if let raw = arguments?["model"] {
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'model' must be a string") }
            do {
                model = try ModelSelection(parsing: text)
            } catch {
                throw MCPError.invalidParams("\(error)")
            }
        }
    }

    /// A boolean argument, or `fallback` when absent.
    ///
    /// - Throws: `MCPError.invalidParams` when present and not a boolean.
    static func flag(_ arguments: [String: Value]?, _ name: String, fallback: Bool) throws -> Bool {
        guard let raw = arguments?[name] else { return fallback }
        guard let flag = raw.boolValue else { throw MCPError.invalidParams("'\(name)' must be a boolean") }
        return flag
    }

    /// A positive integer argument, or `fallback` when absent.
    ///
    /// - Throws: `MCPError.invalidParams` when present and not a positive integer.
    static func count(_ arguments: [String: Value]?, _ name: String, fallback: Int) throws -> Int {
        guard let raw = arguments?[name] else { return fallback }
        guard let count = raw.intValue, count > 0 else {
            throw MCPError.invalidParams("'\(name)' must be a positive integer")
        }
        return count
    }
}

/// Decoded arguments for the `triage` tool.
public struct TriageRequest: Equatable, Sendable {
    /// What to triage.
    public var source: Triage.Source
    /// Model for the judging turns; nil means the server default.
    public var model: ModelSelection?
    /// Findings to keep at most.
    public var maxFindings: Int

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` as `CondensingRequest`, or for a bad `max_findings`.
    public init(arguments: [String: Value]?) throws {
        let shared = try CondensingRequest(arguments: arguments)
        source = shared.source
        model = shared.model
        maxFindings = try CondensingRequest.count(arguments, "max_findings", fallback: Triage.Options().maxFindings)
    }
}

/// Decoded arguments for the `summarise_diff` tool.
public struct SummariseDiffRequest: Equatable, Sendable {
    /// What to summarise.
    public var source: Triage.Source
    /// Model for the judging turns; nil means the server default.
    public var model: ModelSelection?
    /// Files to list at most.
    public var maxFiles: Int

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` as `CondensingRequest`, or for a bad `max_files`.
    public init(arguments: [String: Value]?) throws {
        let shared = try CondensingRequest(arguments: arguments)
        source = shared.source
        model = shared.model
        maxFiles = try CondensingRequest.count(arguments, "max_files", fallback: DiffSummary.Options().maxFiles)
    }
}

/// Decoded arguments for the `scan_secrets` tool.
public struct ScanSecretsRequest: Equatable, Sendable {
    /// What to scan.
    public var source: Triage.Source
    /// Model for the thorough pass; nil means the server default.
    public var model: ModelSelection?
    /// Categories, the model pass, and the cap.
    public var options: SecretScan.Options

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` as `CondensingRequest`, or for a bad flag or count.
    public init(arguments: [String: Value]?) throws {
        let shared = try CondensingRequest(arguments: arguments)
        source = shared.source
        model = shared.model
        options = SecretScan.Options(
            categories: try CondensingRequest.flag(arguments, "personal", fallback: false)
                ? [.secret, .personal] : [.secret],
            thorough: try CondensingRequest.flag(arguments, "thorough", fallback: false),
            maxFindings: try CondensingRequest.count(
                arguments, "max_findings", fallback: SecretScan.Options().maxFindings))
    }
}

/// Decoded arguments for the `redact` tool.
public struct RedactRequest: Equatable, Sendable {
    /// What to redact.
    public var source: Triage.Source
    /// Model for the thorough pass; nil means the server default.
    public var model: ModelSelection?
    /// Categories, the model pass, and the output cap.
    public var options: Redaction.Options

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` as `CondensingRequest`, or for a bad flag or count.
    public init(arguments: [String: Value]?) throws {
        let shared = try CondensingRequest(arguments: arguments)
        source = shared.source
        model = shared.model
        options = Redaction.Options(
            categories: try CondensingRequest.flag(arguments, "secrets_only", fallback: false)
                ? [.secret] : [.secret, .personal],
            thorough: try CondensingRequest.flag(arguments, "thorough", fallback: false),
            maxOutputBytes: try CondensingRequest.count(
                arguments, "max_bytes", fallback: Redaction.Options().maxOutputBytes))
    }
}

/// Decoded arguments for the `condense_log` tool.
public struct CondenseLogRequest: Equatable, Sendable {
    /// Bytes of log read; only the tail beyond this.
    static let maxBytes = 8 << 20
    /// Where the log comes from.
    public enum Origin: Equatable, Sendable {
        /// A command's output or a file.
        case captured(Triage.Source)
        /// This Mac's unified log, read in process.
        case unified(UnifiedLog.Query)
    }
    /// What to condense.
    public var origin: Origin
    /// Groups to return at most.
    public var maxGroups: Int

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` as `CondensingRequest`, for `last` beside a command or path, a bad
    ///   duration, or a bad `max_groups`.
    public init(arguments: [String: Value]?) throws {
        if let raw = arguments?["last"] {
            guard arguments?["command"] == nil, arguments?["path"] == nil else {
                throw MCPError.invalidParams("give exactly one of 'command', 'path', or 'last'")
            }
            guard let text = raw.stringValue else { throw MCPError.invalidParams("'last' must be a string") }
            let seconds: Int
            do {
                seconds = try UnifiedLog.seconds(in: text)
            } catch {
                throw MCPError.invalidParams("'last': \(error)")
            }
            origin = .unified(
                .init(
                    seconds: seconds, process: arguments?["process"]?.stringValue,
                    subsystem: arguments?["subsystem"]?.stringValue))
        } else {
            origin = .captured(try CondensingRequest(arguments: arguments).source)
        }
        maxGroups = try CondensingRequest.count(arguments, "max_groups", fallback: LogDigest.Options().maxGroups)
    }
}

/// Decoded arguments for the `json_shape` tool.
public struct JSONShapeRequest: Equatable, Sendable {
    /// Bytes of JSON read; more is refused.
    static let maxBytes = 16 << 20
    /// What to outline.
    public var source: Triage.Source
    /// Depth and examples.
    public var options: JSONShape.Options

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` as `CondensingRequest`, or for a bad `max_depth` or `examples`.
    public init(arguments: [String: Value]?) throws {
        source = try CondensingRequest(arguments: arguments).source
        options = JSONShape.Options(
            maxDepth: try CondensingRequest.count(arguments, "max_depth", fallback: JSONShape.Options().maxDepth),
            examples: try CondensingRequest.flag(arguments, "examples", fallback: true))
    }
}

/// Decoded arguments for the `flaky_tests` tool: saved runs, or a command to run several times.
public struct FlakyTestsRequest: Equatable, Sendable {
    /// Where the runs come from.
    public enum Runs: Equatable, Sendable {
        /// Files, one per run.
        case paths([String])
        /// A command, run `count` times.
        case command(Triage.Source, count: Int)
    }

    /// Runs allowed from one command.
    static let maxRuns = 10
    /// The runs to compare.
    public var runs: Runs

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` unless exactly one of `paths` (two or more) and `command` is given,
    ///   with `runs` from 2 to 10.
    public init(arguments: [String: Value]?) throws {
        switch (arguments?["paths"], arguments?["command"]) {
        case (let paths?, nil):
            guard let list = paths.arrayValue?.compactMap(\.stringValue), list.count >= 2,
                list.count == paths.arrayValue?.count
            else { throw MCPError.invalidParams("'paths' must list two or more file paths") }
            runs = .paths(list)
        case (nil, .some):
            let count = try CondensingRequest.count(arguments, "runs", fallback: 3)
            guard (2...Self.maxRuns).contains(count) else {
                throw MCPError.invalidParams("'runs' must be from 2 to \(Self.maxRuns)")
            }
            runs = .command(try CondensingRequest(arguments: arguments).source, count: count)
        default:
            throw MCPError.invalidParams("give exactly one of 'paths' and 'command'")
        }
    }
}

/// Decoded arguments for the `draft_change` tool.
public struct DraftChangeRequest: Equatable, Sendable {
    /// What to draft.
    public var kind: ChangeDraft.Kind
    /// Where the diff comes from; `git diff --cached` when the call names neither a command nor a path.
    public var source: Triage.Source
    /// Model for the summarising and writing turns; nil means the server default.
    public var model: ModelSelection?

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` for a missing or unknown `kind`, or as `CondensingRequest`.
    public init(arguments: [String: Value]?) throws {
        guard let text = arguments?["kind"]?.stringValue, let kind = ChangeDraft.Kind(rawValue: text) else {
            throw MCPError.invalidParams("'kind' is required: commit, pr, or changelog")
        }
        self.kind = kind
        if arguments?["command"] == nil, arguments?["path"] == nil {
            var defaulted = arguments ?? [:]
            defaulted["command"] = .string("git diff --cached")
            let shared = try CondensingRequest(arguments: defaulted)
            (source, model) = (shared.source, shared.model)
        } else {
            let shared = try CondensingRequest(arguments: arguments)
            (source, model) = (shared.source, shared.model)
        }
    }
}

/// Decoded arguments for the `close_thread` tool.
public struct CloseThreadRequest: Equatable, Sendable {
    /// The thread to close.
    public var threadID: String

    /// Decodes and validates MCP call arguments.
    ///
    /// - Parameter arguments: The raw `tools/call` arguments.
    /// - Throws: `MCPError.invalidParams` if `thread_id` is missing or malformed.
    public init(arguments: [String: Value]?) throws {
        guard let id = arguments?["thread_id"]?.stringValue else {
            throw MCPError.invalidParams("'thread_id' is required and must be a string")
        }
        try validateThreadID(id)
        threadID = id
    }
}
