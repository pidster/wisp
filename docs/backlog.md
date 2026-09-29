# Backlog

Work agreed but not started, in rough priority order. Each item becomes an ADR when it is picked up.

## Policy

- Done 2026-09-19: each simple command in a line is checked and approved separately, remembered by
  program ([ADR 0015](decisions/0015-per-command-approval.md)).

## Enabling other harnesses (see the objective)

wisp's offer to another harness is work done locally that the harness would otherwise do with its own
tokens on a remote model: reading, condensing, classifying, extracting, and answering over local data, so
the caller's model never ingests the raw material. Other harnesses already run commands locally; that is
not the differentiator. Items, in order of leverage:

- Done 2026-09-20: receipts. Every `respond` result carries `structuredContent.receipt`, the turn's tool
  calls, commands with exit status, denials, approvals, and errors, folded from the audit events
  ([ADR 0021](decisions/0021-receipts.md)). Open: token usage, once wisp records what a runtime reports
  (see "Context estimation from the runtime").
- Done 2026-09-20: structured output. `respond` and the CLI (`--schema`) take a JSON Schema and return
  JSON of that shape through guided generation ([ADR 0022](decisions/0022-structured-output.md)).
- **Condensing tools.** Purpose-built MCP tools that keep raw content on the device and return small
  results ([ADR 0023](decisions/0023-condensing-tools.md)). Done 2026-09-20: `triage`, build or test
  output into a failure list. Done 2026-09-21: `summarise_diff`, a diff into per-file lines and review
  flags. Done 2026-09-23: `scan_secrets` and `redact` ([ADR 0031](decisions/0031-secret-scanning-and-redaction.md));
  `condense_log` and `json_shape`, deterministic ([ADR 0032](decisions/0032-log-and-json-condensers.md)).
  Done 2026-09-26: `dependency_audit`, `flaky_tests`, and `hot_paths`, deterministic, and an exact
  pre-pass in `triage` for known failure formats, which read all four eval fixtures without the model
  ([ADR 0039](decisions/0039-exact-condensers.md)). Next: summarise a file, answer a question over a set
  of files, extract fields to a schema.
- Done 2026-09-20: a measured task catalogue. `scripts/check eval` records a `Measurement` per task
  into an embedded resource; the tool catalogue and `wisp://measurements` publish them
  ([ADR 0026](decisions/0026-task-catalogue.md), [measurements.md](measurements.md)).
- **Reverse delegation through MCP sampling.** When the on-device model is stuck on a sub-step, ask the
  calling harness's model through the protocol, with data leaving the device only for that step and only
  with approval.
- **Roots.** Use the client's declared roots as the sandbox's writable root. Progress, done
  2026-09-29: a caller that sends a `progressToken` gets each line chat would show as a progress
  notification (`mcp.md`, "Progress"). Open there: per-chunk progress in the condensing tools' model pass.

## Use cases chosen for later

Picked on 2026-09-23 alongside secret scanning, the condensers, watch mode, and `system_info`, and left
for after them:

- **Bulk classification.** Label hundreds of commits, issues, or log lines into categories with
  structured output (ADR 0022): too cheap a job for a remote model, and measurable with the eval harness.
- Done 2026-09-24: **git chores.** `draft_change` and `wisp draft`: commit messages, PR descriptions,
  and changelog lines from a diff ([ADR 0035](decisions/0035-change-drafts.md)).
- **Offline work.** wisp as the agent when there is no network: on a plane, or on a network that cannot
  reach a remote model. Mostly a matter of documenting and testing what already works without one.

## Tools

- Done 2026-09-24: custom tools, command templates declared in `~/.wisp/config.json`, and
  `tools.disabled` for built-ins ([ADR 0036](decisions/0036-custom-tools.md)). Later, by decision:
  tools from other MCP servers.

## Terminal front end

