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
| `kind` | One of the kinds below. A line whose kind this build does not know (written by another release) is shown as it is, by `wisp logs` and the audit resources, and is not skipped. |
| `details` | Kind-specific fields. |

### Kinds and their details

| Kind | Details | Written by |
| --- | --- | --- |
| `session.start` | `entryPoint` (`respond`, `chat`, `mcp`, `mcp-thread`, `notify`, `scan`, `redact`, `watch`, `draft`, `classifier`, `config`, `approvals`, `facts`), `systemPromptExtension` and `instructions` (the operator's and the caller's layers, null when absent; wisp's own prompt is fixed per `version`), `tools`, `model`, `unsafe`, `autoApprove`, `resume`, and on a resume whose saved store links entries to audit events (`context-management.md`) `carriedFrom` (the distinct ids of the sessions those events belong to, sorted; absent otherwise); an MCP thread adds `parent` (the server session's id) and records the same fields through `Session.conversation`; a chat `/new` records `reason` (`new`), `tools`, and `model` only, from `Agent.reset` | `Session`, `Agent` |
| `session.end` | `reason`: `closed` (explicit, or a `triage-<id>` session finishing), `evicted` (least recently used thread dropped at capacity) | CLI, MCP |
| `model.resolved` | `model` (the selection), `backend` (`system`, `private-cloud`, or a scheme), `asset` (what backs a local model, null for Apple's), `capabilities` (declared names), `capabilitySource` (`framework`, `runtime`, `configuration`, `undeclared`), `tools` the conversation opened with, `contextSize` (the window, null when unknown), `contextNote` (why, when the backend chose it, such as "24,576 of 131,072: 9.2 GiB of a 9.8 GiB budget"); recorded when a conversation opens, after the capability check | `Conversation` |
| `prompt` | `text`; `schema` (the caller's JSON Schema) when the reply had to be shaped | `Agent` |
| `response` | `text`, `condensed`, `seconds` | `Agent` |
| `tool.call` | `tool`, `arguments` (JSON as the model produced it) | `AuditedTool` |
| `tool.result` | `tool`, `output`, `bytes`, `seconds`; an MCP `respond` result's `calls` name this event's `id`, and `wisp://threads/{thread_id}/output/{id}` serves its `output` ([mcp.md](mcp.md)); chat's fold line names its start for `/show` | `AuditedTool` |
| `policy.decision` | `command`, `workingDirectory`, `verdict` (`allowed`, `denied` by pattern, `disapproved` by the gate), `reason`, `sandbox`, `network`, `nested`; recorded once, after the directory check, patterns, and approval; `origin: "person"` for a command the person typed in chat after `!`, which the gate does not see ([ADR 0049](decisions/0049-commands-typed-in-chat.md)); absent for the model's | `CommandRunner` |
| `command.outcome` | `command`, `exitStatus`, `timedOut`, `truncated`, `stdout`, `stderr`, `seconds`; `origin: "person"` for a typed command, as for `policy.decision` | `CommandRunner` |
| `command.typed` | A command the person typed in chat or `wisp-tui` after `!` ([ADR 0049](decisions/0049-commands-typed-in-chat.md)), recorded after its `policy.decision` and `command.outcome`: `command` (the line without the `!`), `workingDirectory`, `verdict` (`allowed`, or `denied` with the policy's `reason`), `output` (what it printed, stdout then stderr, as chat shows it) and its size in `bytes`, `seconds`; for one that ran, `exitStatus`, `timedOut`, `truncated`, and `sandboxRefused` (it ran confined, failed, and its errors carry Seatbelt's `Operation not permitted`); for one allowed that could not start (a missing directory), `failure`. No classifier verdict or approval comes before it: typing the command is the approval. The conversation's store refers to this event for the entry that tells the model of the command, chat's fold line names its start for `/show`, and `memory` recalls the output from it | `Agent` |
| `secrets.scan` | `source` (`command` and `workingDirectory`, `path`, or `stdin`), `bytes`, `diff`, `thorough`, `findings` (a count), `kinds` (count per kind), `failedChunks` (chunks the model failed on twice, checked by rule only), `classifier` (the personal-data classifier's `personal@<version>`, why it was unavailable, or null without personal data); never a value or a preview | `WispServer`, `wisp scan` |
| `redaction` | `source`, `bytes`, `bytesOut`, `truncated`, `thorough`, `replaced` (occurrences per kind), `failedChunks`; never a value | `WispServer`, `wisp redact` |
| `model.routed` | `task`, `inputBytes`, `model`, `reason` (the measurement that vouched for the model, or why none did, and any fallback; for a task default, whether it is wisp's measured default or `routing.tasks`); one per routed call | `WispServer`, `wisp draft`, `wisp scan`, `wisp redact` |
| `watch.run` | `command`, `run` (from 1), `trigger` (`start`, `change`, `interval`), `exitStatus`, `timedOut`, `state` (`pass`, `fail`), `previous`, `changed`, `seconds`, `findings` (a count, or null when not triaged), `triageError`, `notified`; one per run of `wisp watch` | `wisp watch` |
| `notification` | `title`, `body` (both as bounded for display), `source` (`model`, `user`, `watch`, `approval`), `outcome` (`posted`, `refused`), `route` when posted (`host`, `terminal`, `app`, `osascript`; [ADR 0044](decisions/0044-host-effects.md)), `reason` when refused, and `skipped` when an earlier route was passed over or failed: one short `route: reason` each, such as `terminal: Terminal.app has no notification sequence`; one per request from the `notify` tool, `wisp notify`, `wisp watch`, or a command waiting for approval under `wisp mcp` (`approval`, [ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)). A request refused before any route (off, empty, over the limit) has neither `route` nor `skipped` | `Notifier` |
| `host.hello` | `effects` (as declared, such as `approve`, `notify`), `client` and `version` when sent; one per `hello` line from a `wisp chat --json` front end | `wisp chat --json` |
| `file.write` | `path`, `mode` (`write`, `append`, `replace`), `created`, `bytesBefore`, `bytesAfter`; recorded after an `edit_file` edit lands, the content being in the `tool.call` arguments | `EditFileTool` |
| `context.condensation` | `turnsBefore`, `turnsAfter`, `contextSize`, `tokenCount`, `savedBefore` and `savedAfter` (the Markdown files holding the transcript before and after, when `audit.enabled`), `reason` (`overflow`: the model refused the prompt and the retry follows; `budget`: the transcript's size (the last request's reported usage, or the model's own count when it reports none) plus the new prompt, and under the default policy the headroom for the next turn, would pass `contextBudget` of a known window, so the transcript was condensed first); the store marks the entries it dropped with this event's `id`. Condensing to a target (the default policy; [context-management.md](context-management.md), "Condensing") adds, all in tokens: `target` (the goal it condensed to: the target share of the window, capped at the budget less 0.2, or less when the prompt and the headroom need more room under the budget), `fillBefore` and `fillAfter` (the context before and after, by the model's count or an estimate anchored on the runtime's figure), `headroom` (the average turn kept free), `steps` (in order, each one of `referenced N`, `distilled N turns`, `dropped N turns`, `squeezed earlier`; empty when nothing could change), and `floor: true` only when even the last turn left the context above `target`. That event is recorded after the steps, so a condensation's `context.distillation` and `context.summary` come before it; one at the floor that changed nothing, recorded so the note to the person has its record, has empty `steps` and is not counted as a condensation | `Agent` |
| `context.cut` | `entry` (the reply's id in the conversation's store), `output` (the store id of the tool output it reproduced), `tool`, `response` and `result` (the `id`s of the `response` and `tool.result` events that recorded the reply and the output, when linked), `bytes` (UTF-8 bytes the cut removes from later requests, net of its marker), `tokens` (`bytes` at four bytes a token, an estimate), `words`, `coverage` (the fraction of the stretch's lines found in the output: always 1, since only exact copies are cut); one per stretch of presentational text, recorded after the turn. The reply shown and stored is unchanged; later requests carry a marker in its place ([context-management.md](context-management.md), "Output handling") | `Agent` |
| `context.reference` | `entry` (the tool output's id in the conversation's store), `tool`, `result` (the `id` of the `tool.result` event that recorded the output, when linked), `bytes` (the output's UTF-8 bytes), `referenceBytes` (the reference's), `tokens` (`bytes` less `referenceBytes`, at four bytes a token, an estimate of what each later request saves); one per output, recorded at the start of the turn after the output's, when requests begin to carry a reference in its place. The output shown and stored is unchanged ([context-management.md](context-management.md), "Output handling") | `Agent` |
| `context.distillation` | `turns` (the numbers of the turns distilled), `entries` (their prompts and replies), `bytes` (the distiller's prompt), `facts` (the ids of the facts it recorded), `seconds`, `model`, `failure` (why it failed, when it did; the turns are dropped as before and the turn goes on); one per pass of a condensation of a conversation that keeps facts, recorded after its `context.condensation` under phase 2's fixed turns and before it when condensing to a target. The call runs in a session of its own and never enters the conversation ([context-management.md](context-management.md), "Facts") | `Agent` |
| `context.summary` | `version` (the running summary's new version, from 1; absent when none was written), `turns` (the numbers of the turns it adds), `entries` (their prompts, tool calls, and replies), `bytes` (the prompt), `covered` (how many turns the new version covers, the earlier versions' included), `summaryBytes` (its size), `seconds`, `model`, `combined` (whether the call also distilled the facts; its `context.distillation` then has the same time), `failure` (why no version was written: the call failed, or the answer was empty; the summary stays as it was, and the turns wait for the next batch); one per condensation that brings the dropped turns not yet summarised to a batch (three by default), recorded after its `context.distillation`. The call runs in a session of its own and never enters the conversation ([context-management.md](context-management.md), "The running summary") | `Agent` |
| `context.memory` | `request` (the `memory` call's argument as the model wrote it), `action` (`recall`, `note`, or `task`). A recall adds `target` (`entry`, `turn`, `task`, `summary`, `fact`), `found`, `entries` (the store ids of the entries whose content it returned), `facts` (the fact ids), `summaries` (the running summary's versions), `events` (the `id`s of the audit events the content was read from), `from` (`audit` when every entry's content came from the audit log, `store` when from the conversation's store because the audit did not hold it, `audit+store` for a mix; absent when it returned no entry), `offset` (the page's first line), `bytes` (the result's). A note adds `noted`, and when kept `subject`, `name` (normalised), `value`, and `class` (`permanent` makes it a proposal); when refused, `failure` (`shape`, `subject`, `name`, `off`, `full`). A task adds `noted`, and `value` (the task and its objective as kept) or `failure` (`shape`, `off`, `full`, or `pinned` when the person or a caller set the task). One per `memory` call, after its `tool.call` and before its `tool.result`, which holds the text itself; it names what was restored or noted, which the text alone does not. A note kept is recorded as `fact.recorded` with method `noted` when its turn ends ([tools/memory.md](tools/memory.md)) | `MemoryTool` |
| `context.assessment` | `method` (`rules` when the rules settled the request, `model` when one call to the model did, `fallback` when that call failed and every allowed tool was registered with the task unchanged, `retry` when the model called a tool the request had not registered and the request was retried with every allowed tool), `tools` (the tools chosen, in the conversation's order), `ruleTools` (those the rules gave on their own; for a retry, the selection that missed), `registered` (the tools the request's session registers, or `all`), `taskChanged`, `task` (the task fact recorded, when it changed), `facts` (the ids of the facts repeated next to the request), `seconds`, `bytes` (the model call's prompt; 0 with no call), `model` (when a call was made), `intent` (the person's intent in one line, as the model put it; audited, never sent), `failure`. One per user turn when `assessment.enabled` is true, after `prompt` and any `context.reference`, before the turn's tool calls, plus one per retry; never in the model's context ([context-management.md](context-management.md), "The assessment per request") | `Agent` |
| `fact.recorded` | `id` (`c…` for the conversation's, `s…` the session's, `p…` the shared store's), `scope`, `subject`, `name`, `source` (`person`, `caller`, `tool`, `model`), `version`, `value`, `class` (`permanent`, `dynamic`, `ephemeral`), `method` (`stated`, `extracted`, `distilled`, `noted` for the model's `memory` note or task, `inferred` for a task the assessment inferred), `detail` (the tool, or who spoke), `entries` (the store ids it came from), `sources` (the audit event ids of those entries), `supersedes` (the fact it replaced, when it is a new version) | `Agent` |
| `fact.superseded` | `id`, `subject`, `name`, `source`, `by` (the fact that replaced it: a newer version from the same source, a fact from another source that holds the same value, or its copy in another scope after a move) | `Agent` |
| `fact.deleted` | `id`, `subject`, `name`, `source`, `value`, `by` (`person`); the store keeps the fact, marked deleted, and later requests leave it out | `Agent` (`/fact delete`) |
| `fact.scope.changed` | `fact` (the id it was named by: `c3`, or `git/c3` for another conversation's proposal), `from` and `to` (`permanent`, `thread`, `session`), `by` (`person` in chat, `caller` over MCP, `person` again when the person answered a caller's request to keep it), `now` (its id after the move; the same for a proposal moved to `thread`, which changes in place), `subject`, `name`, `source`, `value`, `proposed` (whether it was a proposed permanent fact), `request` (the pending request the person answered, when there was one: kept, or dropped and so moved to `thread`; [ADR 0048](decisions/0048-permanent-facts-over-mcp.md)); recorded on the log of the conversation that moved it, and on the proposing conversation's when it moved another's, with a `fact.superseded` for the old copy | `Agent` (`/fact ID SCOPE`, `set_fact_scope`) |
| `fact.conflict.raised`, `fact.conflict.resolved` | `subject`, `name`, `winner` (the head that wins by precedence), `others` (the heads that disagree with it; empty when resolved); recorded when the current heads of different sources about one subject and name begin or stop disagreeing | `Agent` |
| `mcp.request` | `tool`, `arguments` | `WispServer` |
| `mcp.result` | `tool`, `isError`, `text`, `seconds` | `WispServer` |
| `error` | `message`, `context` | anywhere |
| `classifier.verdict` | `command` (one simple command), `pattern`, `line` (when the command is part of a longer line), `level`, `reasons`, `sources`, `seconds`, `metadata` (when a classifier adds facts: `coreml.model`, `coreml.version`, `coreml.contract`, `coreml.label`, `coreml.confidence`, and `coreml.fallback` with the reason when the verdict is a fallback; `classifier.failure`, with the reason, when a model classifier could not judge and fell back to `moderate`; `classifier.cached: true` when the session reused an earlier verdict for the same line and directory; `rules.knownSafe: true` when the rules know the command to be read-only and no model was asked) | `ApprovalGate` |
| `classifier.train` | `path` (the model written), `examplesSource` (`bundled` or the file), `examples`, `perLevel` (examples per level), `trainingAccuracy` (the fraction of its own examples it labels back, a sanity check, not a measurement), `seconds` | `wisp classifier train` |
| `config.change` | `path` (the setting), `old` and `new` (its values, null when unset), `source` (`chat` or `cli`) | `/config set` and `unset`, `wisp config set` and `unset` |
| `approval.requested` | `command`, `pattern`, `line`, `level` | `ApprovalGate` |
| `approval.pending` | Under `wisp mcp`, a command waiting for approval filed for another face to answer ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)): `request` (the id `wisp approvals approve` takes), `command`, `pattern`, `line`, `directory`, `level`, `thread`, `client`, `expiresAt` (absent when `approval.timeoutSeconds` is 0), `alongside` (`elicitation` when the client's dialog asks at the same time), `outcome` (`filed`, or `failed` with `reason`, when the channel could not be used). A fact a caller asked to keep as a permanent fact ([ADR 0048](decisions/0048-permanent-facts-over-mcp.md)) is filed the same way, with `kind` (`fact`), `fact` (its id), `subject`, `name`, `value`, and `source` in place of `command`, `pattern`, `line`, `directory`, and `level`, and no `alongside` | `OutOfBandApprover`, `FactKeeper` |
| `approval.answered` | The person answered a waiting request in this process, recorded under that process's own session (`wisp approvals`, entry point `approvals`; or the `wisp chat --json` session behind `wisp-tui`): `request`, `command`, `pattern`, `directory`, `thread`, `decision` (`once`, `session`, `project`, `always`, `no`), `via` (`cli`, `tui`), `delivery` (`taken` by the server, `too-late` when the request went another way first, `waiting` when not yet read, `refused` with `reason` when the answer was not written: unknown, stale, altered, already answered). The waiting server records one with `delivery` `refused` when an answer file was not bound to its request. For a fact to keep: `kind` (`fact`), `fact`, `subject`, `name`, `value`, `source` in place of the command's fields, `decision` `keep` or `drop`, and the session `wisp facts` (entry point `facts`) | `wisp approvals`, `wisp facts`, `PendingRelay`, `OutOfBandApprover`, `FactKeeper` |
| `approval.settled` | How a filed request ended, on the asking thread: `request`, `command`, `thread`, `outcome` (`answered` with `via`: `elicitation`, `cli`, `tui`, and `decision`; `timed-out`; `abandoned` when the caller cancelled the call; `failed` with `reason` when no way was left to ask; `stale` when a sweep removed it after its server stopped or its wait expired, recorded by the sweeping process), `seconds` waited. `approval.decided` follows, as for every face. For a fact to keep: `kind` (`fact`), `fact`, `subject`, `name`, `value`, `source` in place of `command`; `decision` `keep` (with `kept`, the permanent fact's id) or `drop`; `withdrawn` when its thread closed or the server stopped first; `failed` with `reason` when the answer could not be applied (the fact changed after the person was asked); no `approval.decided` follows, and a keep is also a `fact.scope.changed` | `OutOfBandApprover`, `FactKeeper`, `wisp approvals`, `wisp facts` |
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
