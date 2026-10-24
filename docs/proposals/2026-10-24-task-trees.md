# Task trees on the conversation's spine, and the grant that bounds them

Date: 2026-10-24. Status: for review; every decision below is **pending** the operator unless it says otherwise. An
adversarial review on 2026-10-24 found faults this draft does not yet answer; they are listed under "Review" at the end.
The operator then chose skills over recipes ([ADR 0080](../decisions/0080-agent-skills.md)); "After the review" at the
end says what that changes here. The
design behind [ADR 0079](../decisions/0079-the-conversation-as-a-spine-with-task-trees.md) (the spine, task trees,
briefs, the `tasks` tool) and [ADR 0078](../decisions/0078-tasks-a-plan-and-its-grant.md) (the grant, triggers,
channels). Agreed so far, in those ADRs: a tree of tasks with dependencies; the conversation as the spine, a tree
rooted at any turn; a `tasks` tool that reads, writes, and searches and filters the tree; for scheduled runs, a
LaunchAgent, the model driving each run, and a banner with the answer given in wisp.

## The problem

wisp has the primitives a solution needs (commands, files, `notify`, `ask`, `memory`, threads, the pending store,
`wisp watch`, custom tools) and no way to compose them beyond one turn. The planning probe of 2026-10-23
([measurements.md](../measurements.md), "Planning a task tree and its grant") put four local models to four real
problems with a written vocabulary; none of eighteen plans could be approved as written. The failures were of a few
kinds:

- **Arguments with no source.** `brew upgrade <formula>` with `<formula>` taken from the model's text or the
  person's answer, not from the listing's output.
- **Commands that do not exist here.** GNU `find -printf` on macOS; a missing upgrade step.
- **Work outside the vocabulary.** Whole shell scripts, a state file written into the project, a LaunchAgent the plan
  wrote for itself.
- **Wrong placement.** A command that changes Homebrew placed in the sandbox, where it cannot run.

Most of these can be caught by a checker that reads the plan; a few can be prevented outright if the model never
writes a command line at all. The design below is built on that: the model chooses and wires templates, wisp
checks the wiring, and anything whose arguments are all bound runs without a model.

## The proposal in one paragraph

