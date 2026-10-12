# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped: 0.16.0 to
0.21.0, the patches 0.21.1 and 0.21.2, 0.22.0, and 0.23.0 on 2026-10-12. What each carried is in
[CHANGELOG.md](../CHANGELOG.md). No release is planned beyond it yet; the next is chosen with the operator from
the list below and from use. Each release carries one or two larger items and a few smaller ones; a small item
sits with the larger one it touches. These are plans, not commitments: an item may move when its work shows it
should, and the page is edited when it does. When an item ships it leaves this page for the changelog, and
anything not yet scheduled stays in [backlog.md](backlog.md). Each release's preflight runs the eval's floors,
as a guard against regressions, not a measurement.

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

Known, not yet fixed:

- the secret scanner's unquoted `assigned-secret` rule (`scan_secrets`, `redact`, `wisp scan`) reads prose as a
  credential assigned to a name: "per token: every …th layer" and "per drafted token: 748.125 MiB" in commit
  `756b178`'s diff, an eval fixture, which `EvalSetsTests` allows by name (`proseMatches`).

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
