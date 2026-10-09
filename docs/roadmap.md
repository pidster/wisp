# Roadmap

The releases planned from 0.20.0 to 0.23.0, agreed with the operator on 2026-10-01 (0.16.0, the first, 0.17.0,
0.18.x, and 0.19.0 have shipped; 0.20.0 is the release being made). Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning wait for 0.20.0, which is given
to them (the operator, 2026-10-02): no release before it runs an eval to decide or tune anything. Each
release's preflight still runs the eval's floors, as a guard against regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.20.0 | Context checkpoint 2: analysis, evals, and tuning (run and decided, ADR 0057) | The assessment reconsidered (built and decided); MLX against Ollama (measured for Qwen3-1.7B, the gap fixed; the rest to measure); gemma4's window (built); hybrid models' windows (built); the local-model comparison (run); Falcon candidates (run); the lockfile's MLX pins guarded (built); MLX thinking shown (built); `edit_file`'s line edits forgiving (built) |
| 0.21.0 | A shared HTTP executor: llama.cpp and LM Studio (built, ADR 0058) | A context length per model (built); `wisp models pull` follow-ups (built); token usage in `respond`'s receipt (built); qwen3.8's slowdown (measured: none in tool work); the README overview image (done); `model-controls.md` brought up to date (done); shell completions (built) |
| 0.22.0 | The tool-output budget from the model's window, and nothing past it dropped | Shell loops judged by what they run; approvals for folders that are gone |
| 0.23.0 | A verification pass: a reply checked against the turn's calls | Larger eval sets; three details of permanent facts settled; the terminal-only answers reviewed; the process title decided |

## 0.20.0: analysis, evals, and tuning

The release given to measurement, once the four before it were out. What was built and decided:

- **Context checkpoint 2** (larger), the open items of
  [ADR 0045](decisions/0045-layered-context.md): a scenario long enough to condense at the default
  budget, to tune the target and headroom; the 50% variants again, now that the target is capped below
  the trigger; a model switch mid-conversation (D10); and whether `memory` helps. By then the context
  features will have been in use for several releases, which the checkpoint takes into account. Prepared on
  2026-10-06: the plan, its decision rules, and the commands are
  [proposals/2026-10-06-context-checkpoint-2.md](proposals/2026-10-06-context-checkpoint-2.md); a scenario that
  condenses at the default budget (`sustained`, 29 turns and ten questions), the grid, the switches, and
  `scripts/check eval checkpoint` are built and pass the gate without a model. Run 2026-10-06 to 2026-10-08 and
  decided 2026-10-09 ([ADR 0057](decisions/0057-context-defaults-from-checkpoint-2.md)): `memory` off by default,
  kept as `context.memory`; `context.target` 0.6; the headroom (8) and the guard unchanged; the switch sound.
  Without `memory`, a reference to earlier output says to call a read-only tool again, and for a command or an
  edit that the output is not repeated and not to run it again, so no conversation is invited to rerun a command
  to see what it printed.
- **The assessment reconsidered, if wanted.** It stays off: the checkpoint found it rewrote the inferred
  task on 8 to 11 of 22 requests. A version that changes the task only when a request restates it is the
  starting point. Built on 2026-10-06 as `assessment.taskChanges: restated`, and measured
  by the checkpoint's `assessment` part ([the plan](proposals/2026-10-06-context-checkpoint-2.md), question 5). Run
  and decided ([ADR 0057](decisions/0057-context-defaults-from-checkpoint-2.md)): `restated` kept the task on every
  run where `any` lost it on five of six, so it is the default; the assessment stays off.
