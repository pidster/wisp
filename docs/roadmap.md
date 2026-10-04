# Roadmap

The releases planned from 0.19.0 to 0.22.0, agreed with the operator on 2026-10-01 (0.16.0, the first, 0.17.0, and
0.18.x have shipped; 0.19.0 is the release being made). Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning wait for 0.20.0, which is given
to them (the operator, 2026-10-02): no release before it runs an eval to decide or tune anything. Each
release's preflight still runs the eval's floors, as a guard against regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.19.0 | MLX on a par with Ollama (built) | Core AI's context window (built); the model's thinking shown (built); the sandbox's refusals checked (built); the pathless refusal note (built); wisp itself denied to the model (built); cited entries checked (built); models enabled and disabled, the models table, capability checks on enable (built); chat's fallback when its model is unavailable (built); Ollama stopping mid-turn tested (built) |
| 0.20.0 | Context checkpoint 2: analysis, evals, and tuning | The assessment reconsidered; MLX against Ollama; gemma4's window (built); the local-model comparison |
| 0.21.0 | A shared HTTP executor: llama.cpp and LM Studio | |
| 0.22.0 | The tool-output budget from the model's window, and nothing past it dropped | |

## 0.19.0

- **MLX on a par with Ollama** (larger): the context window from the model's metadata, sized from
  memory as [ADR 0043](decisions/0043-context-window-from-memory.md) does for Ollama; exact token counts
  with the model's tokenizer, and usage reported; reusing the processed prefix, which an in-process
  runtime controls directly, so composing each request ([ADR 0045](decisions/0045-layered-context.md),
  D11) costs little; and fetching `mlx-community` models, with the person's approval. Measuring MLX
  against Ollama waits for 0.20.0. Built ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)): wisp's
  own executor, `mlx.contextLength` and `mlx.executor`, and `wisp models pull`; tested over a fake runtime and a
  fake Hub, and on real weights on 2026-10-04: `scripts/check mlx-live` passed all five tests with
  `mlx-community/Qwen3-1.7B-4bit`, fetched by `wisp models pull`. What 0.20.0 measures is listed in the ADR.
- **Core AI's context window** from its bundle's metadata, by the same path. Built (ADR 0052): the bundle's
  declared `max_context_length`.
