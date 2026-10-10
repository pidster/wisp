# Roadmap

The releases planned from 0.22.0 to 0.23.0, agreed with the operator on 2026-10-01 (0.16.0, the first, 0.17.0,
0.18.x, 0.19.0, 0.20.0, and 0.21.0 have shipped; 0.21.1, a patch from the code review of 2026-10-09, is the
release being made). Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning were given to 0.20.0 (the operator,
2026-10-02), which ran them. Each release's preflight still runs the eval's floors, as a guard against
regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.22.0 | The tool-output budget from the model's window, and nothing past it dropped | Shell loops judged by what they run; approvals for folders that are gone; one set of model actions, for the person and the model; thinking chosen per call; the rest of the 2026-10-09 review |
| 0.23.0 | A verification pass: a reply checked against the turn's calls | Larger eval sets; three details of permanent facts settled; the terminal-only answers reviewed; the process title decided |

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
  loop whatever its body ran. The operator revoked it. 0.21.1 stopped the harm: keywords and interpreters are
  remembered by exact text, and `sh -c` and `eval` bodies are judged. What remains: judge and key `do X` and
  `then X` by `X`'s own pattern, with loop variables understood, so each new loop body does not ask again; look
  into `python -c`, `perl -e`, `find -exec sh -c`, and `| python3`; normalise `w''isp`, `${IFS}`, and a variable
  as the program name; and ask once, not twice, for a line whose risk only the whole line shows.
- **Approvals for folders that are gone.** A project approval is tied to the directory it was given in, and
  outlives it: `b12873de` (`git commit *`) belonged to an agent's worktree removed on 2026-10-04 and could
  never match again (revoked 2026-10-09). `wisp approvals` should mark an approval whose directory no longer
  exists, and offer to remove such approvals (`wisp approvals clear --gone`, or when listing).

- **One set of model actions, for the person and the model**, proposed in [ADR
  0059](decisions/0059-one-set-of-model-actions.md) on 2026-10-09 after the operator asked for a tool for managing
  models in chat "so the agent and user can both do it", adapting `/models` and `/model` rather than adding beside
  them. One `ModelActions` layer behind `wisp models`, `/models`, and `/model`; `/models pull` and `trust` in chat and
  `wisp-tui`, with the publisher question as a dialog, progress in the status line, and Ctrl-C to cancel; a `models`
  tool for the model, off by default, which lists and shows freely and asks the person for every pull, enable,
  disable, or check, a pull never remembered and `trust` the person's alone. (MLX pulls from any publisher, first
  planned here, moved to 0.21.1 at the operator's request, where it is built.)
- **Thinking chosen per call**, asked for on 2026-10-10 after the granite comparison of 2026-10-09: `granite4.2:8b`
  matched `granite4.1:8b` on every tool suite but was 4 to 15 times slower, because it thinks before every answer, and
  its classifier half alone took about six hours; not thinking, it matched 4.1's speed and got every draft right
  ([measurements.md](measurements.md), "granite4.1 against granite4.2"). Today `ollama.think`,
  `mlx.think`, and llama.cpp's `think` apply to every request to every model of the runtime
  ([ADR 0053](decisions/0053-the-models-thinking-shown.md)). Proposed, as an amendment to ADR 0053 and a concrete part
  of [model-controls.md](model-controls.md): wisp sends `think: false` for its own calls that gain nothing from it
  (classifier verdicts, schema replies, the fact distiller, summaries, triage, the assessment), and keeps the model's
  default for open-ended turns; `respond` takes `think` when a thread starts, so a caller chooses (the git thread off, a
  complex task on); and `<runtime>.models.<name>.think` sets one model's default, beside its `contextLength`. Build the
  per-model default first: on its own it lets `granite4.2:8b` be the default with thinking off.
- **The eval's output shown as it runs.** Since 0.21.1's fix to the eval's exit status, `scripts/check eval` writes a
  run's results only when it ends: the granite comparison of 2026-10-09 showed nothing for `granite4.2:8b` for six
  hours. Stream the lines again while keeping `swift test`'s own status.
- **Ctrl-C during a model turn.** In plain chat it still quits wisp at once, and a `run_command` the model started
  in that turn can outlive it (found on 2026-10-09 while giving typed commands Ctrl-C). The first Ctrl-C should
  stop the turn and its command, as it now stops a typed command, and the second quit.
- **The rest of the 2026-10-09 review**, deferred from 0.21.1 because each belongs with this release's budget
  work: `run_command` holding every byte until it trims to the tail (a ring buffer of the bound, with a count
  of what was dropped); `wisp://threads/{id}/audit` and `wisp://audit/{session}` unbounded (paged like the other
  collections); a reused `thread_id` (`git`) mixing every earlier thread's history into its resources (one audit
  session per opened thread); pipes and files opened without close-on-exec, so concurrent commands inherit each
  other's descriptors; `read_file` of a FIFO or a file with no newlines; `write` and `append` loading a whole
  file; `run_command`'s result bound as a whole, its note included; and the review's low findings.

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
