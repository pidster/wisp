# Plan: context checkpoint 2

Date: 2026-10-06. Status: prepared, not run. The measurement is built and passes the gate without a model; the run
waits for a Mac with nothing else on the GPU or in Ollama. The roadmap item is 0.20.0's "Context checkpoint 2"
([roadmap.md](../roadmap.md)); its questions are the open items of
[ADR 0045](../decisions/0045-layered-context.md), whose first checkpoint (2026-10-01) is the baseline here. The
[layered-context proposal](2026-09-29-layered-context.md) has the design and every earlier figure.

This page says what each question is, what is measured, which result would change which default, and the exact
commands, so that the run and the decisions can follow it without a further design step.

## What is built

| Piece | Where | What it does |
| --- | --- | --- |
| The `sustained` scenario | `ContextEval.sustained()` in `WispTestSupport`, six new fixtures beside the old | `noting` (15 turns) and then 14 turns back on the task: the task restated (`Back to the task: …`), the planner and its tests read, a short follow-up with no tool, the issue that asked for the flag, a fact planted (the beta channel), the changelog, the command read again, a failing `swift test` log, a line of help text, review notes, the flags reference, the planner, and the configuration file read again, and the changelog line asked for. Then `noting`'s eight questions and two more: the channel (a late fact) and who opened the issue (a detail of a read, which no fact need carry). 29 turns and ten questions |
| The plan | `ContextCheckpoint` in `WispTestSupport` | The parts, the grid, the window, the runs, and the switch plans, read from the environment; the cells of each part; the table's row |
| The model switch | `SwitchingStrategy`, `SwitchingThread` | Before given turns, a new agent on another model continues the store (facts, summary, references, dropped turns), the tools and `memory` source, and every setting, as chat's `/model` does |
| The assessment variant | `assessment.taskChanges: restated` ([context-management.md](../context-management.md), "When the task may change") | Once there is a task, only a request that states one may change it; other requests keep it without a model call for the task. Off with the assessment, as before; `any` is the default and unchanged |
| The runner | `ContextCheckpointTests` in `harness/Evals` | Each part as a test, each cell on each model, a `checkpoint row` per run |
| The command | `scripts/check eval checkpoint` ([measurements.md](../measurements.md#context-checkpoint-2)) | The parts `WISP_CHECKPOINT` names, then a table and a TSV of every row |

The gate (no model) proves the scenario and the plumbing: the fixtures are one `read_file` page each and hold no
answer but their own; only the first turn and the return to the task state the task; an estimate on a scripted
model at three bytes a token, calibrated on the first checkpoint (where `recalling` reached 6,239 and 6,511 tokens
without condensing and the estimate gives 5,718), has `recalling` never condensing at the default budget and
`sustained` condensing in its last third, and a higher target condensing at least as often as a lower one; the
switch carries the store, its facts, and the tool events to the next model; the plan parses and rejects what it
should; the script's table names the row's fields in order.

## Use since the first checkpoint

The context features have been the default since 0.16.0, and the checkpoint is designed from that use without
reading anyone's `~/.wisp`:

- **The shapes of real turns.** A working session is not 15 reads in a row. `sustained` adds what chat and the git
  thread show in the docs and the audit's event kinds: a task restated on return, files read again later, replies
  with no tool (a follow-up of a few words, a line to write), a build log, and late facts. The scenario still reads
  only fixtures, so a run is repeatable.
- **The real records.** The runner reads the audit events the shipped code writes (`context.condensation`'s
  `fillAfter`, `target`, and `floor`; `context.distillation`; `context.memory`; `context.assessment`'s
  `taskChanged`; `fact.recorded`), and the switch goes through `Agent(store:…)`, the path `/model` takes.
- **Real windows.** A delegated thread on `granite4.1:8b` gets a window sized from memory, often far above 8,192,
  where the default budget rarely condenses; the second switch plan starts granite at 32,768 and moves to the
  on-device model's 8,192, the case where a switch must condense at once.
- **The defaults in use.** `context.target` 0.5, `context.headroomTurns` 8, the guard (0.65 at the default budget),
  `memory` with every tool, the summary in the facts' call, and the assessment off: the checkpoint measures them as
  shipped and changes one only by the rules below.

## The questions

Every run records, per cell: the answers (score, the planted and noted facts, the details, the task, the first
file), condensations and floors, the turns between condensations, the fill after condensing, tokens (median and
maximum after a turn), time per turn (median and p95), distillations and their seconds, `memory` calls, task changes,
and assessment calls. The first checkpoint showed on-device scores moving by two or three of seven between near
identical builds, so **no default changes on one run**: a candidate change is confirmed by three runs of the
default cell and of the candidate (command 4), and the medians decide.

### 1. The target and the headroom, at the default budget

The first checkpoint never condensed at 85% in 22 turns, so the defaults were never exercised there.

- **Measured**: `grid`, the `sustained` scenario at the default budget, with the target at 0.4, 0.5, and 0.6 and
  the headroom at 0, 1, and 8 turns: nine cells per model.
- **Expected**: one to three condensations per run, all after the return to the task (the gate's estimate gives
  the default cell one, at turn 18, and 0.6 with a headroom of one or eight turns two).
- **What would change a default**:
  - `context.target`: another target scores at least one answer more than 0.5 in the median of three runs on both
    `system` and `granite4.1:8b`, without more than 20% more time per turn and without a floor. A lower target
    that ties 0.5 with fewer condensations and less distilling time is also a reason, since each distillation is
    another chance to garble a fact.
  - `context.headroomTurns`: 1 or 0 replaces 8 only if it ties or beats it on both models with fewer
    condensations, no floor, and no overflow retry. A headroom of 0 waits until the context and prompt alone pass
    the budget; if it shows overflows on Ollama (which truncates silently), it stays out whatever it scores.
  - If no default cell condenses at least once on a model, the scenario is too short for that model's replies:
    say so, and rerun the grid with `WISP_CHECKPOINT_WINDOW=6144` on Ollama only (the on-device window is fixed).
- **Not changed by it**: the budget (85%), which is not a setting, and the guard's margin, which the half part
  tests.

### 2. The 50% variants under the guard

At a budget of 0.5 the first checkpoint's target equalled the budget, and 70 of 84 gaps between condensations were a
single turn. The guard now caps the target at the budget less 0.2 (0.3 here).

- **Measured**: `half`, the `recalling` scenario at a budget of 0.5, as the first checkpoint ran it: the whole
  stack (`half-stack`), without `memory` (`half-no-memory`), phase 2's fixed four turns (`half-fixed`), and
  dropping (`half-dropping`).
- **Compared with**: the first checkpoint's rows at 50% (stack 3/7 and 4/7, fixed four turns 4/7 and 7/7, without
  memory 5/7 and 5/7, dropping 0/7 and 0/7, on-device and granite).
- **What it decides**: the guard works if the stack's gaps between condensations are mostly two turns or more and
  its distillations fall from 7 to 12 toward the fixed policy's 1 or 2, scoring at least as well as before. If it
  reaches the floor on most condensations, a 50% budget is too tight for an 8,192 window (as ADR 0045 foresaw), and
  that is recorded rather than the margin changed. If gaps are still single turns, the margin (0.2) is too small,
  and a larger one is the follow-up, with its own gate test.

### 3. A model switch mid-conversation (D10)

D10 says a switch carries the store to the new model's agent, which composes for its own window. Never evaluated.

- **Measured**: `switch`, the stack on `sustained`, with two plans by default: `system>ollama:granite4.1:8b>system`
  (granite from the return to the task, the on-device model again for the questions), and
  `ollama:granite4.1:8b@32768>system` (granite at a window that holds the conversation, then the on-device model
  from turn 16, whose window it does not fit).
- **Compared with**: the grid's default cell (`t50-h8`) on each model alone.
- **What it decides**: the switch is sound if, at the first turn on the new model, the facts and summary are carried
  (the switch line counts them), the turn does not fail or overflow, and the questions score within one answer of
  the destination model's own run. A switch to a smaller window should condense on its first turn (reason `budget`)
  and keep the early facts through distillation; if instead it overflows, fails, or reaches the floor, the
  follow-up is a condensation at the switch itself, before the first request, built with a gate test.

### 4. Whether `memory` helps

`memory` stayed at the first checkpoint because granite used it correctly whenever it recalled the right entry;
the evidence was thin.

- **Measured**: `memory`, `sustained` at the default budget with the stack (`t50-h8`, shared with the grid) and
  without `memory` (`memory-off`); and in `half`, `half-stack` against `half-no-memory`.
- **What it decides**: `memory` stays registered with every tool if, with it, the detail questions (`detail`,
  `reporter`) score at least as well and the total no worse, in the median of three runs on both models. If it costs
  answers on the on-device model and helps on granite, the follow-up is registering it by window size or model,
  not removing it. The `memory` calls and the questions' other tool calls (re-reads) are the mechanism to read
  beside the score.

### 5. The assessment reconsidered

The assessment stays off (`assessment.enabled`). The first checkpoint found the inferred task rewritten on 8 to 11 of
22 requests, so the return to the task failed.

- **Measured**: `assessment`, `sustained` at the default budget with every built-in tool offered: the stack without
  the assessment (`assess-off`), the assessment as built (`assess-any`), and with `taskChanges: restated`
  (`assess-restated`).
- **Expected under `restated`**: task changes at most two (the first turn and the return to the task, the only two
  that state one, which the gate checks), and fewer assessment calls than `any`, since the rules settle the task on
  every other request.
- **What it decides**: if `restated` keeps the task (the `task` answer correct) and scores within one answer of
  `assess-off`, `taskChanges` becomes `restated` by default (the assessment itself still off). The assessment goes
  on by default only if `assess-restated` beats `assess-off` by at least one answer in the median of three runs on
  both models, with its added time per turn (2 to 4 s a call at the first checkpoint) stated in the decision.
  Otherwise it stays off, and the open items in ADR 0045 (D7's repeated facts, a tools line that invites calls, a
  fast classifier for tools) stay open.

## Models and run time

The checkpoint runs on the on-device model (`system`, wisp's default) and on `granite4.1:8b` (the delegation
default), at a window of 8,192 for both, as the first checkpoint did. `gemma4:12b`, the model for complex work, runs
the default cell and `memory-off` only, to see whether a larger model changes the answer to question 4; the rest of
the grid on it would take about six hours.

Estimated from the times measured on 2026-10-01 (on-device context turns 6.9 to 13.7 s, distillations 12 to 30 s)
and 2026-10-04 (granite about 6.4 s a context turn; gemma4:12b 12 to 18 s a request, so about 30 s a turn with a
tool call and its reply). `sustained` is 39 turns, `recalling` 22. Under load, or with Ollama evicting a model, add
to these.

| Part | Runs per model | `system` | `granite4.1:8b` | `gemma4:12b` |
| --- | --- | --- | --- | --- |
| `grid` (9 cells) | 9 × `sustained` | about 70 min (7.5 min a run) | about 45 min (5 min) | about 3.5 h (22 min), not planned |
| `half` (4 cells) | 4 × `recalling` | about 20 min (5.5 min) | about 20 min (5.5 min) | about 1 h, not planned |
| `memory` (1 more cell) | 1 × `sustained` | about 8 min | about 5 min | 2 cells, about 45 min |
| `assessment` (3 cells) | 3 × `sustained`, every tool | about 25 min | about 20 min | not planned |
| `switch` (2 plans) | once, not per model | about 15 min in all | | |

The main pass is about two hours on `system`, an hour and a half on `granite4.1:8b`, and a quarter of an hour of
switches: about four hours. Confirmation runs (command 4) take three runs of two to four cells per model.

## Commands

Run from the repository root, with nothing else using the GPU or Ollama, and `ollama:granite4.1:8b` and
`ollama:gemma4:12b` pulled and enabled (`wisp models`). Each command ends with the table; the log, the table, and
the TSV are under `harness/Evals/.build/evals`. Nothing is recorded into `measurements.json` without `record`.

```
# 0. Build only, to be sure the eval package compiles (no model).
swift build --package-path harness/Evals --build-tests

# 1. The main pass: every part on the on-device model and granite (about four hours).
WISP_EVAL_MODELS=system,ollama:granite4.1:8b scripts/check eval checkpoint

#    The same in two sittings, if wanted:
WISP_EVAL_MODELS=system,ollama:granite4.1:8b WISP_CHECKPOINT=grid scripts/check eval checkpoint
WISP_EVAL_MODELS=system,ollama:granite4.1:8b WISP_CHECKPOINT=half,memory,assessment,switch scripts/check eval checkpoint

# 2. gemma4:12b on question 4 (about 45 minutes).
WISP_EVAL_MODELS=ollama:gemma4:12b WISP_CHECKPOINT=memory scripts/check eval checkpoint

# 3. Another switch, for instance the complex-work model handing back to the delegation default.
WISP_CHECKPOINT=switch WISP_CHECKPOINT_SWITCHES='ollama:gemma4:12b>ollama:granite4.1:8b' scripts/check eval checkpoint

# 4. Before changing a default: three runs of the default cell and the candidate (here target 0.6, headroom 1;
#    the grid is every target with every headroom, so this is four cells).
WISP_EVAL_MODELS=system,ollama:granite4.1:8b WISP_CHECKPOINT=grid WISP_CHECKPOINT_TARGETS=0.5,0.6 \
    WISP_CHECKPOINT_HEADROOMS=8,1 WISP_CHECKPOINT_RUNS=3 scripts/check eval checkpoint
WISP_EVAL_MODELS=system,ollama:granite4.1:8b WISP_CHECKPOINT=assessment WISP_CHECKPOINT_RUNS=3 \
    scripts/check eval checkpoint

# 5. When the figures are to be kept in measurements.json, the same command with record.
WISP_EVAL_MODELS=system,ollama:granite4.1:8b scripts/check eval checkpoint record
```

## After the run

1. Put the table of each command, with the date, the load averages, and the build, into this page under "Results",
   one table per part, as the first checkpoint's are in ADR 0045.
2. Decide each question by its rule above, with the operator; a changed default goes in `ContextTarget.default` or
   `AssessmentSettings`, `Config`, [wisp.md](../wisp.md), [context-management.md](../context-management.md), and the
   CHANGELOG, in its own commit.
3. Record the decisions in a new ADR that amends ADR 0045 (its open items: the guard re-run, the target and headroom,
   the assessment, D10), and mark this plan done.

## Results

Not yet run.
