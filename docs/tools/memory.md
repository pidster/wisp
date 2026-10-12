# memory

The conversation's memory, for the model: one tool with verbs, as the person's chat commands have them.
`recall` restores, for the current turn, earlier material that the model's context holds only as a
reference, a marker, a summary, or a fact. `note` records a fact the model wants kept, as the model's, below
the person's and a tool's. `task` proposes the conversation's task and its objective, never over the person's or
a caller's. It reads only the conversation's own record and the audit log it refers to, writes
only the conversation's facts, runs no command, and needs no approval. This is phase 4c of the
[layered-context proposal](../proposals/2026-09-29-layered-context.md) ("Recall", decisions D2, D8, and D12),
widened from a `recall` tool to `memory` on 2026-09-30.

It is not the Mac's memory: `system_info`'s `memory` topic reports RAM. The tool's description says so, and
the eval checks that questions about RAM still go to `system_info` (below).

**Off by default.** Context checkpoint 2 scored fewer answers with `memory` than without it on every model it
measured (the on-device model, `granite4.1:8b`, and `gemma4:12b`), so since
[ADR 0057](../decisions/0057-context-defaults-from-checkpoint-2.md) a conversation gets it only when you turn it on
or name it. Turn it on for every conversation given every tool:

```
wisp config set context.memory true
```

or `/config set context.memory on` in chat, or `"context": { "memory": true }` in `~/.wisp/config.json`; it applies
from the next conversation. With it on, everything on this page behaves as it did before ADR 0057.

## When a conversation has it

| Conversation | `memory` |
| --- | --- |
| Every tool (no `--tool`, MCP `respond` without `tools`, chat), `context.memory` off (the default) | No |
| Every tool, `context.memory: true` | Yes, as a built-in tool |
| A named list (`--tool read_file`, MCP `tools: ["run_command"]`) | Only when the list names `memory`, whatever `context.memory` says |
| No tools (`--no-tools`, `tools: []`) | No |
| `tools.disabled: ["memory"]` in `~/.wisp/config.json` | No, anywhere: the tool is not registered, so a list that names it is refused |

