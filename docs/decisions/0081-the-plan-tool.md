# ADR 0081: The plan tool, a recorded and tracked tree of tasks

Date: 2026-10-24. Status: accepted by the operator, decisions 1 to 4 on 2026-10-24, 5 to 11, how it is built,
on 2026-10-25, and 12 on 2026-10-26; built for 0.32.0. The first part of
[ADR 0079](0079-the-conversation-as-a-spine-with-task-trees.md) (the conversation as a spine, with task trees at its
turns), which stays proposed for the rest; nothing here runs a task, grants anything, or touches
[ADR 0078](0078-tasks-a-plan-and-its-grant.md) or [ADR 0080](0080-agent-skills.md).

## Context

ADRs 0078 to 0080 propose how wisp would compose its primitives into plans that run: trees of tasks, grants, skills,
a runner. An adversarial review on 2026-10-24 ([the proposal](../proposals/2026-10-24-task-trees.md), "Review") found
that the parts that run are not ready: statuses that gate execution, values flowing into commands, stored plans before
the protection track, a gate with no provenance. The operator chose to build the plan tool first, and to think about
skills further.

What a plan tool is useful for without running anything: the model writes down the steps of work that spans several
calls or turns, tracks them, and reads back what is left, in a form the person and an MCP caller can read too. The
probe of 2026-10-23 ([measurements.md](../measurements.md), "Planning a task tree and its grant") had models write
whole plans at once as JSON; whether they build one call at a time through a tool is not yet measured.

## Decision

The operator's answers on 2026-10-24:

1. **The tool is `plan`**, `/plan` in chat, `wisp://threads/{thread_id}/plan`. (`task` is the thread's task fact;
   ADR 0079 called the tool `tasks`.)
2. **It records and tracks**: the model adds tasks and dependencies, reads and searches the tree, and marks its own
   progress (`running`, `done`, `failed`, `skipped`) as it works in ordinary turns, like a checklist. No runner, no
   typed outputs, no grants, no briefs. ADR 0079 decision 12's rule that only a runner sets the status of steps,
   questions, and notices comes with a runner, since here no status gates anything.
3. **The person sees it in every face**: chat and `wisp-tui` (`/plan`), a terminal (`wisp threads plan ID`), MCP
   (the resources, and `respond`'s `plan` when a turn changed it), and later turns of the conversation (a line a tree
   in the request's now block).
4. **0.32.0, off by default**: `tools.plan`, or a tool list naming `plan`, as `ask` and `memory` are added, until it
   is measured on local models.

How it is built ([tools/plan.md](../tools/plan.md)), proposed with the build and agreed by the operator on
2026-10-25:

5. **Trees are rooted at turns.** The first task a turn adds without a parent roots that turn's tree; the agent records
   the store id of the turn's prompt on the tree when the turn ends. Trees are numbered `t1`, `t2`, … and tasks `t1.1`,
   …, never reused. ADR 0079 decision 2 proposed the prompt's store id as the tree's id; that id is not known until the
   turn ends, and a number reads better, so the id is a number and the prompt is recorded beside it.
6. **Dependencies cross trees; a cycle is refused** when added, with the path. Starting or finishing a task whose
   dependencies are not done is refused; failing or skipping one is not, and what depends on a failed or skipped task
   is not ready.
7. **Bounded**: 64 tasks a tree, 256 a plan, 6 deep, 8 dependencies a task, a goal of 200 characters and a note of
   300; a result pages at 40 lines and is fitted to the tool-output budget.
8. **Saved with the record** (`ThreadRecord.plan`, in `record.store`), not in a file of its own: it is written with the
   rest of the thread under the thread's lock, and resumed with it. A `PlanBook` holds the live plan for the tool,
   which the framework calls from its own task; the agent saves it into the store when each turn ends.
9. **Later turns see a line a tree**, not the tree: up to four open trees, newest first, and a count of the rest, in
   the now block, marked as a record and not instructions. Trees the turn under way rooted are left out.
10. **Audited** as `plan.add`, `plan.depend`, and `plan.update`.
11. **`add` takes the calls a small model makes.** A first run with `ollama:granite4.1:8b` on 2026-10-25 made every
    `add` fail: it named the tree it expected (`parent: "t1"`) before the tree existed, gave its own ids, and called for
    all three tasks at once, so a dependency arrived before the task it named. So a parent naming the turn's own tree
    counts as none, a model's id is kept when it fits the tree and is unused, and a dependency may name a task of the
    same tree not yet added (not ready until it is added and done; a cycle through it refused when it would close). Run
    again, the same prompt built the tree, marked the first task done, and freed the next.

Agreed by the operator on 2026-10-26, after the plan probe ([measurements.md](../measurements.md), "Keeping the plan
while working"):

12. **Every other tool's result reminds the model to mark its task.** While a task is running or ready and the turn has
    marked none, `AuditedTool` ends each result of every tool but `plan` with one line naming the task and the call that
    marks it (`[plan: t1.2 List the largest folders is next; if this result finishes it, mark it: plan update t1.2
    done]`), and the audit records the result as the model sees it. A mark quiets it until the next turn. In the probe,
    `granite4.1:8b` finished no conversation without it (0/6, not one `update`) and five of six with it; `gemma4:12b`
    and `granite4.2:8b` not thinking kept their plans either way (6/6 and 4/6 with it, 5/6 and 5/6 without). The line
    naming the next task in later turns (`PlanText.reference`'s `next`) stays in the probe only: alone it took
    `granite4.1:8b` to 1/6.

## Consequences

- A model can keep the steps of long work outside its context and pick them up in a later turn or after a resume, and
  the person can see the plan it is following.
- The plan carries no authority: a status set by the model gates nothing, and nothing in the plan runs. When a runner
  arrives (ADR 0079, proposed), statuses that gate execution move to the runner and the person, as the review asked.
- Whether local models use the tool well is unmeasured; it stays off by default until an evaluation shows it, and the
  probe of ADR 0078 is to be rerun through the tool.
- A chat by the operator on 2026-10-25 (`granite4.1:8b`, 18 turns) found the model adding tasks but never marking
  one: it ran all three, said so in its replies, and left them `ready`, and in most turns it restated the plan instead
  of working until it was prompted again. The plan probe, `scripts/check eval plan` (`PlanEvalTests`), measures that:
  three problems, each driven with "go on" for up to six turns, scored from the plan and the audit (every task settled,
  updates made, turns with no call, tasks marked done ahead of the work, conversations that never planned), under four
  variants: no help, a line naming the tree's next task and how to mark it (`PlanText.reference`'s `next`,
  `PlanBook(namesNext:)`), the reminder (`PlanBook(reminds:)`), and both. Decision 12 adopted the reminder.
- `granite4.2:8b`'s failure in the probe is another one: it often did the work without adding a task, so the plan
  stayed empty and nothing reminded it. A nudge for a turn that was asked for a plan and added none would need its own
  variant in the probe first.
- The plan is stored in `~/.wisp` with the rest of the thread, under the same protection, or lack of it, as the
  thread's record; it holds no grant and no instructions that run.
