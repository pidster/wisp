# TODO: on-device task assessment, routing and audit

Date: 2026-09-19, updated 2026-10-04. Status: a living backlog. Items are ticked only where the code and a
measurement show them done; each track's progress note links the decisions that did it.

## Goal and scope

Evaluate on-device AI for four jobs: input classification and pre-processing, dynamic context assembly,
tool approval escalation classification, and local generation with tool execution. Select useful model
and task combinations based on measured speed and accuracy. A specialist can be useful without handling
every job.

This extends the [local-model evaluation design](local-model-evaluation.md). The
[installation record](local-model-installation.md) describes the existing Python MLX smoke checks.
Those checks do not establish Swift provider compatibility or workload quality.

This backlog does not change the [objective](objective.md), accepted ADRs or runtime behaviour, and does not
introduce remote generation. Explicit model selection and modular backends are implemented
([backends.md](backends.md), [ADR 0019](decisions/0019-model-backends.md)). The current work and the wider
backlog are listed in section 7.

## 1. Input classification and pre-processing

"Optimal" means matching the model type, capability and execution settings to the request's complexity,
urgency and nature. It does not mean always selecting the fastest or largest model.

**Progress.** wisp routes by what it can measure before anything runs. An assessment of each request
exists but stays off (below), and it chooses tools, not models:
- **By input size.** A task's measured size bands pick a model from `routing.ladder`
  ([ADR 0037](decisions/0037-routing-by-input-size.md)).
- **By task.** `routing.tasks` sets a default model per task, and wisp ships measured defaults, such as
  `secrets: system` (ADR 0037, amendment).
- **By memory.** An Ollama model's context window is sized from its shape and the Mac's free memory
  ([ADR 0043](decisions/0043-context-window-from-memory.md)).
- **A measured catalogue.** Every eval task records results per model
  ([ADR 0026](decisions/0026-task-catalogue.md), [measurements.md](measurements.md)).
- **The assessment per request**, built 2026-10-01 and off by default (`assessment.enabled`): rules, or one
  model call, choose the tools a request registers, the facts repeated beside it, and in chat the task. At
  the phase-6 checkpoint it scored lower on both models and cost 2 to 4 s a call
  ([ADR 0045](decisions/0045-layered-context.md)).

- [ ] Define a request profile covering intent, task type, modalities, complexity, urgency, requested
  reasoning effort, required capabilities, constraints and uncertainty.
- [ ] Distinguish explicit user preferences from inferred preferences. Preserve the original prompt and
  record any extracted or transformed input separately.
- [ ] Define complexity labels using reasoning depth, ambiguity and task dependencies. Permit selection of
  stronger reasoning, higher requested effort, or a larger model where measurements support it.
- [ ] Define urgency labels or time budgets. Prefer fast models or faster models with equivalent relevant
  capability when the request calls for speed.
- [ ] Define capability requirements for text generation, image analysis, extraction, coding, tool use and
  mixed requests. Do not infer capability from parameter count alone.
- [ ] Build a versioned model capability catalogue using measured quality, latency, memory, supported
  inputs, context limits and available execution settings. *Partly:* measured quality and latency per
  task (ADR 0026), declared capabilities per backend (ADR 0019), and context limits read or sized per
  model (ADR 0043). No version, and no execution settings.
- [ ] Define routing policy for conflicting preferences, uncertain assessments, unavailable models and
  requests no eligible local model can handle. Record the reason for each fallback or override.
  *Partly:* an explicit model always wins, a rung that cannot open is passed over, and each choice is
  audited as `model.routed` with its reason.
- [ ] Evaluate request assessment separately from model selection. Use an explicit user choice where
  feasible and make any inability to honour it visible.

## 2. Dynamic context assembly

**Progress.** Built and recorded in [ADR 0045](decisions/0045-layered-context.md) on 2026-10-01, from the
[layered-context proposal](proposals/2026-09-29-layered-context.md): a store that refers to the audit log;
a context composed for each request from the instructions, facts and a running summary, literal recent
turns with tool output as a reference after its turn, and the task; `memory` to recall; condensing to a
token target with headroom; and display decoupled from context. At the default budget the design kept
everything in view for 22 turns where dropping lost every early fact (6/7 on device and 7/7 on granite,
against 0/7 and 1/7).
- **Condensing works on the on-device model** since 2026-09-29. It counts the transcript and recognises
  the overflow message ([ADR 0025](decisions/0025-context-estimation.md), amendment).