- **MLX against Ollama**, for the same models, now that 0.19.0 has MLX on a par, with the rest of what
  [ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md) lists under "What 0.20.0 must measure" (in its
  Consequences): the bridge against wisp's executor, prefix reuse, the cache's real cost per token, the windows
  sized for common models, the pull against the real Hub, and Core AI past its bundle's window. Measured for
  `Qwen3-1.7B-4bit` on 2026-10-06 ([measurements.md](measurements.md), "MLX against Ollama"): MLX was far behind on
  `edit_file` (2/30 against 20/30) and drafts because wisp told an undeclared model not to think, where Ollama lets it;
  fixed (ADR 0052, refined 2026-10-06): unset, `mlx.think` leaves thinking to the chat template, and a schema reply
  lets a thinking model finish before the schema holds it; MLX then scores 13/30 against Ollama's 15/30 in the same
  run, drafts 7/10, 1/2, 1/2 against 9/10, 1/2, 2/2, slower. A tool call with a `null` argument no longer breaks
  the conversation's later requests. wisp's executor stays the default; the bridge scored 6/30 on `edit_file`, failing as the executor did before. The
  rest of the list is still to measure.
- **gemma4's window.** Built ([ADR 0043](decisions/0043-context-window-from-memory.md), refined 2026-10-04).
  `wisp models` on 2026-10-04 showed `ollama:gemma4:12b` and `gemma4:26b` at 8,192 tokens from `default`: Ollama
  reports gemma4's key-value heads and sliding-window attention per layer, as arrays, and sizing read only a
  number. Sizing now counts a per-layer model layer by layer: only its global layers (8 of 48 in 12b, 5 of 30 in
  26b) grow with the window, its sliding layers cost a fixed window plus a batch, and the draft model Ollama runs
  beside gemma4 adds one more global layer. Estimated at 18 KiB a token for 12b and 24 KiB for 26b; measured for
  12b at exactly 18 KiB (16 for the model, 2 for its draft). On this Mac (51.5 GB) 12b reaches its full 262,144
  tokens with 30 GB available and 126,976 with 25 GB; 26b needs about 41.5 GB available to leave the floor (at
  most 217,088 tokens with all 51.5 GB free), so on this Mac it stays at 8,192 while much else is loaded. No other
  installed model's window changed.
- **Hybrid models' windows.** Built ([ADR 0043](decisions/0043-context-window-from-memory.md), refined
  2026-10-05). `qwen3.8:27b` (`qwen35`) interleaves 16 attention layers with 48 recurrent ones and was counted at
  260 KiB a token for all 65 layers, so it never left the floor. Sizing now counts only the attention layers
  (`full_attention_interval`) and the model's own draft layer per token, and the recurrent state as a fixed cost
  from the `ssm.*` fields: 68 KiB a token and 748 MiB, both measured exactly in llama.cpp's allocations at 8,192
  and 32,768 tokens. `ornith:9b` (same architecture) goes from 65,536 to 262,144 tokens with 30 GB available. MLX
  applies the same principle to `config.json` (Falcon-H1's parallel Mamba-2 state, Qwen3.5's interval). Other
  hybrid families' GGUF fields are unverified (listed in the ADR).
