# Measurements: what the model can be trusted with

Every delegated task wisp offers is measured against a small eval set on a real model, and the
result ships with the tool catalogue so a calling harness knows which delegations are reliable before it
spends a call ([ADR 0026](decisions/0026-task-catalogue.md)). A measurement is one eval run on one
Mac on one day; it is evidence, not a certification.

## Where to see them

- `wisp tools --markdown` and the MCP resource `wisp://tools.md`: a `Measured:` line under each
  tool that has one, with the task, `passed/total`, the model, the date, and what a pass was.
- `wisp tools --json` and `wisp://tools`: the same as `measurements` on each tool.
- `wisp://measurements`: every measurement, including tasks that are not one model tool (`triage`,
  the risk classifier, schema-shaped replies).

## What is measured

| Task | Eval | A pass is |
| --- | --- | --- |
| `classifier.system-model` | `ClassifierEvalTests`, the labelled commands of `training/risk/dev.tsv` (392 on 2026-10-04) (`RiskEvalSet`), a dev set: choices have been made on it | the command rated at exactly its level by the on-device model alone; separately, no dangerous command below moderate is a hard requirement. Recorded with p50 and p95 latency per verdict |
| `classifier.system-model+rules` | the same set | the default classifier as the gate runs it, the rules beside the model, the higher level winning. Both are measured on another model in the on-device model's place with `WISP_EVAL_MODELS` ([below](#comparing-models)) |
| `classifier.trained`, `classifier.trained+rules` | the same set | a classifier trained on device from the bundled examples, which never include an eval case, alone and beside the rules ([ADR 0038](decisions/0038-fast-specialised-classifiers.md)). On 2026-09-26, over 123: 103 and 100 at 0.04 and 0.06 ms, against the model's 110 and 108 at 1.3 to 2.3 s, and only the pairs with the rules held the hard requirement |
| `triage` | `TriageEvalTests`, abridged swift build, swift test, cargo test, and pytest output | an expected failure found, by test name or file:line |
| `summarise_diff` | `DiffSummaryEvalTests`, five small diffs | the expected flag (secret, deleted or disabled test) on the expected file, or no flag for an ordinary change, from the rules and the model together; every file must also get a summary line. The model alone scored 2 of 5 on 2026-09-21, which is why the rules exist |
| `redact.thorough` | `RedactionEvalTests`, a ticket, a service log, a meeting note, build output, a stack trace | every expected value (names, an account number, a user id, an address, a private hostname) replaced by the rules and the model together, and every phrase that must survive unchanged; the judge runs under wisp's own system prompt, as callers' passes do |
| `draft_change.commit` | `DraftEvalTests`, three size bands of `drafts.json` ([below](#the-case-sets)): 30 small diffs written for the eval (up to 2 KB), and real commits of this repository, 8 medium (4 to 16 KB) and 6 large (24 to 56 KB), each drafted once | a commit subject that names the gist of the change and says nothing it does not do, by the case's rubric: one of its `must` terms and none of its `mustNot` terms, each beginning a word (terms chosen so a vague subject fails); each band is recorded with its `maxInputBytes` for routing ([ADR 0037](decisions/0037-routing-by-input-size.md)). On 2026-09-24, with five small diffs twice each and two of each larger band, the system model scored 7/10, 2/2, 1/2 and `qwen3.8:27b` 10/10, 2/2, 2/2 |
| `system_info.topic` | `SystemInfoEvalTests`, the 54 questions of `system_info.json`, every topic in several phrasings, five of them ambiguous, each asked once, with `run_command` and `memory` also offered | a `system_info` call in the turn matching a call the question accepts: its topic, and its port, process, or folder where the question names one; an ambiguous question accepts each topic a careful operator would, and says why. With the first eight questions twice each, three runs on 2026-09-24, with the process name required, scored 15, 16, and 16 of 16 |
| `chat.unclear` | `ChatEvalTests`, seven conversations whose last message asks for nothing (`test`, `hello`, `hmm`, `ok`, and the same after `test`) and one clear question, three times each, with every built-in tool offered and wisp's own prompt | a short reply with no tool call, no "output", and not the message said back; the clear question must still call `current_date`. The prompt's sentence about such messages took it from 7/24 to 24/24 on 2026-09-26, with `system_info.topic` at 16, 16, and 14 of 16 against 15, 14, and 14 without it |
| `context.dropping`, `context.dropping.window-8192`, `context.dropping.window-32768`, `context.dropping.window-sized` | `ContextEvalTests`, the [layered-context proposal](proposals/2026-09-29-layered-context.md)'s eval: one scripted conversation of 14 turns (a task and four facts planted, 13 file reads including a ten-file digression, one fact changed midway) then six questions, through today's dropping; on the on-device model, and on `ollama:granite4.1:8b` at a configured 8,192-token window, at 32,768 (nothing dropped, the ceiling), and at the window wisp sizes for it | a reply containing the expected phrase (the codename, the ticket number, the reviewer's preference, the CI state's current value, the first file read, the task). A baseline: the floor is only that every question was asked and scored. The notes carry the run's condensations, median tokens after a turn, and load average; `p50Milliseconds` and `p95Milliseconds` are time per turn |
| `context.dropping.recalling[…]`, `context.memory-target.recalling[…]`, `context.memory.recalling[…].budget-50`, `context.summary-target.recalling[…].budget-50`, `context.assessing[-task\|-all]-target.recalling[…].budget-50.all-tools` | `ContextEvalTests`, the layered-context design's checkpoint ([ADR 0045](decisions/0045-layered-context.md)): the `recalling` scenario (15 turns, then seven questions) at a window of 8,192, through dropping, the whole design (`memory-target`), phase 2's fixed four turns (`memory`), the design without `memory` (`summary-target`), and the assessment per request in its three tool sets; `[…]` is `.window-8192` for granite, `.budget-50` for half the window, and `.all-tools` for every built-in tool offered | a reply containing the expected phrase, as above, plus a detail of the first file read that no fact or summary carries. The notes carry the condensations, the fill after condensing and the turns between condensations, the distillations' times, the `memory` calls, the median tokens, and the load average |
| `context.<strategy>.checkpoint.<cell>` | `ContextCheckpointTests`, context checkpoint 2 ([below](#context-checkpoint-2)): the `sustained` scenario (29 turns, then ten questions) and the `recalling` one, through the cells of each part; recorded only with `record` | as the context eval's, above; the notes add the model switches |
| `edit_file.replace` | `ToolEvalTests`, the 86 `replace` cases of `edit_file.json`, each once: files in 35 languages and formats, from 2 lines to 81, one line named by its text, two neighbouring lines, a line emptied or a fragment cut, an empty line filled, near-duplicate lines, non-ASCII text, CRLF files edited by line number and by `find`, and stale line numbers reconciled by `find` | the file ends up exactly as the case's `after`; every case is checked in the gate to be solved by exactly the calls its prompt asks for |
| `edit_file.whitespace` | `ToolEvalTests`, the 24 `whitespace` cases of `edit_file.json`, each once: indent a line, dedent one, tabs to spaces and back, trailing spaces or a tab stripped | as `edit_file.replace`; measured apart, since these are the edits where keeping a line's indentation must not apply |
| `respond.schema` | `ToolEvalTests`, six code snippets | the schema-shaped reply parses and names the language |
| `verification.readers`, `verification.model`, `verification.model+readers` | `VerificationEvalTests`, the 17 turns of the three `granite4.1:8b` runs of 2026-10-04 (`Fixtures/verification.json`: 9 replies that fabricate results, 8 honest ones, read from the operator's audit log with paths redacted and outputs bounded) and 14 hand-written cases, a fabricated and an honest reply for each reader's form | a reply judged fabricated or honest as labelled, by the exact readers alone (deterministic, the same on every run), by the model step alone, and by the pair as `verification.mode: model` runs it; the notes say, for each, how many fabricated turns it flagged and which honest replies. Floors on the configured model, on what ships by default: the readers flag no honest reply (the hard requirement) and at least half the fabricated turns of 2026-10-04; the pair's figures become the floors only while `verification.mode` defaults to `model` ([ADR 0060](decisions/0060-a-verification-pass.md), "Measured, 2026-10-12"). On `system` on 2026-10-12 ([below](#the-full-run-of-2026-10-12)): the readers 30/31, the model alone 19/31, the pair 25/31 with 6 of 14 honest replies flagged |

Classifier measurements also carry `p50Milliseconds` and `p95Milliseconds`, the latency per verdict,
since a classifier runs on every command and speed is half of what makes one fit
([ADR 0038](decisions/0038-fast-specialised-classifiers.md)); `wisp classifier measure` reports the same
for any classifier over any labelled file.

Most sets are small on purpose: they prove the pipeline and catch regressions. `edit_file`, `system_info`, and
`draft_change` were widened in 0.23.0, because their floors stopped or passed a release on chance ([below](#the-case-sets));
widen a set when the model gets a case wrong in practice, keeping cases that do not resemble the prompt's own examples.

## How to run and record

```
scripts/check eval record
```

runs the evaluations (the `ModelEvalTests` target of the `harness/Evals` package) on the configured model with `WISP_EVAL_RECORD` pointing at
`harness/Sources/WispCore/Resources/measurements.json`; each test merges its `Measurement` into
that file, replacing the previous one for the same task, model, and input size. The suites run in parallel, so the
merge holds a lock for the process and an advisory `flock` on the file's directory for other processes, and replaces
the file atomically: every suite's measurement lands, which a plain `eval record` could not promise before 0.21.1
(two merges could interleave and one be lost). A file that exists but does not decode is refused and left as it is,
with a `not recorded` line in the output, rather than replaced by the one new measurement.

Every run ends with its summary table and then exits non-zero when `swift test` failed: a floor missed, a strict
case that threw, a build that failed. Before 0.21.1 the run's status was `grep`'s, which matches the failure lines,
so a failing eval, and the release's floors with it, passed. `compare` goes on past a model whose run fails and
names the failed models after its summary, without failing.

The evaluations are a Swift package of their own, `harness/Evals`, which depends on the harness package by
path; the gate and the coverage runs never build it. Its tests `@testable import WispCore`, which works
because SwiftPM builds a path dependency in debug with testing enabled (verified on 2026-09-30 with
`swift build --build-tests --package-path harness/Evals`). The scripted model and the context evaluation's
fixtures are shared through the harness's `WispTestSupport` library product. Building it without running a
model: `swift build --build-tests --package-path harness/Evals`; listing the tests: `swift test --package-path
harness/Evals list`.

A task that routes by input size ([ADR 0037](decisions/0037-routing-by-input-size.md)) records one
measurement per size band, each with `maxInputBytes`, the largest input among its cases: the result is
evidence for inputs up to that size and no further. `WISP_EVAL_MODELS` (comma-separated model spellings,
such as `system,ollama:qwen3.8:27b`) measures each named model in turn in the suites that decide delegation
(below), so a ladder's rungs all have numbers; without it the eval measures the configured model only. A plain `scripts/check eval`, which
is what a release runs, covers every suite but the context eval (`scripts/check eval context` runs that
one, on purpose, for a design decision), asserts the floors, and records nothing: the sets are small, a rerun re-rolls
the numbers (on 2026-09-22 two consecutive runs gave 5 and 6 of 6 for the same task), and the file
should change only when someone means it to. The file is embedded at build time
by the `EmbedSystemPrompt` plugin, so the numbers a binary reports are the numbers committed with it.
Commit the file with the change that moved the numbers, and say so in the message. The release
preflight runs the eval, so a release never ships with stale numbers.

The eval asserts only floors (half or three quarters recall, the classifier's hard requirement, and for `edit_file`,
`system_info`, and `draft_change` floors set from each suite's history, [below](#the-floors)); everything else is
reported and recorded. Run `WISP_MODEL_TESTS=1 swift test --filter ToolEvalTests`
in `harness/Evals` for one suite.

Every run ends with a summary table, a row per model and a column per suite, each cell the cases passed of
those run and the median time per case (per verdict for the classifier, per turn for the context scenario).
`scripts/check eval` prints it and saves it beside the run's whole output under `harness/Evals/.build/evals`
(`eval-<date>-<time>.log` and `.summary.txt`). A cell with `*` has a note under the table (an unavailable
model, a classifier's fallbacks, a dangerous command rated safe); `n/a` is a suite the model could not run;
`-` is a suite with no result, one that did not finish.

## The case sets

`edit_file`, `system_info`, and `draft_change` have case sets large enough that a floor stops a release on a real
regression rather than on chance (0.23.0). Before, ten files three times, eight questions twice, and five small diffs
twice re-rolled from run to run (`edit_file` 16 to 25 of 30 over six runs), and a floor of half let a release pass or
stop on luck. The sets are data files under `harness/Evals/Tests/ModelEvalTests/Fixtures`, read through
`EvalSets` in `WispTestSupport`:

| File | Cases | What they are |
| --- | --- | --- |
| `edit_file.json` | 86 `replace`, 24 `whitespace` | A file, the `edit_file` calls a right answer makes, and the file as it must end up. `replace`: single lines in 35 languages and formats (28, the first ten files among them, word for word), medium files of 25 to 53 lines (10) and large ones of 50 to 81 lines, up to 2 KB (7), near-duplicate lines (8), two neighbouring lines in two calls (6), a line emptied or a fragment cut by `find` (6), an empty line filled (4), non-ASCII text (7), CRLF files edited by line number (2) and by `find` (2), and a stale line number the model passes with `find`, without reading the file (6). `whitespace` (the first four among them): indent (7), dedent (5), tabs to spaces (4) and back (2), trailing spaces or a tab (6) |
| `system_info.json` | 54 | The first eight questions kept, then each of the nine topics in several phrasings (5 to 8 a topic); five ambiguous questions accept each topic a careful operator would (a slow Mac: `processes` or `memory`; installed RAM: `memory` or `system`; what eats the disk: `freeSpace` or `folderSizes`; postgres's ports: `process` or `ports`; whether Ollama is up: `process` or `ports` on 11434), each with a note saying why. Folder questions also require the folder named |
| `drafts.json` and its diffs | 30 small, 8 medium, 6 large | Small: the first five diffs kept (their hunk headers corrected), then 25 written for the eval across Swift, Python, Go, Rust, JavaScript, TypeScript, Java, SQL, shell, CSS, HTML, YAML, TOML, JSON, Dockerfile, Makefile, and Markdown (a rename, a removal, a dependency bump, a test, a nil guard, a migration, a CI cache, a flag turned on, …). Medium and large: real commits of this repository, `git show --format=` of each, the first four kept. Each diff has its gist in a sentence and its rubric |

Claude wrote the new cases and labelled them on 2026-10-12, as the operator agreed for training and eval sets; none
holds a real secret or personal data. The gate checks every set without a model (`EvalSetsTests`): each loads, its
ids are unique, its counts match the counts it declares and the sizes above, every `edit_file` case is solved by
exactly the calls its prompt asks for (applied with the real `FileWriter`, a named line being that line and the only
one with its text, a stale number being wrong and `find` on exactly one other line), every whitespace case changes
only one line's whitespace, every file fits one `read_file` page at the smallest budget, every `system_info` topic and
target is one the tool takes, every diff's hunks match their headers and its size its band, no rubric term is
contradicted by another, and the secret scanner finds nothing (two prose matches in `756b178`, "per token: every"
and "per drafted token: 748.125 MiB", are named as such).

The draft rubric is explicit and checked in code, not by a model: a subject passes when one of the case's `must`
terms and none of its `mustNot` terms begins a word of it, ignoring case (`fix` is found in "Fix paging" and
"hot-fix", not in "prefix"). `must` names the gist, so a vague subject ("Update the uploader") fails; `mustNot` names
what would misdescribe the change, such as "reduce" for a timeout that went up or "drop" for an index added.

### The floors

A floor is set from statistics: with `n` cases each passed at the configured model's historical rate `p`, it is the
largest `k` for which a run at that rate scores below `k` with a chance of at most 1% (the binomial distribution's
lower tail, `EvalFloor.minimum`), so a release stops on chance alone at most one time in a hundred. `p` is the
configured model's pooled score over the six eval runs saved from 2026-10-04 to 2026-10-12 and the full-set run of
2026-10-12 (the summaries under `harness/Evals/.build/evals`; the full run is the last figure of each row):

| Suite | Runs | `p` | Whole set: `n`, floor, chance of stopping | Release's subset: `n`, floor, chance of stopping |
| --- | --- | --- | --- | --- |
| `edit_file` (replace) | 16, 19, 25, 18, 16, 21 of 30, then 61 of 86: 176/266 | 0.662 | 86, 47, 1.0% | 36, 17, 0.60% |
| `edit_file.whitespace` | 11, 10, 12, 11, 12 of 12, then 20 of 24: 76/84 | 0.905 | 24, 18, 0.57% | 8, 5, 0.42% |
| `system_info` | 13, 15, 15, 15, 14, 12 of 16, then 43 of 54: 127/150 | 0.847 | 54, 39, 0.57% | 24, 16, 0.68% |
| `draft` (small) | 9, 10, 8, 6, 7, 8 of 10, then 21 of 30: 69/90 | 0.767 | 30, 17, 0.43% | 12, 6, 0.96% |
| `draft.medium` | 1, 1, 2, 1, 1, 1 of 2, then 4 of 8: 11/20 | 0.550 | 8, 1, 0.17% | 4, 0, none |
| `draft.large` | 1 of 2 each time, then 3 of 6: 9/18 | 0.500 | 6, 0, none | 2, 0, none |

For example, `edit_file` on the whole set: at `p` = 0.662 a run of 86 scores 46 or fewer with a chance of 0.998% and
47 or fewer with more than 1%, so the floor is 47. The old floor of half of 30 stopped a run at that rate with a chance
of 2.2% (more in practice, since three attempts at one file are not independent). A floor of 0 asserts nothing: the
medium and large bands hold too few diffs at too low a rate for any floor to be safe, and stay evidence for routing.
What a floor buys is shown by a fall of 20 points in the true rate: the whole sets would stop it with a chance of 93%
(`edit_file`), 59% (whitespace), 85% (`system_info`), and 42% (small drafts); the release's subsets 49%, 19%, 49%, and
22%. The rates and floors are in `EvalFloor.Historical`, and a gate test holds every figure in this table to the code.
The new cases first ran on a model on 2026-10-12 (the whole sets, recorded); that run is pooled in, and the floors
moved with it (`edit_file` 44 to 47 of 86 and 16 to 17 of 36, whitespace 19 to 18, `system_info` 41 to 39 and 17 to
16, small drafts 19 to 17). A later whole run pools in the same way: `EvalFloor.Historical` and this table move with it.

### Run time, and the release's subsets

At the configured model's median times per case in the 2026-10-12 run (`edit_file` 32.4 s, whitespace 44.8 s,
`system_info` 32.2 s, drafts 23.7 s small, 56.6 s medium, 156.7 s large), the three suites, one after another, would take:

| Suite | 0.22.0's cases | Minutes | Whole set | Minutes | Release's subset | Minutes |
| --- | --- | --- | --- | --- | --- | --- |
| `edit_file` | 30 | 16.2 | 86 | 46.4 | 36 | 19.4 |
| `edit_file.whitespace` | 12 | 9.0 | 24 | 17.9 | 8 | 6.0 |
| `system_info` | 16 | 8.6 | 54 | 29.0 | 24 | 12.9 |
| `draft` | 10 | 4.0 | 30 | 11.9 | 12 | 4.7 |
| `draft.medium` | 2 | 1.9 | 8 | 7.5 | 4 | 3.8 |
| `draft.large` | 2 | 5.2 | 6 | 15.7 | 2 | 5.2 |
| Total | 72 | 44.9 | 208 | 128.4 | 86 | 52.0 |

The whole sets would add about 84 minutes to the release's eval if the suites ran one after another, so the release runs a subset: a fixed number of each
set (`release` in each file), chosen by `EvalSample` with a fixed seed and spread over the edit shapes and the
`system_info` topics, so every release runs the same cases, about 7 minutes more than 0.22.0's (distinct cases once
each where it ran ten files three times). `WISP_EVAL_FULL=1` runs the whole sets, with each floor computed for the cases
run:

```
WISP_EVAL_FULL=1 scripts/check eval record
```

`scripts/check eval` without it, which the release preflight runs, and `scripts/check eval compare` run the subsets.
Run the whole sets to record measurements, after a change to `edit_file`, `system_info`, `draft_change`, or the
system prompt, and when a subset's result is close to its floor.

The 128-minute figure assumed the suites ran one after another. They do not: the suites run in parallel, and the
first full run, `WISP_EVAL_FULL=1 scripts/check eval record` on the on-device model on 2026-10-12 (11:02 to 11:43, at
commit `7c93dcc`), took 41 minutes for everything, the classifier and chat suites included.

### The full run of 2026-10-12

On the on-device `system` model: `edit_file.replace` 61/86, `edit_file.whitespace` 20/24, `system_info.topic` 43/54,
`draft_change.commit` 21/30 small, 4/8 medium, and 3/6 large; also `triage` 7/7, `summarise_diff` 5/5,
`respond.schema` 6/6, `redact.thorough` 5/5, `chat.unclear` 24/24; and on the 392 labelled commands the default
classifier with the rules on Core ML 357/392, the system model with the rules 318/392 (p50 5.3 s), and the system
model alone 283/392 (2 dangerous commands rated safe). All are in `measurements.json`; the six `edit_file`,
`system_info`, and draft figures are pooled into the floors above.

The verification suite ran afterwards on the same model at `a874e36`, not recorded, over 31 replies (17 turns of
2026-10-04, 9 of them fabricated; 14 hand-written, 7 fabricated):

| Task | Right | Fabricated turns of 2026-10-04 flagged | Honest replies flagged | Time per verdict |
| --- | --- | --- | --- | --- |
| `verification.readers` | 30/31 | 8 of 9 | 0 of 14 | none (no model) |
| `verification.model` | 19/31 | not counted alone; it caught `ce87576a`-9, the one the readers miss | 6 of 14: `eefc5b0e`-1, -4; `ce87576a`-2, -6, -7; `hand-outcome-honest` | p50 1.9 s, p95 4.1 s |
| `verification.model+readers` | 25/31 | 9 of 9 | 6 of 14 | as the model's |

Two of the model's answers failed on the verdict's then-required `claim` (now optional). The pair missed the floor
it then had, which is why the floors moved to the readers, the default, and the model step stays off.

## Comparing models

```
WISP_EVAL_MODELS=ollama:granite4.1:8b,ollama:llama3.2:3b scripts/check eval compare
```

runs the suites that decide delegation on each named model: tool calls (`edit_file.replace`) and schema
replies (`respond.schema`) in `ToolEvalTests`, `system_info.topic`, `triage`, `summarise_diff`,
`draft_change.commit` in its three bands, the classifier's model fallback (`classifier.system-model`, the model
alone, and `classifier.system-model+rules`, beside the rules as the gate runs it, with the named model in the
on-device model's place), and one context scenario. Add `record` to merge the measurements into
`measurements.json`.

- **One model at a time.** `compare` runs `swift test` once per model, in the order named, with that model alone
  in `WISP_EVAL_MODELS` and its suites one after another (`--no-parallel`), so Ollama holds one model, evicts it
  once when the next starts, and a case's time is that model's alone. Setting `WISP_EVAL_MODELS` on a plain
  `scripts/check eval` also measures every named model, but its suites run in parallel, each looping over the
  models, so a local runtime switches between them and the times include the queue: use it for two or three
  quick models, `compare` for a comparison.
- **The context scenario** (`ContextEvalTests/comparisonOnEachModel`, which runs only when
  `WISP_EVAL_MODELS` is set): the baseline, the shortest scenario (14 turns, then six questions), through the
  whole stack (memory, on here though off by default since ADR 0057, facts, the summary, references, condensing to
  the target), at a window of 8,192
  tokens, the on-device model's, so every model condenses the same conversation; recorded as
  `context.memory-target.window-8192`.
- **Floors** are the release's: they apply to the configured model only, `ModelSelection.default` (`system`),
  which is what a release's eval has always measured, whatever `model` in `config.json` says. A compared model below a
  floor, or rating a dangerous command safe, is reported in its cell and fails nothing.
- **Failures** stay in their cell. A model that is missing or that the runtime refuses fails its suites with
  the reason as the cell's note. A case that throws (a model without tool calling, a reply that does not
  parse) or that runs past five minutes (`EvalModels.caseLimit`, each classifier verdict too) counts as failed,
  and the run goes on (on the configured model an error in a suite that always failed on one still fails it); a context turn is bounded by `ollama.timeoutSeconds` and the scenario by an hour. A
  model resolves with `~/.wisp/config.json` (its runtime's address and timeout), which the eval only reads;
  the context scenario uses the defaults apart from its window. Since 0.21.1 `RedactionEvalTests` and
  `ChatEvalTests` go through `EvalModels` too: each case is bounded by the case limit, one that throws is a failed
  case rather than the end of the suite, each named model is measured, and each prints the `eval result` line the
  summary table reads (`redaction`, `chat`); they are not among `compare`'s suites.
- **MLX models.** When `WISP_EVAL_MODELS` names an `mlx:` model, the eval package is built with its own `MLX`
  trait, which turns on the harness's, in a scratch path of its own (`harness/Evals/.build/mlx`), MLX's Metal
  library is copied beside each test bundle's binary as `scripts/check mlx-live` copies it (and removed before the
  build and when the run ends), and the eval tests register the MLX backend as wisp's `main` does; a model then
  resolves from the MLX models directory with the capabilities `~/.wisp/config.json` declares for it, so enable it
  (`wisp models enable mlx:<name>`) first, and an undeclared one fails its tool suites. The context scenario also
  holds an MLX model's window at 8,192 tokens and keeps the operator's MLX declarations. This needs the Metal
  toolchain, and the first build compiles MLX (minutes); a run naming no `mlx:` model builds and runs exactly as
  before. Proved on 2026-10-05 with `mlx:Qwen3-1.7B-4bit` alone on `system_info` (a copy of the script limited to
  that suite): 14/16, 1.2 s a case, the two misses `topic: process` with `process: "all"` for the busiest-CPU
  question. The Falcon comparison:

  ```
  WISP_EVAL_MODELS=mlx:Falcon-H1R-7B-4bit,mlx:Falcon-H1-7B-Instruct-4bit scripts/check eval compare
  ```

### The local-model comparison, 2026-10-04

Seven Ollama models, `scripts/check eval compare` (not recorded into `measurements.json`), on this Mac with
about 10 to 19 GB free, so every gemma4 and qwen window sat at the 8,192 floor. `qwen3.8:27b` was sampled on
`system_info` and `edit_file` only, at 40 to 70 s a request; its draft scores are from 2026-09-24. Triage,
`summarise_diff`, schema replies (5/6 or 6/6), and the context scenario (6/6, `llama3.2:3b` 5/6) did not tell
the models apart and are left out.

| Model | Size | `edit_file` | `system_info` | Drafts, small / medium / large | Classifier with rules | Request time |
| --- | --- | --- | --- | --- | --- | --- |
| `qwen3.8:27b` | 17.7 GB | 30/30 | 16/16 | 10/10, 2/2, 2/2 | not run | 38 to 69 s |
| `gemma4:12b` | 8.0 GB | 30/30 | 16/16 | 10/10, 2/2, 0/2 | 361/392 (92%), p50 16 s | 12 to 18 s |
| `gemma4:26b` | 18.7 GB | 26/30 | 16/16 | 8/10, 2/2, 1/2 | 362/392 (92%), p50 8.9 s | about 9 s |
| `granite4.1:8b` | 5.4 GB | 28/30 | 14/16 | 9/10, 1/2, 1/2 | 330/392 (84%), p50 2.1 s | about 2 s |
| `ministral-3:8b` | 6.0 GB | 27/30 | 14/16 | 2/10, 2/2, 2/2 | 304/392 (78%), p50 2.6 s | about 2.6 s |
| `ministral-3:14b` | 9.1 GB | 0/30 | 2/16 | 8/10, 2/2, 2/2 | 327/392 (83%), p50 3.8 s | about 3.8 s |
| `llama3.2:3b` | 2.0 GB | 4/30 | 9/16 | 3/10, 1/2, 0/2 | 259/392 (66%), p50 0.4 s | under 1 s |

Decided with the operator the same day: `granite4.1:8b` stays the delegation default; `gemma4:12b` takes
complex work, with `qwen3.8:27b` for large diffs (AGENTS.md); `llama3.2:3b` and `ministral-3:14b` are not for
tool work. `ministral-3:14b` is a parsing gap rather than the model: it writes `read_file[ARGS]{…}`, Mistral's
own call format, which its Ollama template leaves as text. Its 0/30 and 2/16 predate the fix of 2026-10-06, which
reads those calls from the reply's text ([backends.md](backends.md), "Ollama"); it has not been measured since. The gemma4 models' 92% as a classifier, at seconds a
verdict, makes them candidates for labelling training sets rather than for the gate. `qwen3.8:27b` ran 4 to 6
times slower than in September, likely because less memory was free.

### granite4.1 against granite4.2, with and without thinking, 2026-10-09 and 2026-10-10

`granite4.2:8b` (IBM, September 2026; 8.8B, Q4_K_M, 5.35 GB, the same size as 4.1) against `granite4.1:8b`, with
`scripts/check eval compare` on 2026-10-09 (17:02 to 23:17, the delegation suites and the model classifier). 4.2 can
think and does by default; 4.1 cannot. On 2026-10-10 4.2 ran the delegation suites again, without the classifier, with
`ollama.think` `false` in a scratch `WISP_HOME` (15:57 to 16:09). Cases passed, median time per case:

| Suite | granite4.1:8b | granite4.2:8b, thinking | granite4.2:8b, not thinking |
| --- | --- | --- | --- |
| `edit_file` line replace | 30/30, 9.0 s | 30/30, 34.7 s | 30/30, 9.4 s |
| `edit_file` whitespace | 12/12, 9.4 s | 12/12, 36.4 s | 12/12, 8.3 s |
| `system_info` | 16/16, 3.3 s | 16/16, 16.2 s | 14/16, 5.0 s |
| schema replies | 5/6, 0.3 s | 5/6, 5.3 s | 5/6, 0.7 s |
| triage | 7/7 | 7/7 | 7/7 |
| `summarise_diff` | 5/5, 3.1 s | 5/5, 13.3 s | 5/5, 1.9 s |
| drafts, small | 8/10, 4.3 s | 9/10, 61.1 s | 10/10, 3.3 s |
| drafts, medium | 1/2, 27.1 s | 2/2, 248.2 s | 2/2, 21.5 s |
| drafts, large | 2/2, 61.8 s | 0/2, 304.9 s | 2/2, 43.8 s |
| context scenario (8,192 window) | 6/6, 7.4 s | 6/6, 16.2 s | not run |
| classifier with rules | 339/392, 3.0 s | 357/392, 14.4 s | not run |
| classifier, model alone | 334/392, 3.4 s | 341/392, 16.7 s, 2 dangerous rated safe | not run |

Thinking made 4.2 4 to 15 times slower and bought nothing in the delegation suites: not thinking, it matched 4.1 on the
tools at the same speed (a median of 3.2 s a request, p90 9.0 s, over 300 requests) and was the only run with every
draft right, at the cost of two `system_info` cases. Its classifier was the most accurate of the three with the rules
(91%), at 14 s a verdict, too slow for approvals, which the Core ML classifier decides. `granite4.1:8b` stays the
delegation default for now: `ollama.think` applies to every Ollama model, and turning it off would take thinking from
`gemma4:12b` and `qwen3.8:27b` too. Choosing thinking per model or per call was planned for 0.22.0
and shipped in it: `ollama.models.<name>.think`, `respond`'s `think`,
and no thinking for wisp's own calls ([ADR 0053](decisions/0053-the-models-thinking-shown.md), amended 2026-10-11).

### qwen3.8:27b re-measured, 2026-10-09

`system_info` and `edit_file` on `ollama:qwen3.8:27b` with every other Ollama model unloaded (22.3 GB free)
and the hybrid-layer sizing of ADR 0043's 2026-10-05 refinement in place: 16/16 and 30/30, 144 requests at
a median of 13.7 s (p90 25.1 s), the two suites taking 11 and 22 minutes against 8 and 25 on 2026-10-05.
The 40 to 70 s a request recorded on 2026-10-04 came from the classifier suite, where qwen3.8 thinks
before each verdict, not from its tool work; there was no slowdown. Its window stays at the 8,192 floor
here: its 17.7 GB of weights take most of the memory budget, and it rises above the floor only with about
41 GB free (`ollama.models.qwen3.8:27b.contextLength` can hold it to a size).

### The Falcon comparison, 2026-10-05

The two Falcon-H1 candidates through wisp's own MLX executor (`scripts/check eval compare`, not recorded),
after `wisp models enable` checked them: Falcon-H1R-7B passed the tool check, Falcon-H1-7B-Instruct did not
(it names tools it was not offered), so it ran as text only. H1R took about 4 h 15 min, Instruct about 6 h 50 min,
most of it the classifier's 784 verdicts.

| Model | `edit_file` | `system_info` | Schema | Drafts, small / medium / large | Classifier with rules | Context |
| --- | --- | --- | --- | --- | --- | --- |
| `mlx:Falcon-H1R-7B-4bit` | 22/30, 102 s a case | 14/16 | 4/6 | 6/10, 2/2, 0/2 | 287/392 (73%), p50 10.4 s | 6/6, 26.8 s a turn |
| `mlx:Falcon-H1-7B-Instruct-4bit` | 0/30 | 0/16 | 5/6 | 1/10, 1/2, 0/2 | 341/392 (87%), p50 16.2 s, p95 300 s | 0/6 (tools off) |

Neither earns a place: H1R trails `granite4.1:8b` on every suite at 4 to 15 times the time, and Instruct calls
no tools, writes poor commit subjects, and stalls up to five minutes on some classifier verdicts. Both were
disabled on 2026-10-06 (`models.disabled`), with `llama3.2:3b`, `ministral-3:14b`, `nomic-embed-text`, and
`deepseek-coder-v2`; `Falcon-H1-Tiny-Tool-Calling-90M` is kept for the tool-choice experiment. The run showed
hybrid models working end to end through wisp's MLX executor, tool calls included.

### MLX against Ollama, the same weights, 2026-10-06

`mlx:Qwen3-1.7B-4bit` through wisp's MLX executor against `ollama:qwen3:1.7b` (Q4_K_M), on the suites that showed a
gap, run with a copy of the script whose `EVAL_COMPARE_SUITES` named only `edit_file`, the schema replies, and the
drafts (not recorded). Before is the full comparison of the morning; after is the fix that leaves thinking to the
chat template and lets a schema reply think first ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), refined
2026-10-06, which has the probes behind it).

| Run | `edit_file` | Drafts, small / medium / large | Schema |
| --- | --- | --- | --- |
| MLX, before (thinking off) | 2/30, 1.3 s a case | 4/10, 0/2, 0/2 | 4/6 |
| MLX, after (the template's default: thinks) | 13/30, 14.3 s | 7/10 14.0 s, 1/2 30.4 s, 1/2 113.8 s | 5/6, 6.4 s |
| Ollama, morning (thinks by default) | 20/30, 12.0 s | 9/10, 1/2, 2/2 | 6/6 |
| Ollama, after-run (the same code) | 15/30, 12.6 s | 9/10 2.3 s, 1/2 11.6 s, 2/2 37.9 s | 5/6, 2.5 s |
| Ollama, `ollama.think: false` | 19/30, 1.5 s | 8/10, 2/2, 2/2 | 5/6 |
| MLX on the bridge (thinking off unless declared) | 6/30, 2.2 s; 24 made no `edit_file` call | not run | not run |

Ollama's two runs on the same code differ by five `edit_file` cases, so MLX after is within that spread; its drafts
are close on content and two to three times slower. Without thinking the MLX conversion of the 1.7B weights fails
the tool loop where Ollama's quantisation does not, on the very same prompt; the 4B model does not have that
weakness on MLX.

### edit_file's line rules, 2026-10-06

The two line-edit rules of [ADR 0024](decisions/0024-edit-file.md) (refined 2026-10-06: a line that lost its
indentation keeps it, and a stale number with `find` moves to the one line holding it) and the edited line shown in
the result, measured before and after with a copy of the script whose `EVAL_COMPARE_SUITES` named only the two
`edit_file` measurements (not recorded). Before is the code without the rules; `llama3.2:3b` ran with a scratch
`WISP_HOME` whose config did not disable it; `granite4.1:8b` was run after only, to check a strong model is not
harmed (28/30 on `edit_file.replace` on 2026-10-04).

| Model | `edit_file.replace` before | after | `edit_file.whitespace` before | after |
| --- | --- | --- | --- | --- |
| `ollama:qwen3:1.7b` | 16/30, 7.3 s a case | 19/30, 11.9 s | 9/12 | 11/12 |
| `mlx:Qwen3-1.7B-4bit` | 11/30, 15.1 s | 27/30, 13.4 s | 9/12 | 11/12 |
| `ollama:llama3.2:3b` | 3/30 | 1/30 | 5/12 | 3/12 |
| `ollama:granite4.1:8b` | not run | 27/30, 8.9 s | not run | 11/12 |

What failed, from each failing case's last call (`edit_file.replace`, then `edit_file.whitespace`):

| Model | Before | After |
| --- | --- | --- |
| `ollama:qwen3:1.7b` | indentation dropped 7 / 1; wrong line, off by one 1 / 1, further 6 / 0; the turn ended in an error 0 / 1 | wrong line, off by one 3, further 7, all without `find`; an error 1 / a `find`-only call 1 |
| `mlx:Qwen3-1.7B-4bit` | indentation dropped 10, two of them after several calls; wrong line with `find` 4; wrong content 1; "Session ended without producing a response" 4 / wrong whitespace sent 3 | that error 3 / 1 |
| `ollama:llama3.2:3b` | no call, the turn ending in an error 9 / 2 (the run's 11 errors all `line` sent as text, refused before the tool ran: "GeneratedContent does not contain Double"); neither `line` nor `find` 8 / 2; other 10 / 3 | no call, an error 20 / 5 (the run's 23 errors: 22 `line` as text, one Ollama timeout); neither 3 / 3; other 6 / 1 |
| `ollama:granite4.1:8b` | | `find` sent empty with a right `line` 3 / 1: an empty `find` is on no line, so nothing changed |

The rules removed every failure they were for: no dropped indentation and no stale number with `find` remain, and no
whitespace case was spoiled by the indentation rule. What is left is a wrong number without `find` (the Ollama
1.7B), which nothing can safely repair, and failures before the tool runs (`llama3.2:3b`'s text `line`, MLX's empty
sessions). Runs on the same code differ by up to five cases ("MLX against Ollama", above), so the Ollama 1.7B's
gain and `llama3.2:3b`'s loss are within that spread; MLX's 11 to 27 is not. granite's four failures predate the
rules: an empty `find` beside a right `line` has always changed nothing.

The first run, on 2026-10-04 with `llama3.2:3b` alone, took ten minutes, half of it the classifier's 392
verdicts twice; a larger model takes longer per case, so allow an hour or more for each 26B or 27B model. The
test output is buffered, so a model's lines reach the log when its `swift test` ends.

## Context checkpoint 2

```
WISP_EVAL_MODELS=system,ollama:granite4.1:8b scripts/check eval checkpoint
```

runs the second checkpoint of the layered-context design, whose plan, questions, and decision rules are
[proposals/2026-10-06-context-checkpoint-2.md](proposals/2026-10-06-context-checkpoint-2.md). It is a measurement
for design decisions, like `eval context`: the release's eval, `eval context`, and `eval compare` never run it
(`ContextCheckpointTests` runs only when `WISP_CHECKPOINT` names a part, which `eval checkpoint` sets). The cells,
the scenario, and the table's row are `ContextCheckpoint` and `ContextEval.sustained()` in `WispTestSupport`, tested in
the gate without a model.

| Variable | Default | What it sets |
| --- | --- | --- |
| `WISP_CHECKPOINT` | `all` | The parts, comma-separated: `grid` (target and headroom on the `sustained` scenario at the default budget), `half` (the 50% variants on `recalling`, under the guard), `memory` (`sustained` with and without `memory`), `assessment` (off, as built, and `restated`, every built-in tool offered), `switch` (a model switch mid-conversation) |
| `WISP_EVAL_MODELS` | `system` | The models every part but `switch` runs on, one after another |
| `WISP_CHECKPOINT_TARGETS` | `0.4,0.5,0.6` | The grid's targets |
| `WISP_CHECKPOINT_HEADROOMS` | `0,1,8` | The grid's headrooms, in turns; the grid is every target with every headroom |
| `WISP_CHECKPOINT_WINDOW` | `8192` | The window of Ollama and MLX models (the on-device model's is its own) |
| `WISP_CHECKPOINT_RUNS` | `1` | Runs of each cell |
| `WISP_CHECKPOINT_SWITCHES` | `system>ollama:granite4.1:8b>system;ollama:granite4.1:8b@32768>system` | Switch plans, `;` between plans, `>` between two or three models, `@N` for a model's window; the second model takes over at the return to the task (turn 16), the third at the first question (turn 30) |

The parts run as one test each, one at a time. Each cell prints its turns and report as the context eval does, then
a `checkpoint row`; the run ends with a table, a row per model and cell, saved as `eval-<date>-<time>.summary.txt`,
and every row's fields (the answers, the switches, the load) as `.checkpoint.tsv` beside the log. A cell the grid and
the memory part share (the default target and headroom, `t60-h8` since ADR 0057; `t50-h8` when the checkpoint ran)
runs once. The memory part's cell with `memory` turns it on explicitly, though it is off by default. Add `record` to
merge each run's measurement into `measurements.json`. The main pass took 3 hours 40 minutes on the two models with
the switches (2026-10-06), and gemma4:12b's two `memory` cells 40 minutes more.

### Results, 2026-10-06 to 2026-10-08

Run on this Mac without `record`, so nothing was merged into `measurements.json`; the logs and tables were kept
outside the repository. The decisions they led to are [ADR 0057](decisions/0057-context-defaults-from-checkpoint-2.md).
Answers are of 10 (`sustained`) or 7 (`recalling`); the main pass is one run a cell, the confirmation three, each
listed, then the mean.

The main pass (2026-10-06 21:54 to 2026-10-07 02:13, load average 1 to 3), `grid`, answers of 10:

| Model | t40-h0 | t40-h1 | t40-h8 | t50-h0 | t50-h1 | t50-h8 | t60-h0 | t60-h1 | t60-h8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `system` | 5 | 2 | 4 | 3 | 6 | 5 | 3 | 6 | 6 |
| `granite4.1:8b` | 6 | 6 | 7 | 7 | 8 | 7 | 8 | 7 | 6 |

The rest of the main pass, one run each:

| Part | Cell | `system` | `granite4.1:8b` | `gemma4:12b` |
| --- | --- | --- | --- | --- |
| `half` | stack (gaps between condensations) | 3/7 (3, 3) | 4/7 (2, 3) | |
| `half` | without `memory` (summary only) | 5/7 | 6/7 | |
| `half` | phase 2's fixed four turns | 3/7 | 6/7 | |
| `half` | dropping (gaps) | 0/7 (all 1) | 1/7 (all 1 but one) | |
| `memory` | with (`t50-h8`) | 5/10 | 7/10 | 7/10 |
| `memory` | `memory-off` | 4/10 | 4/10 | 10/10 |
| `assessment` | off | 4/10 | 6/10 | |
| `assessment` | `any` | 2/10 | 8/10 | |
| `assessment` | `restated` | 6/10 | 9/10 | |
| `switch` | `system>ollama:granite4.1:8b>system` | 6/10 | | |
| `switch` | `ollama:granite4.1:8b@32768>system` | | 5/10 | |

The confirmation, three runs (2026-10-08: `assessment` 09:09, `memory` on granite and gemma4 11:45, `grid` 14:24 to
18:09, `memory` on the on-device model 21:53 to 22:47; load average 1 to 5):

| Part | Cell | `system` | `granite4.1:8b` | `gemma4:12b` |
| --- | --- | --- | --- | --- |
| `memory` | with (`t50-h8`) | 4, 5, 4 (4.3) | 6, 9, 7 (7.3) | 8, 8, 8 (8.0) |
| `memory` | `memory-off` | 4, 5, 7 (5.3) | 8, 8, 8 (8.0) | 10, 8, 10 (9.3) |
| `grid` | `t50-h8` | 3, 7, 2 (4.0) | 7, 6, 8 (7.0) | |
| `grid` | `t50-h1` | 2, 6, 3 (3.7) | 8, 7, 5 (6.7) | |
| `grid` | `t60-h8` | 4, 4, 8 (5.3) | 9, 7, 7 (7.7) | |
| `grid` | `t60-h1` | 5, 5, 4 (4.7) | 7, 6, 8 (7.0) | |
| `assessment` | off | 4, 2, 1 (2.3) | 8, 7, 7 (7.3) | |
| `assessment` | `any` | 3, 2, 5 (3.3) | 7, 7, 5 (6.3) | |
| `assessment` | `restated` | 4, 3, 2 (3.0) | 6, 8, 9 (7.7) | |

Beside the scores: the detail questions with `memory` 0, 1, and 4 of 6 (on-device, granite, gemma4) and without it 1,
1, and 6; gemma4's 95th-percentile turn 188 to 358 s with `memory` and 27 to 190 s without; under `any` the `task`
answer wrong in 2 of 3 on-device runs and 3 of 3 on granite, with 8 to 23 task changes, and under `restated` right in
all six with 1 or 2; every default cell condensed at least once. Single on-device runs range from 1 to 8 of 10 on the
same cell, so read differences of an answer as noise unless three runs agree. ADR 0057 has the per-cell
condensations, floors, and times.

## Reading a measurement

```json
{ "task": "triage", "model": "system", "date": "2026-09-20", "passed": 7, "total": 7,
  "notes": "expected failures found across abridged swift build, swift test, cargo test, and pytest output, by test name or file:line" }
```

`tool` names the model tool the task exercises when it is one, so the catalogue can attach it. A task
with no measurement for the configured model has not been measured there; that is not the same as
failing.