An explicit list is exactly that list, so the MCP git thread of `AGENTS.md` (`tools: ["run_command"]`) stays
`run_command` alone, and `--tool read_file --tool memory` has `memory` with the setting off. A conversation
without `memory` is not given the system prompt's rule about it, and its references say `call it again to see it` for a tool that only reads, and `its output is not repeated; do
not run it again to see it` for a command or an edit
instead of naming a recall; the facts, the running summary, and the references themselves are the same. You can
still see any earlier output with `/show` and `/inspect context`, which cost the model nothing. With `memory`, the
tool is there from the first turn: a note needs nothing stored, and a recall before anything is stored says the
first turn is all in view.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `request` | string | yes | A verb and its object: `recall entry 7`, `recall turn 3`, `recall task`, `recall summary`, `recall fact codename`, `recall output 3f9a2c1b`, `summarise entry 7`, `condense entry 7: why did it fail`, `note entity release codename = BLUE HERON`, or `task fix the CI build; objective: swift test passes`. A recall takes a filter (`matching PATTERN`, `lines A-B`, `head N`, `tail N`) and a later page adds `from line N`. |

One text argument, because the references and markers the model reads already spell a recall (`to see it:
memory "recall entry 7"`, `(showed the person the read_file output, entry 7)`, and the entries named in facts'
sources, such as `from tool read_file, turn 2, entry 4`), and a small model copies a phrase more reliably than
it fills optional fields. Every tool's schema is in every request (decision D4 measured them), so the schema
has one field. The first word is the verb; `remember` is taken as `note`, and a request with no verb is a
recall, so `entry 7` alone works. `task` followed by text proposes the task (below); `task` alone recalls it.

Tool definition as the model sees it (description, then the argument's guide):

```
This conversation's memory, not the Mac's RAM (that is system_info): recall earlier material in full, or note a fact to keep.
request: "recall entry 7", "recall turn 3", "recall task", "recall fact codename", or "note entity release codename = BLUE HERON".
```

It costs 110 tokens in every request's instructions, measured with `tokenCount(for:)` on the on-device model
on 2026-10-01 for this text (`recall` alone cost 103). The `task` verb is not among the guide's examples: one
added on 2026-10-01 ("task fix the CI build; objective: swift test passes") took the definition to 123 tokens
in every conversation with `memory`, and was dropped on 2026-10-03; the verb works as before (below).

## recall

| After `recall` | Restores |
| --- | --- |
| `entry 7`, `7`, `output of entry 7` | Store entry 7: a tool output, a reply, a prompt, or tool calls. A tool output the model was given only in part is restored whole from the output store, with the stored output's line numbers (the header says `the whole output from the output store`). |
| `output 3f9a2c1b` | The whole stored output with that id, the one a held-back note names ([ADR 0050](../decisions/0050-tool-output-budget-and-overflow.md)): reachable in the turn that produced it, before its entry exists. |
| `… matching PATTERN`, `… lines 100-200`, `… head 50`, `… tail 50` | The same, filtered first: the lines matching a regular expression (case-insensitive; a literal when it does not compile), a range, the first or the last lines; each line carries its number in the whole, the header says how many of how many were kept, and the pages continue the filter. |
| `turn 3` | Every stored entry of turn 3, in order, each under a line naming it. |
| `task`, `the task` | The task's versions, oldest first, then the prompt the conversation began with, in full. |
| `summary` | The running summary's versions, newest first, with the turns each added. |
| `c12`, `fact c12` | The versions of what fact `c12` is about. |
| `fact tests`, `codename`, `CI` | The versions of the facts whose subject, name, or value the words match, at most four subjects. |
| `… from line 60` | The same, from line 60. |

A header saying what was found and where its content was read from, the lines of one page, then a last line
that names the next page or says it ended:

```
entry 4: read_file output, turn 2 at 14:05:12, from the audit log
arguments: {"path": "/work/harbour/docs/overview.md"}
1	# harbour sync: design overview
…
77	leaves the previous manifest intact and the next run repeats only the unfinished work.
[end of file]
[end of what recall found]
```

A page that is not the last ends `[more: memory "recall entry 4 from line 60"]`. A fact's history names each
version's id, source, time, value, state, and the entries it came from:

```
fact "ci": 1 subject
tests ci: 2 versions, oldest first:
- c3 [tool run_command, turn 2, entry 9] at 11:02:10: failed (exit status 1); superseded by c9
- c9 [tool run_command, turn 11, entry 30] at 11:07:40: passed; current
memory "recall entry N" shows what a fact came from.
[end of what recall found]
```

When nothing matches, one line starting `memory:` says why and what there is: the range of entries or turns
stored, or the subjects the conversation knows. A turn's own entries are not stored until it ends; the model
has them whole until then.

**Where the content comes from.** The audit log is the one verbatim record (decision D8), and the store refers
into it: each entry names the audit events that recorded it (`tool.result` for an output, `prompt`, `response`,
`tool.call`). A recall reads an entry's content from that event. The store's own copy of the entry, which it
keeps in memory (and in the `.store` sidecar for dropped entries) so that composing never reads the audit
files, is the fallback for an entry the audit does not hold: text the model wrote before a tool call, which no
event records on its own; an entry whose event has rotated out of the files kept; or a conversation with
`audit.enabled: false`. The header says which (`from the audit log`, `from the conversation's store`).

**After its turn.** What a recall returns is an ordinary tool output: whole in its own turn, and from the next
turn on a reference like any other (`[output of entry 40 not repeated: memory at …; to see it: memory "recall
entry 40"]`), so restored material ages out and is never carried in full again.

## summarise

```
summarise entry 7
summarise output 3f9a2c1b overview
```

