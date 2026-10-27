# ADR 0079: The conversation as a spine, with task trees at its turns

Date: 2026-10-24. Status: proposed. The operator agreed on 2026-10-23 that a problem becomes a tree of tasks with
dependencies between its branches and leaves, worked by the model through a `tasks` tool (then in
[ADR 0078](0078-tasks-a-plan-and-its-grant.md), decisions 1 and 2, which move here). On 2026-10-24 they set out the
spine: the conversation is the spine of the task tree, and a tree is rooted at any point in it. They also set the
tool's scope: the model can read, write, and search and filter the tree. Everything else, marked **pending**, is not
agreed. On 2026-10-24 the operator chose that plans are Agent Skills the person configures
([ADR 0080](0080-agent-skills.md)): a skill's body is a brief, and using a skill roots a tree. On 2026-10-24 the operator also chose to build
the tool first, recording and tracking only: [ADR 0081](0081-the-plan-tool.md), the `plan` tool, built for 0.32.0. ADR 0078 keeps what a plan may do and when it runs (the grant, triggers, channels, protection) and builds on
this one.

## Context

wisp records a conversation as a line. The store holds every entry once, in order, under a stable id: instructions,
prompts, tool calls, tool output, replies, each referring to the audit events that recorded it
([context-management.md](../context-management.md), "The store and the composer"). `ContextComposer` composes each
request from the line: facts, a running summary, recent turns, and earlier tool output as compact references
(`[output of entry 7 not repeated: …; to see it: memory "recall entry 7"]`), condensed ahead of the window
([ADR 0045](0045-layered-context.md)). Facts are scoped `thread`, `session`, or `permanent`. A question the model
parks reaches the thread's next turn as a note ([ADR 0062](0062-the-inquiry-verb.md)).

Within a turn the model's tool calls are already a small tree: flat, unnamed, and unrecorded as one. That is where
work beyond one request falls apart. The planning probe of 2026-10-23 ([measurements.md](../measurements.md),
"Planning a task tree and its grant") found the models' plans failing mostly on what flowed between steps: arguments
taken from the model's text instead of an earlier step's output. A small model's window fills with the whole
conversation when a step needs only its own instruction and its inputs.

Two things are needed: somewhere to put the structure of the work, so that it can be read, run step by step, and
audited; and a way to give each step only the context it needs.

## Decision

### The spine

1. **The conversation is the spine.** Its turns stay the primary sequence, saved and resumed as now
   ([ADR 0066](0066-one-thread-store.md)); the thread's task fact is the spine's goal.
2. **A task tree is rooted at a turn.** Any turn may root a tree; its id is the store id of the prompt that started
   it, so a tree, its entries, and its audit events hang off a point the store already has. A turn that makes no plan
   is a tree of one leaf, its tool calls as today: this generalises the turn rather than adding a mode.
3. **The spine sees a tree only as a reference**, as it sees earlier tool output: a later turn carries
   `[tasks of entry 12: 4 done, 1 waiting on you; to see them: tasks "show 12"]`, built mechanically, and never the
   tree's internals. **Pending:** the reference's exact form.
4. **A trigger adds a point to the spine.** A run started by a schedule or `wisp watch` is a turn not typed by the
   person, and roots its own tree; what happened while the person was away is the thread read in order.

### The tree

5. **A task** has a goal, the primitive it uses (a command or template, a tool, a question to the person, a
   notification), a status (`pending`, `ready`, `running`, `waiting`, `done`, `failed`, `skipped`), its dependencies,
   its brief (below), and its result. A failure stops what depends on it and nothing else.
6. **Dependencies cross trees.** A task may depend on any task in the thread by id, not only on its parent or its own
   tree, so a later turn's work builds on an earlier tree's result instead of redoing it. A cycle is refused when it
   is added (pending).
7. **A task links to the record.** It holds the store entries and output-store ids its run produced, the audit events
   carry its id as they carry their turn, and its result goes to its dependents as a reference to the output store,
   so the tree obeys the tool-output budget ([ADR 0050](0050-tool-output-budget-and-overflow.md)).

### Briefs: context consumed when a task starts

8. **A task carries a brief**: a short instruction, and the facts and spine entries it needs, written when the plan
   is made. When the task runs, its request is composed from wisp's system prompt, the thread's instructions, the
   brief, the goal, and its dependencies' results as references; not the whole spine. A task may read a spine entry
   by reference, never change one. A skill's body is the brief of the tree it roots (ADR 0080, decision 6).
