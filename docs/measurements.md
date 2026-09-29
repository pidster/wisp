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
| `classifier.system-model` | `ClassifierEvalTests`, the 123 labelled commands of `training/risk/dev.tsv` (`RiskEvalSet`), a dev set: choices have been made on it | the command rated at exactly its level by the on-device model alone; separately, no dangerous command below moderate is a hard requirement. Recorded with p50 and p95 latency per verdict |
| `classifier.system-model+rules` | the same set | the default classifier as the gate runs it, the rules beside the model, the higher level winning |
| `classifier.trained`, `classifier.trained+rules` | the same set | a classifier trained on device from the bundled examples, which never include an eval case, alone and beside the rules ([ADR 0038](decisions/0038-fast-specialised-classifiers.md)). On 2026-09-26, over 123: 103 and 100 at 0.04 and 0.06 ms, against the model's 110 and 108 at 1.3 to 2.3 s, and only the pairs with the rules held the hard requirement |
| `triage` | `TriageEvalTests`, abridged swift build, swift test, cargo test, and pytest output | an expected failure found, by test name or file:line |
| `summarise_diff` | `DiffSummaryEvalTests`, five small diffs | the expected flag (secret, deleted or disabled test) on the expected file, or no flag for an ordinary change, from the rules and the model together; every file must also get a summary line. The model alone scored 2 of 5 on 2026-09-21, which is why the rules exist |
| `redact.thorough` | `RedactionEvalTests`, a ticket, a service log, a meeting note, build output, a stack trace | every expected value (names, an account number, a user id, an address, a private hostname) replaced by the rules and the model together, and every phrase that must survive unchanged; the judge runs under wisp's own system prompt, as callers' passes do |
| `draft_change.commit` | `DraftEvalTests`, three size bands: five small diffs twice each, then real commits of this repository at 9 and 14 KB and at 30 and 52 KB, once each; per model with `WISP_EVAL_MODELS` | a commit subject naming the gist of the change (words chosen so a vague subject fails); each band is recorded with its `maxInputBytes` for routing ([ADR 0037](decisions/0037-routing-by-input-size.md)). On 2026-09-24 the system model scored 7/10, 2/2, 1/2 and `qwen3.8:27b` 10/10, 2/2, 2/2 |
| `system_info.topic` | `SystemInfoEvalTests`, eight plain questions about the Mac, twice each, with `run_command` also offered | a `system_info` call in the turn naming the expected topic (and port or process); three runs on 2026-09-24, with the process name required, scored 15, 16, and 16 of 16 |
| `chat.unclear` | `ChatEvalTests`, seven conversations whose last message asks for nothing (`test`, `hello`, `hmm`, `ok`, and the same after `test`) and one clear question, three times each, with every built-in tool offered and wisp's own prompt | a short reply with no tool call, no "output", and not the message said back; the clear question must still call `current_date`. The prompt's sentence about such messages took it from 7/24 to 24/24 on 2026-09-26, with `system_info.topic` at 16, 16, and 14 of 16 against 15, 14, and 14 without it |
| `context.dropping`, `context.dropping.window-8192`, `context.dropping.window-32768`, `context.dropping.window-sized` | `ContextEvalTests`, the [layered-context proposal](proposals/2026-09-29-layered-context.md)'s eval: one scripted conversation of 14 turns (a task and four facts planted, 13 file reads including a ten-file digression, one fact changed midway) then six questions, through today's dropping; on the on-device model, and on `ollama:granite4.1:8b` at a configured 8,192-token window, at 32,768 (nothing dropped, the ceiling), and at the window wisp sizes for it | a reply containing the expected phrase (the codename, the ticket number, the reviewer's preference, the CI state's current value, the first file read, the task). A baseline: the floor is only that every question was asked and scored. The notes carry the run's condensations, median tokens after a turn, and load average; `p50Milliseconds` and `p95Milliseconds` are time per turn |
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

runs `ModelEvalTests` on the configured model with `WISP_EVAL_RECORD` pointing at
`harness/Sources/WispCore/Resources/measurements.json`; each test merges its `Measurement` into
that file, replacing the previous one for the same task, model, and input size.

A task that routes by input size ([ADR 0037](decisions/0037-routing-by-input-size.md)) records one
measurement per size band, each with `maxInputBytes`, the largest input among its cases: the result is
evidence for inputs up to that size and no further. `WISP_EVAL_MODELS` (comma-separated model spellings,
such as `system,ollama:qwen3.8:27b`) measures each named model in turn, so a ladder's rungs all have
numbers; without it the eval measures the configured model only. A plain `scripts/check eval`, which
is what a release runs, asserts the floors and records nothing: the sets are small, a rerun re-rolls
the numbers (on 2026-09-22 two consecutive runs gave 5 and 6 of 6 for the same task), and the file
should change only when someone means it to. The file is embedded at build time
by the `EmbedSystemPrompt` plugin, so the numbers a binary reports are the numbers committed with it.
Commit the file with the change that moved the numbers, and say so in the message. The release
preflight runs the eval, so a release never ships with stale numbers.

The eval asserts only floors (half or three quarters recall, and the classifier's hard requirement);
everything else is reported and recorded. Run `WISP_MODEL_TESTS=1 swift test --filter ToolEvalTests`
in `harness/` for one suite.

## Reading a measurement

```json
{ "task": "triage", "model": "system", "date": "2026-09-20", "passed": 7, "total": 7,
  "notes": "expected failures found across abridged swift build, swift test, cargo test, and pytest output, by test name or file:line" }
```

`tool` names the model tool the task exercises when it is one, so the catalogue can attach it. A task
with no measurement for the configured model has not been measured there; that is not the same as
failing.
