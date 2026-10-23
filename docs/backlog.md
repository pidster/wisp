# Backlog

Work agreed but not started, in rough priority order, with what has shipped marked done and dated. Each
item becomes an ADR when it is picked up.

## Planned for the next releases

The releases planned next, and what each carries, are in [roadmap.md](roadmap.md). This page keeps the
agreed work that is not yet scheduled, and what has shipped, marked done and dated.

## Context

- Done 2026-10-01: layered context ([ADR 0045](decisions/0045-layered-context.md), the
  [proposal](proposals/2026-09-29-layered-context.md) phases 1 to 6). Each request is composed from a store
  that refers to the audit log: tool output as a reference after its turn, retyped output cut, facts
  (2026-09-30), the running summary (2026-09-30), the `memory` tool (2026-09-30), and condensing to a token
  target with headroom and its guard (2026-10-01). The per-request assessment is built and off. Open: `memory` on a
  second scenario ([context-management.md](context-management.md), "Not done yet"), and a specialised distiller
  ([roadmap.md](roadmap.md), "Not scheduled").
- Done 2026-10-09: context checkpoint 2 ([ADR 0057](decisions/0057-context-defaults-from-checkpoint-2.md)). The
  target and headroom tuned on a conversation that condenses at the default budget, the 50% variants re-measured
  under the guard, D10's model switch evaluated, and `memory` measured on and off. `memory` is off by default
  (`context.memory` turns it on), `context.target` is 0.6, and the assessment, still off, changes an inferred task
  only when a request restates one (`assessment.taskChanges: restated`).
- Done 2026-10-03: permanent facts over MCP ([ADR 0048](decisions/0048-permanent-facts-over-mcp.md)). A
  `wisp mcp` caller asks with `set_fact_scope` `permanent`, and the person keeps or drops the fact with
  `wisp facts keep|drop` or in `wisp-tui`. Settled 2026-10-12: a request has no time limit and outlives its thread
  and its server (ADR 0048, amended); the terminal-only answers were reviewed and kept
  ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md), "Review, 2026-10-12").
- Done 2026-10-12: the tool-output budget ([ADR 0050](decisions/0050-tool-output-budget-and-overflow.md)). Every
  tool result is bounded by an eighth of the model's window (4 to 64 KiB); what does not fit is kept whole in the
  conversation's output store (`~/.wisp/output/<session>/`, swept by age, `context.outputDays`) and reached through
  `memory` by page, filter, exact summary, or a condensing question; `inspect` lists a turn's calls and a repeated
  call is noted. Done 2026-10-12 too: chat's `/show` and `/last` and `wisp-tui`'s expanded view (Ctrl-O) show the
  stored whole, through a pager on a terminal and a page at a time in `wisp-tui` (ADR 0050, "The person's views").

## Policy

- Done 2026-09-19: each simple command in a line is checked and approved separately, remembered by
  program ([ADR 0015](decisions/0015-per-command-approval.md)).
- Done 2026-10-04: the sandbox's refusals checked against the writable roots, and a nested wisp agent denied to
  the model and to typed `!` commands ([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md)).
- Done 2026-10-12: loops and conditionals judged and remembered by the commands inside them, inline programs
  (`python3 -c`) at least moderate, `find -exec` judged, piping into an interpreter dangerous, and a line whose risk
  only the whole line shows asked once ([ADR 0015](decisions/0015-per-command-approval.md), amended 2026-10-11); the
  rules and deny patterns read a search pattern, an awk program, or printed text as data, not as a pipe, a
  deletion, or a write.
- Done 2026-10-12: project approvals whose folder is gone marked in `wisp approvals`, `/approvals`, and
  `wisp://approvals`, and removed by `wisp approvals clear --gone`.
- Done 2026-10-14: command time limits: `run_command`'s `timeoutSeconds` and `respond`'s `commandTimeoutSeconds`,
  clamped to the operator's `commandMaxTimeoutSeconds`, with the default raised to 120 s
  ([ADR 0063](decisions/0063-command-time-limits.md)).
- Done 2026-10-14: an approved run outside the sandbox, for the chores it refuses (`brew upgrade`, `cargo install`,
  `rustup update`): `run_command`'s `outsideSandbox`, asked of the person every time for that exact line and
  remembered by nothing, behind `commandPolicy.sandbox.allowOutsideSandbox`; and the person's own run outside it,
  typed after `!!` ([ADR 0064](decisions/0064-an-approved-run-outside-the-sandbox.md)). Done the same day: Homebrew's
  `not writable` lines read as the sandbox's refusal ([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md),
  amended 2026-10-14).

## Enabling other harnesses (see the objective)

