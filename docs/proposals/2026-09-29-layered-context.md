# Proposal: layered context, composed for each request

Date: 2026-09-29. Status: reviewed; decisions D1 to D12 recorded; phases 1 to 4c built. Becomes an
ADR with the eval's figures.
It would reverse design rule 4 of [context-management.md](../context-management.md) ("the transcript stays
a faithful record"), amend [ADR 0025](../decisions/0025-context-estimation.md), and leave
[ADR 0017](../decisions/0017-three-layer-instructions.md) unchanged.

## Problem

wisp keeps one transcript, and it grows. The model, the audit, and the person all see the same thing, and
the only way to keep it inside the window is to cut the oldest turns off. Measured on 2026-09-29 with the
on-device model, which has an 8,192-token window ([context-management.md](../context-management.md), "On
the on-device model, and what condensing costs"):

- **Facts go with the turns that held them.** A fact planted in turn 1 was dropped by the first
  condensation, and the model then said it did not know it.
- **Nothing tells the model what it lost.** Asked which file it read first, the model named the oldest one
  still in its window, confidently and wrongly.
- **It cannot go back.** The dropped turns exist in the audit log and, since `/inspect context`, in saved files. The
  model has no way to reach them.
- **Once full, it condenses every turn.** Four turns of file reading sit near the 85% budget, so from then
  on the transcript lost a turn before almost every prompt.
- **Most of the window is output nobody needs twice.** Tool output was most of the tokens: 4 KiB of file
  text a turn, often retyped by the model in its reply for the person to read.

These are not tuning problems. As long as the transcript is both the record and the model's view, keeping
it small means forgetting.

## Goals

1. Nothing is lost. Every turn, tool output, and reply is stored verbatim, as the audit log already is.
2. The model sees a context composed for each request: recent turns word for word, older ones as a
   summary and facts, and a way to recall anything in full.
3. What the person is shown is decided separately from what the model carries.
4. Content that came from the conversation never gains the authority of instructions.
5. Measured: an eval shows the design recalls more than today's dropping, at a stated cost in tokens and
   time per turn.

## Non-goals

- New tools for what output handling can do. `run_command("cat <path>")` shows a file; how its output is
  routed is the question, not how to fetch it.
- Retrieval over documents or the file system. This is about the conversation's own history.
- Sharing a conversation's history across sessions or threads. Each conversation's store is its own.
  Permanent facts are the exception, in a shared store ([D2](#d2-staleness-versioned-facts-under-a-composite-key)).

## Design

### Three views of one conversation

| View | Holds | For |
| --- | --- | --- |
| **Stored** | Every entry verbatim, once: prompts, tool calls, tool output, replies. Also the facts and summaries derived from them, each linked to its source entries. | The record, `recall`, the audit, `/inspect context`. |
| **Active** | The context composed for the next request, within a token budget. | The model. |
| **Shown** | What the person sees: the conversation, output in full or summarised, notes. | The person, in chat, `wisp-tui`, or the MCP caller's own view. |

Today all three are one `Transcript`. Here they are separate, and the stored view is the faithful one.

### The active context, in layers

In the order the model reads them:

| Layer | Where | Contents | Size |
| --- | --- | --- | --- |
| 1. Instructions | the instructions entry | wisp's system prompt, the operator's extension, the caller's instructions (ADR 0017, unchanged), and one standing rule on how context reaches the model and how to recall. | Fixed, the same every turn, so the prefix is stable for caching. |
| 2. Earlier | one prompt-side entry at the start | A summary of the turns older than the literal segment, then the facts. Each fact cites its source entries and says who it came from: the person, the model, or a tool. Labelled as a record, not as instructions. | Capped. |
| 3. Literal | the turns themselves | The most recent turns word for word, with their tool calls and output. | What the budget leaves, scaled to the model's window. |
| 4. Current | the prompt | The task frame (the task, its state, and how to recall it in full), then the request. | Small. |

**Authority is set by position.** Content derived from the conversation (summaries, facts, and above all
anything a tool returned) goes on the prompt side, never into the instructions. A README that says "ignore
your instructions" can reach the model only as a fact labelled as tool-derived. A test checks this.

**Chronological order.** Layer 2 stands where the turns it summarises happened, before the literal
segment. The task comes last, just before the request, where a small model weighs it most.

### Output handling decouples display from context

Every output is stored once, verbatim. Each view then holds its own rendering of it:

| Output | Stored | Shown | Active context |
| --- | --- | --- | --- |
| A command's or tool's output | full | full, a summary, or a one-line note, by the request and the size | full while in the literal segment; then a summary, facts, or a reference; or nothing, if nothing came of it |
| The model's reply | full | full | analysis, answers, and decisions kept (and distilled into facts); presentational text cut |

**Presentational text** is text the model wrote for the person to read, restating output that is stored
anyway: a retyped file, a table of a command's results. Once shown, it has done its job, and the composer
cuts it from the active context. It leaves a marker such as "(showed you the output of call 3)". It is
found mechanically: a stretch of the reply that largely reproduces a tool output of the same turn, by
word-sequence overlap. That is deterministic, fast, and testable without a model. Analysis does not
reproduce the output, so it stays.

### Recall

A `recall` tool, bounded and paged like `read_file`, restores stored material for the current turn only:

- a turn, or an entry, by its id;
- a fact's sources;
- the task in full: its original statement and the turns that shaped it.

The standing rule in layer 1 says it exists and when to use it. What it returns lives only in that turn's
literal segment, and ages out like anything else.

Built in phase 4c as the `recall` verb of a `memory` tool, which also lets the model note a fact as it works
(operator, 2026-09-30; see the phasing entry and "Memory, 2026-09-30").

### Facts

- **Short statements about earlier situations and outcomes**, such as "the codename is BLUE HERON" or
  "the gate passed at `cbec7db`".
- **Each fact is a versioned assertion** about an identity: its source entries, its origin (the person,
  the model, or a tool), when it was recorded, and a temporal class that sets how long it lives and where
  ([D2](#d2-staleness-versioned-facts-under-a-composite-key)).
- **Visible to the person:** `/inspect facts` in chat, and a matching MCP resource for a thread. Whether the
  person can pin, delete, and approve them is settled in [D3](#d3-what-the-person-can-do-to-facts).

### Condensing becomes distilling

When a turn leaves the literal segment, its content is distilled into facts and into the running summary,
and cut from the active context. It is not dropped from the store. The model sees less detail, not less
history, and knows how to get the detail back. Facts from tool output are extracted deterministically at
every turn. Facts from prose are distilled by the conversation's model as their turn ages out, and the
summary is written in batches ([D1](#d1-who-distils-and-when)).

## What changes in wisp

- **A store per conversation.** Entries by id, with facts and summaries linked to their sources. The
  verbatim content stays in the audit log, and the store refers to it
  ([D8](#d8-the-audit-log-stays-the-verbatim-record)). It lives beside the transcript and the audit, in
  `~/.wisp`, user-only.
- **A composer.** It builds each request's `Transcript` from the store, within a budget per layer. The
  framework already allows it: `LanguageModelSession(model:tools:transcript:)` starts a session from any
  transcript, which is how condensing works today. `Agent` asks the composer instead of continuing one
  session.
- **Output handling** after each turn: routing for display, and cutting presentational text.
- **A distiller** that writes facts and summaries.
- **The `recall` tool** and the standing rule.
- **`/inspect facts` and a facts resource.** `/inspect context` already shows the active view as it is.
- **Audit.** New events for distillation, recall, and cuts, each naming what it touched, so the
  composition is reconstructable.
- **Docs.** `context-management.md` (the design rules), `logging.md`, `wisp.md`, `mcp.md`, and an ADR.

## Evaluation

The scripted chat from 2026-09-29 is now an eval, `ContextEvalTests` in `ModelEvalTests`, run with
`scripts/check eval` like the others. Its scenario, scoring, and runner are `ContextEval` in
`WispTestSupport`, tested in the gate without a model:

1. Turn 1 states the task (add a `--dry-run` flag to `harbour sync`, a fictional file-sync tool) and a
   codename. Turns 2 to 4 each plant one more fact (the CI build is failing; the reviewer Maria prefers
   early returns; the ticket is 4127) and read one of three task files with `read_file`.
2. Turns 5 to 14 are a digression: ten incident reviews of an unrelated shop, one read per turn. Turn 10
   also changes a fact: the CI build is green again (D2's current value).
3. Six questions follow, one per turn: the codename, the ticket, Maria's preference, the CI state now,
   the first file read, and a return to the task.

Every fixture is one `read_file` page of about 3.6 KB, and none contains an answer, which a gate test
checks. The whole conversation comes to about 16,000 tokens, two on-device windows. A reply is scored by
phrase after normalising case and punctuation: the expected phrase anywhere in the reply is correct.
For the changed fact, naming the new value counts even beside the old one, and naming only the old value
counts as stale. Each turn records its wall time, the tokens occupied after it, the condensations during
it (from the audit), and the tools it called. The run's measurement is `context.<strategy>[.<variant>]`
in `measurements.json`, with time per turn as p50 and p95. The notes carry the condensations, the median
tokens, and the load average.

A strategy is the seam. `ContextStrategy` opens a conversation over the same model, tools, and
instructions, and the same scenario runs through it. Today there is one, `DroppingStrategy`: the
`Agent` unchanged. Layers without recall, the full design, D5's cap and floor variants, and D7's repeated
facts each add a strategy. A model switch (D10) and an inferred task (D6) will need new step kinds.

Ollama's window is sized from free memory (ADR 0043), so granite runs at three windows:
- 8,192, configured, to compare with the on-device model.
- 32,768, configured, which holds the whole scenario: the ceiling, with nothing dropped.
- The window wisp sizes, which is what a user gets.

All three use the default config, not the operator's.

It is scored on facts recalled, correct "what came first" answers, a correct return to the task, tokens
per turn, and time per turn. It is run for today's dropping, then for layers without recall, then for the
full design, on the on-device model and on `ollama:granite4.1:8b`. The bar: better recall than dropping
at a small, fixed cost per turn.

### Baseline, 2026-09-29

Measured on this Mac with `WISP_MODEL_TESTS=1 swift test --filter ContextEvalTests`, recorded in
`measurements.json`. Another project's builds kept the machine under heavy load throughout (one-minute
load average 18 at the start, 150 to 270 for the rest), so times are indicative only.

| Model, window | Facts (of 4) | CI now | First file | Task | Condensations | Tokens after a turn, median (max) | Time per turn, median (p95) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| On-device, 8,192 | 0 | wrong | wrong | wrong | 9 | 5,896 (7,123) | 21.2 s (34.2 s) |
| granite4.1:8b, 8,192 | 1 | correct | wrong | wrong | 4 | 6,124 (7,411) | 9.4 s (27.1 s) |
| granite4.1:8b, 32,768 | 4 | correct | correct | correct | 0 | 11,201 (16,252) | 11.0 s (13.2 s) |
| granite4.1:8b, sized (8,192 under load) | 0 | wrong | wrong | wrong | 5 | 6,206 (7,573) | 11.4 s (30.6 s) |

What the baseline shows:
- **Dropping loses everything planted early.** At an 8,192-token window every early fact and the task
  are gone by the questions. The one correct answer at 8,192 on granite is the CI state, planted mid
  digression and still in the window.
- **Wrong answers are confident.** Both models named a mid-digression file as the first one read
  (`postmortem-07`, `postmortem-06`). Asked to return to the task, they described reading postmortems.
  On granite with the sized window, the model named the codename question as the task. Granite said
  the facts were not in "the postmortem files you provided".
- **The on-device model answered as itself.** Every question got "I am Wisp, a concise assistant
  running on this Mac" and a refusal ("I cannot provide release codenames").
- **The model can recall when nothing is dropped.** At 32,768 granite answered all six, so the loss at
  8,192 is the dropping's, not the model's.
- **Condensing makes turns slower.** From turn 7 the on-device model condensed before every turn. Granite
  at 8,192 condensed every other turn, and those turns took 26 to 31 s against 9 to 13 s for the
  others. Rebuilding the session re-reads the whole prompt, the cost D11 is about.
- **The sized window is not always bigger.** Under load, wisp sized granite's window at 8,192 of 131,072
  ("6.7 GiB of a 7.3 GiB budget"), so that run repeated the 8,192 one.

### Output handling, 2026-09-29

Measured on this Mac with `WISP_MODEL_TESTS=1 swift test --filter ContextEvalTests/showing`, recorded
in `measurements.json` as `context.<strategy>.showing[.window-8192]`. The `showing` scenario is the
baseline with one more turn after the task files: read `harbour.toml` (866 bytes) and show it in full.
Every model retyped it in a code block, and cutting found it each time: one cut per run. Another project's
builds loaded the machine, so times are indicative only. The one-minute load average was 3 to 8 for the
first on-device runs, 8 to 148 for granite dropping, 148 to 196 for granite cutting, 179 to 101 for the
on-device rerun, and 78 to 165 for the third on-device cutting run, on 2026-09-30.

| Model, window | Strategy | Facts (of 4) | CI now | First file | Task | Cuts | Condensations | Tokens after a turn, median (max) | Time per turn, median (p95) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| On-device, 8,192 | dropping | 0 | wrong | wrong | wrong | 0 | 8 | 6,009 (7,925) | 16.7 s (19.8 s) |
| On-device, 8,192 | cutting, first run (outlier) | 1 | correct | wrong | wrong | 1 | 1 | 3,047 (7,188) | 6.3 s (15.9 s) |
| On-device, 8,192 | cutting, rerun | 0 | wrong | wrong | wrong | 1 | 8 | 6,004 (7,717) | 25.9 s (30.4 s) |
| On-device, 8,192 | cutting, third run (recorded) | 0 | wrong | wrong | wrong | 1 | 8 | 5,955 | 26.3 s (30.9 s) |
| granite4.1:8b, 8,192 | dropping | 1 | correct | wrong | wrong | 0 | 4 | 6,170 (7,968) | 5.3 s (45.7 s) |
| granite4.1:8b, 8,192 | cutting | 0 | wrong | wrong | wrong | 1 | 4 | 5,306 (7,868) | 11.0 s (28.3 s) |

What it shows:
- **A cut saves what the retyping cost, and no more.** After the shown file's turn, granite carried 5,536
  tokens with cutting against 5,813 without (the turn after it), close to the 200 or so tokens the
  866-byte retype is worth at four bytes a token. On this scenario that is 3% of the window, too little to move a
  condensation: both granite runs condensed four times, and the on-device rerun eight times, as dropping did.
- **The first on-device cutting run is not the cut's doing.** In that run the model read every file
  differently (about 450 tokens a read instead of 1,300, one read of a file that does not exist), so it
  stayed under the budget until turn 15. Both later runs read as the dropping run did and matched it;
  the third is the one recorded in `measurements.json` as `context.cutting.showing`.
- **Recall is unchanged.** Every run lost the early facts and the task with the turns that held them, as
  the baseline did; the one or two right answers are the CI state, planted mid-digression. Cutting was
  never meant to fix recall on its own; facts and `recall` (phase 4) are.
- **A cut costs a new session on the next request**, as a condensation does. At this scale it is lost in
  the load: granite's cutting run took 11.8 s for the turn after the cut against 5.5 s without, under a
  load average near 150.

### References after the turn, 2026-09-30

Measured on this Mac with `WISP_MODEL_TESTS=1 swift test --filter ModelEvalTests.ContextEvalTests/referencing`
and recorded in `measurements.json` as `context.referencing[.showing][.window-8192]`, with the phase 3b
system prompt. For comparison, the whole model eval was then run once more without recording (the same
build; its suites run in parallel), which gives dropping and cutting under the new prompt and a second
referencing run of each. The load came and went: one-minute load average 2 to 9 for the recorded runs,
and from 2 up to 335 across the comparison run, so times are indicative only.

| Model, window | Scenario | Strategy | Facts (of 4) | CI now | First file | Task | Condensations (first at turn) | Tokens after a turn, median (max) | Time per turn, median (p95) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| On-device, 8,192 | baseline | dropping | 0 | wrong | wrong | wrong | 9 (7) | 6,387 (7,637) | 42.8 s (57.9 s) |
| On-device, 8,192 | baseline | referencing, recorded | 4 | correct | correct | correct | 0 | 4,721 (7,093) | 13.4 s (19.9 s) |
| On-device, 8,192 | baseline | referencing, rerun | 4 | correct | correct | correct | 0 | 4,719 (7,090) | 13.9 s (25.6 s) |
| On-device, 8,192 | showing | dropping | 0 | wrong | wrong | wrong | 10 (7) | 6,593 (7,695) | 19.9 s (21.1 s) |
| On-device, 8,192 | showing | cutting | 0 | wrong | wrong | wrong | 10 (7) | 6,436 (7,621) | 19.1 s (30.9 s) |
| On-device, 8,192 | showing | referencing, recorded | 0 | wrong | wrong | wrong | 1 (16) | 2,612 (7,183) | 9.7 s (21.6 s) |
| On-device, 8,192 | showing | referencing, rerun (outlier) | 4 | correct | correct | correct | 0 | 4,578 (6,445) | 11.5 s (27.0 s) |
| granite4.1:8b, 8,192 | baseline | dropping | 1 | correct | wrong | wrong | 1 (12) | 5,162 (7,250) | 4.7 s (10.9 s) |
| granite4.1:8b, 8,192 | baseline | referencing, recorded | 4 | correct | correct | correct | 0 | 5,204 (7,061) | 5.9 s (8.8 s) |
| granite4.1:8b, 8,192 | baseline | referencing, rerun | 4 | correct | correct | correct | 0 | 5,178 (6,998) | 13.0 s (15.6 s) |
| granite4.1:8b, 8,192 | showing | dropping | 0 | wrong | wrong | wrong | 4 (10) | 5,554 (8,046) | 7.0 s (47.4 s) |
| granite4.1:8b, 8,192 | showing | cutting | 0 | wrong | wrong | wrong | 5 (8) | 5,665 (7,836) | 10.4 s (25.3 s) |
| granite4.1:8b, 8,192 | showing | referencing, recorded | 4 | correct | correct | correct | 0 | 5,520 (7,325) | 14.0 s (19.8 s) |
| granite4.1:8b, 8,192 | showing | referencing, rerun | 4 | correct | correct | correct | 0 | 5,465 (7,198) | 15.3 s (20.2 s) |

What it shows:
- **References fit the scenario in the window.** A file-reading turn added about 490 tokens on the
  on-device model and 450 on granite, against about 1,300 when the output stays whole, so the 14-turn
  baseline never condensed on either model at 8,192 tokens; dropping condensed from turn 7 on the
  on-device model and from turn 8 to 12 on granite.
- **Recall follows.** With nothing dropped, both models answered all six questions, as granite did with a
  32,768-token window and dropping. The reference's `arguments` line kept the first file's path in view.
- **The showing scenario sits at the edge on the on-device model.** Its one more turn took the recorded
  run to 7,183 tokens after the last read, past the 85% budget, so the first question condensed to the
  last four turns and every early fact went with them, as with dropping; the model then answered "You
  haven't asked a question" to each. The rerun read every digression file under a wrong path (the tool
  said the file did not exist, so there was less to carry), stayed at 6,445 tokens, and scored 6 of 6; it
  is the outlier, and the recorded run is the representative one. What survives a condensation is phase
  4's job (facts and `recall`).
- **Asked to show a file, both models still retyped it**, as the prompt allows, and exact-copy cutting
  took the copy out: one cut per showing run.
- **Time per turn.** On the on-device model, smaller requests and no condensing made turns faster. On
  granite at low load a turn took a little longer (5.9 s against 4.7 s median): each turn after a
  tool-using turn starts a new session, and a context that never condenses stays large. Under the
  comparison run's load (73 to 335) granite's times are not comparable.
- **A smoke test in chat** (2026-09-30) showed the other side of "call it again to see it": asked how many
  lines a file it had read had, the on-device model read the file again rather than use the reference's
  count, then misreported the byte count as lines.

### Facts, 2026-09-30

Measured on this Mac with `WISP_MODEL_TESTS=1 swift test --filter ModelEvalTests.ContextEvalTests/facts`
and `…/budget50`, recorded in `measurements.json` as `context.facts[.showing][.window-8192]` and
`context.<strategy>.showing[.window-8192].budget-50`. `FactsStrategy` is `ReferencingStrategy` with facts:
extracted from tool output each turn, distilled at each condensation, and composed on the prompt side at a
share of 0.1. Another project's builds loaded the machine: one-minute load average 26 to 139 across the
runs, so times are indicative only.

At the default 85% budget no run condensed on either model: the reads came to 300 to 330 tokens a turn,
against about 490 in phase 3b's recorded on-device showing run, so the target case (one condensation at
turn 16, every early fact lost) did not recur, and no distillation ran. To measure what facts do when turns
are dropped whatever the reads come to, the `budget-50` variants condense at half the window, with
referencing at the same budget as the comparison.

| Model, window | Scenario | Strategy | Facts (of 4) | CI now | First file | Task | Condensations (first at turn) | Distillation | Tokens after a turn, median (max) | Time per turn, median (p95) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| On-device, 8,192 | baseline | facts | 4 | correct | correct | correct | 0 | none | 3,314 (4,901) | 14.6 s (25.2 s) |
| On-device, 8,192 | showing | facts | 4 | correct | correct | correct | 0 | none | 3,588 (5,212) | 15.1 s (26.8 s) |
| granite4.1:8b, 8,192 | baseline | facts | 4 | correct | correct | correct | 0 | none | 4,150 (5,473) | 9.4 s (13.0 s) |
| granite4.1:8b, 8,192 | showing | facts | 4 | correct | correct | correct | 0 | none | 4,416 (5,744) | 11.9 s (14.3 s) |
| On-device, 8,192 | showing, budget 50% | referencing | 1 | correct | wrong | wrong | 1 (14) | none | 2,377 (4,278) | 15.7 s (26.5 s) |
| On-device, 8,192 | showing, budget 50% | facts, recorded | 3 | correct | correct | correct | 1 (13) | 5 facts, 5.0 s | 3,180 (4,277) | 8.7 s (13.7 s) |
| granite4.1:8b, 8,192 | showing, budget 50% | referencing | 1 | correct | wrong | wrong | 1 (14) | none | 2,584 (5,002) | 8.0 s (12.7 s) |
| granite4.1:8b, 8,192 | showing, budget 50% | facts, recorded | 4 | correct | wrong | correct | 1 (14) | 8 facts, 12.0 s | 3,103 (5,019) | 4.8 s (10.5 s) |
| granite4.1:8b, 8,192 | showing, budget 50% | facts, earlier build | 4 | correct | correct | correct | 1 (14) | 7 facts, 42.8 s | 2,769 (5,269) | 7.6 s (12.1 s) |
| On-device, 8,192 | showing, budget 50% | facts, earlier build | 0 | wrong | wrong | correct | 1 (14) | 13 facts, 22.7 s | 3,152 (4,238) | 8.2 s (16.6 s) |

What it shows:
- **Facts survive a condensation.** With one condensation that dropped every early turn, referencing
  alone scored 1 of 6 on each model; with facts the on-device model scored 5 and granite 5 (6 in the run
  before), naming the codename, the ticket, the current CI state, and the task from the earlier and now
  blocks. The first file came from the extracted `file` fact on the on-device model.
- **What the distiller is offered matters on the small model.** The two "earlier build" rows ran before two
  changes the eval prompted. First, the on-device distiller spent all twelve facts summarising the files
  read (the instruction said to leave file summaries out), so the codename, ticket, and preference were
  never recorded; kinds whose facts come from tool output (`file`, `service`, `machine`) now say
  `distil: false` in `subject-kinds.json`, are not offered, and are dropped if returned. Second, it
  distilled "CI failing" from turn 2 while "green again" (turn 11) was still in the kept turns, so the
  earlier block contradicted the literal turns; the distiller now also reads the kept turns' prompts for
  the latest values. And a path cut at 60 characters lost the file's name ("harbour-sync-o…"); a long path
  now keeps its end.
- **The on-device model repeats the provenance.** It answered "The codename for this release is blue
  heron [model, distilled: the person said, turns 1-8]". The answer is right; the bracket is noise the
  person sees, and a note for the standing rule D12 adds with `recall`.
- **Granite's distillation is sometimes loose**: it named a decision "blue heron release" with the task as
  its value, and recorded a guessed branch ("Assuming the default branch is unspecified…") despite the
  instruction to leave out anything uncertain. The kinds' descriptions and the normalisers are where to
  tune it (D2's reopen condition).
- **The distillation's cost** was 5.0 s on the on-device model and 12.0 s on granite for eight or so turns
  (22.7 s and 42.8 s in the earlier build, whose prompts and answers were longer), once per condensation.
  Before a condensation facts cost nothing: a fact whose turn is still in view is not repeated, so the
  earlier block is empty and the default-budget runs carried the same tokens as referencing.
- **Changed facts supersede** in the gate: `FactExtractionTests` runs `swift test` failing, then passing,
  and checks the new version supersedes the old; `FactDistillationTests` has a distillation whose answer
  says CI failing and then green, and keeps the latter; `FactBookTests` covers versions, sources, and
  conflicts.

### Summary, 2026-09-30

Measured on this Mac with `WISP_MODEL_TESTS=1 swift test --filter ModelEvalTests.ContextEvalTests/summary`,
recorded in `measurements.json` as `context.summary.showing[.window-8192].budget-50` (the summary written
in the facts' call) and `context.summary-separate.…` (in a call of its own). The `showing` scenario at a
50% budget, as for facts, since at 85% nothing condenses; window 8,192. Each figure is one run: a second
on-device run was started and stopped before it produced results. Load average 78 to 110, so times are
indicative only.

| Model | Summary written | Score | Wrong | Condensations | Model call | Tokens median (max) | Time per turn median (p95) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| On-device | in the facts' call | 5/6 | preference | 1 (turn 14) | 34.4 s | 3,049 (4,318) | 14.2 s (24.4 s) |
| On-device | separate call | 3/6 | ticket, preference, first file | 2 (first at turn 13) | 29.9 + 30.4 s summaries, 27.2 + 17.0 s facts | 3,259 (4,373) | 12.7 s (52.6 s) |
| granite4.1:8b | in the facts' call | 6/6 | none | 1 (turn 14) | 28.6 s | 3,190 (5,057) | 10.9 s (14.8 s) |
| granite4.1:8b | separate call | 5/6 | first file | 1 (turn 14) | 19.9 s facts + 12.4 s summary | 2,945 (4,492) | 7.1 s (15.4 s) |

What it shows:
- **One call for facts and the summary** held its schema on both models with no failure, cost less time
  than two calls, and scored as well or better; it is the default (`FactSettings.summaryWithFacts`, not a config key).
- **Granite now answers "which file came first"**: 6 of 6 against 5 of 6 with facts alone. On the
  on-device model the first file was right from the extracted `file` fact and its turn, not the summary;
  the on-device score stays 5 of 6.
- **The summary has its own cap** (`facts.summaryShare`, 0.05 of the window, at least 512 bytes), beside
  the facts' 0.1: sharing one cap was measured first, and the summary crowded out early facts (an earlier
  on-device run lost the preference and named a later file as the first).
- **The on-device model ignores the word limit** and retells what files hold, so an answer over the cap
  loses its middle sentences, oldest first, keeping how the work began and the newest turns; long paths
  are shortened in what the call is shown.
- **D1's reopen condition** (a batched summary lagging enough to mislead) is not measured: with references
  on, one condensation drops many turns at once, so no batch waited in these runs.

### Recall, 2026-09-30

Measured on this Mac with `WISP_MODEL_TESTS=1 swift test --filter ModelEvalTests.ContextEvalTests/recalling…`,
one run at a time, recorded then in `measurements.json` as `context.recall.recalling[.window-8192].budget-50`
and, for the comparison without `recall`, `context.summary.recalling[.window-8192].budget-50`; both were
replaced by the runs of "Memory, 2026-09-30" below, and the figures here are kept as the first build's. The `recalling`
scenario is `showing` with a seventh question on a detail of the first file that no fact or summary carries
(the name of the temporary file a copy writes to, `.harbour-tmp-<random>`), at a 50% budget so the read is
dropped before it is asked about; window 8,192. `RecallStrategy` is `SummaryStrategy` (summary in the facts'
call) with `recall` and its prompt rule. The first two on-device rows ran on earlier builds of this phase; the
changes between them are under "Choices made in the build" in the phasing entry. One-minute load average 3 to
6, except the granite comparison (13 to 23), so times are comparable except there.

| Model | Strategy | Score | Wrong | Recalls (turn: what, result) | Other tool calls in the questions | Condensations (first at) | Tokens median (max) | Time per turn median (p95) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| On-device | recall, first build | 5/7 | preference, detail | 1: `task`, none; 22: `entry 2`, found (the first prompt, not the read) | 0 | 1 (13) | 3,297 (4,359) | 6.3 s (10.7 s) |
| On-device | recall, second build | 3/7 | ticket, preference, task, detail | 1: `task`, none (then "I have no stored task") | 0 | 2 (12) | 2,684 (4,405) | 6.7 s (27.0 s) |
| On-device | recall, recorded | 4/7 | ticket, preference, detail | 1: `task`, none; 19: `task`, found; 22: `entry 8`, found (the right read) | 0 | 2 (12) | 3,246 (4,314) | 7.0 s (26.3 s) |
| On-device | summary, no recall | 5/7 | first file, detail | none | 1 (`read_file` of `postmortem-09`, at the detail question) | 2 (13) | 2,729 (4,241) | 9.0 s (25.8 s) |
| granite4.1:8b | recall | 6/7 | first file | 22: `entry 6`, found (the right read) | 0 | 1 (14) | 3,513 (5,200) | 5.1 s (10.2 s) |
| granite4.1:8b | summary, no recall | 6/7 | detail | none | 0 | 1 (14) | 3,051 (4,994) | 4.7 s (8.6 s) |

What it shows:
- **Granite recalls what it needs and uses it.** Asked for the detail, it recalled the first read by the
  entry its `file` fact names and quoted `.harbour-tmp-<random>`; without `recall` it made a name up
  (`tmp/<uuid>.harbour-sync`). It recalled nothing else. Its one miss with recall was the first file, named as
  `postmortem-01` beside the right fact's source: noise in one run, since the fact and the summary both
  said otherwise.
- **The on-device model calls `recall`, but does not yet profit from it.** In the recorded run it recalled
  the right entry at the detail question and still invented the name (`tmp_plan_001`) from a page that held
  it; in the first run it took the turn in a fact's source ("turn 2") for an entry number and recalled the
  first prompt. That is why a tool fact's source now names its entry. Its losses on the ticket and the
  preference are the distiller's (it recorded "ticket = ticket" and nothing for Maria), as in phase 4a's
  earlier runs, not recall's.
- **It recalls when nothing is missing.** Every on-device run recalled `task` in the first turn, where the
  task was the prompt in front of it; the second run took the empty answer as "there is no task" and carried
  that into its reply and the distilled facts. Recall before anything is stored now says the first turn is all
  in view, and in the recorded run the first-turn recall did no harm. A recall of the task at the CI question
  was also unneeded. D12's reopen condition (recalling on most turns) is not met: 1 to 3 recalls in 22 turns.
- **Re-reads fell away.** With `recall` no run called another tool while answering the questions; without it,
  the on-device model answered the detail question by reading a file again, the wrong one
  (`postmortem-09-config-typo.md`), which is 3b's smoke-test finding again.
- **Costs.** A recall adds its page to its turn: granite's detail turn carried 4,815 tokens against 3,255
  without, and took 10.2 s against 2.5 s. The tool definition and the rule add 146 tokens to every request's
  instructions on the on-device model.
- **The bracket clause did not work.** The on-device model copied the facts' sources into every answer in
  all runs, under both wordings; granite did too with `recall` and its rule, and not without them. Moving the
  sources out of brackets, or out of the fact's line, is the likelier fix, and a change to the facts' frame.
- **A second run of each, in the full eval** (`scripts/check eval`, not recorded; load average 45 to 115 from
  other work): on-device with recall 3/7 and without 4/7; granite with recall 6/7 and without 5/7. Granite
  again recalled the first read (`entry 6`) and quoted the name; without `recall` it missed the detail. The
  on-device model again recalled at the first turn (`harbour`, a fact query) and replied "I have no prior
  record of harbour's details", and at the detail question recalled a digression's read (`entry 36`) and said
  the file did not mention one: the early answer that everything is in view did not stop the first-turn
  recall from misleading it, which stays open.
- **One run each, and variance is large**: the three on-device runs with recall scored 5, 3, and 4 on builds
  that differ in small ways, so the on-device figures say what the model does, not by how much recall helps.

### Memory, 2026-09-30

After the operator widened `recall` to `memory` (phasing, 4c), measured on this Mac with `WISP_MODEL_TESTS=1
swift test --filter ContextEvalTests/<test>`, one run at a time, window 8,192, budget 50%, recorded in
`measurements.json` as `context.memory.<scenario>[.window-8192].budget-50` and, without `memory`,
`context.summary.<scenario>[.window-8192].budget-50` (these replace the first build's `context.recall.*` and
`context.summary.recalling.*` rows). `MemoryStrategy` is `SummaryStrategy` with `memory` and its rule. The
`noting` scenario is `recalling` with "Keep this in mind for later: the release date moved to 14 November."
said at the eighth incident review, and an eighth question, "When is the release date?". An answer that
repeats a fact's source (a bracket, `— from …`, or `(source: …)`) is counted as an echo. The one-minute load
average was 4 to 14 for the first three runs and 15 to 130 for the rest, from other work on the Mac, so
times are comparable only within the first three.

| Model | Scenario | Strategy | Score | Wrong | Memory calls (turn: request, result) | Other tool calls in the questions | Echoes | Condensations (first at) | Tokens median (max) | Time per turn median (p95) | Load |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| On-device | recalling | memory, facts `— from` | 5/7 | preference, detail | 1: `BLUE HERON`, recall, nothing stored; 22: `recall entry 1`, found (the instructions, not the read) | 0 | 1/7 | 1 (13) | 3,321 (4,383) | 6.1 s (10.5 s) | 4 |
| On-device | recalling | memory, facts `(source: …)` | 4/7 | ticket, preference, detail | 1: `BLUE HERON`, recall, nothing stored | 1 (`read_file`, a wrong path) | 7/7 | 2 (12) | 2,632 (4,101) | 8.6 s (21.8 s) | 6 |
| On-device | recalling | summary, no memory | 6/7 | detail | none | 0 | 7/7 | 1 (14) | 3,133 (4,338) | 7.8 s (14.7 s) | 9 |
| granite4.1:8b | recalling | memory | 5/7 | first file, detail | none | 1 (`read_file`) | 0/7 | 1 (13) | 3,683 (5,078) | 7.4 s (16.3 s) | 15 |
| granite4.1:8b | recalling | summary, no memory | 6/7 | first file | none | 1 (`read_file`) | 6/7 | 1 (15) | 3,020 (5,231) | 9.5 s (14.2 s) | 36 |
| On-device | noting | memory | 6/8 | ticket, preference | 1: `note entity release codename = BLUE HERON`, noted; 22: `recall entry 8`, found (the right read) | 0 | 0/8 | 2 (12) | 3,409 (4,247) | 11.5 s (30.1 s) | 35 |
| On-device | noting | summary, no memory | 5/8 | ticket, preference, detail | none | 1 (`read_file`, not found) | 8/8 | 1 (13) | 3,425 (4,390) | 11.7 s (25.3 s) | 130 |
| granite4.1:8b | noting | memory | 6/8 | first file, detail | none | 0 | 0/8 | 1 (14) | 3,463 (5,184) | 9.1 s (12.5 s) | 58 |
| granite4.1:8b | noting | summary, no memory | 8/8 | none | none | 8 (re-reads) | 0/8 | 2 (14) | 3,252 (5,118) | 6.5 s (38.2 s) | 33 |

What it shows:
- **The facts' format.** The two forms were compared on the same strategy and scenario, one run each: with
  the source behind a dash the on-device model echoed it in 1 of 7 answers, with `(source: …)` in 7 of 7 (the
  first build's brackets: every answer). The dash form was kept. It is not the whole fix: without `memory`,
  whose rule adds the prompt's second line, the on-device model echoed the dash form in every answer (7/7,
  8/8), and granite in 6 of 7 on `recalling` and none on `noting`. With `memory`, across four runs, 1 echo in
  30 answers. Which part of the difference is the prompt's second line and which is variance is open.
- **Notes.** The on-device model noted once in four runs with `memory`, correctly, in the first turn: `note
  entity release codename = BLUE HERON`, which was recorded as a proposal. Its other first-turn calls were
  `BLUE HERON` with no verb, a recall that answered that nothing is stored yet; the replies ("We're starting
  fresh", "I've noted the BLUE HERON codename") did no harm to the later answers. Neither model noted the
  release date said in passing, and both answered it without a note: the distiller kept it, or the turn was
  still in view. Granite called `memory` in none of its runs, where the first build's `recall` was called in
  both (the right read, both times). Noting does not yet show a gain the distiller does not already give.
- **Recall.** The on-device model recalled at the detail question in both of its runs with `memory`: once the
  right read (`entry 8`), and it answered `.harbour-tmp-<random>`, which no run of it did before; once `entry
  1`, the instructions. Without `memory`, it and granite re-read a file instead, the wrong one or a wrong
  path, except granite on `noting`, which re-read the right file and answered everything.
- **No RAM question went to `memory`.** `SystemInfoEvalTests` on the on-device model, with `memory`,
  `system_info`, and `run_command` offered and the memory rule in the prompt: 13 of 16 passed, and no turn
  called `memory`. The three misses were `system_info` with the wrong topic (`system` for "How much memory is
  in use, and by what?", twice; `memory` for "Is Ollama running, and how much memory does it use?", which
  expects `process`); the recorded figure before `memory` was 14 of 16. The description's steer holds in this
  eval; the name stays.
- **Other suites** on the on-device model, not recorded: `ChatEvalTests` 24/24 (every built-in tool and
  `memory`, no call to it on a greeting), `ToolEvalTests` schema 6/6 and `edit_file` 16/30 (floor 15; 21/30 on
  2026-09-26; that suite has neither `memory` nor the rule, and its prompt is the unchanged first line, so the
  drop is variance or the load of 35 to 43 at the time).
- **One run each, and variance is large**, as before: the on-device `recalling` runs with `memory` scored 5
  and 4 on builds that differ only in the facts' line.

## Decisions

Each question settled in review is recorded here with what was considered, what was chosen and why,
and when to reopen it, so a later revisit starts from the reasoning rather than the conclusion.

### D1. Who distils, and when

Decided 2026-09-29 with the operator.

**The question.** When a turn leaves the literal segment, its content has to become facts and a line
of the running summary. The question is who writes them, and when.

**Considered:**

| Option | Cost | Risk |
| --- | --- | --- |
| The conversation's model, after every turn | A model call every turn, most of them for turns that never age out | Fresh facts, at the highest cost |
| The conversation's model, when a turn ages out | A model call only for turns that leave the literal segment | Facts arrive later, but with hindsight of what followed |
| The conversation's model, in the background between turns | No added latency | A race when the person prompts before distilling ends; the model busy when needed |
| A small specialised model when a turn ages out | Cheap and fast on device, like the classifiers | Needs training data that does not exist yet; weaker on facts unlike its training |
| Deterministic extraction from structured tool output | No model at all | Covers only structured output, not prose |

In discussion, the last row turned out to be a different kind of answer. Much of what is worth
remembering comes out of tools already structured: exit statuses, file paths and sizes, counts, and
the condensers' findings. Only prose needs a model: what the person said, and what the model
concluded.

**Chosen:** distil by source.
- **Facts from tool output** are extracted deterministically at every turn, at no model cost. For
  example: "`git push` succeeded at 11:05", or "docs/mcp.md is 4,356 bytes".
- **Facts from prose,** the person's statements and the model's conclusions, are distilled by the
  conversation's own model when their turn ages out of the literal segment.
- **The running summary** is written by the same model, batched every few aged-out turns rather than
  every one, which spreads its cost.

**Why:**
- The model is only paid for what needs a model.
- Distilling on ageing out calls it only for turns that are actually leaving, and with hindsight.
- Batching the summary keeps its cost low.
- Every part can be measured separately in the eval.

**Rejected:**
- **After every turn:** it pays for many turns that never age out.
- **In the background:** it races with the person's next prompt, and gains nothing that distilling on
  ageing out does not.

**Deferred: a small specialised distiller.** It stays for later review, once the data to build one
exists. The store will accumulate pairs of a turn and the facts distilled from it by the conversation's
model. Reviewed and labelled, as the classifiers' sets were
([ADR 0038](../decisions/0038-fast-specialised-classifiers.md)), they become training and test data.
Reopen when both hold:
- there are enough reviewed pairs to train and hold out a test set;
- the eval shows that the model's distilling costs enough time per turn to matter.

**Consequences:**
- Facts carry their origin as well as their source turns: tool, person, or model; and extracted or
  distilled. Staleness (question 3) must work across both kinds. A mechanical "tests failed" must be
  superseded by a later mechanical "tests passed", and a distilled fact by a newer one on the same
  subject.
- The eval measures recall and time per turn for each part: mechanical facts, distilled facts, and the
  summary. It also measures the batch size for the summary.

**Reopen if:**
- the mechanical facts prove too noisy to help recall;
- distilling on ageing out misses facts that mattered in the turns before;
- the batched summary lags enough to mislead the model.

### D2. Staleness: versioned facts under a composite key

Decided 2026-09-29 with the operator.

**The question.** Facts go out of date: "tests fail" becomes "tests pass", a service stops, a decision
is revised. D1 adds a second axis, because a mechanical fact and a distilled fact can disagree about the
same thing. The question is how a newer fact replaces an older one, what happens when two sources
disagree, and how long a fact lives.

**Considered:**

| Option | How a fact is replaced | Weakness |
| --- | --- | --- |
| A. Supersede by subject | A newer fact on the same subject replaces the older | "Subject" is undefined; too coarse and unrelated facts replace each other |
| B. Newest from the same source wins | Per source, the latest fact stands | Says nothing when sources disagree |
| C. The distiller revises the whole set | Shown the existing facts, the model rewrites them | A model call over every fact; a small model drops or garbles facts |
| D. Expiry | A fact lapses after a time or a number of turns | Right for a service's state, wrong for a codename |
| E. Versioned facts under a composite key | A fact is an assertion about an identity; a newer version of the same identity from the same source supersedes | Needs identities to be named consistently |

In discussion, A and B turned out to be parts of E, and D a property of some facts rather than a rule for
all of them. C was rejected for cost and for what a small model does to a list it rewrites.

**Chosen:** E, with precedence between sources, visible conflicts, and a temporal class per fact.

- **Identity** is `{scope, subject, name}`: what the fact is about. For example, `{conversation, tests,
  harness}` or `{permanent, entity, BLUE HERON}`.
- **An assertion** is an identity plus `{source, version}`. The source is the person, a tool, or the
  model. A newer version from the same source supersedes the older one; the older is kept in the store,
  marked superseded, with a link to what replaced it.
- **Attributes** of an assertion: the value, its temporal class, the turns it came from, when it was
  recorded, and what superseded it.
- **Precedence between sources:** the person, then a tool, then the model. A `person` assertion is
  therefore a pin: it outranks what a tool or the model says about the same identity.
- **Conflicts are visible, not settled silently.** When the current heads of different sources disagree,
  the active context shows the winning head and says that another source disagrees, so the model can take
  it into account or ask. `/inspect facts` shows both, and the person resolves the conflict by making a
  `person` assertion or by retracting one side.
- **Temporal classes,** each with its own scope:

  | Class | For | Scope |
  | --- | --- | --- |
  | Permanent | Names, codenames, settled decisions, the person's preferences | A shared store, across sessions |
  | Dynamic | The state of the work: tests, the branch, the task's progress | The conversation |
  | Ephemeral | The state of the machine now: a running service, free memory, a port in use | The session: every conversation in one `wisp` process, ending with it |

- **History through `recall`.** The superseded versions of an identity are recallable, so the model can
  answer "the tests failed at 11:02 and passed at 11:07", not only "the tests pass".
- **Subjects are defined, not hard-coded.** A subject kind declares its temporal class, how names under
  it are normalised, and a description the distiller is shown. wisp ships a starting set (for example
  `task`, `decision`, `preference`, `entity`, `tests`, `file`, `service`, `workdir`, `branch`), and
  configuration can add or change kinds. The distiller is shown the kinds and the existing identities,
  and asked to reuse them.
- **The working directory and the git branch are versioned dynamic facts** (added 2026-09-30 by the
  operator). They are extracted mechanically (D1): the directory from chat's start, an MCP caller's
  prompt, and `run_command`'s working directory; the branch from git. A move supersedes only that fact,
  so the stable prefix is untouched, and the history answers "where did that command run?".
- **Name normalisation is per subject kind, behind one interface,** so the rules can be iterated without
  touching the store: for example, a path relative to the repository root for `file`, case folding for
  `entity`. Mechanical extractors normalise the same way.

**Why:**
- Versioning keeps history, which recall and the audit need, while the active view shows only heads.
- `source` in the assertion, not the identity, turns disagreement into parallel heads that precedence
  orders and the person can see, instead of one source silently overwriting another.
- Pins need no separate mechanism: they are the person's assertions (question 1).
- Temporal class answers expiry where it applies, and ties scope to how long a fact is true.
- Subject kinds and normalisers are the parts most likely to be wrong at first. Defining them as data and
  one interface lets the eval drive them without changes to the store or the composer.

**Rejected:**
- **C, revising the whole set:** a model call over every fact at every distillation, and on the
  on-device model a real chance of losing facts in the rewrite.
- **D alone, expiry for everything:** it would age out permanent facts.
- **A fixed subject vocabulary in code:** tried in discussion and found too rigid; kept only as the
  shipped defaults.

**Consequences:**
- **Amends the non-goal** on sharing memory across sessions: permanent facts live in a shared store,
  user-only in `~/.wisp` like the rest. A permanent fact outlives the turn that produced it, so a README
  that plants a "fact" could otherwise carry it into every later session. **Only the person admits a
  fact to the shared store:** they state it, or they approve one proposed by a tool or the model.
  Until approved, a proposed permanent fact lives in the conversation, as a dynamic one does.
- Ephemeral facts are shared across an MCP server's threads, since they describe the machine rather than
  the conversation.
- The store needs identities, versions, and supersession links; the composer picks heads and marks
  conflicts; `recall` takes an identity and returns its versions.
- New audit events: an assertion recorded, superseded, retracted, and a conflict raised and resolved.
- The eval adds a fact that changes over the conversation, and scores whether the model reports its
  current value and, when asked, its history.

**Reopen if:**
- identities split one thing into several lineages, or merge unrelated things, often enough that the
  normalisers cannot be tuned to fix it;
- conflicts shown to the model confuse it more than they help, in the eval;
- the temporal class proves too often wrong at the point a fact is recorded.

### D3. What the person can do to facts

Decided 2026-09-29 with the operator.

**The question.** Facts change what the model believes. Can the person change them, and how?

**Considered:** view only; pin and delete; full edits of any fact's text.

**Chosen:**
- **View** every fact, with its source, version, class, and any conflict (`/inspect facts`, and the
  thread's facts resource over MCP).
- **Pin** by stating a fact: a `person` assertion, which outranks a tool and the model (D2). This is
  also how the person corrects one; there is no separate edit.
- **Delete** any fact. It leaves the active view and every later composition. The store marks it
  deleted rather than rewriting history, and the audit records who deleted it and when.
- **Approve** a permanent fact proposed by a tool or the model, admitting it to the shared store (D2).
- **The agent supersedes, and never deletes.** Tools and the model add newer versions of their own
  assertions; they cannot remove a fact or outrank the person's.

**Why:** pinning through a `person` assertion gives edits' effect without a second mechanism, keeps the
old value in the history, and leaves every change attributable. Deletion stays with the person, so the
model cannot quietly shed a fact that is inconvenient to it.

**Rejected:** full edits of a fact's text in place: they would rewrite what a tool or the model said
under its name.

**Consequences:** new audit events for a pin, a deletion, and an approval, each naming the fact.
`/inspect facts` gains actions, or chat gains commands, for them; their form is left to the build.

**Reopen if** the person finds stating a fact a clumsy way to correct one, in use.

**Note, 2026-09-30 (operator):** approving is a host effect ([ADR 0044](../decisions/0044-host-effects.md),
amended 2026-09-30). Over MCP, a client with elicitation is asked once per proposed permanent fact, after
the call's result, in a fieldless Accept/Decline dialog; Decline is remembered and not asked again, and
silence leaves the proposal waiting. Without elicitation, proposals wait in `wisp://facts/proposed`. Chat
lists the proposals of every conversation of its process in `/inspect facts` and approves them with `/fact
approve`. The facts resources moved under what owns them: `wisp://facts` (permanent), `wisp://facts/proposed`,
`wisp://session/facts`, and `wisp://threads/{thread_id}/facts` for the thread's own.

**Note, 2026-09-30, later (operator): the approval dialog is withdrawn.** The note above stands as history:
approving over MCP by dialog was built and removed before release ([ADR 0044](../decisions/0044-host-effects.md),
amended again 2026-09-30). A fact's scope is a state the person sets by command, naming the target:
`/fact ID permanent|thread|session` in chat, which replaces `/fact approve`, and `set_fact_scope` over MCP,
which offers only `thread` and `session` until the operator decides how permanent facts are managed there.
Scope and temporal class move together. After each turn wisp lists the facts it recorded or changed (a note
in chat and `wisp chat --json`, `structuredContent.facts` in MCP `respond`), and proposals of every
conversation stay listed in `/inspect facts` and `wisp://facts/proposed`.

### D4. What goes in the instructions, and which tools each request carries

Decided 2026-09-29 with the operator. Amended by
[D12](#d12-four-records-one-assessment-and-tool-output-as-a-reference): tool selection becomes part of one
assessment per request.

**The question.** Question 4 (budgets per layer) turned out to be two problems. The instructions are set
once per conversation and take a fixed share of the window; the other layers are composed per request
and share what is left. This decision settles the first: what the instructions hold, where the task
goes, and how much of the window the tools take.

**Measured** on the on-device model on this Mac, 2026-09-29, with `SystemLanguageModel.tokenCount(for:)`
(window 8,192 tokens; an empty instructions block costs 46 tokens, subtracted below):

| What | Tokens | Share of 8,192 |
| --- | --- | --- |
| All seven tool definitions, as registered today | 1,157 | 14.1% |
| `system_info` / `edit_file` / `inspect` alone | 303 / 290 / 231 | |
| `read_file` / `run_command` alone | 182 / 170 | |
| `notify` / `current_date` alone | 143 / 114 | |
| `run_command` and `read_file` together | 306 | 3.7% |
| wisp's system prompt (488 characters) | 104 | 1.3% |
| A hand-written catalogue, one short clause per tool | 103 | 1.3% |
| A catalogue of each description's first sentence | 215 | 2.6% |
| A catalogue of names only | 26 | 0.3% |

A tool's cost is mostly its argument schema (67 to 188 tokens) rather than its description (55 to 112).
Registering two tools and a terse catalogue in place of all seven costs 409 tokens instead of 1,157, and
saves about 750 tokens, 9% of the on-device window, on every request.

**Considered:**
- Every tool registered on every request, as today, with shorter descriptions: saves little, since most
  of the cost is argument schemas, and shortening those risks the model's choice of tool and arguments.
- Tool help in the prompt: impossible as a saving, because the framework puts the definition of every
  registered tool into the context whatever the prompt says.
- A catalogue in the instructions and definitions registered per request, chosen by a selection step.

**Chosen:**
- **The task goes in the prompt,** in the task frame of layer 4, never in the instructions.
- **The instructions hold a terse tool catalogue:** one short clause per tool, saying what it is for. It
  is stable across the conversation, so the prefix stays the same.
- **Each request registers only the tools it needs.** The composer builds each request's session
  anyway, so its tool set can differ per request.
- **A selection step decides which.** Rules first, where they settle it (the task's expected tools, a
  follow-up to a turn that used a tool). Otherwise a separate call to the model, with the catalogue and
  the request only, returns the tools needed. That call is written to the audit log but is not kept in the
  conversation's context. `run_command` is always registered, as the general fallback.
- **The prompt names the selected tools** in the task frame, so the model knows where to start.
- **Schemas are minimised only where the eval shows no loss** in tool choice or arguments.

**Why:** the tools are the largest fixed cost in the on-device window, and most requests use one or
two. A selection call costs time once per request and buys the window back for the whole turn. Keeping
the catalogue in the instructions keeps it stable and out of the per-request budget.

**Rejected:** trimming every tool's schema as the main saving (small gain, real risk to efficacy); tool
help in the prompt (does not reduce what the framework sends).

**Consequences:**
- A new audit event for tool selection: the request, the method (rules or model), the tools chosen, and
  the time taken.
- The eval scores tool choice as well as recall: the selection's misses, and the turn's outcome when a
  needed tool was not registered.
- The tool set at the front of the context changes between requests, which may cost prefix caching;
  question 11 measures it.
- A tool the model finds it needs part-way through a turn is not registered. How it asks for one then
  (ending the step and restarting it with the tool added) is left to the build, and measured by how
  often the eval hits it.
- A fast specialised classifier could replace the model's selection call later, trained on the audit's
  pairs of a request and the tools it used (ADR 0038), as D1 defers its distiller.

**Reopen if:**
- the selection call's time outweighs the tokens it saves, on the on-device model or on Ollama;
- selection misses often enough that turns fail or restart;
- the catalogue alone proves too thin for the model to choose well.

### D5. How the per-request layers share the window, and how big tool output may be

Decided 2026-09-29 with the operator. Settles the rest of question 4, and question 9. Amended by
[D12](#d12-four-records-one-assessment-and-tool-output-as-a-reference): tool output is full only in the
turn that produced it, then a structured reference.

**The question.** After the instructions and the request's tools (D4), the rest of the window is shared
by the earlier block (summary and facts), the literal turns, and the current request. How is it divided,
and how large may a tool's output be in the active context, now that every result is a fixed 4 KiB
whatever the window?

**Considered:**
- Fixed shares for each layer, such as 15% for the earlier block and 70% for the literal turns.
- A floor for the literal turns, and the earlier block taking the rest up to a cap.
- Demand first: the current request takes what it needs, the earlier block what it needs up to a cap,
  and the literal turns the rest, above a floor.
- For tool output: a byte bound derived from the window, with a floor, a ceiling, and a per-model
  override; or full output stored and shown, with only the active slice sized to the window.

**Chosen:**
- **Demand first, with a cap and a floor.** In order: the instructions and the tools registered for the
  request (D4); the current request whole; the earlier block up to a cap, a share of the window; the
  literal turns in what is left, never less than a floor of the last whole turn.
- **When even the floor does not fit,** the literal turn's tool output is cut to its slice first, then
  the earlier block below its cap, and the request is never cut.
- **Tool output in the active context is sized from the literal turns' share,** not a fixed 4 KiB. The
  full output is stored and can be shown; only the slice the model carries follows the window, so a
  128k-window model pages less and the on-device model fills less.
- **The cap, the floor, and how tool output is sliced come from the eval,** as shares of the window,
  not as fixed numbers now.

**Why:** the instructions and the request must be whole, so they come first. A cap stops facts and the
summary from crowding out recent turns, which small models use best, and a floor keeps at least the last
turn verbatim on the smallest window. Shares scale to every backend without a table per model.

**Rejected:** fixed shares for every layer: they waste the earlier block's share early in a
conversation, when it is empty, and cannot adapt to a long request.

**Consequences:**
- Every bound that is 4 KiB today (tool results, `read_file` pages, model-pass chunks) becomes a
  function of the window and the literal share, and the composer, not each tool, decides the slice.
- The eval runs each design at more than one cap and floor, on the on-device model and on Ollama.
- `/inspect context` shows each layer's size against its budget.

**Reopen if:** the eval shows recall or the return to the task depends more on the split than the
design assumes, for example if a larger earlier block helps small models more than literal turns do.

### D6. What the task is, and who sets it

Decided 2026-09-29 with the operator. Amended by
[D12](#d12-four-records-one-assessment-and-tool-output-as-a-reference): in chat, the task and its
objective are inferred by the assessment on each request, not only as turns age out.

**The question.** The task frame in the prompt (layer 4) keeps the model oriented after the turns that
stated the task have aged out; the experiment of 2026-09-29 showed a model losing it. Where does the
task come from, and how does it change?

**Considered:**
- In an MCP thread: an explicit `task` argument on `respond` (A); the thread's first prompt (B).
- In chat: set by the person with a command (C); proposed by the model from the first request and
  confirmed (D); inferred and revised as the person restates it, without asking (E).
- Revision: only explicitly, or also proposed by the model when the conversation changes direction.

**Chosen:**
- **MCP: an explicit `task` argument** (A), given when the thread starts and revisable on later calls.
  A thread without one has no task frame. The caller is another agent that knows its task, and a first
  prompt is often a single command rather than a task.
- **Chat: inferred** (E). The model infers the task from the conversation and revises it as the person
  restates it, without a confirmation step.
- **The task is a special case of a dynamic fact:** subject `task`, class dynamic, one per
  conversation. It is versioned, its history is recallable, and the person can see it in `/inspect
  facts`, pin their own wording as a `person` assertion, or delete it (D2, D3).
- **The person can interrogate and update the task directly.** In chat, `/task` shows the current task,
  who stated or inferred it, and its earlier versions; `/task <text>` replaces it with the person's
  wording, a `person` assertion. Over MCP, the thread's facts resource shows it and the `task` argument
  updates it.

**Why:** a confirmation step on every change of direction is friction in chat, and the person already
has the fact controls to override an inference. An MCP caller states what it wants; guessing from a
first prompt would often guess wrong.

**Rejected:** confirming every inferred task in chat (D): worse to use, for control the fact controls
already give. The first prompt as an MCP thread's task (B): too often not a task.

**Consequences:**
- `respond` gains an optional `task` argument, documented in `mcp.md`; chat gains `/task`, documented
  in `wisp.md`.
- Inferring the task is part of distilling (D1): the conversation's model writes it as it writes other
  facts from prose, and a pinned task is never replaced by an inferred one.
- The eval's "return to the task" score covers an inferred task as well as a stated one.

**Reopen if:** inferred tasks drift or mislead often enough in the eval or in use that people keep
correcting them; or MCP callers turn out rarely to pass a task.

### D7. Repeating the relevant facts next to the request

Decided 2026-09-29 with the operator. Amended by
[D12](#d12-four-records-one-assessment-and-tool-output-as-a-reference): the relevant facts come from the
assessment.

**The question.** The earlier block holds every current fact, but well before the request, and small
models weigh what is near the question most. Should the few facts that bear on a request be repeated in
its task frame?

**Considered:** never repeat; repeat the facts chosen by word overlap with the request; have the D4
selection call name them too; a separate model call to choose them.

**Chosen, as a trial the eval decides:**
- The task frame repeats the facts relevant to the request, up to a handful.
- They are chosen by word overlap between the request and each fact's identity and value, which is
  deterministic and free, plus any facts the D4 selection call names. That call reads the request
  anyway, so it costs no extra call.
- The eval runs it against no repetition, on the on-device model and on Ollama. If it does not improve
  recall on the on-device model, it is dropped.

**Why:** it is cheap, targets the weakness the experiment showed, and is simple to remove.

**Rejected:** a separate model call to choose the facts: a cost per request for what overlap and the
existing call can do.

**Consequences:** the selection call's output gains the relevant facts; the audit records which facts
were repeated and why.

**Reopen if:** the eval result is mixed, better on one model and worse on another, or overlap chooses
poorly enough that only the model's choice helps.

### D8. The audit log stays the verbatim record

Decided 2026-09-29 with the operator.

**The question.** Some output will only be shown to the person and never carried in the model's
context. Should the audit log still record it in full, and how do the audit log and the store relate?

**Considered:**
- A. Keep logging every output in full, as today.
- B. Log only a reference (path, size, and hash) for output that is only shown.
- The store as the one copy of the content, with the audit log referring to it.
- The audit log as the one copy, with the store referring to it.

**Chosen:** A, and the audit log is the one copy.
- The audit log keeps full content, append-only, and stands on its own: handed to someone, it contains
  everything that happened.
- The store holds no second copy. It refers to audit entries and adds what composition needs on top:
  identities, versions, links, and state such as superseded or deleted.
- A deletion (D3) removes a fact from composition and marks it in the store. It never erases the
  audit's record of what happened.

**Why:** the audit log is the tamper-evident record for security review, so it must not depend on a
store that people can change. One copy avoids doubled disk use and two copies that could disagree.

**Rejected:** B, references in the audit: it would make the audit incomplete on its own. The store as
the one copy: its content could be deleted or edited, and the audit's integrity would follow it.

**Consequences:**
- Personal data or secrets that pass through a tool stay in the audit log after a fact is deleted.
  Purging content is a separate, later question, for the audit log as a whole.
- `recall` and `/inspect` read content from the audit log through the store's references, so the
  audit's entries need stable ids that the store can point to.

**Reopen if:** reading content back from the audit log proves too slow for composition, or a need to
purge content from the record arises.

### D9. What an MCP `respond` result carries

Decided 2026-09-29 with the operator.

**The question.** An MCP caller has its own view and its own context. When the model ran tools in a
turn, what does `respond` return besides the reply?

**Considered:**
- A. The reply only, as today.
- B. The reply and every tool output in full.
- C. The reply and a reference to each tool call's output, resolvable through a resource.
- D. C, with output under a small threshold inline.

**Chosen:** D.
- The result lists each tool call of the turn: its id, the command or arguments, the exit status, and
  the output's size.
- Output under a threshold (1 KiB to start) is inline. Larger output is a reference the caller reads
  through a resource, such as `wisp://output/{thread_id}/{id}`, served from the audit log (D8).
- The output returned is what the tool produced, not what the model said about it.

**Why:** most output worth seeing is small, so inlining it saves the caller a round trip, while large
output stays a reference and the caller decides whether to spend its own context on it. The caller also
gets the real output whatever the model's reply says. A small model told to repeat output verbatim does
not always do so.

**Rejected:** A: the caller cannot check the reply against the output. B: floods the caller's context,
which the condensing tools exist to prevent.

**Consequences:** `respond`'s `structuredContent` gains the tool calls; a new resource template serves
output by id; both are documented in `mcp.md`. The threshold is a setting, tuned in use.

**Reopen if:** callers routinely fetch every reference (inline more), or inline output crowds their
context (inline less).

### D10. A model switch recomposes the active view

Decided 2026-09-29 with the operator.

**The question.** `/model` builds a new `Agent` over the old transcript, with the new model's window.
Today, switching to a smaller model condenses turns away for good.

**Chosen:** a switch recomposes the active view from the store for the new model's window,
instructions, and tools. The store is untouched, so switching back loses nothing. The window is read
when the model is selected, for every backend that reports one: through
[ADR 0043](../decisions/0043-context-window-from-memory.md) for Ollama, and from the framework for the
on-device model and Private Cloud Compute.

**Considered:** keeping today's behaviour, where a switch continues the old transcript and condenses it
to fit; it loses history when the new window is smaller.

**Why:** with a store that keeps everything, the active view is a function of the store and the
model, so recomposing is the natural result, and history is never lost to a switch.

**Consequences:** Core AI and MLX need their windows read from their bundles' metadata; until then they
recompose against a default. The eval switches models mid-conversation and checks recall on both sides.

**Reopen if:** recomposing on a switch costs noticeable time on a large store.

### D11. Keeping the prefix cacheable

Decided 2026-09-29 with the operator. Amended by
[D12](#d12-four-records-one-assessment-and-tool-output-as-a-reference): the context is ordered by how
often each part changes.

**The question.** Ollama and the on-device runtime reuse the processed prefix of the context when a
request starts as the previous one did. Today the prefix only grows, so almost every request reuses it.
This design changes things near the front: the tool definitions per request (D4) and the earlier block
as turns age out. A change there makes the runtime reprocess everything after it, which is cheap on an
8,192-token window and could cost seconds per request on a 64k Ollama window.

**Considered:**
- A. Measure first and design around caching only if it matters.
- B. Design for the cache now: a tool set that only grows within a task, and an earlier block
  recomposed in batches.
- C. B's cheap parts now, and measure the rest.

**Chosen:** C.
- **The earlier block changes in batches,** every few aged-out turns, together with the summary (D1),
  not on every turn. It costs nothing that D1 does not already pay.
- **The tool set is measured both ways** on each model: selected per request (D4), and grown within a
  task and reset when the task changes (D6). The eval records time per turn and tokens per request for
  both, and the choice follows it.
- The instructions and the catalogue stay stable for the conversation. Everything that changes per
  request (the task frame, the repeated facts of D7) sits at the end.

**Why:** batching aligns caching with a decision already made. The tool set is a real trade-off between
D4's saving and a reused prefix, and only measurement settles it.

**Rejected:** B in full now: it would give up D4's per-request saving before knowing whether caching
matters on either model.

**Consequences:** the audit records, per request, whether the tool set or the earlier block changed, so
the eval can relate time per turn to what changed.

**Reopen if:** the eval shows prefix reuse matters on one model and not the other, in which case the
choice becomes per model.

### D12. Four records, one assessment, and tool output as a reference

Decided 2026-09-30 with the operator, after phase 3. Settles question 12, and amends D4, D5, D6, D7,
and D11.

**The question.** Phase 3 left the person's view of tool output to the model: chat showed a one-line
note, the model retyped what the person asked to see, and wisp cut the copy afterwards. MCP callers got
the real output (D9), so the two faces behaved differently. Question 12 asked whether chat should print
output itself when asked, and how.

**The operator's reasoning, as given:**
- Chat and MCP behaving differently is wrong.
- For each request the model must infer the person's intent, the task, and its objective.
- The transcript is what the person sees; it need not be what the model sees.
- The person must be able to see the model's context at any time, without that costing the model
  context in the turn.
- So the truth, its sources, the model's context, and the person's transcript are different things.
- Facts are temporal, and instructions and prompts change at different rates; the most stable
  information goes first, for caching.
- As long as the model can recall the full output, the context can carry a compact structured
  reference to it instead: which tool ran, when, whether it succeeded, and notes on the output.
- wisp can show the person the full output, the same way in chat and over MCP, without it entering the
  model's context in full.

**Considered** (question 12): leave the model to retype and cut the copy (A); chat prints output when
the request says "show" (B); a `/show <entry>` command (C); and the shape above, which removes the
question.

**Chosen:**
- **Four records, each a view of the truth:**

  | Record | Holds | For |
  | --- | --- | --- |
  | The truth | The audit log, verbatim and append-only (D8) | The audit, `recall` |
  | The sources | The store: every derived item linked to the audit events it came from | wisp |
  | The model's context | Composed for each request | The model |
  | The transcript | Prompts, replies, and tool output in full | The person, in chat or over MCP |

- **wisp shows tool output; the model does not retype it.** The transcript carries every tool's output
  from the truth, the same in chat and over MCP; only the rendering differs by face (chat prints or
  folds, `wisp-tui` folds, MCP returns it inline or as a reference, D9). The instructions tell the model
  that the person sees tool output, so it comments rather than repeats. Cutting presentational text
  stays as a safety net, limited to exact copies: a block reproduced with changes carries information
  the output does not, such as a proposed edit, and is kept.
- **Tool output in the model's context is full only in the turn that produced it.** The model needs it
  whole to act on it. After that turn it is a structured reference: the tool, the store entry, the time,
  success or failure, the size, and notes on the output (extracts, findings, or a summary). `recall`
  returns the full output.
- **One assessment per request.** Before each request, one call infers the person's intent, the task
  and its objective, the tools the request needs, and the facts that bear on it. It is audited and never
  enters the context. It replaces D4's selection call and D7's choice of facts, and gives D6's inferred
  task in chat on every request.
- **Ordered by stability,** most stable first: wisp's prompt; the operator's extension and the tool
  catalogue; the caller's instructions; permanent facts; dynamic facts and the summary; the literal
  turns; then ephemeral facts, the task frame, and the request. Authority by position is unchanged:
  facts stay on the prompt side, however stable.
- **The model's context is always viewable, at no cost to the model:** `/inspect context` as now, a
  live view in `wisp-tui`, and a `wisp://context/{thread_id}` resource for MCP callers.

**Taken as the leans, to be confirmed in the build:**
- A reference's notes are written mechanically first (exit status, counts, the first and last lines,
  the condensers' findings), as D1 extracts facts; a model summary only for large prose output, in D1's
  batches.
- Chat shows output up to a size and folds the rest behind a command to expand it; `wisp-tui` folds.

**Why:** the person sees the real output rather than the model's copy, the same in both faces; the
model carries what it needs to reason, not what the person needs to read; one assessment does what
three mechanisms did separately; and ordering by stability serves the cache without a rule per layer.

**Rejected:** A, retyping and cutting: the copy costs the model time and tokens, a small model alters
what it retypes, and the faces differ. B: a guess at what the person wants to see. C: kept as a
possible addition for showing an older entry again, not as the way output is shown.

**Consequences:**
- The eval scores a new strategy with references after the turn; it is expected to fit far more turns
  in the window and so to improve recall.
- Cutting's matching changes to exact copies; the phase 3 test that cuts an edited copy is reversed.
- The assessment call is a new cost per request, measured with D11's figures.
- Chat, `wisp-tui`, and `wisp chat --json` gain output display; `mcp.md` documents the context
  resource.

**Reopen if:** the model often needs the full output of an earlier turn and recalls it on most turns
(references too thin); or the assessment's time per request outweighs what it saves.

## Open questions

The first eleven were settled with the operator on 2026-09-29; each points to its decision. New questions
go here as they arise.

1. **Can the person edit facts?** Decided 2026-09-29: see D3 under "Decisions".
2. **Who distils, and when?** Decided 2026-09-29: see D1 under "Decisions".
3. **Staleness.** Decided 2026-09-29: see D2 under "Decisions".
4. **Budgets per layer.** Decided 2026-09-29: see D4 and D5 under "Decisions".
5. **What is the task?** Decided 2026-09-29: see D6 under "Decisions".
6. **Should relevant facts be repeated in the current prompt?** Decided 2026-09-29: see D7 under
   "Decisions".
7. **Audit of displayed output.** Decided 2026-09-29: see D8 under "Decisions".
8. **MCP.** Decided 2026-09-29: see D9 under "Decisions".
9. **Tool output scaled to the window.** Decided 2026-09-29: see D5 under "Decisions".
10. **A model switch recomposes.** Decided 2026-09-29: see D10 under "Decisions".
11. **Caching.** Decided 2026-09-29: see D11 under "Decisions".

12. **Routing for display by the request.** Decided 2026-09-30: see D12 under "Decisions".

## Phasing

1. The eval, run against today's dropping, as the baseline. Done 2026-09-29: `ContextEvalTests`, figures
   under "Evaluation" (on-device 0 of 6, granite at 8,192 1 of 6, granite with nothing dropped 6 of 6).
2. The store and the composer, reproducing today's behaviour exactly (literal turns only), so the change
   of structure is proven before behaviour changes. Done 2026-09-29:
   - `ThreadRecord`: every entry once, in order, by a stable id, with its kind, origin, state
     (active, or dropped by a named `context.condensation`), and references into the audit log.
   - Audit events gained an `id` for the store to point to (D8), so the store holds no second copy on
     disk. It keeps the framework's entries in memory as a cache of the conversation's own entries, so
     composing never reads the audit files; it is not persisted yet, and a resume rebuilds it from the
     saved transcript. Persisting it, and reading content back through the references, come with
     `recall` in phase 4.
   - `ContextComposer`: literal turns only, today's condensing (the 85% budget, the policy's four turns,
     the overflow retry, the archive saves) as pure decisions that `Agent` applies. `Agent` asks it for
     every request, continuing the session only when the composition is what the session holds.
   - `/model` carries the store to the new model's agent (D10's path, still composing literally).
   - `ContextEquivalenceTests` compares every request, audit event, reply, saved context, and chat's
     output against snapshots recorded from the code before the change. `DroppingStrategy` is now the
     composer's path; later designs add strategies whose agents compose differently.
   - Facts, summaries, and D2's identities and versions are not modelled yet; they will cite store
     entries by id.
3. Output handling: routing and cutting presentational text. Done 2026-09-29:
   - `Presentation` finds presentational text deterministically: a reply's blocks (fenced code blocks
     and paragraphs) whose word 4-grams are at least half found in one of the turn's tool outputs (with
     and without `read_file`'s line numbers), joined into runs of the same output, cut only when a run
     holds at least 24 words. Tested on a retyped file, a table restating a command's output (cut), and a
     summary quoting one line, analysis, and code the model wrote (kept).
   - The store records each stretch as a `Cut` on the reply's entry; the entry and the reply the person
     saw stay whole (D8). `ContextComposer.cutsPresentation` (on by default) sends the reply with the
     stretch replaced by "(showed the person the read_file output, entry 7)", where 7 is the output's
     store id, for `recall` to take in phase 4. Cuts are saved in the store's links and composed again on
     resume. Each is audited as `context.cut`.
   - `ContextEquivalenceTests` runs with cutting off and still matches the phase 2 snapshots; the
     snapshots were not re-recorded. With cutting on they match too, since no scripted reply there
     reproduces 24 words of an output.
   - Routing for display, as built: chat and `wisp-tui` keep their one-line note per result and `/last`;
     MCP `respond` gains D9's `calls` with output inline up to `inlineOutputBytes` (1 KiB, a setting) and
     a `wisp://output/{thread_id}/{id}` reference above it, resolved from the audit log by the
     `tool.result` event's id, which is the store's reference for the output. The "summary" route and
     routing by what the request asked for are not built (see "Open questions", 12).
   - The eval gained `CuttingStrategy` and the `showing` scenario (the baseline plus one turn that shows
     a file in full); figures under "Evaluation", "Output handling, 2026-09-29": each model retyped the
     file and each cut saved about 200 tokens, too few on this scenario to move a condensation or recall.
   - Deviations: a cut forces a new session on the next request, like a condensation, since the rewritten
     reply is in the middle of what the runtime has processed (D11's cost, measured below); cuts are
     judged only against the same turn's output, as the design says, so a reply that retells an earlier
     turn's output is kept.
3b. D12's output handling. Done 2026-09-30:
   - **Cutting limited to exact copies.** `Presentation` now compares lines, not word 4-grams: a block is
     cut only when its lines, normalised for formatting alone (`read_file`'s line numbers, whitespace, a
     Markdown table's pipes and header), occur in the output in order. The phase 3 test that cut an edited
     copy is reversed, and a proposed edit shown as a changed copy of a file is kept.
   - **Tool output as a structured reference after its turn.** `ContextComposer.referencesOutput` (on by
     default, beside `cutsPresentation`) sends each stored output as a reference built by `OutputReference`,
     under the same entry id, with no model call:

     ```
     [output of entry 7 not repeated: read_file at 14:05:12, ok, 101 lines, 3612 bytes; call it again to see it]
     arguments: {"path": "/work/harbour/docs/overview.md"}
     first line: 1	# harbour sync: overview
     last line: [end of file]
     ```

     The notes are D12's mechanical lean: status (a command's exit status, or `failed` for an `error: …`
     result), line and byte counts, the first and last lines of content, and the call's arguments so the
     model can run it again until `recall` exists. None of the model's own tools has a condenser's
     findings, so there are none to add yet. Lines are cut to 100 characters, arguments to 200, the whole
     to 640 bytes, and an output no longer than its reference stays whole. The switch happens once, at the
     start of the turn after the output's: the agent marks the store entry (`referencedAt`) and audits
     `context.reference`. The store also records each entry's time and the turn a condensation dropped it
     (`droppedAt`); the sidecar saves all three, so a resumed conversation composes the same references.
   - **D11's effect.** A reference rewrites an entry already in the session, so the turn after every
     tool-using turn starts a new session, as a cut or a condensation does. The rewritten entry is the
     previous turn's output, near the end of the context, so a runtime that reuses a processed prefix
     (Ollama) reprocesses only that turn and the new prompt. For a model that reports usage, the
     ahead-of-window estimate subtracts the bytes the new references save, since the last request's report
     counted those outputs whole; in granite's recorded baseline run the last read reported 7,061 tokens, 86% of
     the window, so the unadjusted estimate would have condensed at the first question.
     Measured below: on the on-device model time per turn fell (13.4 s median against 19.9 to 42.8 s for
     dropping), since requests are smaller and nothing condenses; on granite it rose a little at low load
     (5.9 s against 4.7 s), the new session each turn and a context that no longer shrinks.
   - **wisp shows tool output.** Chat prints each output under its note, in the quiet tone, up to
     `shownOutputLines` (20, a setting; 2 KiB at most), with a fold line naming `/show <id>` (the start of
     the `tool.result` event id; `/show` also takes a store entry id, the addition D12's rejected C kept).
     `wisp chat --json` adds `output` (text up to 16 KiB, lines, bytes, `truncated`, `shownLines`, id) to
     each `tool.result` event; `wisp-tui` folds output in the scrollback and expands the last one in a
     panel (Ctrl-O). MCP's `calls` (D9) was already the same rule, and `mcp.md` now says so.
   - **The system prompt** replaces "Report tool results faithfully, quoting exit status and output as
     returned" with one standing rule: "The person sees tool output as returned, so comment on it rather
     than repeat it unless asked to". The instructions with seven tools went from 1,261 to 1,268 tokens on
     the on-device model (`/tokens`, 2026-09-30), so about 7 tokens more than the 104 D4 measured. A
     prompt that asks for a copy still gets one: in the `showing` scenario both models retyped the file,
     and cutting took the exact copy out.
   - **The model's context, viewable at no model cost.** `ContextComposer.composition(_:atTurn:)` rebuilds
     the context composed at the start of any turn from the store (entries recorded before it, less those
     dropped by then, with the cuts and references in force then, then the turn's own entries as its tool
     loop carried them); `ContextView` renders it and the turn list. Chat has `/inspect context next`,
     `/inspect context N`, and `/inspect context turns` (the bare `/inspect context` still saves files); `wisp-tui` shows the same in a panel (Ctrl-T, Left and Right step through turns);
     MCP has, under the thread, `wisp://threads/{thread_id}/context` (the turns: time, start of the prompt,
     tokens composed, what changed), `…/context/{turn}`, and `…/context/next` (what `/inspect context`
     saves). With them, resources about a thread moved under `wisp://threads/{thread_id}`: its summary,
     `output` (its calls) and `output/{id}` (formerly `wisp://output/{thread_id}/{id}`), and `audit`
     (formerly `wisp://audit/{thread_id}`); `wisp://threads` lists the server's threads, open or closed.
   - **Ordering by stability.** Nothing to reorder yet: the framework puts the instructions entry (wisp's
     prompt, the operator's extension, the caller's instructions, and every tool definition) first and
     unchanged for the conversation, then the turns, then the request. D12's full order (permanent facts,
     dynamic facts and the summary, the literal turns, then ephemeral facts and the task frame before the
     request) lands with facts in phase 4.
   - **Tests** without the model: `OutputReferenceTests`, `ChatOutputTests`, `ThreadResourcesTests`,
     `ContextResourcesTests`, and the reversed and new `PresentationTests`. `ContextEquivalenceTests` runs
     with references and cutting off and still matches the phase 2 snapshots without re-recording; it
     writes the system prompt back as the phase 2 wording before comparing, since the prompt is not what
     it checks.
   - **The eval** gained `ReferencingStrategy` (exact-copy cutting and references, `Agent`'s default);
     figures under "Evaluation", "References after the turn, 2026-09-30".
4a. Facts (D1, D2, D3, D6, D8, D12). Done 2026-09-30:
   - **The model.** A `Fact` is a versioned assertion: identity `{scope, subject, name}`, `source`
     (`person`, `caller`, `tool`, `model`), `version`, value, temporal class, method (`stated`,
     `extracted`, `distilled`), the store entries and audit events it came from, when and in which turn it
     was recorded, what superseded it, and its state (current, superseded, deleted). A `FactBook` per scope
     keeps every version; a newer assertion from the same source supersedes, and one with the same value
     adds nothing. `FactView` groups the current heads of all three books by `{subject, name}` and orders
     them by precedence (the person and a caller, then a tool, then the model, the newer on a tie; a fact
     the person approved ranks with the person); heads that disagree are a conflict.
   - **Where they live.** Dynamic facts in the conversation's store, saved in its `.store` sidecar and
     restored on `--resume`; ephemeral facts in the session (`Session.sessionFacts`), shared by an MCP
     server's threads and gone with the process; permanent facts in `~/.wisp/facts.json`, user-only,
     admitted only by the person: stated with `/fact` under a permanent kind, or approved with `/fact
     approve`. Until approved, a tool's or the model's permanent fact is held by the conversation as a
     proposal.
   - **Subject kinds as data**, shipped as `Resources/subject-kinds.json` and changed or extended by
     `facts.kinds` in the config: `task`, `decision`, `preference`, `entity`, `tests`, `file`, `service`,
     `machine` (added beside `service` for `system_info`'s other topics), `workdir`, and `branch`, each with
     its class, a normaliser behind `FactNameNormaliser` (`casefold`, `trim`, `single`, `command`, `path`
     relative to the repository root), and a description for the distiller.
   - **Extraction every turn, no model**, from the turn's `tool.call` and `tool.result` events, at most 12
     a turn: `workdir` from `run_command`'s working directory and from chat's start; `branch` from git's
     output where it names one branch, and from chat's start through the git read the status line already
     makes; `tests` from the exit status of a listed test command (the list is data); `file` from
     `read_file` (lines, to the end or not, bytes) and `edit_file`; `service` per listening port and
     `machine` per other topic from `system_info`, ephemeral.
   - **Distillation at condensation.** Before a condensation drops turns, one call to the conversation's
     model in a session of its own distils their prompts and replies into at most 12 facts, shown the
     kinds and the identities already known, answering a `@Generable` schema, bounded (each text cut to
     its share of a third of the window, at most 12,000 bytes; 900 output tokens; greedy). Audited as
     `context.distillation`; a failure is audited and the turns are dropped as before. The kept turns'
     prompts follow the dropped turns, for the latest values, and kinds whose facts come from tools
     (`file`, `service`, `machine`) say `distil: false` and are not offered; both came from the eval,
     under "Facts, 2026-09-30".
   - **Composition.** Two prompt-side entries, never the instructions: the earlier block after the
     instructions (permanent facts, then the conversation's facts the literal turns no longer show, and any
     in conflict) and the now block before the request (ephemeral facts and the task). Each is labelled as
     a record, each fact one line with its source in brackets and a note when another source disagrees,
     both within `factsShare` of the window (0.1, never below 1 KiB). `ContextEquivalenceTests` still
     matches the phase 2 snapshots without re-recording: an agent made directly keeps no facts, and the
     one opened through `WispThread.openAgent` there has them switched off.
   - **The eval** gained `FactsStrategy` and `budget-50` variants of it and of `ReferencingStrategy`;
     figures under "Evaluation", "Facts, 2026-09-30". At half the window, with one condensation that
     drops every early turn, facts took the on-device model from 1 to 5 of 6 and granite from 1 to 5.
   - **Person controls.** Chat: `/inspect facts [all]`, `/fact SUBJECT [NAME] = VALUE`, `/fact delete ID`,
     `/fact approve ID`, `/task [text]`, with completion and help; `wisp chat --json` sends `/inspect facts`
     as a `view` of kind `facts`, which `wisp-tui` shows in its panel. MCP: `respond`'s `task` and
     `wisp://threads/{thread_id}/facts` (paged, `?all=true` for history) and `…/facts/{fact_id}`.
   - **Audit.** `fact.recorded`, `fact.superseded`, `fact.deleted`, `fact.approved`,
     `fact.conflict.raised`, `fact.conflict.resolved`, and `context.distillation`.
   - **Choices made in the build**, each open to review:
     - *A distilled fact is the model's*, recorded with `source: model` and `the person said` or `the model
       concluded` beside it, even when the person spoke. Recording it as the person's would let the
       distiller pin a fact, over a tool's, by attributing it to the person.
     - *An MCP caller's task is `source: caller`*, ranked with the person (the caller is the person's
       agent) but recorded apart, so the audit says who set it. The caller sets only the task; deleting and
       approving stay with the person in chat.
     - *A fact the literal turns still show is not repeated* in the earlier block. That keeps the block
       unchanged between condensations and the person's changes, which is D11's batching without a rule of
       its own; a fact in conflict is shown regardless.
     - *The task goes in the now block*, next to the request (D6, D12), though it is a dynamic fact.
     - *Not extracted:* the working directory from an MCP caller's prompt, which is prose; `respond` has no
       working-directory argument to read it from.
     - *D11's cost.* The now block sits before the request, so every request with a task or an ephemeral
       fact starts a new session; the earlier block's id is made from its content, so an unchanged block
       costs nothing.
4b. The running summary of dropped turns, beside the dynamic facts (D1's batches). Done 2026-09-30,
   figures under "Evaluation", "Summary, 2026-09-30":
   - Written by the conversation's model at a condensation, once the dropped turns not yet summarised come
     to `summaryBatchTurns` (3); with references on, one condensation drops enough at once. By default in
     the same call that distils facts (one `@Generable` answer with both), otherwise a call of its own.
   - Updated, not rewritten: the call sees the previous summary and the batch's prompts, tool calls, and
     replies (not tool output), and returns the summary within `facts.summaryShare` of the window; an
     answer over the cap loses its middle sentences. A failure keeps the summary as it was and the turns
     for the next batch.
   - It ends the earlier block, after the facts, labelled as a record, never in the instructions. Each
     version is kept in the thread record (the last 20) with the turns, entries, and audit references it
     covers, saved in the `.store` sidecar; audited as `context.summary`.
   - Visible with the facts: `/inspect facts` shows it (`all` adds earlier versions), `/inspect context
     turns` marks the turn that wrote one, and `wisp://threads/{id}/facts` carries `summary`.
4c. `memory`: recall of stored entries, a fact's sources and history (D2), and the task in full, and notes by
   the model. Built first as a `recall` tool, then widened to `memory` the same day; done 2026-09-30, figures
   under "Evaluation", "Recall, 2026-09-30" and "Memory, 2026-09-30"; [tools/memory.md](../tools/memory.md)
   is its page. The bullets below describe the first build, as `recall`; the next block says what the
   widening changed.
   - **The tool.** One text argument, `what`: `entry 7`, `turn 3`, `task`, `summary`, or `fact <subject or
     name>` (a fact id such as `c12` too), read leniently (`Recall.target`), with `from line N` for a later
     page. One string because the references and markers already spell what to ask for (`recall entry 7 to
     see it`, `…, entry 7)`, and the turns in facts' sources), and a small model copies a phrase more reliably
     than it fills optional fields; paging in the same string because an `offset` field cost the tool 31 of its
     134 tokens (103 without it, measured with `tokenCount(for:)` on the on-device model, as D4 measured the
     others). Description: "Restores earlier material in full, for this turn: an entry or turn a reference
     names, the task, the summary, or a fact's history." Pages of 4 KiB, as `read_file`'s.
   - **What it restores, and from where.** An entry's content is read from the audit event its store entry
     refers to (D8), by id, through `AuditLog.event(_:)` (a sink that can read back, `AuditReader`: the file
     sink searches the current and rotated files, newest first, for the id and decodes only the lines that
     hold it). Phase 2 kept the framework's entries in memory so that composing never reads the audit files;
     that copy is the fallback, for an entry the audit does not hold (text before a tool call, an event rotated
     out, the audit off), and the result's header and the `context.recall` event say which was used. A turn is
     its stored entries in order. The task is the task fact's versions, oldest first, with their sources and
     entries, then the prompt the conversation began with, in full: the store knows no more than that of
     "the turns that shaped it" until phase 4d infers the task. A fact is found by id or by words matched
     against subjects, names, then values (at most four subjects) and returned as every version, with source,
     time, value, state, what superseded it, and the entries it came from: D2's history. The summary is its
     versions, newest first (the store keeps 20).
   - **For the turn only.** The result is an ordinary tool output: whole in its turn, a reference after it
     (`[output of entry 40 not repeated: recall at …]`), so recalled material ages out as anything else does.
     The agent publishes a copy of its store and facts to the tool (`RecallSource`) before every request; the
     tool never touches the agent.
   - **References and markers name it.** A reference ends `recall entry 7 to see it` in a conversation with
     `recall`, and keeps `call it again to see it` only in one without it: an agent made directly (tests,
     the earlier eval strategies), or a conversation whose config disables `recall`. Every stored output can
     be recalled, since the store keeps every entry. The cut marker already named the entry.
   - **The standing rule** (D12's layer 1) is the system prompt's last line, given only to a conversation
     with `recall`: "Earlier turns may reach you only as a summary, facts, or references; when a question
     needs detail they leave out, call recall with the entry or turn they name instead of guessing or running a
     tool again." (The first wording, "to see one in full, call recall with the entry or turn it names rather
     than running a tool again", led the on-device model to recall the task in the first turn; see below.) One clause for 4a's
     finding that the on-device model repeats facts' provenance follows the first line's "Keep replies
     short.": "Facts from earlier carry their source in brackets, for you only: never copy a bracket into a
     reply." Measured with `tokenCount(for:)` on the on-device
     model, 2026-09-30: the prompt went from 111 tokens to 132 without the rule and 175 with it; with every
     tool, the instructions from 1,268 to 1,435 tokens.
   - **Registration.** `recall` is a built-in tool (`ToolRegistry.builtInNames`, so `wisp tools` and
     `wisp://tools` list it and `tools.disabled` can name it), added to every conversation that has any tool,
     all or named (`ToolRegistry.withRecall`, from `WispThread.setUp`), and wired to the agent by
     `WispThread.openAgent`. A conversation with no tools does not get it.
   - **Audit.** A call is a `tool.call` and `tool.result` like any tool's, and a `context.recall` event names
     what the text alone does not: the target, the entries, facts, and summary versions restored, the audit
     events read, and whether the content came from the audit log or the store (the proposal's "new events
     for … recall").
   - **The eval** gained `RecallStrategy` (summary in the facts' call, plus `recall`) and the `recalling`
     scenario (showing, then a seventh question on a detail of the first file that no fact or summary
     carries: the name of the temporary file a copy writes to, `.harbour-tmp-<random>`).
   - **Choices made in the build**, each open to review:
     - *Named tool selections get `recall` too.* `--tool read_file` and MCP `tools: ["run_command"]` now give
       the tool and `recall`, where they gave exactly the tools named; `tools.disabled` is the way out. The
       alternative, `recall` only with all tools or when named, keeps the selection exact but leaves a
       conversation of named tools with references it cannot follow, which then keep "call it again".
       Reversed by the operator the same day: `memory` comes with all tools or when named (decision 3 below).
     - *A tool fact's source names its entry.* `[tool read_file, turn 2, entry 4]` where it said `[tool
       read_file, turn 2]`: once condensing has dropped a read, the fact is the only pointer left to it, and in
       the first on-device run the model read "turn 2" and recalled `entry 2` (the first prompt), then made
       the answer up. A fact from one output names it; a distilled fact, from many entries, does not.
     - *No fact ids in facts' lines.* `recall fact <words>` finds a fact by subject, name, or value; ids would
       cost a few tokens a fact.
     - *Nothing stored yet is not "none".* Before the first turn is stored, every target answers that the
       first turn is all in the model's context. In the second on-device run the model recalled `task` at the
       first turn, read "no task and no prompt stored yet", told the person it had no task, and the distiller
       later recorded "no task stored" and "no codename provided".
     - *The clause on brackets* was first "leave the bracketed sources of facts out of them"; the on-device
       model still copied every bracket in the first run, so it became "Facts from earlier carry their source
       in brackets, for you only: never copy a bracket into a reply." Removed with the widening (decision 4 below).
   - **Widened to `memory`, 2026-09-30 (operator).** Five decisions after the first build's evaluation:
     1. *One tool, `memory`, with verbs*, as the person's chat commands and `config get/set` have them, in one
        string argument, `request`: `recall …` does everything `recall` did (`recall entry 7`, `recall turn
        3`, `recall task`, `recall summary`, `recall fact codename`, `recall entry 7 from line 60`), with the
        same lenient reading, and a request with no verb is a recall; `note SUBJECT NAME = VALUE` records a
        fact as the model. A `task` verb is left for phase 4d (today `task` alone recalls the task).
        References and page ends name the call to copy: `to see it: memory "recall entry 7"`, `[more: memory
        "recall entry 7 from line 60"]`. The page is [tools/memory.md](../tools/memory.md); `recall.md` is
        gone. The audit event is `context.memory` with an `action` (`recall`, `note`), one kind for both, so a
        reader filters one kind for everything the tool did.
     2. *The name is shared with `system_info`'s `memory` topic (RAM)*, so the description starts "This
        conversation's memory, not the Mac's RAM (that is system_info)". The eval decides whether that is
        enough: `SystemInfoEvalTests` now offers `memory` beside `system_info` and `run_command`, and counts
        the turns that call it (below). A rename is the operator's call if it is not.
     3. *Registration: all tools, or named.* `memory` is a built-in tool, so a conversation given every tool
        has it from the first turn, and a named list has it only when the list names it: MCP's git thread
        (`tools: ["run_command"]`) stays exact. This reverses the first build's choice (named selections got
        `recall` too). Without `memory`, references keep "call it again to see it".
     4. *The bracket clause is removed*, and the facts' line puts the source after the value, behind a dash:
        `- entity release codename: BLUE HERON — from the person`. Both forms tried were measured on the
        on-device model (below); the dash form was echoed less.
     5. *Token cost* measured again with `tokenCount(for:)` on the on-device model: the tool's definition 110
        tokens (the first build's `recall` 103); the system prompt 111 tokens without the rule and 154 with
        it (175 in the first build, with the bracket clause); every tool and the prompt 1,375 against 1,222
        without `memory` (1,435 against 1,268 in the first build).
   - **Notes, as built.** `note SUBJECT NAME = VALUE` (also `SUBJECT: NAME = VALUE`, and `SUBJECT NAME:
     VALUE` without `=`; `remember` is taken as `note`) records a fact with source `model` and a new method,
     `noted`, rather than `stated`: `stated` is the person's and a caller's word, and a note is neither
     extracted nor distilled, so the audit and `/inspect facts` should tell it apart (`model, noted, turn 4`).
     Precedence is the model's, the lowest, so a note never outranks the person or a tool; a newer note or
     distilled fact on the same identity is the model's next version. The subject must be a kind the
     distiller may use (`file`, `service`, and `machine` are the tools'); an unknown one is refused with a
     short directive error that lists the kinds and repeats the example. A kind that names its facts needs a
     name. The class is the kind's, so a note of a permanent kind is a proposal until the person keeps it
     (D2). At most 12 a turn, as a distillation; values cut to 200 characters. The tool cannot touch the
     agent, so it leaves the note in the `MemorySource`, and the agent records it when the turn ends, beside
     the turn's extracted facts: it reaches the model's facts from the next request and the person's list of
     the turn's new facts. Audited as `context.memory` and, when recorded, `fact.recorded`.
4d. The assessment per request (D12): the task inferred in chat (D6), the tools a request needs (D4), and
   the facts to repeat next to the request (D7).
5. Condensing's guarantees, which today are missing: `ContextComposer.ahead` and `overflow` condense to a
   fixed four turns (`ContextPolicy.default`) with no check that the result fits; ahead of the window,
   nothing happens when there are four turns or fewer, even over budget; the overflow retry fails when four
   turns still exceed the window; and the 85% estimate (usage plus the prompt at four bytes a token) leaves
   no room for the next turn's reply and tool output. Phase 5:
   1. Condense to a token target, a low-water mark as a share of the window taken from the eval, in the
      order references, then distilled facts, then dropping the oldest turns, verifying the composed result
      after each step (by count or estimate) and condensing further while it is above the target.
   2. Keep headroom for the next turn in the budget check: D5's literal floor, or a running average of a
      turn's size.
   3. When even the floor cannot fit, say so and audit it.
   4. An invariant test without the model: for any sequence of turn sizes, the context composed after a
      condensation is at or below the target, and an average turn fits.
   5. The eval records the fill after each condensation and the turns until the next.
6. The ADR, with the eval's figures.
