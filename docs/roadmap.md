# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped, and so have
0.23.1 and 0.24.0 (the inquiry verb), on 2026-10-12, 0.24.1, a patch of small items, and 0.24.2, command time
limits, on 2026-10-14, and 0.25.0, an approved run outside the sandbox and the documentation site, on 2026-10-15.
What each carried is in [CHANGELOG.md](https://github.com/pidster/wisp/blob/main/CHANGELOG.md). 0.26.0, the model's
thinking set from chat and a status line that reads the version control off the prompt's path, shipped on
2026-10-15, and 0.26.1 and 0.26.2, a help mode and the parts of a turn set apart, the same day; 0.26.3, four
fixes found while mapping the thread store, on 2026-10-16, and 0.26.4, llama.cpp's thinking on a par with Ollama's,
on 2026-10-18; 0.27.0, one thread store, every thread saved and resumed by any face, on 2026-10-19, and 0.27.1, two fixes to the answer reader and the facts blocks, the same day; 0.27.2, a call's time limit only lengthening the thread's and clearer tool lines in `wisp-tui`, on 2026-10-20. Each release carries one or two larger items and a few smaller ones; a small item sits with the larger
one it touches. These are plans, not commitments: an item may move when its work shows it should, and the page is
edited when it does. When an item ships it leaves this page for the changelog, and anything not yet scheduled stays
in [backlog.md](backlog.md). Each release's preflight runs the eval's floors, as a guard against regressions, not a
measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.28.0 | The thread store's phase 3: `wisp threads` to list, show, delete, and hand threads, and a thread picker in `wisp-tui` that switches in place | The store in `wisp doctor`'s report; `/resume ID` in chat |
| 0.29.0 | `wisp-tui`'s conversation as a log pane of its own, with long outputs folded and each element reachable | Copying from the pane |

## 0.28.0

The thread store's phase 3 ([proposals/2026-10-16-one-thread-store.md](proposals/2026-10-16-one-thread-store.md),
"Phases"), planned with the operator on 2026-10-20; built on 2026-10-20 (ADR 0066, the phase 3 amendment), not yet
released. Phases 1 and 2 (ADR 0066) save every thread and
resume it from any face; what is missing is a way for the person to see and manage them outside chat, and to move
between them inside it.

- **`wisp threads`**, a subcommand over `ThreadStore`, with `--json` on each:
  - `wisp threads` (or `list`): every saved thread, as chat's `/threads` shows it (`ChatThread.listing`): id,
    owner, model, turns, last used, and state (`saved`, or `open elsewhere` with the holder's pid and client).
  - `wisp threads show ID`: its start settings, turns, audit sessions, the facts it dropped, its size on disk with
    its stored outputs, and when the sweep will delete it (`threads.keepDays`).
  - `wisp threads delete ID`: the thread and its stored outputs, as `close_thread` deletes one; refused while a
    process holds it (D6), naming the holder. Audited, a new `thread.deleted` kind beside `thread.swept`.
  - `wisp threads hand ID CLIENT`: the thread's owner set to `CLIENT` (D3), so that client's agent may resume it;
    refused while it is held. Audited as `thread.handed`, with the owner before and after. The refusal an MCP
    caller gets for another client's thread then names the command, as D3 has it: `thread X belongs to codex;
    wisp threads hand X claude-code gives it to you`.
  - **The person only** (chosen 2026-10-20): `delete` and `hand` change what an agent may open, so, like
    `wisp approvals approve`, they need a terminal, and `CommandPolicy`'s defaults refuse `wisp threads
    delete|hand` to wisp's model, so no agent can take another's thread through `run_command`. `list` and `show`
    are reads, open to anyone.
- **`/resume ID` in chat**, for the plain chat and `wisp-tui` alike: the current thread is saved and let go (its
  lock released), and `ID` is opened as `--resume ID` opens it at start, an agent's thread with its settings
  holding (D11). Refused, with the reason, for a thread held elsewhere or one that cannot be resumed; the
  current thread stays open then.
- **A thread picker in `wisp-tui`**, switching in place (chosen 2026-10-20): `/threads` opens a picker over the
  same listing (the `choice` protocol line `/model` uses), the current thread marked; choosing one sends
  `/resume ID`. Held threads are shown and not chosen. The plain chat keeps the printed listing.
- **The store in `wisp doctor`**, a `threads` finding beside `saved transcripts`: how many saved, how many held and
  by whom, their size on disk, and the next sweep's count under `threads.keepDays`; a `thread.json` that cannot be
  read is a warning naming `wisp threads delete`.
- **Docs and decision:** an amendment to [ADR 0066](decisions/0066-one-thread-store.md) for phase 3; `docs/wisp.md`
  (`wisp threads`, `/resume`, the doctor finding), `docs/mcp.md` (the owner refusal's message),
  `docs/logging.md` (the two kinds), and `docs/tools/run_command.md` (the policy's new defaults).
- **Tests, without the model:** each subcommand over a scratch home (list, show, delete and hand, both refused while
  a lock is held); the policy refusing `wisp threads delete|hand` and allowing `list` and `show`; `/resume`
  switching threads in a scripted chat, the first saved and unlocked, an agent's thread keeping its settings; the
  picker's `choice` line and the `/resume` it sends, in `wisp-tui`'s tests; an MCP server refused another client's
  thread, then allowed it after `hand`, over the wire.

## 0.29.0

- **A foldable conversation in `wisp-tui`** (asked for by the owner on 2026-10-15; planned, not built; moved from
  0.27.0 behind the thread store on 2026-10-16, and from 0.28.0 behind its phase 3 on 2026-10-20). Today the
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
- LM Studio against a real LM Studio server ([ADR 0058](decisions/0058-a-shared-http-executor.md)); llama.cpp's
  executor was measured against a real `llama-server` on 2026-10-17 ([measurements.md](measurements.md)).
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
