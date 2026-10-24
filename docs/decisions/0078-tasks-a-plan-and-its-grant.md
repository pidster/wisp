# ADR 0078: Tasks: a plan and its grant, approved together

Date: 2026-10-23. Status: proposed. The operator agreed on 2026-10-23 the framing (a problem is solved by a plan of
tasks that composes wisp's primitives, approved with what it may do), the tree of tasks with dependencies, and, for
scheduled runs, decisions 5 to 7; the rest, marked **pending**, is not agreed. The tree itself moved on 2026-10-24 to
[ADR 0079](0079-the-conversation-as-a-spine-with-task-trees.md), which this one builds on. On 2026-10-24 the operator
chose that plans are skills the person configures ([ADR 0080](0080-agent-skills.md)), whose `allowed-tools` carries the
grant; decisions 3 and 4 below read with that. Leaves
[ADR 0064](0064-an-approved-run-outside-the-sandbox.md) (an outside run is remembered by nothing) unchanged: a step outside
the sandbox still asks on every run, and changing that is not proposed. Would extend
[ADR 0033](0033-watch-mode.md) (watch mode) and [ADR 0073](0073-wisp-install-and-the-finder.md) (`wisp install`).

## Context

wisp has a fair set of primitives: commands under a sandbox and a classifier (`run_command`), files (`read_file`,
`edit_file`), `notify`, the model's question to the person (`ask`), `memory`, threads saved and resumed by any face,
approvals answered from any face (`~/.wisp/pending`), and `wisp watch`. What a person cannot yet do is hand wisp a
problem and have it compose those primitives into a solution that outlives one turn. The model improvises inside a
turn, each risky command asked as it comes; nothing writes the plan down for the person to read, nothing says ahead
what the plan may do, and nothing runs it later.

The operator's example, on 2026-10-23: watch Homebrew, running `brew outdated` now and then and asking whether to
update a given formula. It needs all four parts a solution has, and wisp has only some of each:

| Part | Homebrew | wisp today |
| --- | --- | --- |
| Plan: the steps | Check, ask per formula, upgrade the ones agreed | Improvised in one turn, unrecorded |
| Grant: what the steps may do | `brew outdated` in the sandbox; `brew upgrade <formula>` outside it | Per-command approval, session or project patterns |
| Trigger: when it runs | Every morning | Now; `wisp watch` on a change or an interval; an MCP call |
| Channel: how it reports and asks | A banner; the answer in wisp | `notify`, `ask`, the pending store, `wisp-tui` |

A command that changes Homebrew cannot run in wisp's sandbox: its writes go to `/opt/homebrew/…` and
`~/Library/Logs/Homebrew`, and Homebrew runs its own `sandbox-exec`, which Seatbelt refuses inside a different
profile, so widening `writablePaths` does not help (probed 2026-10-14, [run_command.md](../tools/run_command.md),
"Running outside the sandbox"). Under ADR 0064 it runs outside only with the person's yes each time, remembered by
nothing, which is right for a command the model thinks of and wrong for a step the person has already read.

Whether a local model can write a plan and a grant good enough to approve was measured before anything is built;
the probe below has the results.

## Decision

### The task tree

1. and 2. **Moved on 2026-10-24 to [ADR 0079](0079-the-conversation-as-a-spine-with-task-trees.md)**, which records
   the agreed tree of tasks with dependencies and the `tasks` tool, and roots a tree at a turn of the conversation,
   its spine. In this ADR's terms: "upgrade `<formula>`" depends on "list outdated" and on the person's yes to that
   formula, and the grant below is approved for a tree.

### The grant

3. **A plan carries its grant, and the person approves both together.** Since 2026-10-24 the plan is a skill and its
   grant the skill's `allowed-tools`, approved against the skill's digest ([ADR 0080](0080-agent-skills.md), decisions 4
   and 5); the vocabulary below is what that syntax expresses. The grant says what the tree may do, in a
   small vocabulary the person can read:

   | Kind | Example | Means |
   | --- | --- | --- |
   | Command template | `brew outdated --json=v2` | This command, exactly, in the sandbox |
   | Template with typed arguments | `brew upgrade <formula>` | `<formula>` must match its type and come from a named source |
   | Argument source | `<formula>` from task 1's output, field `formulae[].name` | Not from the model's text |
   | Placement | outside the sandbox, network on, extra writable path | How each template runs |
   | Person's yes per run | on `brew upgrade` | The step still waits for an answer each time |

   Once approved, the model runs only what the grant names; anything else goes through the ordinary approval as
   now. The policy's deny list still applies to every command. **Pending:** whether a template's approval replaces
   the classifier's ask for it; what types an argument may have (a name pattern, a path under a root, one of a
   list); whether a template outside the sandbox may ever run without a per-run yes, which is the change to ADR
   0064 and is not proposed for Homebrew.