- **The consequences were measured.** A planted fact was lost with the first condensation, and the model
  confidently misreported what came first ([context-management.md](context-management.md)).
- **The context can be inspected.** `/inspect context` saves the exact context, and every condensation
  saves the transcript before and after it; `/inspect context next|N|turns`, `wisp-tui`'s panel, and
  `wisp://threads/{thread_id}/context` show it at no model cost.

- [ ] Evaluate selection of relevant history, files, passages and tool results for the assessed request.
- [ ] Compare deterministic retrieval, embedding models, rerankers and generative models where applicable.
- [ ] Evaluate selection and compression separately. Retain source references, constraints, contradictory
  evidence and uncertainty in assembled context.
- [ ] Fit context to the selected model's actual tokenizer and budget, reserving space for tools and output.
  *Partly:* the window is known per model (framework, sized, or configured), and the on-device model's
  transcript is counted with its own tokenizer. Tool output stays bounded at 4 KiB in its own turn and is a
  reference after it, which answered question 9 instead of sizing it to the window (ADR 0045).
- [ ] Record which evidence was selected, omitted or compressed, and the context assembler's version.
  *Partly:* condensations save the context before and after, name both files in the audit, and record
  their steps; cuts, references, distillations, summaries, recalls, and assessments are audited
  (`context.*`).
- [ ] Measure evidence retention, irrelevant content, assembly latency, token reduction and downstream
  answer accuracy. Include cases where an omitted detail changes the correct answer. *Partly:* the
  proposal's eval, `ContextEvalTests` (now in `harness/Evals`), measures recall of planted and changed
  facts, order, and return to the task, for each phase and at the phase-6 checkpoint (ADR 0045).

## 3. Tool approval escalation classification

**Progress.** This track is largely done:
- **Fast specialised classifiers** judge each command beside the rules
  ([ADR 0038](decisions/0038-fast-specialised-classifiers.md)).
- **The shipped Core ML classifier is the default** ([ADR 0041](decisions/0041-shipped-classifier-is-the-default.md)).
- **Measured closely.** Five-fold cross-validation over 403 labelled dangerous commands rates 6 safe (1.5%,
  at most 2.9%) (ADR 0038, amendment).

- [x] Evaluate proposed tool requests for required human escalation, separately from request routing.
- [x] Preserve [ADR 0011](decisions/0011-risk-classifier-and-approval.md): the model can raise the rules'
  verdict but cannot lower it, bypass policy or weaken the sandbox.
- [ ] Define handling of uncertain, malformed and failed classifications. Test the resulting approval
  behaviour explicitly, including clients that cannot obtain approval. *Partly:* below 0.6 confidence, a
  verdict is raised to at least `moderate`, and a classifier that fails falls back to `moderate`, both
  tested. Clients that cannot show an approval are the paused escalations proposal
  ([2026-09-20-escalations.md](proposals/2026-09-20-escalations.md)).
- [x] Measure missed required escalations, unnecessary escalations and decision latency separately.
  Set acceptance criteria that give missed escalations greater weight. (Dangerous rated safe, safe
  commands that ask, and latency per verdict are recorded separately, and the measure exits 1 when a
  dangerous command is rated safe.)
- [ ] Include ambiguous commands, contextual risks and misleading text in labelled evaluation cases.
  *Partly:* real and drafted commands with look-alikes, reviewed adversarially. The frozen test set
  holds only 25 dangerous commands.
- [x] Link the assessment, policy verdict and human decision to the originating prompt and tool call
  (`classifier.verdict`, `policy.decision`, and `approval.decided` carry the turn and the call).

## 4. On-device generation and tool execution

**Progress:**
- **Evals.** On-device evals run with `scripts/check eval` and publish their results
  ([measurements.md](measurements.md)).
- **Ollama.** Ollama models drive the same tool loop through wisp's executor
  ([ADR 0016](decisions/0016-local-runtimes-through-an-executor.md)). Since 2026-09-29, a required text
  argument such as `system_info`'s `process`, when a model leaves it out, is filled empty instead of
  ending the turn.
- **Visibility.** Chat shows the gate's decisions, each turn's tokens, and a live working line. MCP
  callers get progress.

- [ ] Evaluate bounded text generation, evidence-based answers and complete tool interactions locally.
  *Partly:* the eval suites cover tool calls, schema output, drafting, triage, and redaction.
