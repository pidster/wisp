# Logging: audit and diagnostics

wisp keeps two logs with different jobs. The **audit log** is the record of what the agent was asked,
what it decided, what it ran, and what came back, written verbatim for the user alone. The **diagnostic
log** is for debugging wisp itself and goes through Apple's unified logging.

## Audit log

Location: `~/.wisp/logs/audit.jsonl` (under `$WISP_HOME` when set). JSON Lines, one event per line,
mode `0600`, rotated by size to `audit.1.jsonl` … `audit.N.jsonl`. Every entry point writes to it: `respond`,
`chat`, and `mcp`. It is on by default; `config.json` controls it:

```json
{ "audit": { "enabled": true, "maxFileBytes": 10485760, "keepFiles": 5 } }
```

Content is stored verbatim by decision (prompts, replies, commands, tool output). Treat the file as
sensitive; it is why it is user-only.

### Event envelope

| Field | Meaning |
| --- | --- |
| `schema` | Event schema version, currently 1. |
| `time` | ISO 8601 UTC with milliseconds. |
| `version` | wisp version that wrote it. |
| `pid` | Process id, to separate concurrent wisps sharing a file. |
| `session` | A CLI run, a chat, an MCP server, or an MCP thread (its `thread_id`). |
| `turn` | 1-based turn within the session, present from the first prompt on. |
| `call` | Pairs a `tool.call` with its `tool.result`, or an `mcp.request` with its `mcp.result`. |
| `kind` | One of the kinds below. |
| `details` | Kind-specific fields. |

### Kinds and their details

