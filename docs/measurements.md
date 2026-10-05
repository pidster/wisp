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
| `draft_change.commit` | `DraftEvalTests`, three size bands: five small diffs twice each, then real commits of this repository at 9 and 14 KB and at 30 and 52 KB, once each | a commit subject naming the gist of the change (words chosen so a vague subject fails); each band is recorded with its `maxInputBytes` for routing ([ADR 0037](decisions/0037-routing-by-input-size.md)). On 2026-09-24 the system model scored 7/10, 2/2, 1/2 and `qwen3.8:27b` 10/10, 2/2, 2/2 |
| `system_info.topic` | `SystemInfoEvalTests`, eight plain questions about the Mac, twice each, with `run_command` also offered | a `system_info` call in the turn naming the expected topic (and port or process); three runs on 2026-09-24, with the process name required, scored 15, 16, and 16 of 16 |
| `chat.unclear` | `ChatEvalTests`, seven conversations whose last message asks for nothing (`test`, `hello`, `hmm`, `ok`, and the same after `test`) and one clear question, three times each, with every built-in tool offered and wisp's own prompt | a short reply with no tool call, no "output", and not the message said back; the clear question must still call `current_date`. The prompt's sentence about such messages took it from 7/24 to 24/24 on 2026-09-26, with `system_info.topic` at 16, 16, and 14 of 16 against 15, 14, and 14 without it |
| `context.dropping`, `context.dropping.window-8192`, `context.dropping.window-32768`, `context.dropping.window-sized` | `ContextEvalTests`, the [layered-context proposal](proposals/2026-09-29-layered-context.md)'s eval: one scripted conversation of 14 turns (a task and four facts planted, 13 file reads including a ten-file digression, one fact changed midway) then six questions, through today's dropping; on the on-device model, and on `ollama:granite4.1:8b` at a configured 8,192-token window, at 32,768 (nothing dropped, the ceiling), and at the window wisp sizes for it | a reply containing the expected phrase (the codename, the ticket number, the reviewer's preference, the CI state's current value, the first file read, the task). A baseline: the floor is only that every question was asked and scored. The notes carry the run's condensations, median tokens after a turn, and load average; `p50Milliseconds` and `p95Milliseconds` are time per turn |
| `context.dropping.recalling[…]`, `context.memory-target.recalling[…]`, `context.memory.recalling[…].budget-50`, `context.summary-target.recalling[…].budget-50`, `context.assessing[-task\|-all]-target.recalling[…].budget-50.all-tools` | `ContextEvalTests`, the layered-context design's checkpoint ([ADR 0045](decisions/0045-layered-context.md)): the `recalling` scenario (15 turns, then seven questions) at a window of 8,192, through dropping, the whole design (`memory-target`), phase 2's fixed four turns (`memory`), the design without `memory` (`summary-target`), and the assessment per request in its three tool sets; `[…]` is `.window-8192` for granite, `.budget-50` for half the window, and `.all-tools` for every built-in tool offered | a reply containing the expected phrase, as above, plus a detail of the first file read that no fact or summary carries. The notes carry the condensations, the fill after condensing and the turns between condensations, the distillations' times, the `memory` calls, the median tokens, and the load average |
| `edit_file.replace` | `ToolEvalTests`, ten small files | after read_file then edit_file replace by line number, the file is exactly as intended |
| `respond.schema` | `ToolEvalTests`, six code snippets | the schema-shaped reply parses and names the language |

Classifier measurements also carry `p50Milliseconds` and `p95Milliseconds`, the latency per verdict,
since a classifier runs on every command and speed is half of what makes one fit
([ADR 0038](decisions/0038-fast-specialised-classifiers.md)); `wisp classifier measure` reports the same
for any classifier over any labelled file.

The sets are small on purpose: they prove the pipeline and catch regressions. Widen a set when the
model gets a case wrong in practice, keeping cases that do not resemble the prompt's own examples.

## How to run and record

```
scripts/check eval record
```

runs the evaluations (the `ModelEvalTests` target of the `harness/Evals` package) on the configured model with `WISP_EVAL_RECORD` pointing at
`harness/Sources/WispCore/Resources/measurements.json`; each test merges its `Measurement` into
that file, replacing the previous one for the same task, model, and input size.

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

The eval asserts only floors (half or three quarters recall, and the classifier's hard requirement);
everything else is reported and recorded. Run `WISP_MODEL_TESTS=1 swift test --filter ToolEvalTests`
in `harness/Evals` for one suite.

Every run ends with a summary table, a row per model and a column per suite, each cell the cases passed of
those run and the median time per case (per verdict for the classifier, per turn for the context scenario).
`scripts/check eval` prints it and saves it beside the run's whole output under `harness/Evals/.build/evals`
(`eval-<date>-<time>.log` and `.summary.txt`). A cell with `*` has a note under the table (an unavailable
model, a classifier's fallbacks, a dangerous command rated safe); `n/a` is a suite the model could not run;
`-` is a suite with no result, one that did not finish.

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
  whole default stack (memory, facts, the summary, references, condensing to the target), at a window of 8,192
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
  the context scenario uses the defaults apart from its window.
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
own call format, which its Ollama template leaves as text. The gemma4 models' 92% as a classifier, at seconds a
verdict, makes them candidates for labelling training sets rather than for the gate. `qwen3.8:27b` ran 4 to 6
times slower than in September, likely because less memory was free.

The first run, on 2026-10-04 with `llama3.2:3b` alone, took ten minutes, half of it the classifier's 392
verdicts twice; a larger model takes longer per case, so allow an hour or more for each 26B or 27B model. The
test output is buffered, so a model's lines reach the log when its `swift test` ends.

## Reading a measurement

```json
{ "task": "triage", "model": "system", "date": "2026-09-20", "passed": 7, "total": 7,
  "notes": "expected failures found across abridged swift build, swift test, cargo test, and pytest output, by test name or file:line" }
```

`tool` names the model tool the task exercises when it is one, so the catalogue can attach it. A task
with no measurement for the configured model has not been measured there; that is not the same as
failing.