- [x] Verify model-specific chat templates, tool-call parsing, argument validation, tool results and
  conversation continuation through the intended Swift provider and packaged CLI (the on-device model
  through the framework; Ollama through wisp's executor, tested over a fake server and live).
- [ ] Keep model proposals distinct from Wisp's validated execution. Score actual completion and
  supporting evidence, not merely a plausible tool request or a claim of success.
- [ ] Measure end-to-end latency, first-attempt success, retries, unsupported claims and peak memory.
  Report policy denials, approval waits and execution failures separately. *Partly:* turn time and tokens
  per turn, `/stats`, and Ollama's memory at a sized window (ADR 0043).
- [ ] Verify offline operation and compare direct use, MCP replay and parent-harness delegation as
  described in the existing evaluation design.

## 5. Prompt-linked transcript and audit records

Audit events carry `id`, `session`, `turn` and an optional `call`. `Agent` records the prompt before
invoking the model, and the conversation's store links each entry to the audit events that recorded it,
saved with a transcript as `<name>.store` (since 2026-09-29). See [logging](logging.md),
[Agent](../harness/Sources/WispCore/Session/Agent.swift),
[AuditEvent](../harness/Sources/WispCore/Audit/AuditEvent.swift) and
[TranscriptStore](../harness/Sources/WispCore/Config/TranscriptStore.swift).

**Progress:**
- **`model.resolved`** records the model, its capabilities, and its window with why.
- **`model.routed`** records a routing choice with why.
- **`context.condensation`** names the saved context before and after.
- **`wisp logs --follow`** and `/audit sessions` let a person follow any session, MCP threads included.
- **Every event has an `id`**, and a store entry, an MCP `calls` item, and `memory`'s recall point to the
  event that holds the prompt, reply, or output; `session.start` names the sessions a resumed one came from
  (`carriedFrom`).

- [ ] Define stable prompt identity and its mapping to the transcript prompt entry. Support assessment
  before generation and failures that occur before a framework prompt entry exists. *Partly:* each store
  entry refers to its audit event by id, including a failed turn's entries.
- [ ] Link the request profile and routing decision to that prompt ID in the persisted transcript/audit
  representation. Choose the storage mechanism without assuming the framework transcript accepts custom
  entries or arbitrary metadata.
- [ ] Record task type, complexity, urgency, requested effort, capabilities, explicit preferences and
  uncertainty. Treat reported confidence as uncalibrated until evaluated.
- [ ] Record the selected model and exact revision, runtime, generation/reasoning settings, classifier
  identity, classifier instructions/schema version, routing-policy version, timing and a concise decision
  reason. A reason is a decision summary, not a request to retain hidden reasoning. *Partly:* model,
  backend, asset, window, the classifier version and its verdict's timing, and routing reasons. No exact
  model revision and no generation settings.
- [ ] Record context provenance, user overrides, unavailable candidates, fallbacks and later routing
  changes as linked events. Preserve the original assessment and decision.
- [ ] Append outcomes under the same prompt ID: elapsed time, completion status, retries, tool-call links
  and separately measured quality results. Include evaluator identity/version when quality is scored;
  an unscored result must not imply correct completion.
- [ ] Preserve correlation through streaming, retries, context condensation, transcript save/resume and
  concurrent MCP threads. Distinguish one logical prompt from its separate execution attempts.
- [ ] Define schema compatibility, audit-disabled behaviour and retention so saved records remain
  interpretable. Update `AuditEvent.Kind`, `docs/logging.md` and relevant transcript documentation.

## 6. Common model controls

The [model-controls proposal](model-controls.md) defines the draft contract for reasoning mode, effort,
native speed mode, separate performance preferences and reasoning output. These are still proposed
controls, not implemented settings. Ollama reports `thinking` for reasoning models such as
`qwen3.8:27b`, but wisp neither requests nor relays their reasoning.

- [ ] Describe supported controls and values per model/runtime/adapter combination, with provenance.
- [ ] Translate common controls in each backend and reject unsupported explicit requests before use.
- [ ] Keep reasoning generation separate from whether reasoning text is exposed to the caller.
- [ ] Expose supported native standard/fast modes as explicit controls and reject unsupported requests.
  Keep routing preferences separate; preserve explicit model, reasoning, capability, context, quality
  and locality constraints.
- [ ] Validate combinations with tools, schema output and streaming, rather than independent flags alone.
- [ ] Audit requested and resolved controls against the prompt/attempt, and evaluate their actual effects.

## 7. Current work and backlog (2026-10-04)

### Committed, not yet released (0.17.0)

`CHANGELOG.md`, "Unreleased", lists each change. In outline:
- **Permanent facts over MCP** ([ADR 0048](decisions/0048-permanent-facts-over-mcp.md)): `set_fact_scope`
  `permanent` files a request in `~/.wisp/pending` and posts a notification; the person keeps or drops the
  fact with `wisp facts keep|drop` or in `wisp-tui` (the `keep-facts` effect); `respond` counts the
  proposals waiting (`factsProposed`); the default policy refuses `wisp facts keep|drop` to the model.
- **MLX in the release** ([ADR 0047](decisions/0047-mlx-in-the-release.md)): built with the `MLX` trait,
  with `mlx.metallib` beside `wisp` in the formula's `libexec`, a `wisp doctor` `MLX` finding, and
  `scripts/check mlx-live` for the live test.
- **Smaller changes:** the commit in `--version` for builds that are not releases, a palette check in the
  gate, and `memory`'s `task` example dropped from its argument guide.

0.16.0 (2026-10-03) carried host effects over MCP
([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)) and `wisp watch --settle`; its section
of `CHANGELOG.md` has the detail.

### Planned next

The [roadmap](roadmap.md) has each release to 0.21.0; next, 0.18.0: `! <command>` in chat and the input
box, the tool glyph, and where the summary is shown.

### Open from the layered context

- the guard's 50% variants re-run, and the target and headroom tuned;
- the assessment, if reconsidered: a task that changes only when the request restates it;
- a specialised distiller, once reviewed pairs exist;
- D10's model switch evaluated;
- window sizing for Core AI and MLX, from their bundles' metadata (ADR 0043).

### Offered, not started

- a test for the singular form of `/tokens`.

### Carried over

- **Secrets:**
  - the gap between the drafted training data and third-party test data (85% against 32% of secrets
    found);
  - personal data in `redact`, which needs the model to name values within flagged lines;
  - the classifier's low confidence on `git push`, which is a candidate for training data.
- **Classifiers:**
  - growing the dangerous test set beyond 25;
  - wiring in the failures classifier, which beats `KnownFailures` on test;
  - new providers, such as embeddings or an external process.
- **From the [backlog](backlog.md):**
  - condensers that summarise a file, answer over several files, and extract fields;
  - reverse delegation through MCP sampling;
  - client roots;
  - per-chunk progress in the condensing tools;
  - bulk classification;
  - offline use;
  - the notification helper app;
  - Private Cloud Compute signing.
- **Open:** the inquiry verb of the [escalations proposal](proposals/2026-09-20-escalations.md); its
  approval part was settled by [ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md).

## Evaluation and completion criteria

- [ ] Adapt the existing workload cases into the four tracks, with separate development and held-out
  cases. Define expected results, latency budgets and accuracy thresholds before comparing candidates.
  *Partly:* the classifier tasks have train, dev, and frozen test sets (ADR 0038).
- [ ] Use deterministic baselines where they can solve the task. Compare model/settings combinations,
  including reasoning levels, and account for assessment and context-assembly overhead. *Partly:* rules
  baselines for risk, failures, log severity, and secrets (`wisp classifier baseline`), and exact
  condensers ahead of the model ([ADR 0039](decisions/0039-exact-condensers.md)).
- [ ] Report speed versus accuracy per workload. Measure cold/warm execution, short/long inputs, retries
  and fallbacks; include time to a correct result where correctness can be established.
- [ ] For recurrent/state-space candidates, test fact retention, corrections and continued state alongside
  memory use. Distinguish base-model limitations from architecture or runtime failures.
- [ ] Select initial candidates from the researched shortlist without declaring architecture or parameter
  count a winner in advance. Pin assets and runtimes before each comparison.
- [ ] Produce a suitability table identifying useful model/task/settings combinations, measured limits
  and fallback conditions for each track.
- [ ] Add model-independent tests for routing policy, identity correlation and audit persistence. Keep
  live-model evaluation separate from the unit-test gate, consistent with repository guidance.
  *Partly:* routing, sizing, and audit fields are tested without a model.
- [ ] Demonstrate that an auditor can trace a prompt through assessment, selection, context assembly,
  tool approvals, execution and outcome, including any changes to the original decision.