- **The model's thinking shown.** Built ([ADR 0053](decisions/0053-the-models-thinking-shown.md)). Ollama streams a reasoning model's thinking as `message.thinking`
  whether or not `think` is set (probed on 2026-10-04 with `ornith:9b`: 42 thinking chunks before a
  two-chunk answer), and the executor drops it, so the time looks idle and usage reports no reasoning
  tokens. Decode it: a "thinking" activity in chat, `wisp chat --json`, and `wisp-tui`'s busy box, drawn
  as a thought bubble growing and then ellipsis dots cycling (the operator's design, 2026-10-04): `.`,
  `.o`, `.oO`, `.oO( thinking )`, `.oO( thinking. )`, `.oO( thinking.. )`, `.oO( thinking... )`, then the last
  four looping while it thinks (agreed the same day); the
  text kept as the turn's `.reasoning` entry, folded with `/show` and readable through `/inspect` and the
  thread's resources, audited with its token count, and left out of the model's context; a `think`
  setting where the model offers one. Core AI and MLX the same where they report it.
- **The sandbox's refusals checked.** Built ([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md)). Seatbelt is passive: a refused operation fails with `EPERM`, and on
  macOS 27 the kernel logs no `deny` line for a `sandbox-exec` profile (probed on 2026-10-04: no record
  with `(debug deny)` or `(deny default)`; `(with report)` is refused on a deny rule, and
  `(with send-signal …)` delivered nothing). wisp guesses today, from "Operation not permitted" in the
  error output, and only for commands the person types. Check instead: a path in that error outside the
  writable roots is the sandbox's refusal, one inside them is not; flag it on the model's commands too,
  telling the model what was refused and where it may write. Network and process refusals name no path
  and stay a guess.
- **The pathless refusal note.** Built ([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md)). When a
  command fails with `Operation not permitted` and names no path, the model's result says the sandbox may have
  refused it and no policy rule did (session `ce87576a`, 2026-10-04: a nested wisp's `Error: Operation not
  permitted` read as a policy denial).
- **wisp itself denied to the model.** Built ([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md)). The
  default deny list refuses `wisp respond`, `chat`, `mcp`, and the bare `wisp "prompt"`, a nested agent with its own
  model, tools, and approvals; its other subcommands stay allowed.
- **Cited entries checked.** Built ([ADR 0055](decisions/0055-cited-entries-checked.md)). Beside `ran:`, a muted line
  names the entries a reply cites in wisp's reference forms that the conversation does not hold (session
  `ce87576a`, 2026-10-04: "Result (entry 19)" to "(entry 30)" and "entries 16-30", with about 18 entries stored).
- **Models enabled and disabled, and the models table.** Built
  ([ADR 0056](decisions/0056-models-enabled-and-disabled.md)). `models.disabled`: a disabled model hidden from
  `/model` and Tab and refused by `/model`, `--model`, `model`, and MCP `respond`, the default never disabled;
  `wisp models enable|disable`, `/models enable|disable`, and `wisp-tui`'s `/models` picker; enabling a cached MLX
  model links it. `wisp models` became a table of every known fact, fitted to the terminal, the same in chat,
  `--json`, and the picker (the operator's decisions, 2026-10-04). Enabling an MLX model whose capabilities
  `config.json` does not declare loads it and asks three short questions (a reply, a tool call, a structured reply),
  recording what passes; `wisp models check` and `/models check` check again; audited as `model.verified`.
- **Chat's fallback when its model is unavailable.** Built (ADR 0056). Probed on 2026-10-04 with `ollama.baseURL` at
  an unused port: every entry point failed fast and clearly, but `wisp chat` refused to start, so `/model` was out of
  reach. Chat now starts on `system` and says so; `--model`, `respond`, and MCP still fail.
- **Ollama stopping mid-turn tested.** Built. Tests over the fake Ollama server: a connection lost after content,
  a tool call, or thinking; a stream closed without `done`; a server that holds the connection silent. They found
  two faults, fixed: a stream that ended without `done` was kept as the whole reply, and a lost or silent connection
  read `no Ollama server`.

## 0.20.0: analysis, evals, and tuning

The release given to measurement, once the four before it are out:

- **Context checkpoint 2** (larger), the open items of
  [ADR 0045](decisions/0045-layered-context.md): a scenario long enough to condense at the default
  budget, to tune the target and headroom; the 50% variants again, now that the target is capped below
  the trigger; a model switch mid-conversation (D10); and whether `memory` helps. By then the context
  features will have been in use for several releases, which the checkpoint takes into account.
- **The assessment reconsidered, if wanted.** It stays off: the checkpoint found it rewrote the inferred
  task on 8 to 11 of 22 requests. A version that changes the task only when a request restates it is the
  starting point.
- **MLX against Ollama**, for the same models, now that 0.19.0 has MLX on a par, with the rest of what
  [ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md) lists under "What 0.20.0 must measure" (in its
  Consequences): the bridge against wisp's executor, prefix reuse, the cache's real cost per token, the windows
  sized for common models, the pull against the real Hub, and Core AI past its bundle's window.
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
- **The local-model comparison**: `gemma4:26b`, `gemma4:12b`, `ministral-3:14b`, `ministral-3:8b`,
  and `llama3.2:3b` against `granite4.1:8b` and `qwen3.8:27b`, on the suites that decide delegation
  (tool calls and schema replies, triage, `summarise_diff`, `draft_change`, the classifier's model
  fallback, one context scenario), with `WISP_EVAL_MODELS`. It may change the default model for
  delegation (AGENTS.md, [backends.md](backends.md)). The models were pulled on 2026-10-01. Prepared on
  2026-10-04: those suites honour `WISP_EVAL_MODELS`, floors bind the configured model only, and
  `scripts/check eval compare` runs them one model at a time and ends with a table, model by suite
  ([measurements.md](measurements.md#comparing-models)); the comparison itself is still to run.
  Early evidence, not measured: in a chat on 2026-10-02 `llama3.2:3b` wrote tool calls as JSON text
  instead of making them, kept a wrong path through three corrections, and claimed a plan had run when
  it had only read the file.

## 0.21.0

- **A shared HTTP executor** (larger), bringing llama.cpp and LM Studio as backends. Several local
  runtimes serve an OpenAI-compatible HTTP API, and the Ollama executor's mapping from a transcript to a
  chat request is most of what they need; the executor is parameterised by base URL, authentication,
  and the request's dialect ([backlog.md](backlog.md),
  [ADR 0016](decisions/0016-local-runtimes-through-an-executor.md)).

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

## Not scheduled

Waiting on data, a signing set-up, or someone asking; each is described in [backlog.md](backlog.md):

- a small specialised distiller, and a tool-choice classifier, once the audit log holds enough labelled
  pairs;
- a signed helper app, so notifications come from wisp itself;
- tools for embeddings and reranking;
- the deferred uses: bulk classification, git chores, offline work.
