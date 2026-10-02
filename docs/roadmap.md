# Roadmap

The releases planned after 0.15.0, agreed with the operator on 2026-10-01. Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md).

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.16.0 | Host effects over MCP | `wisp watch --settle`; the chat parser driven by the help's table |
| 0.17.0 | Permanent facts over MCP | MLX in the release; a palette check in the gate; `memory`'s `task` example |
| 0.18.0 | `! <command>` in chat, and the input box | The tool glyph; where the summary is shown |
| 0.19.0 | MLX on a par with Ollama | Core AI's context window |
| 0.20.0 | Context checkpoint 2 | The assessment reconsidered, if wanted |

## 0.16.0

- **Host effects over MCP** (larger). [ADR 0044](decisions/0044-host-effects.md) gave each face a
  `SessionHost`; under `wisp mcp` only approval reaches the client, through elicitation, and
  notifications take the process routes. To settle: notifications, for which MCP has no primitive;
  approval for a client without elicitation (the question paused since 2026-09-17, in
  [backlog.md](backlog.md)); and whether the terminal route is ever allowed under MCP, which ADR 0044
  refuses today because a server started by a client in a terminal shares that terminal.
- **`wisp watch --settle`**, `watch.settle` in `config.json`, 1 s by default: a run starts only once no
  file change has arrived for the settle period. FSEvents' fixed 0.5 s batch can start a run part-way
  through a long burst (a checkout, a formatter, save-all), which gives a spurious failure and then a
  pass. Changes during a run already collapse into one pending run.
- **The chat parser driven by the help's table**, so a command added to the parser cannot be missing
  from `/help`; today a test checks the help's words parse, but a new parser case is not caught.

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
  D11) costs little; fetching `mlx-community` models, with the person's approval; and an eval of MLX
  against Ollama for the same models.
- **Core AI's context window** from its bundle's metadata, by the same path.

## 0.20.0

- **Context checkpoint 2** (larger), the open items of
  [ADR 0045](decisions/0045-layered-context.md): a scenario long enough to condense at the default
  budget, to tune the target and headroom; the 50% variants again, now that the target is capped below
  the trigger; a model switch mid-conversation (D10); and whether `memory` helps. By then the context
  features will have been in use for several releases, which the checkpoint takes into account.
- **The assessment reconsidered, if wanted.** It stays off: the checkpoint found it rewrote the inferred
  task on 8 to 11 of 22 requests. A version that changes the task only when a request restates it is the
  starting point.

## Not scheduled

- **The local-model comparison**, on a day set aside for it rather than in a release (the operator,
  2026-10-02; the models were pulled on 2026-10-01): `gemma4:26b`, `gemma4:12b`, `ministral-3:14b`,
  `ministral-3:8b`, and `llama3.2:3b` against `granite4.1:8b` and `qwen3.8:27b`, on the suites that
  decide delegation (tool calls and schema replies, triage, `summarise_diff`, `draft_change`, the
  classifier's model fallback, one context scenario), with `WISP_EVAL_MODELS`. It may change the
  default model for delegation (AGENTS.md, [backends.md](backends.md)).

Waiting on data, a signing set-up, or someone asking; each is described in [backlog.md](backlog.md):

- a small specialised distiller, and a tool-choice classifier, once the audit log holds enough labelled
  pairs;
- a signed helper app, so notifications come from wisp itself;
- further backends through a shared HTTP executor (llama.cpp, LM Studio);
- tools for embeddings and reranking;
- the deferred uses: bulk classification, git chores, offline work.
