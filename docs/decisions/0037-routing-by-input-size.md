# ADR 0037: Route a task to a model by the size of its input, from measurements

Date: 2026-09-24. Status: accepted.

## Context

`draft_change` showed the system model drafting small diffs acceptably and large ones badly: for a
22-file change it invented a point that was not in the diff, while `ollama:qwen3.8:27b` drafted it
well. Nothing in wisp noticed. Asking the small model how well it did is not a signal: a 4k-token model
is poorly calibrated about its own output, and the wrong draft came back as confidently as the right
ones. Checking outputs against inputs, sampling twice, or asking the operator would all work, but each
adds machinery; wisp is meant to stay compact. What is known before anything runs is the input's size,
and what the eval already records is how each model did.

## Decision

- **A measurement may carry `maxInputBytes`**, the largest input among its cases. A task that routes
  records one measurement per size band and model; the merge key includes the size, so the bands sit
  side by side in `measurements.json`. `WISP_EVAL_MODELS` measures each named model in one eval run.
- **A model's envelope** for a task is the largest band in the run of passing bands (80% or better)
  that starts at the smallest. A model that fails small inputs is never trusted with larger ones,
  however a larger band went: bands hold few cases, and a lucky two of two proves little.
- **`routing.ladder`** in the config lists models from least to most capable. For a routed task wisp
  measures the input, then takes the first rung whose envelope covers it, or the last rung when none
  does. The choice is recorded as `model.routed` with the reason, and returned as `model` and `routing`
  in the result. An explicit model from the caller always wins; an empty ladder turns routing off, which
  is the default; a rung that cannot open (Ollama not running) is passed over for the first, with the
  reason recorded.
- **The pilot routes `draft_change` and `wisp draft`**, every kind on the commit measurements, since
  summarising the diff is the costly shared step. Other tasks route once they have size bands in their
  evals.

## Consequences

- Measured on 2026-09-24 with `DraftEvalTests` over three bands (five small diffs twice each; two real
  commits of this repository at 9 and 14 KB; two at 30 and 52 KB):

  | Model | Small (≤ 481 B) | Medium (≤ 14 KB) | Large (≤ 52 KB) | Envelope |
  | --- | --- | --- | --- | --- |
  | `system` | 7/10 | 2/2 | 1/2 | none |
  | `ollama:qwen3.8:27b` | 10/10 | 2/2 | 2/2 | 52 KB |

  A first run with looser expected words scored the system model 10/10, 2/2, and 1/2, passing subjects
  such as "Cache installation instructions and config format in JSON" for a README change; the words now
  name each change's gist, and the system model falls below the bar even on small diffs. With a ladder of
  `system` then `qwen3.8:27b`, every draft on this Mac goes to `qwen3.8:27b`.
- Routing needs no judgement and costs nothing at run time; its quality is exactly the eval's. Bands of
  two cases are thin evidence; the contiguous-run rule keeps them from over-trusting, and widening them
  is how the envelope grows.
- A routed draft on a large model is slower (minutes for a 52 KB diff on `qwen3.8:27b`) but right.
- Tests without the model: the envelope rule including a failing small band, the ladder choice and its
  fallbacks, an explicit model, an unopenable rung, merging by size, the config, the audit record, and
  the shipped measurements' envelopes.

## Amendment, 2026-09-27: a default model per task

The thorough pass of `scan_secrets` and `redact` was measured on the secrets test set
([ADR 0031](0031-secret-scanning-and-redaction.md), second amendment of 2026-09-27). With the rules
beside it, the on-device model reached macro-F1 0.67 and `ollama:granite4.1:8b` 0.56. Without a
model named, the pass ran on `config.json`'s `model`. On this Mac that is granite, so the pass ran on
the worse of the two. Input size says nothing here, since every chunk is 4 KiB, so the ladder does not
apply.

**Decision.**
- **`routing.tasks` maps a task to the model for its model pass.** It applies when the caller names no
  model; an explicit `--model` or `model` still wins.
- **Wisp ships a measured default per task** (`ModelRouting.taskDefaults`), and `routing.tasks` overrides
  it. The one task today is `secrets`, the thorough pass of `scan`, `redact`, `scan_secrets`, and
  `redact`, and its default is `system`.
- **The choice is recorded.** Each routed pass writes a `model.routed` audit event with the reason:
  the measured default, or the configured model.
- **Only a thorough call routes.** A rules-only call never opens a model, so its model is left alone.
- **Settable from the CLI and chat.** `wisp config set routing.tasks.secrets <model>` and chat's `/config`
  set it.