- **The local-model comparison**: `gemma4:26b`, `gemma4:12b`, `ministral-3:14b`, `ministral-3:8b`,
  and `llama3.2:3b` against `granite4.1:8b` and `qwen3.8:27b`, on the suites that decide delegation
  (tool calls and schema replies, triage, `summarise_diff`, `draft_change`, the classifier's model
  fallback, one context scenario), with `WISP_EVAL_MODELS`. It may change the default model for
  delegation (AGENTS.md, [backends.md](backends.md)). The models were pulled on 2026-10-01. Prepared on
  2026-10-04: those suites honour `WISP_EVAL_MODELS`, floors bind the configured model only, and
  `scripts/check eval compare` runs them one model at a time and ends with a table, model by suite
  ([measurements.md](measurements.md#comparing-models)).
  Early evidence, not measured: in a chat on 2026-10-02 `llama3.2:3b` wrote tool calls as JSON text
  instead of making them, kept a wrong path through three corrections, and claimed a plan had run when
  it had only read the file.
  Run on 2026-10-04 and 05: results and the decisions in [measurements.md](measurements.md), "The local-model
  comparison, 2026-10-04". Decided with the operator: `granite4.1:8b` stays the delegation default,
  `gemma4:12b` takes complex work, `qwen3.8:27b` large diffs (AGENTS.md); `llama3.2:3b` and `ministral-3:14b` are not
  for tool work. Follow-ups: read Mistral's `name[ARGS]{…}` calls from a reply's text, which
  `ministral-3:14b` makes and its template leaves unparsed (built on 2026-10-06, [backends.md](backends.md),
  "Ollama"; not re-measured); and the gemma4 models as labellers for training sets.
- **`edit_file`'s line edits forgiving.** Built ([ADR 0024](decisions/0024-edit-file.md), refined 2026-10-06). The
  1.7B models' failed line edits were mostly a line written without its indentation and a stale number, often with
  a `find` naming the right line. A line that lost its indentation keeps it unless only whitespace changes, a stale
  number with `find` edits the one line holding it, and the result shows the line as it now reads. Measured before
  and after ([measurements.md](measurements.md), "edit_file's line rules"): `mlx:Qwen3-1.7B-4bit` 11/30 to 27/30,
  `ollama:qwen3:1.7b` 16/30 to 19/30, granite4.1:8b unharmed at 27/30, with a new `edit_file.whitespace`
  measurement. Follow-up, built on 2026-10-09: an empty `find` beside `line`, which granite sends for an argument it
  does not need, checks nothing instead of refusing the edit.
- **Falcon candidates**, chosen on 2026-10-04 from the Hugging Face listings: `mlx:Falcon-H1R-7B-4bit`, a
  reasoning model for the complex-work slot that `qwen3.8:27b` holds at a quarter of its size, and
  `mlx:Falcon-H1-7B-Instruct-4bit`, a delegation-default candidate against `granite4.1:8b`, in a second
  comparison through wisp's MLX executor; and `Falcon-H1-Tiny-Tool-Calling-90M` as an experiment for the
  backlog's tool-choice classifier (BFCL v3 relevance 94.4%, multi-turn 0%, per TII). All are hybrid
  attention and Mamba-2, under the Falcon-LLM License; MLX sizing reads the hybrid shape (above).
  Enabled on 2026-10-05: H1R passed the capability check's tool question, Instruct and Tiny did not. What they
  wrote, probed through the executor ([backends.md](backends.md), "Tool calls"): Instruct a `</tool_call>` where
  `<tool_call>` belongs, a Python literal, and a tool name it was not offered, so the model, not the parsing,
  fails; Tiny an unclosed JSON array without the argument, and, with the schema less the framework's `x-order` and
  `title`, the array form its template asks for, which mlx-swift-lm rejected. wisp's executor now reads that form
  and stops at ChatML's `<|im_end|>`, which Tiny's generation config leaves out (it ran on to the token limit,
  writing further turns). The comparison can now run through the evals: `WISP_EVAL_MODELS=mlx:…`
  ([measurements.md](measurements.md#comparing-models)). Instruct is usable with tools off only, so its tool-call
  suites would fail as things stand.
  Compared on 2026-10-05: neither earns a place ([measurements.md](measurements.md), "The Falcon comparison");
  both 7B models disabled, the 90M kept for the tool-choice experiment.
- **The lockfile's MLX pins guarded.** `harness/Package.resolved` loses its MLX-only pins (mlx-swift,
  mlx-swift-lm, swift-numerics, swift-syntax) whenever a build without the `MLX` trait resolves it, which the
  gate's own build does; a commit on 2026-10-05 carried the loss and was put right the same day. The gate should
  check the staged lockfile keeps the pins and restore them after its build. Built: hygiene fails when the
  staged lockfile (the working copy, run by hand) lacks a pin, and the gate puts both lockfiles back after its
  builds ([engineering.md](engineering.md), "The lockfiles' MLX pins").
- **MLX thinking shown** (near term, the operator, 2026-10-04): ADR 0053 shows a reasoning model's thinking
  for Ollama only; the MLX executor needs the same `ThinkingStretch` hook (the chat template's `<think>`
  block split from the reply), so Falcon-H1R and Qwen3 on MLX show their thinking and count it. Built
  ([ADR 0053](decisions/0053-the-models-thinking-shown.md), refined 2026-10-06): the tags read from the chat
  template, the reply split as it streams, and `mlx.think` for a template that takes `enable_thinking`; shown and
  counted live with `mlx:Qwen3-1.7B-4bit` on 2026-10-06.

## 0.21.0

- **A shared HTTP executor** (larger), bringing llama.cpp and LM Studio as backends. **Built**
  ([ADR 0058](decisions/0058-a-shared-http-executor.md)): one executor for OpenAI's chat-completions API with a
  small dialect, `llamacpp:<model>` and `lmstudio:<model>`, the key from the environment or `config.json`, the
  window read from the server, and what it shares with Ollama's executor extracted (`ReplyRelay`). Tested
  against a fake server for each dialect and live against Ollama's OpenAI-compatible endpoint; a real
  `llama-server` and LM Studio remain to be tried.

- **A context length per model.** `ollama.contextLength` sets the window of every Ollama model at once;
  a setting per model (beside `mlx.models.<name>`), so one model can be held to a size while the rest are
  sized from memory. Raised on 2026-10-05 when qwen3.8 sat at the 8,192 floor. Built:
  `ollama.models.<name>.contextLength` and `mlx.models.<name>.contextLength`, ahead of the runtime's setting
  ([wisp.md](wisp.md), "`wisp config`"; [backends.md](backends.md)).
- **`wisp models pull` follow-ups**, from the Hugging Face cache work (ADR 0052, refined 2026-10-04):
  resume a half-fetched file with HTTP range requests rather than restarting it; seed the cache from a
  real directory's checked files instead of fetching them again; and Core AI's listing, which does not
  follow a linked model directory, as MLX's once did. Built
  ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-09).
- **Token usage in `respond`'s receipt.** `mcp.md` says usage is not reported yet; the turn's input,
  output, cached, and reasoning tokens, which the executors now report, belong in the receipt. Built:
  `receipt.usage`, and `usage` on the `response` audit event ([mcp.md](mcp.md)).
- **qwen3.8's slowdown.** Measured 2026-10-09: no slowdown in tool work. With nothing else loaded and the
  hybrid sizing in place it scored 16/16 and 30/30 at a median of 13.7 s a request, the two suites taking
  about as long as on 2026-10-05; the 40 to 70 s of 2026-10-04 were the classifier suite, where it thinks
  before each of 784 verdicts ([measurements.md](measurements.md), "qwen3.8:27b re-measured"). Its window
  stays at the 8,192 floor on this Mac for memory, not arithmetic.
- **The README overview image** says the model runs "on device or through Ollama"; redraw both versions
  with MLX (and Core AI), and the alt text with them. Done 2026-10-09: "on device, Ollama, MLX, or Core AI" in both
  versions, the `<desc>`, and the alt text, rendered in headless Chrome. The HTTP runtimes (llama.cpp, LM Studio)
  join the drawing when the shared executor ships.
- **`docs/model-controls.md`**, a draft proposal of which `ollama.think` and the thinking display now
  implement part: mark what is built and what is still proposed. Done 2026-10-09: a "What is built" section,
  the proposal otherwise as written.
- **Shell completions**, asked for on 2026-10-09: completion scripts for zsh, bash, and fish embedded in the
  binary, `wisp completions <shell>` to print one and `wisp completions install` to put it in place, and the
  Homebrew formula installing all three. Built: generated from the command tree and kept current by the gate,
  with ids, settings, and tools completed from `~/.wisp` ([wisp.md](wisp.md), "`wisp completions`").

## 0.22.0

- **The tool-output budget, and nothing past it dropped** (larger), proposed in [ADR
  0050](decisions/0050-tool-output-budget-and-overflow.md) on 2026-10-04. One budget for every tool result
  from the current model's window (an eighth, 4 KiB at least and 64 KiB at most) in place of the fixed 4
  KiB; the whole output kept in the thread's output store, with a marker saying what is held back;
  `memory` recall and `read_file` to page it; an overview or the notable lines of an output or a file (a
  build that succeeded summarised compactly, one that failed by its root causes), exact readers first and
  a model only where they fall short; `memory "condense entry N: <question>"` to answer from all of it;
  filters over the stored output, and never a command run again to see more of what it printed;
  `inspect(audit)` by turn, one line per call, and noticing the same tool call repeated within a turn (six
  `inspect(audit)` calls in one turn of session ce87576a, 2026-10-04). `run_command` stops discarding all but the
  tail. Found when a model asked to check its turn read only its last 20 audit events.

- **Shell loops judged by what they run.** A standing approval `do *` was found on 2026-10-09: wisp had
  remembered a `for … do …` loop by its first word, the shell keyword `do`, so the approval covered any later
  loop whatever its body ran. The operator revoked it. The classifier and the approval patterns should look
  through `for`, `while`, `until`, `if`, and `case` to the simple commands inside (as `CommandSplitter` does
  for `;` and `&&`), rate the line by its riskiest command, and never remember a pattern by a keyword.
- **Approvals for folders that are gone.** A project approval is tied to the directory it was given in, and
  outlives it: `b12873de` (`git commit *`) belonged to an agent's worktree removed on 2026-10-04 and could
  never match again (revoked 2026-10-09). `wisp approvals` should mark an approval whose directory no longer
  exists, and offer to remove such approvals (`wisp approvals clear --gone`, or when listing).

## 0.23.0

- **A verification pass** (larger), [ADR 0051](decisions/0051-the-turns-tool-calls-beside-the-reply.md)'s
  open option: after a reply, a classifier or a model is given the reply and the turn's complete call list
  from the audit log, not a slice the model fetched, and answers one narrow question: does the reply report
  a result from a call that is not in the list? Flagged beside `ran:` when it does, behind a setting, with
  an eval of its own built from the fabricated runs of 2026-10-04 (sessions `eefc5b0e`, `ba7865f0`,
  `ce87576a`).
- **Larger eval sets** for `edit_file`, `system_info`, and `draft_change`: their floors swing from run to
  run (`edit_file` 16 to 23 of 30 across 0.17.0 to 0.19.0's preflights), so a release can pass or stop on
  chance.
- **Three details of permanent facts settled**, left unconfirmed since 0.17.0 (ADR 0048): a fact request's
  wait reuses `approval.timeoutSeconds`; a drop is remembered only for the thread's life; a drop takes the
  proposal off the proposed list. The operator confirms or changes each.
- **The terminal-only answers reviewed.** `wisp approvals approve|deny` and `wisp facts keep|drop` answer
  only from a terminal, kept on 2026-10-02 to see how it behaves; review it with the use since.
- **The process title decided.** Whether wisp describes itself in the process list (`ps` shows a rewritten
  argument list; Activity Monitor only the executable's name), or only names the processes it starts at
  spawn; the operator is considering it (2026-10-04).

## Not scheduled

Every item in [backlog.md](backlog.md) not yet given a release, grouped by what it waits on.

Waiting on data:

- a small specialised distiller, and a tool-choice classifier, once the audit log holds enough labelled
  pairs (`Falcon-H1-Tiny-Tool-Calling-90M`, pulled on 2026-10-04, is the experiment for the second);
- classifiers from other providers: embedding nearest-neighbour over labelled examples, or an external
  process speaking JSON Lines; and classifiers for other tasks: personal data for `redact`, log-line
  categories.

Waiting on signing (a Developer ID or App Store signature):

- a notification helper app, so notifications come from wisp itself, with its icon and action buttons;
- a DMG, with the package declaring where its parts are;
- Private Cloud Compute, whose entitlement Apple grants only to signed App Store apps.

Waiting on someone asking:

- tools for embeddings and reranking;
- reverse delegation through MCP sampling: the local model asks the calling agent's model when it is
  stuck on a sub-step;
- the deferred uses: bulk classification, and offline work (git chores shipped on 2026-09-24 as
  `draft_change` and `wisp draft`).

Waiting on a design decision:

- escalations: approval and inquiry as distinct verbs, over more channels than MCP;
- approval banners when the client's dialog works: with `approval.outOfBand` on, every approval under MCP
  also posts a notification, even when the client's own dialog is showing;
- waiting MCP requests in plain chat, which `wisp-tui` shows and the line chat does not.