The notable lines of a stored entry or output, or with `overview` an overview, by exact readers and no model
([ADR 0050](../decisions/0050-tool-output-budget-and-overflow.md)). The notable summary leads with what matters
given how the output ended: for a build or test output in a format `triage` reads, the errors grouped by file or
test, the first of each with its line and the lines after it and the later ones in the same place counted under
it, the warnings tallied, and the test failures; for a log, its severities and the rare or severe messages; for
JSON, its shape; else the lines that mention an error, else the first and last lines. Each point cites its line
(`L154`), the stored output's numbering, so a recall from that line lands on it. The overview gives the size, how it
ended (a command's exit status, else the last line), the kinds of line counted, the lines that look like headings
with their numbers, and the first and last lines. Both say what no reader explained, so the model knows what
`condense` could still answer, and both fit the budget.

```
notable lines (exact readers, no model): 2,340 lines, 187 KiB; exit status 1 (failed)
2 errors in 1 place; the first of each, root causes first:
L154 error at Sources/B.swift:42:9: cannot find 'frob' in scope (+1 more in Sources/B.swift)
  L155:     frob(1)
  L156:     ^~~~
1 warning (Sources/A.swift ×1)
1 failure-looking line no reader explained, such as: error: fatalError: 1 of 3 targets failed
```

## condense

```
condense entry 7: why did the link step fail
```

Answers the question after the colon from the whole of a stored entry or output, by a chunked pass of the
conversation's own model: the output is cut into chunks within the budget (at most 48; the result says when the
output had more), each chunk is asked the question in a fresh tool-less session of the same model and told to
answer `nothing here` when it has nothing, the answers that say something are joined in order, and when they do
not fit the budget the model is asked once more to combine them. The result names the question, the lines and
chunks read, and that the model wrote it; a chunk that fails is counted. Each chunk is one of wisp's own side calls
([ADR 0053](../decisions/0053-the-models-thinking-shown.md), amended 2026-10-11): a model that can think is asked not
to, whatever the conversation or the model's settings choose, and its thinking is not recorded as the turn's, as
the fact distiller, the running summary, and `triage` are run. It is the one verb that costs model
calls, in proportion to the output's size, and only when asked. Without a model attached (an agent made directly,
tests) it says so and points at `summarise` and the filters. Paging alone is not enough for a long output: a model
reading page after page can lose the earlier pages to condensing, so this asks about all of it at once.

## note

```
note SUBJECT NAME = VALUE
```

`SUBJECT` is a subject kind the model may note, `NAME` what the fact is about, and `VALUE` its value, as the
person's `/fact SUBJECT [NAME] = VALUE` is written. The forms a small model writes are read too:
`SUBJECT: NAME = VALUE`, and `SUBJECT NAME: VALUE` with no `=`. Quotes around the value are dropped.

| Rule | What happens |
| --- | --- |
| Source | `model`, method `noted`: the lowest precedence, so a person's or a tool's fact on the same subject and name wins, and a disagreement is shown as a conflict (D2). A newer note or distilled fact on the same identity is a new version of the model's. |
| Subject kinds | Those the distiller may use: `task`, `decision`, `preference`, `entity`, `tests`, `workdir`, `branch`, and any the config adds with `distil` not false. `file`, `service`, and `machine` are the tools' to record. Another subject is refused with the list. |
| Name | Required, except for kinds with one fact per conversation (`task`, `workdir`, `branch`). |
| Temporal class | The kind's. A note of a permanent kind (`decision`, `preference`, `entity`) is a proposal held by the conversation until the person keeps it with `/fact ID permanent`: only the person admits a permanent fact (D2). |
| When | Kept when the call is made and recorded as a fact when the turn ends, with the turn's number; it reaches the model's facts from the next request. The person sees it in the note chat prints after the turn, as for any new fact. |
| Bound | 12 notes a turn, as one distillation keeps at most 12 facts; the value is cut to 200 characters. |
| Facts off | With `facts.enabled: false`, a note is refused; recall still works. |

The result says what was kept, or why not, in a form the model can act on:

```
noted: entity release codename = BLUE HERON (a proposal until the person keeps it)
noted: tests ci = green
error: no subject weather to note; use one of task, decision, preference, entity, tests, workdir, branch, such as note entity release codename = BLUE HERON
error: say which entity it is before the =, such as note entity release codename = BLUE HERON
error: write note SUBJECT NAME = VALUE, such as note entity release codename = BLUE HERON
error: at most 12 notes a turn; the rest were not kept
```

In facts' lines a noted fact's source reads `model, noted, turn 4`.