Accepted 2026-09-22 ([ADR 0029](decisions/0029-tui-front-end.md)). Input history shipped 2026-09-23
(Up and Down recall, `/history` in chat). Line editing shipped 2026-09-24: a cursor, word and line
motions, readline's deletions, bracketed paste, and Alt-Enter for a newline. The input grows to six rows
for a multi-line message, done 2026-09-25. The `turn` event and the rendered `text` on
events, done 2026-09-25 (ADR 0029, amendment), a bordered approval dialog with the reasons inside it,
and Markdown rendering of replies as they are committed, the same day. Done 2026-09-26: `/config` from
chat with a picker for choices and Tab completion ([ADR 0040](decisions/0040-config-from-chat.md)).
Done 2026-09-26 too: `/config` as YAML and `/config get`; `/status`, `/approvals` (with `revoke`), and
`/audit` in place of `/inspect`, kept as an alias, with Tab completing them and approval ids; and sent
lines styled in the scrollback like the input box. Done 2026-09-29, in both front ends: the gate's
decision for each command, each turn's time and tokens, a live line for what the turn is doing, and
`/audit sessions` and `/audit <id>`. Nothing further is planned for the front end; tables and links in
replies are shown as typed.

## When wisp can be signed

Two things wait on a Developer ID or App Store signature rather than on code.

- **A notification helper app.** `Wisp Notifier.app`, a tiny agent bundle (`LSUIElement`) in the
  formula's `libexec`, posting through `UserNotifications` instead of `osascript`
  ([ADR 0030](decisions/0030-notifications.md)). Gains: banners as "Wisp" with its own icon and its
  own row in Notification settings, action buttons and click-through ("Show" opening the audit or the
  terminal), and no Script Editor attribution. `wisp notify` and the `notify` tool launch the helper
  when it is installed and authorised, and fall back to `osascript` otherwise. The open fact to settle
  first: whether macOS grants notification authorisation to the bundle as shipped; signing removes
  that doubt.
- **Private Cloud Compute.** The `com.apple.developer.private-cloud-compute` entitlement is granted to
  signed App Store apps only ([backends.md](backends.md), "Private Cloud Compute").

## Models

- Done 2026-09-24: routing by input size. A task with measured size bands picks the first model on the
  configured `routing.ladder` trusted with an input that large; piloted on `draft_change`
  ([ADR 0037](decisions/0037-routing-by-input-size.md)). Next: size bands for `triage` and the redaction
  pass, and more cases per band.
- Done 2026-09-28: a default model per task. `routing.tasks` names the model for a task's model pass;
  `secrets` defaults to `system`, measured best for it (ADR 0037, amendment).

- Done 2026-09-19: `ollama:<name>` models through a wisp-supplied executor
  ([ADR 0016](decisions/0016-local-runtimes-through-an-executor.md)).
- Done 2026-09-20: a backend registry with declared capabilities, and MLX Swift and Core AI as backends
  ([ADR 0019](decisions/0019-model-backends.md)); a Core ML approval-risk classifier behind a versioned
  contract ([ADR 0020](decisions/0020-coreml-risk-classifier.md)).
- Done 2026-09-20: context estimation from the runtime. `Agent` condenses ahead of a known window from
  the usage every reply reports; Ollama is asked for an explicit `contextLength`
  ([ADR 0025](decisions/0025-context-estimation.md)).
- Done 2026-09-20: agent tests without the model. `ScriptedModel` drives `Agent`, the tool loop,
  `WispServer` over a real client and in its unit tests (the fake thread is gone), and the whole
  `wisp chat` loop, which moved into `WispCore` as `ChatLoop` with injected input and output.

## Classifiers

Accepted 2026-09-25 ([ADR 0038](decisions/0038-fast-specialised-classifiers.md)): classifiers are
tasks served by fast, specialised models, measured for speed as well as accuracy. Done the same day:
`wisp classifier train` (Create ML, on device, from the bundled examples), `wisp classifier measure`,
contract 2, and latency in every classifier measurement. Next, in order:

- Done 2026-09-26: `wisp classifier train --from-audit`, the eval set widened to 123 commands, and
  three rule gaps closed (ADR 0038, amendment).
- Done 2026-09-26: classifier versions. Each release ships a fixed default, `risk@X.Y.Z-default`, used
  by `approval.classifier: coreml` when no model is named; `wisp classifier train` adds
  `risk@X.Y.Z-local.<n>` and never overwrites one; `list`, `use`, and `remove` manage them. Training is
  deterministic and never uses `held-out.tsv` or an `--exclude` set (ADR 0038, amendments).
