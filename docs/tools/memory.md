# memory

The conversation's memory, for the model: one tool with verbs, as the person's chat commands have them.
`recall` restores, for the current turn, earlier material that the model's context holds only as a
reference, a marker, a summary, or a fact. `note` records a fact the model wants kept, as the model's, below
the person's and a tool's. It reads only the conversation's own record and the audit log it refers to, writes
only the conversation's facts, runs no command, and needs no approval. This is phase 4c of the
[layered-context proposal](../proposals/2026-09-29-layered-context.md) ("Recall", decisions D2, D8, and D12),
widened from a `recall` tool to `memory` on 2026-09-30.

It is not the Mac's memory: `system_info`'s `memory` topic reports RAM. The tool's description says so, and
the eval checks that questions about RAM still go to `system_info` (below).

## When a conversation has it

| Conversation | `memory` |
| --- | --- |
| Every tool (no `--tool`, MCP `respond` without `tools`, chat) | Yes, as a built-in tool |
| A named list (`--tool read_file`, MCP `tools: ["run_command"]`) | Only when the list names `memory` |
| No tools (`--no-tools`, `tools: []`) | No |
| `tools.disabled: ["memory"]` in `~/.wisp/config.json` | No, anywhere |

An explicit list is exactly that list, so the MCP git thread of `AGENTS.md` (`tools: ["run_command"]`) stays
`run_command` alone. A conversation without `memory` is not given the system prompt's rule about it, and its
references say to run the call again instead. With it, the tool is there from the first turn: a note needs
nothing stored, and a recall before anything is stored says the first turn is all in view.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `request` | string | yes | A verb and its object: `recall entry 7`, `recall turn 3`, `recall task`, `recall summary`, `recall fact codename`, or `note entity release codename = BLUE HERON`. A later page adds `from line N` to a recall. |

One text argument, because the references and markers the model reads already spell a recall (`to see it:
memory "recall entry 7"`, `(showed the person the read_file output, entry 7)`, and the entries named in facts'
sources, such as `from tool read_file, turn 2, entry 4`), and a small model copies a phrase more reliably than
it fills optional fields. Every tool's schema is in every request (decision D4 measured them), so the schema
has one field. The first word is the verb; `remember` is taken as `note`, and a request with no verb is a
recall, so `entry 7` alone works. `task` is kept for phase 4d; today `task` alone recalls the task.

Tool definition as the model sees it (description, then the argument's guide):

```
This conversation's memory, not the Mac's RAM (that is system_info): recall earlier material in full, or note a fact to keep.
request: "recall entry 7", "recall turn 3", "recall task", "recall fact codename", or "note entity release codename = BLUE HERON".
```

It costs 110 tokens in every request's instructions, measured with `tokenCount(for:)` on the on-device model
on 2026-09-30 (`recall` alone cost 103).

## recall

| After `recall` | Restores |
| --- | --- |
| `entry 7`, `7`, `output of entry 7` | Store entry 7: a tool output, a reply, a prompt, or tool calls. |
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

## Audit

Each call is a `tool.call` and `tool.result` like any tool's, and a `context.memory` event with the `request`
and its `action`. A recall names what was restored: the target, the entries, facts, and summary versions, the
audit events read, and whether the content came from the audit log, the store, or both. A note names the
subject, name, value, and class kept, or the `failure`; each note kept is also a `fact.recorded` (method
`noted`) when its turn ends ([logging.md](../logging.md)).

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Bytes of lines per recall page | 4 KiB, as `read_file`'s page, plus the header and the last line | Fixed (`Recall.pageBytes`) |
| Line length | A line longer than a page is cut to it | same |
| Subjects per fact query | 4 | Fixed (`Recall.factGroups`) |
| Notes per turn | 12 | Fixed (`Memory.notesPerTurn`) |
| A note's value | 200 characters | Fixed (`Memory.valueCharacters`) |
| Scope | This conversation's record and facts, and the session's and shared stores' facts it sees | not configurable |

## Evaluation

Measured in the context eval's `recalling` and `noting` scenarios (`ContextEvalTests`, `MemoryStrategy`); the
figures are in the proposal, "Memory, 2026-09-30". `SystemInfoEvalTests` offers `memory` beside
`system_info` and `run_command` and counts the turns that call it on a question about the Mac: on
2026-09-30, on the on-device model, none of 16 did.

## Implementation

`MemorySource` and `Memory` (the verb, the note's form and rules) in
`harness/Sources/WispCore/Session/Memory.swift`; `Recall` (what a recall names, gathering and paging the
material, pure) in `Session/Recall.swift`; `MemoryTool` in `harness/Sources/WispCore/Tools/MemoryTool.swift`;
and `AuditLog.event(_:)` with the `AuditReader` sinks in `Audit/AuditLog.swift`. The agent publishes its store,
facts, subject kinds, and turn to the tool before every request and records the turn's notes when it ends
(`Agent.memory`). Tested in `MemoryTests`, `RecallTests`, `AuditReadBackTests`, and `MemoryEvalTests`.
