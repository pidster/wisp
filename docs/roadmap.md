# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped, and so have
0.23.1 and 0.24.0 (the inquiry verb), on 2026-10-12, 0.24.1, a patch of small items, and 0.24.2, command time
limits, on 2026-10-14, and 0.25.0, an approved run outside the sandbox and the documentation site, on 2026-10-15.
What each carried is in [CHANGELOG.md](https://github.com/pidster/wisp/blob/main/CHANGELOG.md). 0.26.0, the model's
thinking set from chat and a status line that reads the version control off the prompt's path, shipped on
2026-10-15, and 0.26.1 and 0.26.2, a help mode and the parts of a turn set apart, the same day; 0.26.3, four
fixes found while mapping the thread store, on 2026-10-16. Each release carries one or two larger items and a few smaller ones; a small item sits with the larger
one it touches. These are plans, not commitments: an item may move when its work shows it should, and the page is
edited when it does. When an item ships it leaves this page for the changelog, and anything not yet scheduled stays
in [backlog.md](backlog.md). Each release's preflight runs the eval's floors, as a guard against regressions, not a
measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.26.4 | llama.cpp's thinking on a par with Ollama's: found, levelled, budgeted, and checked by `wisp doctor` | |
| 0.27.0 | One thread store: every thread saved, and resumed by any face | |
| 0.28.0 | `wisp-tui`'s conversation as a log pane of its own, with long outputs folded and each element reachable | Copying from the pane |

## 0.27.0

- **One thread store** (asked for by the owner on 2026-10-16; the plan accepted the same day, not built). Every
  thread, from chat or MCP, is saved after each turn under `~/.wisp/threads/<id>/` with its start settings, and a
  face that names one it does not hold resumes it, under a new audit session linked to the old ones. One process
  holds a thread at a time; an MCP caller resumes only its own client's threads and those handed to it;
  `close_thread` deletes; a thread unused for 30 days is swept. Chat's `/save` and `--resume` become names in the
  same store. ADR 0066 records it. The plan, with every decision and its phases:
  [proposals/2026-10-16-one-thread-store.md](proposals/2026-10-16-one-thread-store.md). Phase 3 (`wisp threads`,
  the picker) is later.

## 0.28.0

- **A foldable conversation in `wisp-tui`** (asked for by the owner on 2026-10-15; planned, not built; moved from
  0.27.0 behind the thread store on 2026-10-16). Today the
  conversation is printed into the terminal's own scrollback ([ADR 0029](decisions/0029-tui-front-end.md)), where
  nothing can fold a line once it is printed. The plan: `wisp-tui` draws the conversation itself, in a log pane
  above the input, on the alternate screen. Output streams in as now; once an element has finished, a long tool
  output or a stretch of thinking folds to its last lines and an info line (`▸ 248 lines · 12 KB · exit 0`).
  Shift-Up and Shift-Down leave the input and step through the elements (prompts, commands, tool calls, thinking,
  replies); Shift-Right unfolds the one selected and Shift-Left folds it; the pane scrolls on its own keys; Esc or
  typing returns to the input. Whole outputs come from wisp a page at a time, as the expanded view's do (ADR 0050).
  The cost, which a new ADR records: the terminal's own scrollback, search, and selection no longer hold the
  conversation, so the pane scrolls and copies itself, and on quitting the conversation leaves the screen (the
  transcript and the audit log keep it). Built in stages: the pane and its scrolling; folding; navigation and
  unfolding; copying. The alternative kept in view: the same navigation and folding inside the Ctrl-O panel,
  leaving the scrollback as it is.

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
- the verification pass's model step (`verification.mode: model`), built and off by default: it is turned on only
  when, on the default model, it flags no honest reply and a verdict takes under 3 s; on the on-device model on
  2026-10-12 it flagged 6 of 14 honest replies (p50 1.9 s). It waits on a more capable model, or a narrower prompt
  that leaves plans and explanations alone, measured with `scripts/check eval compare`
  ([ADR 0060](decisions/0060-a-verification-pass.md), "Measured, 2026-10-12").

Waiting on the operator:

- the hand test of the client's question form (ADR 0062, D8; the procedure is in [mcp.md](mcp.md), "Questions"),
  still to run; once it passes, `inquiry.elicitation` may default on. Whether a question's banner should then wait
  for the dialog as an approval's does (`approval.bannerDelaySeconds`) is open: today it is posted at once, and
  waiting would need an amendment to [ADR 0062](decisions/0062-the-inquiry-verb.md).

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
