# Roadmap

The releases planned after 0.15.0, agreed with the operator on 2026-10-01. Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning wait for 0.20.0, which is given
to them (the operator, 2026-10-02): no release before it runs an eval to decide or tune anything. Each
release's preflight still runs the eval's floors, as a guard against regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.16.0 | Host effects over MCP | `wisp watch --settle`; the chat parser driven by the help's table; two reference bugs; `read_file` on a wildcard |
| 0.17.0 | Permanent facts over MCP | MLX in the release; a palette check in the gate; `memory`'s `task` example |
| 0.18.0 | `! <command>` in chat, and the input box | The tool glyph; where the summary is shown |
| 0.19.0 | MLX on a par with Ollama | Core AI's context window |
| 0.20.0 | Context checkpoint 2: analysis, evals, and tuning | The assessment reconsidered; MLX against Ollama; the local-model comparison |
| 0.21.0 | A shared HTTP executor: llama.cpp and LM Studio | |

## 0.16.0

- **Host effects over MCP** (larger). Built 2026-10-02,
  [ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md). A command waiting for approval under
  `wisp mcp` is filed in `~/.wisp/pending` and announced by a notification; the person answers with
  `wisp approvals approve|deny` or in `wisp-tui`, never through the MCP conversation; with elicitation as
  well, both are asked at once and the first answer wins (`approval.outOfBand`, on by default).
  Notifications keep the process routes and are listed in `respond`'s `notifications`; the terminal
  route stays refused under MCP.
- **`wisp watch --settle`**. Built 2026-10-02 ([ADR 0033](decisions/0033-watch-mode.md), amended).
  `watch.settle` in `config.json`, 1 s by default: a run starts only once no
  file change has arrived for the settle period. FSEvents' fixed 0.5 s batch can start a run part-way
  through a long burst (a checkout, a formatter, save-all), which gives a spurious failure and then a
  pass. Changes during a run still collapse into one pending run.
- **The chat parser driven by the help's table**. Built 2026-10-02: each help entry builds its command
  and the parser looks the command word up in the table, so a command cannot exist without its `/help`
  line.
- **Two bugs in output references** (`OutputReference`). Fixed 2026-10-02. Seen in a saved context the
  same day: a reference's "last line" could be `read_file`'s paging hint ("[more: call again with offset
  94]") rather than the output's last line, and its "first line" a fragment where the output was bounded
  mid-line ("ize."). Both misled every model; references now take the first and last whole lines of
  content and keep the paging hint apart.
- **`read_file` on a wildcard.** Fixed 2026-10-02. Given `test*.wisp`, it answered "file not found", and
  a small model retried the same path three times. It now says it takes one path and to list matches
  with `run_command` (`ls *.wisp`).

## 0.17.0

- **Permanent facts over MCP** (larger). `set_fact_scope` moves a thread's fact between `thread` and
  `session` only; how a caller proposes or keeps a permanent fact, which only the person admits today
  ([ADR 0045](decisions/0045-layered-context.md)), is to be decided.
- **MLX in the release.** The release is built without the `MLX` trait because MLX loads its Metal
  library at run time ([backends.md](backends.md)). MLX looks first for `mlx.metallib` in the binary's
  own directory (`mlx/backend/metal/device.cpp`), so the release can carry that one file beside `wisp`.
  A probe first: the file's size, the binary's growth, whether Homebrew's link to the Cellar changes the
  directory MLX sees, and whether the same file beside the test bundle lets the MLX live test run. Then
  the release build with the trait, the package and formula, a `wisp doctor` finding, and the docs.
- **A palette check in the gate**, so `Style.Palette` in Swift and `palette.rs` in `wisp-tui` cannot
  drift apart.
- **`memory`'s `task` example**, which adds 13 tokens to every conversation that has `memory`: keep it,
  shorten it, or drop it.

## 0.18.0

- **`! <command>` in chat, and the input box** (larger). A prompt line that starts with `!` runs the
  command directly; the input box's background changes while it does, in a colour still to be chosen.
  Decided on 2026-09-30, to be recorded in an ADR, since it is the first command that does not come from
  the model: it passes the policy, the sandbox, and the audit log but not approval, because the person
  typed it; its output is shown, and given to the model as a reference after the turn, marked as the
  person's own action; chat and `wisp-tui` only, not MCP. The same release makes the input box's
  inactive state clearer while a turn is processing.
- **The tool glyph.** `⚙` is drawn as a two-cell emoji in some terminals, so tool lines change width;
  candidates were compared on 2026-09-30.
- **Where the summary is shown.** It sits with the facts today (`/inspect facts`,
  `wisp://threads/{id}/facts`); a place of its own if use shows that is awkward.

## 0.19.0

- **MLX on a par with Ollama** (larger): the context window from the model's metadata, sized from
  memory as [ADR 0043](decisions/0043-context-window-from-memory.md) does for Ollama; exact token counts
  with the model's tokenizer, and usage reported; reusing the processed prefix, which an in-process
  runtime controls directly, so composing each request ([ADR 0045](decisions/0045-layered-context.md),
  D11) costs little; and fetching `mlx-community` models, with the person's approval. Measuring MLX
  against Ollama waits for 0.20.0.
- **Core AI's context window** from its bundle's metadata, by the same path.

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
- **MLX against Ollama**, for the same models, now that 0.19.0 has MLX on a par.
- **The local-model comparison**: `gemma4:26b`, `gemma4:12b`, `ministral-3:14b`, `ministral-3:8b`,
  and `llama3.2:3b` against `granite4.1:8b` and `qwen3.8:27b`, on the suites that decide delegation
  (tool calls and schema replies, triage, `summarise_diff`, `draft_change`, the classifier's model
  fallback, one context scenario), with `WISP_EVAL_MODELS`. It may change the default model for
  delegation (AGENTS.md, [backends.md](backends.md)). The models were pulled on 2026-10-01.
  Early evidence, not measured: in a chat on 2026-10-02 `llama3.2:3b` wrote tool calls as JSON text
  instead of making them, kept a wrong path through three corrections, and claimed a plan had run when
  it had only read the file.

## 0.21.0

- **A shared HTTP executor** (larger), bringing llama.cpp and LM Studio as backends. Several local
  runtimes serve an OpenAI-compatible HTTP API, and the Ollama executor's mapping from a transcript to a
  chat request is most of what they need; the executor is parameterised by base URL, authentication,
  and the request's dialect ([backlog.md](backlog.md),
  [ADR 0016](decisions/0016-local-runtimes-through-an-executor.md)).

## Not scheduled

Waiting on data, a signing set-up, or someone asking; each is described in [backlog.md](backlog.md):

- a small specialised distiller, and a tool-choice classifier, once the audit log holds enough labelled
  pairs;
- a signed helper app, so notifications come from wisp itself;
- tools for embeddings and reranking;
- the deferred uses: bulk classification, git chores, offline work.