4. **Planning and running may use different models.** The plan is written by a model good enough to plan (the
   probe below picks it) and approved by the person; the steps may run on a fast model, which the grant bounds. A
   change to the plan or grant is approved again; the model cannot widen its own grant. Since 2026-10-24 plans come
   from skills the person keeps (ADR 0080); a model that plans drafts a skill for the person to read and save.

### Triggers and channels

5. **A LaunchAgent runs scheduled tasks** (agreed). `wisp install` writes a per-user LaunchAgent in
   `~/Library/LaunchAgents` that starts wisp when a schedule is due, whether or not `Wisp.app` or a chat is open;
   `wisp uninstall` removes it and `wisp doctor` reports it. Other triggers are now (the default), a file change,
   and an interval, as `wisp watch` has them.
6. **The model drives each run** (agreed), on the task's own thread, with the tree, the grant, and only the tools
   the grant needs. **Pending, a conflict for the operator:** the design ([proposal](../proposals/2026-10-24-task-trees.md),
   D9) runs a step whose arguments are all bound with no model at all, and the model only for judgements; that
   narrows this decision, and needs the operator's agreement.
7. **A banner reports, the person answers in wisp** (agreed). A run ends with a `notify` banner of what it found;
   a question waits in `~/.wisp/pending`, answered with `wisp questions`, in `wisp-tui`, or in chat. No banner
   buttons. An unanswered question is never a yes; it waits, and the next run replaces it (pending: expiry).
8. **`/schedule` is the person's; the `schedule` tool proposes** (shape agreed). `/schedule <frequency|time>
   <action>` in chat and `wisp schedule add|list|remove|run` create and manage scheduled tasks; the model's
   `schedule` tool only proposes one, which the person approves as a request of its own kind, as model changes are
   ([ADR 0059](0059-one-set-of-model-actions.md)). **Pending:** the frequency syntax; whether `tasks` and `schedule`
   are in a conversation by default.
9. **Audited** under new kinds (pending: `task.plan`, `task.grant`, `task.update`, `schedule.add`,
   `schedule.remove`, `schedule.run`), with each run's own turn events as any turn's.

### Protection

10. **A stored grant is a standing approval**, narrower than any wisp has had but standing all the same, and the
    most valuable thing in `~/.wisp` for another agent to change. Grants are not kept until the
    [roadmap](../roadmap.md)'s track on protecting wisp's state from other agents can authenticate them; until
    then a plan and its grant live only as long as the conversation that approved them (pending: the operator's
    agreement to that ordering).

## The probe

Before any of this is built: give two local planning candidates, `ollama:gemma4:12b` and `ollama:qwen3.8:27b`, the
vocabulary above and four real problems, Homebrew among them, as text-only threads with a JSON schema for the tree
and grant; read each plan for whether a person could approve it as written: the steps right, the dependencies right,
every command in the grant needed and nothing more, arguments bound to a source, and nothing outside the sandbox
that need not be.

Run on 2026-10-23, with `ollama:gemma4:26b` and `ollama:granite4.2:8b` (thinking and not) added ([measurements.md](../measurements.md), "Planning a task tree and
its grant"): **none of the eighteen plans returned could be approved as written.** `qwen3.8:27b` came nearest (three of four
nearly right, 19 to 62 s a plan); both gemma models bound destructive arguments to the person's answer or to nothing,
`gemma4:12b` once repeated a pipe stage until its reply was cut, and `granite4.2:8b` wrote whole scripts, a
state file in the project, or no plan at all. Most failures could be caught mechanically; a few
could not (a listing that includes its own root, `main` not excluded from deletion). Two probed facts bear on
grants: `brew outdated` in the sandbox lists from Homebrew's cache but cannot refresh it, and `cargo audit`'s
database is outside the writable paths.

What that suggests, **pending** the operator:

- **wisp checks every plan before the person sees it**, and sends it back to the model with the reasons: each
  command task names a defined template; each argument's source is an earlier command task's output field, never an
  answer or the problem's text; each type is in the vocabulary; no template outside the sandbox deletes or
  overwrites with an argument that is not bound to a listing; no cycle.
- **Known tools get curated templates.** For tools wisp knows (`brew`, `git`, `du`, `cargo`), wisp offers checked
  templates with typed outputs (`brew outdated --json=v2` → `formulae[].name`, `git branch --merged` minus `main`
  and the current branch), and the model composes them rather than writing command lines.
- **Read-only steps are dry-run at planning time** in the sandbox, so a wrong flag or a refused write shows before
  the person approves.
- **The planner is `qwen3.8:27b`** until a model does better; a plan is slow to write but written once.

## Consequences

- wisp moves from answering a request to working a problem over time; the tree makes the plan readable, and the
  grant makes what it may do readable, before anything runs.
- The grant vocabulary is what the person approves, so it is the part to keep small and plain; anything it cannot
  say goes through the ordinary approval.
- wisp gains its first process that runs with no person or client in front of it; the LaunchAgent is part of the
  declared layout and goes with `wisp uninstall`.
- Stored grants wait on the protection track, so scheduled tasks ship after it, or with grants that last one
  conversation.
