# Proposal: layered context, composed for each request

Date: 2026-09-29. Status: reviewed; decisions D1 to D11 recorded. Becomes an ADR with the eval's figures.
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
  `task`, `decision`, `preference`, `entity`, `tests`, `file`, `service`), and configuration can add or
  change kinds. The distiller is shown the kinds and the existing identities, and asked to reuse them.
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

### D4. What goes in the instructions, and which tools each request carries

Decided 2026-09-29 with the operator.

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

Decided 2026-09-29 with the operator. Settles the rest of question 4, and question 9.

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

Decided 2026-09-29 with the operator.

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

Decided 2026-09-29 with the operator.

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

Decided 2026-09-29 with the operator.

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

12. **Routing for display by the request.** Raised in phase 3, 2026-09-29, and left to the operator:
    whether chat (and `wisp-tui`) should print a tool's output itself when the person asked to see it
    ("show me the file"), full or summarised by size, instead of relying on the model to retype it; and
    whether that needs a flag or a command. Today chat shows a one-line note and `/last`; MCP callers get
    the real output through D9.

## Phasing

1. The eval, run against today's dropping, as the baseline. Done 2026-09-29: `ContextEvalTests`, figures
   under "Evaluation" (on-device 0 of 6, granite at 8,192 1 of 6, granite with nothing dropped 6 of 6).
2. The store and the composer, reproducing today's behaviour exactly (literal turns only), so the change
   of structure is proven before behaviour changes. Done 2026-09-29:
   - `ConversationStore`: every entry once, in order, by a stable id, with its kind, origin, state
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
4. Facts and the summary, `/inspect facts`, and `recall`.
5. The ADR, with the eval's figures.
