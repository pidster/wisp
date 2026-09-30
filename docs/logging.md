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
| `id` | The event's own id: 16 lowercase hex characters, random. A conversation's store refers to the events that recorded its entries by this id rather than copying their content ([context-management.md](context-management.md), "The store and the composer"). Absent from lines written before ids were added. |
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
| `session.start` | `entryPoint` (`respond`, `chat`, `mcp`, `mcp-thread`, `notify`, `scan`, `redact`, `watch`, `draft`, `classifier`, `config`), `systemPromptExtension` and `instructions` (the operator's and the caller's layers, null when absent; wisp's own prompt is fixed per `version`), `tools`, `model`, `unsafe`, `autoApprove`, `resume`, and on a resume whose saved store links entries to audit events (`context-management.md`) `carriedFrom` (the distinct ids of the sessions those events belong to, sorted; absent otherwise); an MCP thread adds `parent` (the server session's id) and records the same fields through `Session.conversation`; a chat `/new` records `reason` (`new`), `tools`, and `model` only, from `Agent.reset` | `Session`, `Agent` |
| `session.end` | `reason`: `closed` (explicit, or a `triage-<id>` session finishing), `evicted` (least recently used thread dropped at capacity) | CLI, MCP |
| `model.resolved` | `model` (the selection), `backend` (`system`, `private-cloud`, or a scheme), `asset` (what backs a local model, null for Apple's), `capabilities` (declared names), `capabilitySource` (`framework`, `runtime`, `configuration`, `undeclared`), `tools` the conversation opened with, `contextSize` (the window, null when unknown), `contextNote` (why, when the backend chose it, such as "24,576 of 131,072: 9.2 GiB of a 9.8 GiB budget"); recorded when a conversation opens, after the capability check | `Conversation` |
| `prompt` | `text`; `schema` (the caller's JSON Schema) when the reply had to be shaped | `Agent` |
| `response` | `text`, `condensed`, `seconds` | `Agent` |
| `tool.call` | `tool`, `arguments` (JSON as the model produced it) | `AuditedTool` |
| `tool.result` | `tool`, `output`, `bytes`, `seconds`; an MCP `respond` result's `calls` name this event's `id`, and `wisp://threads/{thread_id}/output/{id}` serves its `output` ([mcp.md](mcp.md)); chat's fold line names its start for `/show` | `AuditedTool` |
| `policy.decision` | `command`, `workingDirectory`, `verdict` (`allowed`, `denied` by pattern, `disapproved` by the gate), `reason`, `sandbox`, `network`, `nested`; recorded once, after the directory check, patterns, and approval | `CommandRunner` |
| `command.outcome` | `command`, `exitStatus`, `timedOut`, `truncated`, `stdout`, `stderr`, `seconds` | `CommandRunner` |
| `secrets.scan` | `source` (`command` and `workingDirectory`, `path`, or `stdin`), `bytes`, `diff`, `thorough`, `findings` (a count), `kinds` (count per kind), `failedChunks` (chunks the model failed on twice, checked by rule only), `classifier` (the personal-data classifier's `personal@<version>`, why it was unavailable, or null without personal data); never a value or a preview | `WispServer`, `wisp scan` |
| `redaction` | `source`, `bytes`, `bytesOut`, `truncated`, `thorough`, `replaced` (occurrences per kind), `failedChunks`; never a value | `WispServer`, `wisp redact` |
| `model.routed` | `task`, `inputBytes`, `model`, `reason` (the measurement that vouched for the model, or why none did, and any fallback; for a task default, whether it is wisp's measured default or `routing.tasks`); one per routed call | `WispServer`, `wisp draft`, `wisp scan`, `wisp redact` |
| `watch.run` | `command`, `run` (from 1), `trigger` (`start`, `change`, `interval`), `exitStatus`, `timedOut`, `state` (`pass`, `fail`), `previous`, `changed`, `seconds`, `findings` (a count, or null when not triaged), `triageError`, `notified`; one per run of `wisp watch` | `wisp watch` |
| `notification` | `title`, `body` (both as bounded for display), `source` (`model`, `user`, `watch`), `outcome` (`posted`, `refused`), `reason` when refused; one per request from the `notify` tool or `wisp notify` | `Notifier` |
| `file.write` | `path`, `mode` (`write`, `append`, `replace`), `created`, `bytesBefore`, `bytesAfter`; recorded after an `edit_file` edit lands, the content being in the `tool.call` arguments | `EditFileTool` |
| `context.condensation` | `turnsBefore`, `turnsAfter`, `contextSize`, `tokenCount`, `savedBefore` and `savedAfter` (the Markdown files holding the transcript before and after, when `audit.enabled`), `reason` (`overflow`: the model refused the prompt and the retry follows; `budget`: the transcript's size (the last request's reported usage, or the model's own count when it reports none) plus the new prompt would pass `contextBudget` of a known window, so the transcript was condensed first); the store marks the entries it dropped with this event's `id` | `Agent` |
| `context.cut` | `entry` (the reply's id in the conversation's store), `output` (the store id of the tool output it reproduced), `tool`, `response` and `result` (the `id`s of the `response` and `tool.result` events that recorded the reply and the output, when linked), `bytes` (UTF-8 bytes the cut removes from later requests, net of its marker), `tokens` (`bytes` at four bytes a token, an estimate), `words`, `coverage` (the fraction of the stretch's lines found in the output: always 1, since only exact copies are cut); one per stretch of presentational text, recorded after the turn. The reply shown and stored is unchanged; later requests carry a marker in its place ([context-management.md](context-management.md), "Output handling") | `Agent` |
| `context.reference` | `entry` (the tool output's id in the conversation's store), `tool`, `result` (the `id` of the `tool.result` event that recorded the output, when linked), `bytes` (the output's UTF-8 bytes), `referenceBytes` (the reference's), `tokens` (`bytes` less `referenceBytes`, at four bytes a token, an estimate of what each later request saves); one per output, recorded at the start of the turn after the output's, when requests begin to carry a reference in its place. The output shown and stored is unchanged ([context-management.md](context-management.md), "Output handling") | `Agent` |
| `context.distillation` | `turns` (the numbers of the turns distilled), `entries` (their prompts and replies), `bytes` (the distiller's prompt), `facts` (the ids of the facts it recorded), `seconds`, `model`, `failure` (why it failed, when it did; the turns are dropped as before and the turn goes on); one per condensation of a conversation that keeps facts, recorded after its `context.condensation`. The call runs in a session of its own and never enters the conversation ([context-management.md](context-management.md), "Facts") | `Agent` |
| `fact.recorded` | `id` (`c…` for the conversation's, `s…` the session's, `p…` the shared store's), `scope`, `subject`, `name`, `source` (`person`, `caller`, `tool`, `model`), `version`, `value`, `class` (`permanent`, `dynamic`, `ephemeral`), `method` (`stated`, `extracted`, `distilled`), `detail` (the tool, or who spoke), `entries` (the store ids it came from), `sources` (the audit event ids of those entries), `supersedes` (the fact it replaced, when it is a new version) | `Agent` |
| `fact.superseded` | `id`, `subject`, `name`, `source`, `by` (the fact that replaced it: a newer version from the same source, or its copy in another scope after a move) | `Agent` |
| `fact.deleted` | `id`, `subject`, `name`, `source`, `value`, `by` (`person`); the store keeps the fact, marked deleted, and later requests leave it out | `Agent` (`/fact delete`) |
| `fact.scope.changed` | `fact` (the id it was named by: `c3`, or `git/c3` for another conversation's proposal), `from` and `to` (`permanent`, `thread`, `session`), `by` (`person` in chat, `caller` over MCP), `now` (its id after the move; the same for a proposal moved to `thread`, which changes in place), `subject`, `name`, `source`, `value`, `proposed` (whether it was a proposed permanent fact); recorded on the log of the conversation that moved it, and on the proposing conversation's when it moved another's, with a `fact.superseded` for the old copy | `Agent` (`/fact ID SCOPE`, `set_fact_scope`) |
| `fact.approved`, `fact.approval.asked`, `fact.approval.decided` | Legacy: written only by unreleased builds that asked the person through a dialog, never now; the kinds are kept so their logs still read. `fact.scope.changed` replaced them | none |
| `fact.conflict.raised`, `fact.conflict.resolved` | `subject`, `name`, `winner` (the head that wins by precedence), `others` (the heads that disagree with it; empty when resolved); recorded when the current heads of different sources about one subject and name begin or stop disagreeing | `Agent` |
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
