# Roadmap

The releases planned from 0.17.0 to 0.21.0, agreed with the operator on 2026-10-01 (0.16.0, the first, has
shipped). Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning wait for 0.20.0, which is given
to them (the operator, 2026-10-02): no release before it runs an eval to decide or tune anything. Each
release's preflight still runs the eval's floors, as a guard against regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.17.0 | Permanent facts over MCP | MLX in the release; a palette check in the gate; `memory`'s `task` example; the commit in `--version` |
| 0.18.0 | `! <command>` in chat, and the input box | The tool glyph; where the summary is shown |
| 0.19.0 | MLX on a par with Ollama | Core AI's context window |
| 0.20.0 | Context checkpoint 2: analysis, evals, and tuning | The assessment reconsidered; MLX against Ollama; the local-model comparison |
| 0.21.0 | A shared HTTP executor: llama.cpp and LM Studio | |

## 0.17.0

- **Permanent facts over MCP** (larger). Built 2026-10-03,
  [ADR 0048](decisions/0048-permanent-facts-over-mcp.md). `set_fact_scope` `permanent` files a request in
  `~/.wisp/pending` and posts a notification, and returns at once; the person keeps or drops the fact with
  `wisp facts keep|drop` or in `wisp-tui` (the `keep-facts` effect), never through the MCP conversation. A
  drop leaves the fact in its thread and is remembered there; a caller never moves or removes a permanent
  fact; `respond` counts the proposals waiting (`factsProposed`) instead of a banner for each.
- **MLX in the release.** Built 2026-10-03 ([ADR 0047](decisions/0047-mlx-in-the-release.md)). The
  release is built with the `MLX` trait and carries MLX's Metal library as `mlx.metallib` beside `wisp`
  (3.8 MB; the stripped binary grows from 15.1 to 32.8 MB, the download by about 6 MB). MLX finds it
  through the binary's real path, so Homebrew's links need no wrapper: the formula installs both in
  `libexec`. `wisp doctor` has an `MLX` finding, which the release checks on the staged binary, and
  `scripts/check mlx-live <model>` runs the live test with the library beside the test bundle.
- **A palette check in the gate** (built 2026-10-03), so `Style.Palette` in Swift and `palette.rs` in `wisp-tui` cannot
  drift apart.
- **`memory`'s `task` example**. Dropped 2026-10-03: it added 13 tokens to every conversation that has
  `memory`. The `task` verb still works and [tools/memory.md](tools/memory.md) documents it.
- **The commit in `--version` for builds that are not releases** (built 2026-10-03), e.g. `0.16.0-dev+5886d33`, or
  `0.16.0-dev+5886d33 (modified)` when the tree had changes, so a build from `main` (such as the one `.mcp.json` runs) is not
  mistaken for the release whose number it still carries. A release build prints the bare version,
  which the release script and the Homebrew formula's test check.

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
