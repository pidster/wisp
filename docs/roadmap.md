# Roadmap

The releases planned from 0.21.0 to 0.23.0, agreed with the operator on 2026-10-01 (0.16.0, the first, 0.17.0,
0.18.x, 0.19.0, and 0.20.0 have shipped; 0.21.0 is the release being made). Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning were given to 0.20.0 (the operator,
2026-10-02), which ran them. Each release's preflight still runs the eval's floors, as a guard against
regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.21.0 | A shared HTTP executor: llama.cpp and LM Studio (built, ADR 0058) | A context length per model (built); `wisp models pull` follow-ups (built); token usage in `respond`'s receipt (built); qwen3.8's slowdown (measured: none in tool work); the README overview image (done); `model-controls.md` brought up to date (done); shell completions (built) |
| 0.22.0 | The tool-output budget from the model's window, and nothing past it dropped | Shell loops judged by what they run; approvals for folders that are gone |
| 0.23.0 | A verification pass: a reply checked against the turn's calls | Larger eval sets; three details of permanent facts settled; the terminal-only answers reviewed; the process title decided |

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
  versions, the `<desc>`, and the alt text, rendered in headless Chrome. The HTTP runtimes (llama.cpp, LM Studio),
  built in this release too, are not in the drawing yet.
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

Waiting on a measurement run:

- the rest of what [ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md) lists under "What 0.20.0 must
  measure", beyond the `Qwen3-1.7B-4bit` comparison 0.20.0 ran: prefix reuse, the cache's real cost per token,
  the windows sized for common models, the pull against the real Hub, and Core AI past its bundle's window;
- llama.cpp and LM Studio against a real `llama-server` and LM Studio, neither installed here
  ([ADR 0058](decisions/0058-a-shared-http-executor.md)).

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