## task

```
task THE TASK; objective: WHAT DONE LOOKS LIKE
```

Proposes the conversation's task as the model's fact (subject `task`, source `model`, method `noted`), with its
objective after `objective:` (also `. Objective:` or `, objective:`), kept as one value, `THE TASK; objective: WHAT
DONE LOOKS LIKE`. It is recorded when the turn ends and shown next to each request from the next one (decision
D6). The task the person set with `/task`, or an MCP caller with `respond`'s `task`, is never replaced: the request
is refused and the result names the task as it stands. `task` alone, and `recall task`, recall the task. A task
counts towards the turn's 12 notes, and is cut to 300 characters.

```
noted the task: add a --dry-run flag to harbour sync; objective: sync prints the plan and copies nothing
error: the person set the task, and it stays: fix the CI build
error: write task THE TASK; objective: WHAT DONE LOOKS LIKE
```

With the per-request assessment on, the model's task is also inferred before each request in chat
([context-management.md](../context-management.md), "The assessment per request"); a task the model proposed
either way is the model's, method `noted` here and `inferred` there.

## Audit

Each call is a `tool.call` and `tool.result` like any tool's, and a `context.memory` event with the `request`
and its `action`. A recall names what was restored: the target (`output` for a stored output, with its id as
`output`), the entries, facts, and summary versions, the audit events read, the `filter` applied, and whether the
content came from the audit log, the store, or both. A summary names its target and which `summary` (`notable`,
`overview`); a condense names its target and the `chunks` the model read, and a `failure` when it had no model,
no question, or chunks that failed. A note names the subject, name, value, and class kept, or the `failure`; a
task names the `value` kept or the `failure` (`pinned` when the person or a caller set it); each note or task
kept is also a `fact.recorded` (method `noted`) when its turn ends ([logging.md](../logging.md)).

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Bytes of lines per recall page | The tool-output budget (an eighth of the model's window, 4 to 64 KiB), as `read_file`'s page, plus the header and the last line | Follows the model's window |
| Line length | A line longer than a page is cut to it | same |
| Chunks one `condense` reads | 48, each within the budget | Fixed (`MemoryTool.condenseChunks`) |
| How long stored outputs stay readable | 30 days after the session's last use, then swept at a later session's start | `context.outputDays` (0 keeps them) |
| Subjects per fact query | 4 | Fixed (`Recall.factGroups`) |
| Notes per turn | 12 | Fixed (`Memory.notesPerTurn`) |
| A note's value | 200 characters | Fixed (`Memory.valueCharacters`) |
| Scope | This conversation's record and facts, and the session's and shared stores' facts it sees | not configurable |

## Evaluation

Measured in the context eval's `recalling` and `noting` scenarios (`ContextEvalTests`, `MemoryStrategy`); the
figures are in the proposal, "Memory, 2026-09-30". Context checkpoint 2 compared the whole stack with and without
`memory` on its `sustained` scenario, three runs on each of three models, and found it no help: 4.3 against 5.3 of 10
on the on-device model, 7.3 against 8.0 on granite4.1:8b, and 8.0 against 9.3 on gemma4:12b
([ADR 0057](../decisions/0057-context-defaults-from-checkpoint-2.md)). `SystemInfoEvalTests` offers `memory` beside
`system_info` and `run_command` and counts the turns that call it on a question about the Mac: on
2026-09-30, on the on-device model, none of 16 did.

## Implementation

`MemorySource` and `Memory` (the verb, the note's form and rules) in
`harness/Sources/WispCore/Session/Memory.swift`; `Recall` (what a recall names, gathering and paging the
material, pure) in `Session/Recall.swift`; `MemoryTool` in `harness/Sources/WispCore/Tools/MemoryTool.swift`;
and `AuditLog.event(_:)` with the `AuditReader` sinks in `Audit/AuditLog.swift`. The agent publishes its store,
facts, subject kinds, and turn to the tool before every request and records the turn's notes when it ends
(`Agent.memory`). Tested in `MemoryTests`, `RecallTests`, `AuditReadBackTests`, and `MemoryEvalTests`.