A thread's tasks live in `threads/<id>/tasks.json`. A tree is rooted at a spine turn and holds tasks, each a
**group**, a **step** (a template or a tool with its arguments bound to earlier steps' typed outputs), a **judgement**
(a model turn over its inputs, with a brief), a **question**, or a **notice**. The model builds the tree through the
`tasks` tool; `PlanCheck` checks it mechanically and returns reasons; the person approves the plan and its grant as
one request; a `TaskRunner` works ready tasks in the background, one turn per leaf, running bound steps with no model
and judgements with only their brief and inputs; the spine sees each tree as a one-line reference. Templates gain
typed outputs, read by exact readers, so a value flows from one step to the next without passing through a model.

## Goals and non-goals

Goals: plans the person can read and approve; values that flow between steps without the model retyping them; each
step's context small enough for the on-device model or an 8B model; one record, read by the person, the model, and an
MCP caller; nothing runs that the plan and the grant do not name.

Not goals, for now: trees inside trees (two levels, ADR 0079 decision 16); parallel tasks within a thread; a general
workflow language; stored grants and briefs before the protection track; scheduling (ADR 0078's triggers come last).

## What exists, as mapped on 2026-10-24

| Part | Where | What the design reuses |
| --- | --- | --- |
| The store | `ThreadRecord` (`Session/ThreadRecord.swift`): entries with a stable `id`, `kind`, `origin`, `turn`, `sources` (audit references) | Tasks link to entry ids; task turns add entries |
| The composer | `ContextComposer.composition(_:atTurn:)`, `OutputReference.text` | A task's context is a composition; the tree's spine reference is built as an output reference is |
| The output store | `OutputStore`, `memory "recall entry N"`, `wisp://threads/{id}/output/{id}` | A result is a reference to it |
| Templates | `CustomTool.Definition` (ADR 0036): `command` with `{placeholders}`, typed `arguments`, single-quoted substitution in one pass | Steps are templates; the definition gains outputs and argument constraints |
| Exact readers | `JSONShape` (a document's structure, not its values), `memory summarise`, `ReplyVerification` | Typed outputs are read by exact readers; a path reader is new, and `JSONShape` shows the model what paths a step's output has |
| Approval | `ApprovalGate` (its `clear` calls take the command line as a string), `PendingApprovals` (`~/.wisp/pending`; kinds `command`, `fact`, `question`; ADR 0059's model actions are filed as `command`), scopes `once` to `always` | A plan is a new pending kind |
| Questions | `InquiryBox`, `~/.wisp/pending/<id>.question.json`, the answer as a note on the next turn (ADR 0062) | A question task files one; the spine's note carries the tree's news |
| Threads | `ThreadStore`: `thread.json` and the record, staged and renamed, `ThreadLock`; under MCP, `TurnQueue` serialises a thread's turns; chat's `ChatLoop` runs one turn at a time by its shape | `tasks.json` is saved beside them under the same lock; task turns are serialised with spine turns, through the queue under MCP and the loop in chat |
| Audit | `AuditEvent`: `session`, `turn`, `call`, `kind`, `details` | Task events, and a task id on each task turn's events |

## Decisions

### D1. The file and the ids

`threads/<id>/tasks.json`, written with `thread.json` and the record (staged, renamed, `thread.json` last) under
`ThreadLock`. A task id is `t<root>.<n>`: `<root>` the store id of the prompt that rooted the tree, `<n>` its order
of creation in the tree (`t12.3`). Ids are never reused; a removed task stays as `skipped` with the reason. The tree's
id is `t<root>`.

### D2. A task

```json
{
  "id": "t12.3",
  "parent": "t12.1",
  "goal": "Upgrade each formula the person agreed to",
  "kind": "step",
  "uses": { "template": "brew.upgrade", "arguments": { "formula": { "from": "t12.2", "field": "agreed[]" } } },
  "forEach": "formula",
  "dependsOn": ["t12.2"],
  "brief": null,
  "status": "pending",
  "result": null,
  "entries": [],
  "turns": [],
  "created": "2026-10-24T08:00:00Z",
  "updated": "2026-10-24T08:00:00Z"
}
```

| Kind | Runs | Model at run time |
| --- | --- | --- |
| `group` | Nothing; done when its children are | No |
| `step` | A template or a tool, every argument bound to a typed output, a literal in the plan, or the person's choice from a list | No |
| `judgement` | A model turn with its brief and inputs, and only the tools its brief names; its result is the reply and, with a schema, typed fields | Yes |
| `question` | `ask` to the person, free text or a choice built from an input list | No |
| `notice` | `notify` with a text template filled from inputs | No |

`forEach` fans a step out over a list input, one run per item, each recorded as its own result. Statuses:
`pending`, `ready` (its dependencies done), `running`, `waiting` (on the person), `done`, `failed`, `skipped`,
`interrupted` (the process ended while it ran; never rerun on its own, below).

### D3. Typed outputs, read exactly

A template declares what it produces, and an exact reader produces it from the output; the model never extracts a
value a later step will run with.

```json
{
  "name": "brew.outdated",
  "command": "brew outdated --json=v2",
  "outputs": { "formulae": { "reader": "json", "path": "formulae[].name", "type": "name" } }
}
```

| Reader | Produces |
| --- | --- |
| `json` | Values at a path (`formulae[].name`), by a new path reader; no expressions, no filters |
| `lines` | One value a line, optionally filtered by a regular expression with one capture |
| `exit` | The exit status |
| `fields` | A judgement's typed fields, from its schema (`OutputSchema`) |

An output's values are checked against its type before any step uses them; one that fails stops the dependent step
with the reason.

### D4. Argument types and sources

The grant's vocabulary, extending `CustomTool.Argument`:

| Type | Accepts |
| --- | --- |
| `name` | `[A-Za-z0-9][A-Za-z0-9@._+-]*`, at most 128 characters (covers `ruby@3.3`) |
| `pattern` | A value matching the template's own regular expression |
| `path` | A real path (through `realpath`) under one of the template's roots |
| `oneOf` | One of a fixed list |
| `integer`, `number`, `boolean` | As now |

A source is one of: `{ "from": task, "field": output }`, a literal written in the plan (shown to the person), or the
person's answer to a question task whose choices were that list (`agreed[]` above), so an answer can only narrow a
list a step produced, never introduce a value. Free text never binds an argument.

### D5. Recipes: templates wisp ships

Templates for tools wisp knows ship as a resource (`Resources/recipes/*.json`), checked by the gate: `brew`
(`outdated`, `upgrade`, `cleanup --dry-run`), `git` (`branch --merged`, `branch -d`, `fetch --prune`), `du` (folder
sizes, macOS flags), `cargo` (`audit`, with its database's path as a writable root), and wisp's own exact readers as
steps (`json_shape`, `condense_log`, `triage`, `scan_secrets`). The person's custom tools are templates too, under
their own names. The model sees the catalogue in the `tasks` tool's description, by name and one line each, and
`tasks "recipe brew.upgrade"` shows one in full.

### D6. The `tasks` tool

One tool, actions in a `action` argument, results one line a task and bounded by `ToolBudget`, paged with `page`:

| Action | Arguments | Result |
| --- | --- | --- |
| `tree` | `root?` | The tree's outline, indented; the thread's trees when none is named |
| `show` | `id` | One task: kind, goal, uses, sources, dependencies and dependents, brief, status, result as a reference |
| `ready` | | Tasks that can run, in order |
| `find` | `status?`, `tree?`, `text?`, `dependsOn?`, `dependentsOf?`, `since?` | Matching tasks, one line each |
| `recipe` | `name?` | The catalogue, or one template with its arguments and outputs |
| `add` | `parent`, `kind`, `goal`, `uses?`, `brief?`, `dependsOn?`, `forEach?` | The new id, or the check's reasons |
| `depend` | `id`, `on` | Done, or the cycle it would make |
| `update` | `id`, `status`, `note?` | Done; while running, only for the task the turn is running |
| `submit` | `root` | Runs `PlanCheck`; on a pass, files the plan for approval |

Off by default; `tools.tasks` adds it, as `tools.ask` adds `ask`.

### D7. `PlanCheck`

Run on `add` (for what can be checked alone) and on `submit` (the whole tree). Each failure is a line the model gets
back, at most three rounds before the plan goes to the person marked unchecked, or is dropped (pending):

- every step names a known template or tool, and every placeholder has a source of its type;
- every `from` names a task the step depends on, directly or through its parent, and an output that task declares;
- no argument's source is free text or a judgement's reply text (a judgement's typed fields may be, if its schema
  types them);
- no cycle; the tree within its limits (pending: 64 tasks, depth 6);
- a template that runs outside the sandbox, or deletes or overwrites, binds every argument to a listing, never a
  literal the model wrote;
- a judgement's brief is within its size (pending: 1 KiB) and names only tools the grant covers.

Read-only steps (the classifier's `safe`, sandboxed) may be **dry-run** at `submit`, so a wrong flag or a refused
write is shown before approval (pending).

### D8. Approval of the plan and its grant

`submit` files a request of kind `plan` in `~/.wisp/pending`, rendered for each face: the tree's outline; each step's
template, its placement, and where each argument comes from; each brief in full; and the grant it implies (the
templates, their placements, which need a yes on every run). The person approves it once, for the thread, or denies it
with a reason the model gets. An approved plan is frozen: its digest is recorded, and any change made with `add`,
`depend`, or a changed brief is a new plan, filed again with the difference shown. Until the protection track, an
approval lasts as long as the thread is open (ADR 0078 decision 10).

Within an approved plan, a step's command is the template's line with its bound values; `ApprovalGate` gains a check
before the classifier: a command a running step produces from an approved template is covered, unless the policy
denies it, the classifier calls it `dangerous` (pending: whether a template may cover `high`), or the template is
marked for a yes on every run. Outside the sandbox, a yes on every run stays the rule (ADR 0064 unchanged).

### D9. Running: `TaskRunner`

One runner per open thread. It takes the next ready task when the thread is idle (the `TurnQueue` under MCP, the
loop between prompts in chat), so spine turns and task turns interleave and never overlap. A spine turn waits for a task turn already running, never for a
tree (ADR 0079 decision 15).

- **A step** runs its template through `CommandRunner` (policy, gate, sandbox, timeout, output bound) as a turn of
  its own with no model call: the turn's entries are the call and its output, recorded as any tool call is.
- **A judgement** is a model turn whose request is composed by D10.
- **A question** files its question and moves to `waiting`; the answer moves it on.
- **A notice** posts its banner through the session host.

A task that fails stops its dependents, which become `skipped` with the reason. When the process ends, a task left
`running` becomes `interrupted` on the next load and waits for the person: a step may have changed something, so it is
never rerun on its own (pending: rerunning a step whose command the classifier calls `safe`). Faces with no process
left (an MCP client gone) leave a tree where it stands; it resumes when the thread is next opened.

### D10. A judgement's context

`ContextComposer` gains a task composition: wisp's system prompt; the thread's instructions; the brief; the goal; each
input as an output reference with its typed values inline when small (pending: 512 bytes); the tools the brief names.
Not the spine, not the summary, not other trees. The judgement's own entries carry its task id; when it ends, its brief
is no longer composed anywhere (consumed), and its result is its reply as a reference and its typed fields.

### D11. The spine's view

Entries made by task turns carry `task` and stay out of the spine's composition. After the root turn's reply, every
later spine request carries one line per tree, built by `OutputReference` style rules:

```
[tasks of entry 12: 5 tasks, 3 done, 1 waiting on you (t12.4), 1 pending; to see them: tasks "tree t12"]
```

A tree's news since the last spine turn (done, failed, waiting) reaches the next spine turn as a note, as a parked
question's answer does. The `tasks` tool is how the spine reaches further, and `memory` reads a task's outputs as it
reads any.

### D12. Faces

- **Chat and `wisp-tui`:** `/tasks` (the trees), `/tasks show ID`, `/tasks approve|deny ID` (the plan request),
  `/tasks cancel ID` (a task and its dependents to `skipped`), `/tasks retry ID` (an `interrupted` or `failed` task
  back to `ready`). `wisp-tui` shows a tree in the pane.
- **Terminal:** `wisp tasks list|show|approve|deny|cancel|retry` against a saved or open thread, the approval
  commands refused to wisp's model by policy as `wisp approvals` is.
- **MCP:** `wisp://threads/{thread_id}/tasks` (the trees, JSON) and `wisp://threads/{thread_id}/tasks/{task_id}`
  (one task with its entries, results, and events); `respond` returns `tasks` beside `questions` when a turn changed
  any.

### D13. Audit

New kinds: `task.add`, `task.depend`, `task.update` (status changes, with the reason), `task.plan` (submitted, with
the digest and check), `task.approval` (approved or denied, by whom, the digest), `task.run` (a task turn's start and
end). Every event of a task turn carries the task id; a top-level `task` field on `AuditEvent` beside `turn`
(pending: whether that is a schema change, or a detail).

## Phases

| Phase | Builds | Useful on its own because |
| --- | --- | --- |
| 1 | `tasks.json`, the tree and its statuses, the `tasks` tool's read and write actions, `/tasks`, the resources, audit | The model writes its plan down and the person can read and search it; nothing runs |
| 2 | Typed outputs, argument types and sources, recipes, `PlanCheck`, `submit`, the dry run | Plans that pass the checker; the probe rerun on them |
| 3 | `TaskRunner`, steps with no model, judgements with briefs, the spine's view | Approved plans run, in one session, under ordinary approval per command |
| 4 | Plan approval and the gate's coverage of approved templates | Run without a question per command |
| 5 | Triggers and the LaunchAgent, after the protection track | Scheduled runs |

The probe is rerun after phase 2, with the `tasks` tool and the recipe catalogue, before phase 3 starts.

## Tests

Without the model, as every suite: `ScriptedModel` drives the `tasks` tool and a judgement turn; `PlanCheck`
against a table of plans from the probe (each failure it must catch, each pass it must allow); the readers against
captured outputs (`brew outdated --json=v2` from this Mac); `TaskRunner` with a scripted runner (ordering, fan-out,
failure stopping dependents, `interrupted` after a restart); the spine's composition with and without trees; the
plan's digest changing on any edit.

## Open questions

1. Whether a plan that fails the check three times goes to the person marked unchecked, or is dropped.
2. Whether an approved template may cover a command the classifier calls `high`, or only `moderate`.
3. Whether a judgement may call tools at all, or only read its inputs (fewer surprises, less use).
4. Whether `forEach` runs items one at a time and stops at the first failure, or runs all and reports each.
5. Whether a tree may be rooted by an MCP caller's `respond`, or only by the model in a turn.

## Review

An adversarial review on 2026-10-24, checked against the code, found these faults in this draft and the two ADRs. They
are not yet answered; the operator chooses how.

- **The model can skip the person's answer** by setting a question or step task's status with `update` (D6, ADR 0079
  decision 12). Only the runner should set the status of steps, questions, and notices.
- **A judgement's typed fields can introduce a value** into a destructive step (D7), against D4's rule; injected text in
  what the judgement reads could emit `main`. A field may bind only as a checked subset of an input listing.
- **Stored plans arrive before the protection track** (D1, D9): `tasks.json` holds briefs and literals, and pending
  requests are bound by an unkeyed digest any process running as the user can recompute.
- **The gate has no provenance**: `clear(command:workingDirectory:)` takes the line only, so coverage keyed on the line
  covers the spine model's identical `run_command` too (D8).
- **`forEach` approves a list no one has seen** (D2, D8): the fan-out needs a cap and the realised list shown before a
  destructive step runs.
- **`ask` cannot do what D4 and D9 assume**: one choice of two to six options, one question waiting per thread, two a
  turn (`Inquiry.swift`); `agreed[]` needs a multiple choice of its own.
- **A step waiting on approval holds the thread** (D9): the `TurnQueue` for `approval.timeoutSeconds`, and chat blocks
  in `readLine` with no idle point; steps must park as questions do, and chat's input loop change first.
- **Outputs a waiting tree needs can be swept** (D10): the output store is per audit session, swept after 30 days, and
  absent with the audit off.
- **The ADRs and the design disagree**: ADR 0078 decision 6 (agreed) says the model drives each run, D9 runs steps with
  no model; ADR 0078 decision 4 wants two models on a thread that has one.
- **Homebrew gains little by phase 4**: `brew upgrade` runs outside the sandbox, so every upgrade still asks.
- **Other processes** (D12): `wisp tasks cancel|retry` on an open thread from another process, thread deletion leaving
  pending requests, and hand-over are not designed.
- **Reply verification** (ADR 0060) would flag a spine reply reporting a task's result as unsupported, and task turns
  must stay out of every turn count.
- **Phases lean on later ones**: `submit` in phase 2 needs phase 4's request kind; phase 3 runs briefs no one approved;
  phase 1 builds the tool before a probe shows models can add tasks one call at a time.
- Minor: the tool's call syntax differs between the ADR and D6; recipe names with dots are not valid custom tool names;
  a value starting with `-` can inject an option; `path` is checked before the run, not at it; the digest omits
  cross-tree dependencies; the 8k-window model was never probed.

The reviewer's alternative: ship **curated recipes as whole, fixed trees** (Homebrew, merged branches, folder sizes,
cargo audit), the person approving the recipe and its parameters and the model only choosing one and filling literals,
before any tree the model writes.

## After the review: skills

On 2026-10-24 the operator answered the review's alternative: recipes only work if the person configures them, and
the form exists already, Agent Skills ([ADR 0080](../decisions/0080-agent-skills.md)). What changes in this design:

- **D5's recipes become skills**, kept in `Wisp.app` or `~/Library/Application Support/wisp/skills`, not in `~/.wisp`,
  each checked by its digest before use. The recipe names with dots, which were not valid custom tool names, become
  skill names (`brew-upgrades`).
- **The grant moves into the skill's `allowed-tools`**, in a wisp syntax (`run_command(brew upgrade {formula:name})`,
  `run_command!(…)` outside the sandbox), with sources and outputs in `metadata` under `wisp.` keys; D4's types and
  D3's readers stay, and D8's plan approval becomes the skill's approval against its digest.
- **The model chooses and fills skills rather than writing trees**; `add` and `submit` remain for a tree a skill
  describes and, later, for a model's draft that the person saves as a skill. Phase 1 starts from skills.
- **The review's critical findings are taken as proposals** (pending): only the runner sets steps', questions', and
  notices' status (ADR 0079 decision 12); a judgement's field binds only as a checked subset of an input listing; the
  runner executes the approved skill as held in memory, with a token into the gate only it holds (ADR 0080 decision
  5), and nothing executable is approved for longer than the protection track allows.
