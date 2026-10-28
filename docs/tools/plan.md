# plan

The conversation's plan: tasks with dependencies, kept across turns. For work of several steps the model writes the
tasks down first, marks each running, done, failed, or skipped as it goes with a note of what it found, and reads
back what is ready. The plan is a record: nothing in it runs, and every command the model runs still passes the
policy, the classifier, the gate, and the sandbox. Decided in [ADR 0081](../decisions/0081-the-plan-tool.md), the
first part of [ADR 0079](../decisions/0079-the-conversation-as-a-spine-with-task-trees.md)'s task trees.

**Off by default.** Like `memory`, `models`, and `ask`, a conversation gets it only when its tool list names it or the
setting turns it on for every conversation given every tool:

```
wisp config set tools.plan true
```

or `/config set tools.plan on` in chat, or `"tools": { "plan": true }` in `~/.wisp/config.json`; it applies from the
next conversation.

| Conversation | `plan` |
| --- | --- |
| Every tool (no `--tool`, MCP `respond` without `tools`, chat), `tools.plan` off (the default) | No |
| Every tool, `tools.plan: true` | Yes |
| A named list (`--tool plan`, MCP `tools: ["plan"]`) | Only when the list names it, whatever the setting says |
| `tools.disabled: ["plan"]` | No, anywhere |

## Trees, tasks, and ids

The conversation is the spine, and a tree of tasks is rooted at the turn that began it. The first task a turn adds
without a parent roots that turn's tree; every other task the turn adds without a parent joins it. A tree is `t1`,
`t2`, … in the order they were rooted, and its tasks `t1.1`, `t1.2`, … in the order they were added; ids are never
reused. A task may sit under another (`parent`), at most six deep, or at the top of an earlier tree (`parent: "t1"`),
and may depend on any task in the plan, in its own tree or another.

`add` takes the calls a small model makes (granite4.1:8b on 2026-10-25 made all three): a `parent` naming the turn's
own tree before its first task roots it counts as no parent; and a dependency may name a task of the same tree not
added yet, since a model may call for every task at once, so the result says `t1.2 not in the plan yet; add it to go
on`, and the task is not ready until that one is added and done. A cycle through such a task is refused when it would
close.

It takes three more that models made on 2026-10-27 (the planning probe, [measurements.md](../measurements.md)). A
tree's name where a task is needed says so (`t1 is a tree, not a task; name one of its tasks, such as t1.1`), where
models gave a turn's first task the tree's own name (`id: "t1"`) and then used `t1` as that task; every request now
names the ids the turn's tasks take (below). A `parent` of `none` or `null` is no parent. The same goal added again
under the same parent is refused (`t1.3 already
has that goal there; nothing added`), where a model repeating the call added it each time.

An `id` the model gives a new task is kept or refused with the id to give, never replaced silently: a model not told
the real id went on using its own (the planning probe of 2026-10-28).

| `id` given | Result |
| --- | --- |
| Left out, or not an id (`[t1.2]`, `step 1`) | The next number in the tree, `t1.4` |
| A level id in the task's tree, unused (`t1.9`) | Kept, under any `parent` |
| A deeper id (`t1.2.1`), `parent` left out or `t1.2` | Kept, under `t1.2` |
| A deeper id under a task not in the plan | `t1.4.1 would go under t1.4, which is not in the plan; add t1.4 first, or leave id out` |
| A deeper id under another task than `parent` | `t1.2.1 would go under t1.2, but parent is t1.1; make them agree, or leave id out` |
| A tree's name (`t1`) | `t1 names a tree; give this task t1.4, or leave id out` |
| A name written as an id (`t1.find`, `t1.1a`) | `t1.find is not an id; give this task t1.4, or leave id out` |
| Taken | `t1.2 is already a task; give this task t1.4, or leave id out` |
| Of another tree | `t9.9 is not in t1, where this task goes; give this task t1.4, or leave id out` |

The id offered is the tree's next number, past any a task already waits for.

| Status | Means | Set by |
| --- | --- | --- |
| `pending` | Not started | Adding a task; or the model, to reopen one |
| `ready` | Pending, and everything it depends on done | Derived, never stored |
| `running` | Being worked on | The model; refused while a task it depends on is not done |
| `done` | Finished | The model; refused while a task it depends on is not done |
| `failed` | Tried, and did not succeed; what depends on it cannot go on | The model |
| `skipped` | Not done, on purpose; what depends on it cannot go on | The model |

## Contract