wisp's offer to another harness is work done locally that the harness would otherwise do with its own
tokens on a remote model: reading, condensing, classifying, extracting, and answering over local data, so
the caller's model never ingests the raw material. Other harnesses already run commands locally; that is
not the differentiator. Items, in order of leverage:

- Done 2026-09-20: receipts. Every `respond` result carries `structuredContent.receipt`, the turn's tool
  calls, commands with exit status, denials, approvals, and errors, folded from the audit events
  ([ADR 0021](decisions/0021-receipts.md)). Token usage added 2026-10-09: the turn's input, output, cached,
  and reasoning tokens, where the runtime reports them ([mcp.md](mcp.md)).
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
- Done 2026-10-12: the verification pass ([ADR 0060](decisions/0060-a-verification-pass.md),
  [verification.md](verification.md)). Exact readers check the results a reply reports against the turn's complete
  call list from the audit log, on by default; an unsupported claim is shown as `unsupported:` and returned as
  `verification` by `respond`. The model step (`verification.mode: model`) is built and off by default: on the
  on-device model it flagged 6 of 14 honest replies; open until a more capable model is measured
  ([roadmap.md](roadmap.md), "Not scheduled").
- Done 2026-10-12: the eval sets of `edit_file`, `system_info`, and `draft_change` enlarged (110, 54, and 44 cases),
  with floors set from the suites' pooled history; the release runs a fixed subset, `WISP_EVAL_FULL=1` all of them
  ([measurements.md](measurements.md)).
- Done 2026-10-12: processes named at spawn ([ADR 0061](decisions/0061-process-names-set-at-spawn.md)):
  `scripts/wisp-mcp` starts `wisp mcp (CLIENT)` from `WISP_MCP_CLIENT`, `wisp-tui` its child as `wisp chat (tui)`.
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
- Done 2026-10-09: `edit_file`'s line edits forgive a line sent without its indentation and a stale line number
  beside `find`, without guessing, and an empty `find` beside `line` checks nothing
  ([ADR 0024](decisions/0024-edit-file.md), refined 2026-10-06).
- Done 2026-10-12: `edit_file` on CRLF, CR-only, and mixed-ending files: lines split on bytes as `read_file` numbers
  them, each line keeping its ending, and a guard refusing an edit that would change lines it does not name (ADR
  0024, refined 2026-10-12). Before, an edit of line 1 of a CRLF file replaced the whole file.
- Done 2026-10-12: the secret scanner's unquoted `assigned-secret` rule no longer reads prose as a credential
  assigned to a name ("per token: every …th layer", "per drafted token: 748.125 MiB" in the `756b178` eval fixture):
  after a word and a colon, the value must hold letters and digits and not be a measure (ADR 0031, amended
  2026-10-12).

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
`/audit sessions` and `/audit <id>`. Done 2026-09-30: each tool's output folded in the scrollback with
Ctrl-O for the last one whole, the model's context in a panel (Ctrl-T), facts in that panel, and the
`hello` line with notifications posted through the terminal ([ADR 0044](decisions/0044-host-effects.md)).
Done 2026-10-04: `! <command>` in chat, with `wisp-tui`'s command mode
([ADR 0049](decisions/0049-commands-typed-in-chat.md)); the input box inactive and holding keys while a turn
runs; and the running summary in a place of its own (`/inspect summary`, `wisp://threads/{id}/summary`).
Tables and links in replies are shown as typed.
Done 2026-10-12: Ctrl-C during a model's turn stops the turn and the command it started, in both front ends, and a
second Ctrl-C quits ([ADR 0049](decisions/0049-commands-typed-in-chat.md) and
[ADR 0029](decisions/0029-tui-front-end.md), amended 2026-10-11).
Done 2026-10-14: `wisp-tui`'s outside mode, a muted red input box for a line run outside the sandbox, entered with a
second `!` at the start in command mode and left one mode at a time with Backspace
([ADR 0064](decisions/0064-an-approved-run-outside-the-sandbox.md), amended 2026-10-14); its colours are a first
proposal, open to the operator's choice from renders.
Done 2026-10-15, in both front ends: `/think on|off|LEVEL` and the model's thinking in the status line, an item of
`wisp-tui`'s bar ([ADR 0053](decisions/0053-the-models-thinking-shown.md), amended 2026-10-15); the status line's
left half as `model (think) N% used · path vcs(branch)`, with git or Subversion found by its marker and read off the
prompt's path ([ADR 0029](decisions/0029-tui-front-end.md), amended 2026-10-15). Done 2026-10-22, for
0.29.0: the conversation as a pane of `wisp-tui`'s own, with long outputs folded, each element reachable from the
keyboard, and copying through OSC 52 ([ADR 0068](decisions/0068-the-conversation-in-a-pane.md)).