- Done 2026-09-26: train, dev, and test sets for risk, secrets, failures, and log severity under
  `training/`, kept apart by family, with frozen test sets of real data; the shipped risk default is
  trained from `training/risk/train.tsv`, drafted and real commands. The rules know a short list of
  read-only commands, which skip the model, and rate printing a credential dangerous (ADR 0038,
  amendments).
- ~~**A trained classifier good enough to be the default.**~~ Done 2026-09-26 (ADR 0041). On the 996
  real test commands, the shipped default, trained from drafted and real commands, rates 817 exactly
  beside the rules (`system-model`: 664) at under a millisecond a command, and became
  `approval.classifier`'s default. It rates four of the 25 dangerous commands safe (`system-model`:
  one), three of them undecidable from the text.
- Done 2026-09-26: dangerous commands measured closely. Instead of a new dangerous-only test slice,
  five-fold cross-validation over train and dev scores all 403 labelled dangerous commands with the
  gate's combination; after closing the rule gaps it found, 6 are rated safe (1.5%, at most 2.9% at 95%
  confidence), all credential reads a regex cannot tell from safe look-alikes (ADR 0038, amendment).
  Open: the frozen test set still holds only 25 dangerous commands; growing it from dangerous commands
  the gate sees in real use, confirmed before they join, or from a source the operator picks.
- **Other providers.** Embedding nearest-neighbour over labelled examples (`NLEmbedding` or an Ollama
  embedding model), and an external process speaking JSON Lines, like the binaries in `tools/`.
- **Other tasks.** Secret and personal-data detection for `redact`, log-line categories for
  `condense_log`, failure kinds for `triage`, and the bulk classification chosen for later. Their
  training sets exist (above); on test a trained failures classifier beats `KnownFailures`, and
  `LogDigest`'s keywords beat a trained log-severity classifier. None is wired in yet. For secrets,
  done 2026-09-27: the rules were measured and widened instead
  ([ADR 0031](decisions/0031-secret-scanning-and-redaction.md), amendment). Open there: the gap
  between train (85% of secrets found) and third-party test data (32%). Personal data, done
  2026-09-28: a personal-only classifier beside the rules in `scan_secrets` finds 62% of personal test
  lines, against 12% for the rules alone ([ADR 0042](decisions/0042-personal-data-classifier.md)).
  Open: using it in `redact`, where it would have to point the model at the flagged lines, since it
  cannot name a value.

## Model backends, deferred

Candidates recorded on 2026-09-20 with the MLX and Core AI work, not implemented: llama.cpp; LM Studio
(`llmster`); ONNX Runtime; PyTorch and Hugging Face Transformers; vLLM. Several serve an OpenAI-compatible
HTTP API, so the Ollama executor's transcript-to-chat mapping is most of a shared HTTP executor for them,
parameterised by base URL, auth, and the request dialect. Embeddings, reranking, and other
non-conversational models are not `LanguageModel`s and need task-specific interfaces (an `embed` tool, a
`rerank` tool) rather than a backend; that is a separate design. Packaging chores, wanted only when
someone asks for MLX from the tap: shipping MLX in the Homebrew release, which means carrying
`mlx-swift_Cmlx.bundle` beside the binary (libexec plus a symlink, or a bundle-aware formula); and making
the MLX live test find the Metal library under the test runner.

## Upstream

- Report to `modelcontextprotocol/swift-sdk`: `Client.Capabilities.experimental` is `[String: String]?`
  (`Sources/MCP/Client/Client.swift:128`, still so on main at `a0ae212`) while the specification allows
  object values; Codex sends `{"codex/auth-change": {}}` and the server fails `initialize` with
  `-32603`. wisp works around it in `CompatibilityTransport`; drop the workaround when the SDK
  changes the type.

## Open design

- **Escalations.** Approval and inquiry as distinct verbs, delivered over more channels than MCP
  elicitation (the harness's own question dialog, a terminal, a file, a webhook), so an operator who is
  another agent, or absent, still gets a bounded, audited answer. Proposal written 2026-09-20 at
  `proposals/2026-09-20-escalations.md`; awaiting review before an ADR. It subsumes the earlier question of
  approval for clients that do not render elicitation (mobile), paused since
  [ADR 0014](decisions/0014-persisted-approvals.md).