| Kind | Details | Written by |
| --- | --- | --- |
| `session.start` | `entryPoint` (`respond`, `chat`, `mcp`, `mcp-thread`, `notify`, `scan`, `redact`, `watch`, `draft`, `classifier`, `config`), `systemPromptExtension` and `instructions` (the operator's and the caller's layers, null when absent; wisp's own prompt is fixed per `version`), `tools`, `model`, `unsafe`, `autoApprove`, `resume`; an MCP thread adds `parent` (the server session's id) and records the same fields through `Session.conversation`; a chat `/new` records `reason` (`new`), `tools`, and `model` only, from `Agent.reset` | `Session`, `Agent` |
| `session.end` | `reason`: `closed` (explicit, or a `triage-<id>` session finishing), `evicted` (least recently used thread dropped at capacity) | CLI, MCP |
| `model.resolved` | `model` (the selection), `backend` (`system`, `private-cloud`, or a scheme), `asset` (what backs a local model, null for Apple's), `capabilities` (declared names), `capabilitySource` (`framework`, `runtime`, `configuration`, `undeclared`), `tools` the conversation opened with, `contextSize` (the window, null when unknown), `contextNote` (why, when the backend chose it, such as "24,576 of 131,072: 9.2 GiB of a 9.8 GiB budget"); recorded when a conversation opens, after the capability check | `Conversation` |
| `prompt` | `text`; `schema` (the caller's JSON Schema) when the reply had to be shaped | `Agent` |
| `response` | `text`, `condensed`, `seconds` | `Agent` |
| `tool.call` | `tool`, `arguments` (JSON as the model produced it) | `AuditedTool` |
| `tool.result` | `tool`, `output`, `bytes`, `seconds` | `AuditedTool` |
| `policy.decision` | `command`, `workingDirectory`, `verdict` (`allowed`, `denied` by pattern, `disapproved` by the gate), `reason`, `sandbox`, `network`, `nested`; recorded once, after the directory check, patterns, and approval | `CommandRunner` |
| `command.outcome` | `command`, `exitStatus`, `timedOut`, `truncated`, `stdout`, `stderr`, `seconds` | `CommandRunner` |
| `secrets.scan` | `source` (`command` and `workingDirectory`, `path`, or `stdin`), `bytes`, `diff`, `thorough`, `findings` (a count), `kinds` (count per kind), `failedChunks` (chunks the model failed on twice, checked by rule only), `classifier` (the personal-data classifier's `personal@<version>`, why it was unavailable, or null without personal data); never a value or a preview | `WispServer`, `wisp scan` |
| `redaction` | `source`, `bytes`, `bytesOut`, `truncated`, `thorough`, `replaced` (occurrences per kind), `failedChunks`; never a value | `WispServer`, `wisp redact` |
| `model.routed` | `task`, `inputBytes`, `model`, `reason` (the measurement that vouched for the model, or why none did, and any fallback; for a task default, whether it is wisp's measured default or `routing.tasks`); one per routed call | `WispServer`, `wisp draft`, `wisp scan`, `wisp redact` |
| `watch.run` | `command`, `run` (from 1), `trigger` (`start`, `change`, `interval`), `exitStatus`, `timedOut`, `state` (`pass`, `fail`), `previous`, `changed`, `seconds`, `findings` (a count, or null when not triaged), `triageError`, `notified`; one per run of `wisp watch` | `wisp watch` |
| `notification` | `title`, `body` (both as bounded for display), `source` (`model`, `user`, `watch`), `outcome` (`posted`, `refused`), `reason` when refused; one per request from the `notify` tool or `wisp notify` | `Notifier` |
| `file.write` | `path`, `mode` (`write`, `append`, `replace`), `created`, `bytesBefore`, `bytesAfter`; recorded after an `edit_file` edit lands, the content being in the `tool.call` arguments | `EditFileTool` |
| `context.condensation` | `turnsBefore`, `turnsAfter`, `contextSize`, `tokenCount`, `savedBefore` and `savedAfter` (the Markdown files holding the transcript before and after, when `audit.enabled`), `reason` (`overflow`: the model refused the prompt and the retry follows; `budget`: the transcript's size (the last request's reported usage, or the model's own count when it reports none) plus the new prompt would pass `contextBudget` of a known window, so the transcript was condensed first) | `Agent` |
| `mcp.request` | `tool`, `arguments` | `WispServer` |
| `mcp.result` | `tool`, `isError`, `text`, `seconds` | `WispServer` |
| `error` | `message`, `context` | anywhere |
| `classifier.verdict` | `command` (one simple command), `pattern`, `line` (when the command is part of a longer line), `level`, `reasons`, `sources`, `seconds`, `metadata` (when a classifier adds facts: `coreml.model`, `coreml.version`, `coreml.contract`, `coreml.label`, `coreml.confidence`, and `coreml.fallback` with the reason when the verdict is a fallback; `classifier.failure`, with the reason, when a model classifier could not judge and fell back to `moderate`; `classifier.cached: true` when the session reused an earlier verdict for the same line and directory; `rules.knownSafe: true` when the rules know the command to be read-only and no model was asked) | `ApprovalGate` |
| `classifier.train` | `path` (the model written), `examplesSource` (`bundled` or the file), `examples`, `perLevel` (examples per level), `trainingAccuracy` (the fraction of its own examples it labels back, a sanity check, not a measurement), `seconds` | `wisp classifier train` |
| `config.change` | `path` (the setting), `old` and `new` (its values, null when unset), `source` (`chat` or `cli`) | `/config set` and `unset`, `wisp config set` and `unset` |
| `approval.requested` | `command`, `pattern`, `line`, `level` | `ApprovalGate` |
| `approval.decided` | `command`, `decision` (`approved` with `scope`, `denied`, `timed-out`, `cached-turn` for a once-approval reused within the same turn, `cached` for session, `cached-project`/`cached-always` for persisted), `reason`, `approvalID`, `expiresAt`, `downgradedFrom` when a dangerous command's persisted scope was reduced to session, `persistError` when the store could not be written | `ApprovalGate` |

Every tool the model can call is wrapped by `AuditedTool`, so a new tool is audited without doing anything.
Each row's fields are spelled once, in `AuditEvent.Details` (one constructor per kind) and
`AuditEvent.fields(for:)`; a test checks every constructor against that set, so this table and the
code cannot drift silently. A new field goes in all three places.

### Reading it

`wisp logs` prints one-line summaries, newest last, across rotated files:

```
wisp logs                                   # everything
wisp logs --session 5fd0cf21                # one session
wisp logs --kind tool.call --kind tool.result --tool run_command
wisp logs --last 20 --json | jq .           # raw events
```

A session's events group on `session`; a tool call and its result share `call`. Saved transcripts in
`~/.wisp/transcripts` hold the same conversation in the framework's own format.

### In code

`AuditLog` records events for one session and stamps turn numbers from the conversation's `TurnClock`; `AuditSink` is where they go
(`FileAuditSink`, `MemoryAuditSink` for tests, `NullAuditSink` when disabled). Sibling logs for other
sessions share a sink via `log(forSession:)`. Events are `AuditEvent` values; add a `Kind` and document it
here. Tests assert on `MemoryAuditSink.events`.

## Diagnostic log

Every component logs through `Diagnostics.<category>` (`agent`, `tools`, `policy`, `mcp`, `chat`, `audit`)
to unified logging under subsystem `com.pidster.wisp`. The MCP SDK's swift-log output is bridged into the
`mcp` category.

```
log stream --predicate 'subsystem == "com.pidster.wisp"' --level debug
WISP_LOG=debug wisp "…"      # also mirror to stderr: debug, info, or error
```

Messages are marked public so they are not redacted. Nothing ever goes to stdout, which stays the MCP
protocol channel.
