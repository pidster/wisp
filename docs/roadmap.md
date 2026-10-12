# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped: 0.16.0 to
0.21.0, the patches 0.21.1 and 0.21.2, 0.22.0, and 0.23.0 on 2026-10-12, and 0.23.1, a patch for the secret
scanner, the same day. What each carried is in [CHANGELOG.md](../CHANGELOG.md). The operator chose 0.24.0 on
2026-10-12, and it is the release being made: every item below is built. Each release carries one or two larger items and a few smaller ones; a small item sits with
the larger one it touches. These are plans, not commitments: an item may move when its work shows it should, and
the page is edited when it does. When an item ships it leaves this page for the changelog, and anything not yet
scheduled stays in [backlog.md](backlog.md). Each release's preflight runs the eval's floors, as a guard against
regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.24.0 | The inquiry verb: the model asks the person a question mid-turn | Waiting MCP requests in plain chat; approval banners only when the dialog goes unanswered; the risk test set grown from real use; an interactive status bar in `wisp-tui` |

## 0.24.0

- **The inquiry verb** (larger), the open half of the escalations design (`proposals/2026-09-20-escalations.md`,
  [backlog.md](backlog.md), "Open design"): approval settled by [ADR
  0046](decisions/0046-approval-and-notifications-over-mcp.md), the model asking the person a question mid-turn
  (which of two files, which of two meanings, a value it cannot find) remains. Through the same channels as an
  approval: the chat's dialog, `wisp-tui`, `wisp approvals`, and MCP elicitation, the first answer winning; with
  a bounded wait whose silence is "no answer", never a guess passed off as the person's; audited. A new ADR first,
  for the operator's review before it is built: what the model may ask, the answer's shape (free text, a choice),
  how it reaches the model, its limits, and how it differs from an approval. Built 2026-10-12
  ([ADR 0062](decisions/0062-the-inquiry-verb.md), accepted the same day; [tools/ask.md](tools/ask.md)): the `ask`
  tool, off by default (`tools.ask`); `inquiry.timeoutSeconds`, 0 by default, waiting until the person answers;
  `wisp questions` and plain chat's `/questions`; under MCP the turn parks after 60 s and the answer reaches the
  thread's next turn; the client's question form behind `inquiry.elicitation`, off until the hand test (below).
- **Waiting MCP requests in plain chat.** `wisp-tui` shows commands, and facts to keep, waiting in `wisp mcp`
  servers; `wisp chat --plain` reads a line at a time and does not. A note between prompts, answered with a slash
  command. Built 2026-10-12: `/approvals pending|approve|deny`, `/facts keep|drop`, and `/questions
  answer|decline`, answering only when the chat's input is a terminal.
- **Approval banners only when the dialog goes unanswered.** With `approval.outOfBand` on, every approval under
  `wisp mcp` posts a banner, even when the client's dialog is answered at once
  ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md), "Consequences"): post it only after the
  dialog has gone unanswered for some seconds. Built 2026-10-12: `approval.bannerDelaySeconds`, 10 by default.
- **The risk test set grown from real use.** The classifier's frozen test set held 25 dangerous commands; add
  dangerous commands the gate sees in use, each confirmed by the operator before it joins (ADR 0038,
  [backlog.md](backlog.md), "Classifiers"). Done 2026-10-12: 13 rows, the operator confirming each; 29 dangerous.
- **An interactive status bar in `wisp-tui`** (smaller, asked for by the operator on 2026-10-12). `questions: N`
  and `approvals: N` in the status row, and the row focusable from the input: Left and Right move between items
  and Enter opens the model's picker, the context panel, the waiting question or approval, or the turn list; `/model`
  with no name offers the models in `wisp-tui` ([ADR 0029](decisions/0029-tui-front-end.md), amendment of
  2026-10-12). Built 2026-10-12.

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

Seen once, to investigate:

- a flaky test, `MLXPullerTests.theFetchReportsItsProgressAndTheLinkSaysWhatHappened`: a progress-ordering race
  seen once on 2026-10-12, the reported progress going back (`[0, 22, 4118, 4120, 4127, 4120]`).

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
