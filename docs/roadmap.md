# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped, and so have
0.23.1 and 0.24.0 (the inquiry verb), on 2026-10-12, and 0.24.1, a patch of small items, and 0.24.2, command time
limits, on 2026-10-14. What each carried is in [CHANGELOG.md](https://github.com/pidster/wisp/blob/main/CHANGELOG.md). An approved run outside the sandbox,
chosen by the operator on 2026-10-14, is built for the next patch, 0.24.3, as command time limits were for 0.24.2;
the operator may yet call it 0.25.0. Each
release carries one or two larger items and a few smaller ones; a small item sits with the larger one it touches.
These are plans, not commitments: an item may move when its work shows it should, and the page is edited when it
does. When an item ships it leaves this page for the changelog, and anything not yet scheduled stays in
[backlog.md](backlog.md). Each release's preflight runs the eval's floors, as a guard against regressions, not a
measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.24.3 (patch) | | An approved run outside the sandbox, for `brew upgrade`, `cargo install`, and `rustup update` |

## 0.24.3

- **An approved run outside the sandbox**
  ([ADR 0064](decisions/0064-an-approved-run-outside-the-sandbox.md), chosen by the operator on 2026-10-14):
  `run_command`'s `outsideSandbox`, asked of the person every time for that exact line, once, behind the operator's
  `commandPolicy.sandbox.allowOutsideSandbox`. Probed on 2026-10-14: `cargo install`, `rustup update`, and every
  Homebrew write are refused by the sandbox, and no profile can fix Homebrew, whose own sandbox cannot nest in
  wisp's.

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