## Documentation

- Done 2026-10-14: the documentation site, https://wisp.pidster.com, an mdBook over `docs/` with guides first, the
  reference, then the internals and every decision record, checked in the gate by `scripts/check docs-links` and
  built by `scripts/check docs-site` ([ADR 0065](decisions/0065-documentation-site.md)).

## When wisp can be signed

Three things wait on a Developer ID or App Store signature rather than on code. Done 2026-10-22: the release can be
signed with a Developer ID and notarised ([ADR 0069](decisions/0069-signed-and-notarised-releases.md)), and is by
default from 0.30.1 ([ADR 0071](decisions/0071-signed-releases-by-default.md)); the first two below now wait on their
own work.

- **A notification helper app.** Done 2026-10-22, for 0.30.0, without signing: an ad hoc signed bundle may notify
  once the person allows it ([ADR 0070](decisions/0070-a-notification-helper.md)); a click brings the terminal
  forward, and action buttons ("Show" opening the audit) are not built. The plan as it stood: `Wisp Notifier.app`, a tiny agent bundle (`LSUIElement`) in the
  formula's `libexec`, posting through `UserNotifications` instead of `osascript`
  ([ADR 0030](decisions/0030-notifications.md)). Gains: banners as "Wisp" with its own icon and its
  own row in Notification settings, and action buttons ("Show" opening the audit). Done 2026-09-30
  without signing ([ADR 0044](decisions/0044-host-effects.md)): banners come from the terminal (its
  notification sequence in Ghostty, iTerm2, WezTerm, and kitty, or `display notification` sent to the
  terminal app), so they carry its name and icon and a click returns to it; Script Editor remains only
  as the last route. `wisp notify` and the `notify` tool launch the helper
  when it is installed and authorised, and fall back to `osascript` otherwise. The open fact to settle
  first: whether macOS grants notification authorisation to the bundle as shipped; signing removes
  that doubt.
- **A DMG, with the package declaring its layout.** Scheduled for 0.31.0 with `wisp update`
  ([roadmap.md](roadmap.md)). An app bundle in a disk image, signed and notarised,
  beside the Homebrew formula. Its layout differs from the formula's: `wisp` in `Contents/MacOS` or
  `Contents/Helpers`, `mlx.metallib` and other resources in `Contents/Resources`. Today wisp finds its
  parts by searching from its own real path: `wisp-tui` beside it or in a `bin` beside its folder
  (0.18.1, after 0.17.0's move of `wisp` into `libexec` sent `wisp chat` to the plain chat without a
  word), and the MLX library beside it ([ADR 0047](decisions/0047-mlx-in-the-release.md)). Each new
  layout would need a code change and a release. Instead, each package declares where its parts are,
  relative to `wisp`, at build time: the app's `Info.plist`, or a small manifest in the formula's
  `libexec`. The search stays as the fallback for a build directory, and a `WISP_TUI` variable, like
  `WISP_BIN`, overrides for an odd set-up. `wisp doctor` checks every part the package declares, which
  would have caught 0.17.0's regression before release. Not a `config.json` setting: the layout is a
  fact of the package, not a choice for the person (the operator, 2026-10-04).
- **Private Cloud Compute.** The `com.apple.developer.private-cloud-compute` entitlement is granted to
  App Store apps only ([backends.md](backends.md), "Private Cloud Compute"); researched on 2026-10-23, with the
  operator's steps and a probe, in [roadmap.md](roadmap.md), "Later: Private Cloud Compute".

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
- Done 2026-10-04: MLX on a par with Ollama. MLX models run through wisp's own executor, with the window sized
  from the model and memory, exact token counts, usage, and each thread's processed prefix reused; Core AI reports
  its bundle's window; `wisp models pull` fetches `mlx-community` models into the Hugging Face cache, reusing what
  Hugging Face's tools already fetched, after asking ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)).
  Measured against Ollama for `Qwen3-1.7B-4bit` in 0.20.0; the rest of ADR 0052's list is not yet scheduled
  ([roadmap.md](roadmap.md), "Not scheduled").
- Done 2026-10-04: a reasoning model's thinking shown, counted, audited, and never sent back to the model, and
  `ollama.think` ([ADR 0053](decisions/0053-the-models-thinking-shown.md)).
- Done 2026-10-04: models enabled and disabled, `wisp models` as a table, an MLX model's capabilities checked on
  the model when it is enabled, and chat falling back to `system` when its model is unavailable
  ([ADR 0056](decisions/0056-models-enabled-and-disabled.md)).