9. **A brief is consumed.** When its task ends, the brief leaves the active context and later work sees only the
   task's result; the brief stays in the store and in the audit log while it is kept (the log rotates). **Pending:** whether a brief's
   facts are a fourth fact scope, `task`, held while the task is active.
10. **A brief is part of the plan the person approves** (pending: with ADR 0078's grant), fixed at approval and
    approved again if changed, and bounded in size as facts are (pending: its share of the window). Data from other
    tasks reaches a task only as references, never inside its brief, so one step's output (a formula's description,
    a commit message) cannot become another step's instruction. A brief shapes what the model does, never what it may
    do.

### The `tasks` tool

11. **The model reads, writes, and searches the tree through one tool, `tasks`** (`task` is already the thread's task
    fact). Its actions, **pending** in their names and arguments:

    | Kind | Action | Does |
    | --- | --- | --- |
    | Read | `show` | One task: goal, primitive, status, dependencies and dependents, brief, result as a reference, its entries |
    | Read | `tree` | A tree's outline, one line a task, by its rooting turn; the thread's trees when none is named |
    | Read | `ready` | The tasks whose dependencies are done, in the order they can run |
    | Write | `add` | A task under a parent or a turn, with its goal, primitive, brief, and dependencies |
    | Write | `depend` | A dependency between two tasks anywhere in the thread; a cycle refused |
    | Write | `update` | A task's status and result (`done` with its output's reference, `failed` with the reason, `skipped`) |
    | Search | `find` | Tasks filtered by status, by tree, by text in goal or result, by what depends on or is depended on by a task, or by time |

    Every result is bounded by the tool-output budget and paged, as `read_file` and `memory` are. Off by default,
    added by a setting or a named list, as `memory` and `ask` are (pending: the setting's name).
12. **Who may change what.** The model may add and update tasks while planning, and update status and results while
    running. **Pending, from the review of 2026-10-24:** narrowed so that only the task runner sets the status of
    steps, questions, and notices, the model only that of the judgement it is running, and the person cancels or
    retries; otherwise the model could mark a question done and skip the person's answer. Once a plan is approved, a change to its structure or a brief is a change to the plan and is approved
    again (pending, with ADR 0078); the model cannot add a step its grant does not cover by adding a task.
13. **The person sees and searches the same tree**: `/tasks` in chat and `wisp-tui`, `wisp tasks` from a terminal
    (pending), and the resources `wisp://threads/{thread_id}/tasks` and `wisp://threads/{thread_id}/tasks/{task_id}`
    for an MCP caller, thread-owned things under the thread's path. Kept with the thread, `threads/<id>/tasks.json`
    (pending).
14. **Audited** under new kinds (pending: `task.add`, `task.depend`, `task.update`, `task.brief`), and each task's run as
    turn events carrying the task's id.

### Choices, recommended and pending

15. **The spine does not wait for its tree** (recommended): the person goes on talking while a tree runs, and its
    results and questions reach the next spine turn as a note, as a parked question's answer does.
16. **Two levels only** (recommended): the spine and its trees. A task does not open a conversation of its own, so
    approval and the audit stay readable.
17. **Each leaf runs as its own turn on the thread** (recommended), so its entries and events group under the task's
    id, rather than the whole tree in one turn.
18. **A scheduled task lives on its own thread** (recommended), so each run adds a point to that thread's spine and
    not to the person's working conversation.

## Consequences

- A conversation of any length stays small at the spine, however much work branches off it; each step's context is
  its brief and its inputs, which makes the on-device model's 8k window and the 8B models workable for steps a larger
  model planned.
- What a plan is, what it did, and why, become readable and searchable by the person, the model, and an MCP caller,
  each through its own face, from one record.
- Running a tree in the background (decision 15) is wisp's first work that outlives the turn that started it within
  one conversation; a parked question already showed the shape.
- A stored brief is instructions waiting to run, so stored briefs, like stored grants, wait on the
  [roadmap](../roadmap.md)'s track on protecting wisp's state from other agents.
- The store, the composer, the audit, the thread store, and the `wisp://threads` resources all change; the turn
  remains the unit they are built around, which is why a tree is rooted at one.
