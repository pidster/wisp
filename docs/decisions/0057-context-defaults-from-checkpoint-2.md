# ADR 0057: Context defaults from checkpoint 2

Date: 2026-10-09. Status: accepted. Amends [ADR 0045](0045-layered-context.md): `memory` is off by default and kept as
a setting (`context.memory`), `context.target` is 0.6, and `assessment.taskChanges` is `restated`; the headroom (8
turns), the guard, and the assessment's being off are unchanged. Records the results of
[context checkpoint 2](../proposals/2026-10-06-context-checkpoint-2.md), whose questions are ADR 0045's open items;
the full tables are in [measurements.md](../measurements.md#results-2026-10-06-to-2026-10-08).

## Context

ADR 0045 shipped the layered context with `memory` registered with every tool, a condensing target of half the
window, a headroom of the latest eight turns' average, and the assessment off. Its first checkpoint never
condensed at the default budget (85%) in 22 turns, so the target and headroom were never exercised there; it found
`memory` used correctly by granite when it recalled the right entry, on thin evidence; and it found the
assessment's inferred task rewritten on 8 to 11 of 22 requests.

Checkpoint 2 ran the plan's five parts on the on-device model (`system`) and `ollama:granite4.1:8b`, both at a window
of 8,192 tokens, with `ollama:gemma4:12b` on the `memory` question only. The scenario is `sustained`: 29 turns
(facts and a task planted, reads, a ten-file digression, a return to the task, late facts, files read again) and
ten questions. The main pass ran once per cell (2026-10-06 21:54 to 2026-10-07 02:13, load average 1 to 3); the
candidate changes were then confirmed with three runs of the default cell and each candidate (2026-10-08, 09:09 to
18:09 and 21:53 to 22:47, load average 1 to 5), as the plan requires before any default changes. The tables below
are answers of 10, each run, then the mean and the median.

### Whether `memory` helps (question 4)

`sustained` at the default budget with the whole stack, with `memory` and without it (`memory-off`, the same stack
otherwise: facts, the summary in the facts' call, references, condensing to the target).

| Model | With `memory` | Mean, median | Without | Mean, median |
| --- | --- | --- | --- | --- |
| `system` | 4, 5, 4 | 4.3, 4 | 4, 5, 7 | 5.3, 5 |
| `granite4.1:8b` | 6, 9, 7 | 7.3, 7 | 8, 8, 8 | 8.0, 8 |
| `gemma4:12b` | 8, 8, 8 | 8.0, 8 | 10, 8, 10 | 9.3, 10 |

The detail questions (`detail`, `reporter`), which `memory` exists for, did no better with it: 0 of 6 against 1 of
6 on the on-device model, 1 against 1 on granite, 4 against 6 on gemma4. The on-device model called `memory` 2 to 7
times a run and granite 0 or 1; gemma4 called it 3 to 5 times, and its 95th-percentile turn with `memory` was 188 to
358 s (27 to 190 s without). In the half part (one run, `recalling` at a budget of 0.5) the stack scored 3 of 7 on
the on-device model and 4 on granite, the stack without `memory` 5 and 6.

### The target and the headroom (question 1)

The grid's main pass (nine cells a model, one run each) put target 0.6 at or above 0.5 on the on-device model and
no cell clearly ahead on granite. The confirmation, three runs of the four cells:

| Model | Target × headroom | Runs | Mean, median | Condensations | Turn p50 |
| --- | --- | --- | --- | --- | --- |
| `system` | 0.5 × 8 (the default) | 3, 7, 2 | 4.0, 3 | 4, 2, 3 | 9.7 to 12.4 s |
| `system` | 0.5 × 1 | 2, 6, 3 | 3.7, 3 | 8, 2, 3 | 9.7 to 11.9 s |
| `system` | 0.6 × 8 | 4, 4, 8 | 5.3, 4 | 3, 3, 3 | 11.1 to 11.7 s |
| `system` | 0.6 × 1 | 5, 5, 4 | 4.7, 5 | 6, 3, 3 | 12.4 to 15.0 s |
| `granite4.1:8b` | 0.5 × 8 (the default) | 7, 6, 8 | 7.0, 7 | 1, 2, 1 | 4.7 to 7.2 s |
| `granite4.1:8b` | 0.5 × 1 | 8, 7, 5 | 6.7, 7 | 2, 3, 2 (a floor in two runs) | 5.8 to 7.1 s |
| `granite4.1:8b` | 0.6 × 8 | 9, 7, 7 | 7.7, 7 | 2, 3, 2 (a floor in one run) | 6.5 to 7.2 s |
| `granite4.1:8b` | 0.6 × 1 | 7, 6, 8 | 7.0, 7 | 2, 2, 3 | 6.6 to 6.7 s |

Every default cell condensed at least once, so the scenario exercised the default budget. After condensing, 0.6
left the on-device context at 4,550 to 4,670 tokens (2,500 to 3,800 at 0.5), and the gaps between condensations were
6 or 7 turns. A headroom of one turn scored no better than eight on either model and condensed more often on the
on-device model.

### The assessment (question 5)

`sustained` with every built-in tool offered: the stack without the assessment (`off`), the assessment as built
(`any`), and with `taskChanges: restated`.

| Model | Cell | Runs | Mean, median | `task` answer | Task changes | Assessment calls | Turn p50 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `system` | off | 4, 2, 1 | 2.3, 2 | correct 3 of 3 | 0 | 0 | 9.7 to 13.1 s |
| `system` | `any` | 3, 2, 5 | 3.3, 3 | correct 1 of 3 | 14 to 23 | 28 or 29 | 13.7 to 19.8 s |
| `system` | `restated` | 4, 3, 2 | 3.0, 3 | correct 3 of 3 | 2 | 7 to 9 | 11.2 to 14.2 s |
| `granite4.1:8b` | off | 8, 7, 7 | 7.3, 7 | correct 3 of 3 | 0 | 0 | 5.5 to 7.4 s |
| `granite4.1:8b` | `any` | 7, 7, 5 | 6.3, 7 | correct 0 of 3 | 8 to 19 | 27 to 30 | 11.5 to 13.4 s |
| `granite4.1:8b` | `restated` | 6, 8, 9 | 7.7, 8 | correct 3 of 3 | 1 or 2 | 9 or 10 | 7.5 to 9.3 s |

### Once only

- **The 50% variants under the guard** (question 2; `recalling`, budget 0.5, one run): the stack 3 and 4 of 7
  (on-device, granite), the stack without `memory` (summary only) 5 and 6, phase 2's fixed four turns 3 and 6,
  dropping 0 and 1. The stack's gaps between condensations were 3 and 3 turns on the on-device model and 2 and 3
  on granite, with 4 and 6 distillations, where the first checkpoint had 70 of 84 gaps at a single turn and 7 to 12
  distillations: the guard works, and no run reached the floor.
- **A model switch** (question 3; one run each): on-device to granite at the return to the task and back for the
  questions scored 6 of 10; granite at 32,768 tokens, then the on-device model from turn 16, scored 5. Neither
  failed or overflowed, and both are within one answer of the on-device model's own default cell in the main pass
  (5).

### The noise

Single runs on the on-device model range from 1 to 8 of 10 on the same cell (0.5 × 8 ran 3, 7, and 2 in the grid's
confirmation and 4, 5, and 4 in the memory part's, the same cell on the same code). Three runs narrow that but do
not remove it; the differences above are one answer or less in the median, except `memory` on gemma4 (two). Every
figure is one scenario, at one window (8,192), on three models.

## Decision

1. **`memory` is off by default, kept as a setting.** `context.memory` (default false) puts it among the tools a
   conversation given every tool gets (`wisp "…"`, chat, MCP `respond` without `tools`). It stays registered, so a
   tool list that names it (`--tool memory`, an MCP caller's `tools: ["read_file", "memory"]`) still gets it, as an
   explicit list has always been exactly that list; `tools.disabled: ["memory"]` still removes it everywhere. Off,
   the model is not offered the tool, the system prompt leaves out its rule (as it did for any conversation without
   it), and a reference to earlier output ends `call it again to see it` (for a tool that only reads: `read_file`,
   `inspect`, `system_info`, `current_date`) or `its output is not repeated; do not run it again to see it` (for any
   other, so a command is never run again to see its output, the operator's rule of 2026-10-04) instead of
   `to see it: memory "recall entry 7"`; the facts, the summary, and the references themselves are unchanged. On, everything behaves as before.
   The plan's rule kept `memory` with every tool only if the details scored at least as well with it and the total
   no worse; it lost on all three models, and helped on none, so the plan's middle path (registering it by window
   or model) has nothing to register it for.

   A setting, rather than `memory` in a default `tools.disabled`: `tools.disabled` means "not registered", so
   `--tool memory` would become an unknown tool, and any operator who set `tools.disabled` to something else would
   silently turn it back on. `context.memory` sits with the other context settings, is settable from chat
   (`/config set context.memory on`), and shows in `wisp://config`.

2. **`context.target` is 0.6.** It scored more than 0.5 in the mean on both models (5.3 against 4.0, 7.7 against
   7.0) with no more condensations on the on-device model and turns no slower there. By the plan's rule (one answer
   more in the median on both models) it qualifies on the on-device model (4 against 3) and ties on granite (7 and
   7); the operator chose it on the means and on 0.6 × 1 also beating 0.5 × 1 on both. Granite's median turn was
   longer in this run (6.9 s against 5.4 s), but the same 0.5 × 8 cell ran at 7.9 to 9.0 s in the memory part earlier
   that day, so that difference is within run-to-run spread. One of granite's three 0.6 runs reached the floor once,
   as did one of the 0.5 runs in the memory part. The guard (the share capped at the budget less 0.2) is unchanged
   and leaves 0.6 alone at the default budget: the cap is 0.65.

3. **`context.headroomTurns` stays 8.** One turn neither tied nor beat it on both models with fewer
   condensations, the plan's condition.

4. **The assessment stays off; `assessment.taskChanges` is `restated` by default.** `restated` kept the task on
   all six runs where `any` lost it on five of six, scored within one answer of the assessment off on both models
   (the plan's condition for the default), and made a third as many assessment calls. It matters only when the
   assessment is turned on (`assessment.enabled`); `any` is still a choice. The assessment itself would go on by
   default only if `restated` beat `off` by an answer in the median on both models: it does by the median (3
   against 2, 8 against 7) but not by the mean (0.7 and 0.4 of an answer), within the on-device model's noise, at
   7 to 10 more model calls a conversation and a median turn 1 to 2 s longer. The operator kept it off.

## Consequences

- **A default conversation has seven built-in tools**, and its instructions are about 150 tokens shorter (the
  `memory` definition, 110 tokens, and its rule, 43, measured on the on-device model on 2026-09-30 and 2026-10-01).
  A model that wants a dropped detail reads the file or runs the command again, as the reference says; on a
  `run_command` that changes state that is a second run, which the gate and approval still stand in front of. The
  person still sees every output (`/show`, `/inspect context`), which costs the model nothing.
- **Condensing leaves more in view and runs later**: 0.6 of the window is about 4,900 tokens at 8,192, so a
  condensation keeps about 800 more tokens of turns and leaves a quarter of the window, rather than 35%, for the
  turns before the next one. The context is fuller on more requests.
- **Restoring the old behaviour** is three settings: `context.memory: true`, `context.target: 0.5`, and
  `assessment.taskChanges: any` (each with `wisp config set` or `/config set`).
- **The evals set what they measure explicitly**: the context eval's strategies, the checkpoint's cells, and the chat
  and `system_info` evals build their tool sets and prompts themselves, with `memory` on where they measured it, so
  their figures stay comparable with those recorded before. The checkpoint's default cell is now `t60-h8`, since it
  follows `ContextTarget.default`; its grid's targets stay 0.4, 0.5, and 0.6 unless `WISP_CHECKPOINT_TARGETS` says
  otherwise.

**Open:**

- **One scenario.** `sustained` is a reading conversation with planted facts. A session that edits, builds, and
  tests may want `memory` more, and a window larger than 8,192 (granite's own, sized from memory) condenses rarely
  enough that these defaults barely act. A checkpoint on a second scenario, or on real chat use with
  `context.memory` on, would test both.
- **Why `memory` cost answers** is not settled. In the on-device model's three runs with it, one of its 13 calls
  recalled an entry; the rest asked for facts or were notes in a shape the tool refuses. gemma4 spent minutes on
  some turns with it. A recall hint only in the references, without the tool
  definition in every request, is untested.
- **ADR 0045's remaining open items** stand: D7's repeated facts and the tools line under the assessment, a
  specialised distiller, and a fast classifier for tools.