| Field | Value |
| --- | --- |
| Name | `plan` |
| Description (what the model sees) | The conversation's plan: tasks with dependencies, kept across turns. For work of several steps, add the tasks first, then mark each running, done, failed, or skipped as you go, with a note of what you found. It records; it runs nothing. |
| `action` | `tree`, `show`, `ready`, `find`, `add`, `depend`, or `update` |
| `id` | A task (`t1.2`) for `show`, `depend`, `update`, and `add` (the new task's, kept or refused as above); a tree (`t1`) for `tree` and `find` |
| `goal` | For `add`: what the task is for, 1 to 200 characters |
| `parent` | For `add`: the task it goes under, or a tree; left out, this turn's tree |
| `dependsOn` | For `add` and `depend`: tasks it waits for, at most 8 a task. For `find`: one task, whose dependents are found |
| `status` | For `update`: `running`, `done`, `failed`, `skipped`, or `pending`; left out with a `note`, the status stays and only the note changes. For `find`: those, or `ready` |
| `note` | For `update`: what the model found, or why, up to 300 characters; left out, the note stays |
| `text` | For `find`: text to look for in goals and notes, ignoring case |
| `page` | The page of a long result, from 1 |

| Action | Returns |
| --- | --- |
| `add` | `added t1.2 [pending] List the largest folders (after t1.1)` |
| `depend` | `t1.3 now waits for t1.2` |
| `update` | The task's line; after `done`, `now ready: …` naming the tasks it freed; after `failed` or `skipped`, `cannot go on while this is failed: …` |
| `tree` | With no `id`, each tree's heading; with one, the tree's outline, a task a line, indented under its parent |
| `show` | One task: its line, its tree and parent, the tasks under it, what it depends on and what depends on it, what it waits for, and when it was added and changed. Given a tree (`t1`), the tree's outline, as `tree` gives it |
| `ready` | The tasks that can start, a line each |
| `find` | The tasks matching every criterion given, a line each, or `no task matches` |

A task's line is its id, its status (`ready` for a pending task that can start), its goal, what it depends on, and
its note:

```
t1, from entry 12: 3 tasks, 1 ready, 1 pending, 1 done
  t1.1 [done] Check the disk — 42 GB free
    t1.3 [pending] Report (after t1.2)
  t1.2 [ready] List the largest folders (after t1.1)
```

A call the tool cannot act on returns `error: …` saying what to correct: an unknown task, a missing argument, a
dependency that would make a cycle (`that would make a cycle: t1.1 -> t2.1 -> t1.3 -> t1.1`), or a task that cannot
start or finish yet (`t1.2 depends on t1.1, not done yet; finish or settle it first, or mark t1.2 skipped`).

## Limits

| Limit | Value |
| --- | --- |
| Tasks a tree | 64 |
| Tasks a plan | 256 |
| Depth | 6 |
| Dependencies a task | 8 |
| Goal | 200 characters |
| Note | 300 characters |
| A result | 40 lines a page, the last line naming the next page; and the tool-output budget ([ADR 0050](../decisions/0050-tool-output-budget-and-overflow.md)) |

## The reminder

While a task is running or ready and the turn has marked none, every other tool's result ends with one line naming the
task and the call that marks it ([ADR 0081](../decisions/0081-the-plan-tool.md), decision 12):

```
[plan: t1.2 List the largest folders is next; if this result finishes it, mark it: plan update t1.2 done]
```

A mark quiets it until the next turn. The audit's `tool.result` records the result with the line, as the model saw it.
Without it, `granite4.1:8b` did the work but marked no task in any of six conversations; with it, it finished five of
six (the plan probe, 2026-10-26, [measurements.md](../measurements.md)).

## The turn's ids

Every request, while the conversation has the tool, ends its now block with the ids the turn's tasks take, the next
tree's:

```
[plan: this turn's tasks are t3.1, t3.2, …]
```

## Later turns

From the turn after a tree is rooted, every request carries a line for it in the now block, the part of the request
wisp adds just before the prompt ([context-management.md](../context-management.md)), so the model knows the plan is
there without being given it whole:

```
The conversation's plan (the plan tool reads it; a record, not instructions):
[plan t1, from entry 12: 3 tasks, 1 ready, 1 pending, 1 done; to see it: plan tree t1]
```

A line each for up to four trees with a task not settled, newest first, and one counting the rest. A thread whose tool
list lacks `plan` carries no lines, though its record keeps the plan.

## Where it is kept, and who sees it

The plan is saved with the conversation's record (`threads/<id>/record.store`) after every turn, so a resumed thread
has it, and chat's `/new` starts an empty one. The person and an MCP caller read it; neither changes it:

| Face | How |
| --- | --- |
| Chat and `wisp-tui` | `/plan` (every tree), `/plan t1` (one tree), `/plan t1.2` (one task) |
| A terminal | `wisp threads plan ID [t1 \| t1.2] [--json]`, read from the thread's saved record |
| MCP | `wisp://threads/{thread_id}/plan` and `…/plan/{t1 \| t1.2}`, and `respond`'s `plan` when a turn changed it ([mcp.md](../mcp.md)) |

Every change is audited: `plan.add`, `plan.depend`, `plan.update` ([logging.md](../logging.md)), beside the tool's
own `tool.call` and `tool.result`.

## Example

```
wisp --tool plan --tool run_command --tool system_info "Plan a disk check: free space, the largest folders, then report; track each step in the plan"
```