- Done 2026-10-09: windows sized for models Ollama reports per layer (gemma4) and for hybrid attention and
  recurrent models (`qwen3.8`, Falcon-H1), refining [ADR 0043](decisions/0043-context-window-from-memory.md); MLX
  measured against Ollama on the same weights and the gap closed by leaving thinking to the chat template, with
  MLX's thinking shown and `mlx.think` ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md),
  [ADR 0053](decisions/0053-the-models-thinking-shown.md), refined); MLX tool calls as a JSON array and ChatML's end
  of turn read; Mistral's text tool calls read from Ollama replies; and the local-model and Falcon comparisons, which
  kept `granite4.1:8b` as the delegation default ([measurements.md](measurements.md#comparing-models)).
- Done 2026-10-09: llama.cpp and LM Studio as backends through a shared executor for OpenAI-compatible servers
  ([ADR 0058](decisions/0058-a-shared-http-executor.md); see "Model backends, deferred"); a context window for one
  model (`ollama.models.<name>.contextLength`, `mlx.models.<name>.contextLength`); `wisp models pull` resuming a
  file cut off part-way and seeding the Hugging Face cache from a real directory, and Core AI's listing following
  links ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-09); and `qwen3.8:27b`
  re-measured, with no slowdown in tool work ([measurements.md](measurements.md)).
- Done 2026-10-12: one set of model actions for the person and the model
  ([ADR 0059](decisions/0059-one-set-of-model-actions.md)): `ModelActions` behind `wisp models`, `/models`, and
  `/model`; `/models pull`, `trust`, and `cancel` in chat and `wisp-tui`, with the picker's pull row; and a `models`
  tool for the model, off by default (`tools.models`), whose every change asks the person.
- Done 2026-10-12: thinking chosen per model (`<runtime>.models.<name>.think`) and per call: wisp's own side calls
  send `think: false`, and MCP `respond` takes `think` when a thread starts
  ([ADR 0053](decisions/0053-the-models-thinking-shown.md), amended 2026-10-11).
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
  Growing the frozen test set from real use: done 2026-10-12, 13 rows from the audit log confirmed by the
  operator, 25 dangerous commands to 29 (ADR 0038, amendment). Open: more, as use adds them; 29 still bounds
  a dangerous command rated safe only loosely.
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

Candidates recorded on 2026-09-20 with the MLX and Core AI work, not implemented: ONNX Runtime; PyTorch and
Hugging Face Transformers; vLLM. llama.cpp and LM Studio were built on 2026-10-09 through a shared HTTP executor
with a dialect per runtime ([ADR 0058](decisions/0058-a-shared-http-executor.md)); vLLM serves the same API, so it
is most of the way there. Still to do for those two: a check against a real `llama-server` and LM Studio, neither
of which was on this Mac when they were built. Embeddings, reranking, and other
non-conversational models are not `LanguageModel`s and need task-specific interfaces (an `embed` tool, a
`rerank` tool) rather than a backend; that is a separate design. The MLX packaging chores are done
(2026-10-03, [ADR 0047](decisions/0047-mlx-in-the-release.md)): the release carries `mlx.metallib` beside
the binary, in the formula's `libexec`, and `scripts/check mlx-live` places it beside the test bundle so
the live test runs.

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
  `proposals/2026-09-20-escalations.md`. Its approval part, approval for clients that do not render
  elicitation (mobile), paused since [ADR 0014](decisions/0014-persisted-approvals.md), was resolved on
  2026-10-02 by [ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md): through another face,
  not through the conversation. The inquiry verb: done 2026-10-12 for 0.24.0
  ([ADR 0062](decisions/0062-the-inquiry-verb.md), [tools/ask.md](tools/ask.md)): the `ask` tool, off by
  default, answered in chat, `wisp-tui`, and through `wisp questions` under `wisp mcp`, where the turn parks.
  Open: the operator's hand test of the client's question form (D8), after which `inquiry.elicitation` may default
  on ([roadmap.md](roadmap.md), "Not scheduled").
- **Approval banners when the client's dialog works.** Done 2026-10-12 for 0.24.0: the banner is posted only once
  the client's dialog has gone unanswered for `approval.bannerDelaySeconds` (default 10), and not at all when it is
  answered sooner ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md), amendment of 2026-10-12).
- **Waiting MCP requests in plain chat.** Done 2026-10-12 for 0.24.0: plain `wisp chat` notes commands, facts,
  and questions waiting in `wisp mcp` servers before its prompt, and answers them with `/approvals
  approve|deny`, `/facts keep|drop`, and `/questions answer|decline` when its input is a terminal
  ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md), note of 2026-10-12).
