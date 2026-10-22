# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped, and so have
0.23.1 and 0.24.0 (the inquiry verb), on 2026-10-12, 0.24.1, a patch of small items, and 0.24.2, command time
limits, on 2026-10-14, and 0.25.0, an approved run outside the sandbox and the documentation site, on 2026-10-15.
What each carried is in [CHANGELOG.md](https://github.com/pidster/wisp/blob/main/CHANGELOG.md). 0.26.0, the model's
thinking set from chat and a status line that reads the version control off the prompt's path, shipped on
2026-10-15, and 0.26.1 and 0.26.2, a help mode and the parts of a turn set apart, the same day; 0.26.3, four
fixes found while mapping the thread store, on 2026-10-16, and 0.26.4, llama.cpp's thinking on a par with Ollama's,
on 2026-10-18; 0.27.0, one thread store, every thread saved and resumed by any face, on 2026-10-19, and 0.27.1, two fixes to the answer reader and the facts blocks, the same day; 0.27.2, a call's time limit only lengthening the thread's and clearer tool lines in `wisp-tui`, on 2026-10-20; 0.28.0, the thread store's phase 3, `wisp threads`, `/resume`, and a thread picker in `wisp-tui`, on 2026-10-22. 0.29.0, `wisp-tui`'s conversation in a pane of its own, with long outputs folded, each element reachable from the keyboard, and copying, shipped the same day. 0.29.1, the release's optional signing and notarisation, off by default, and `wisp doctor`'s signature line, shipped the same day too. Each release carries one or two larger items and a few smaller ones; a small item sits with the larger
one it touches. These are plans, not commitments: an item may move when its work shows it should, and the page is
edited when it does. When an item ships it leaves this page for the changelog, and anything not yet scheduled stays
in [backlog.md](backlog.md). Each release's preflight runs the eval's floors, as a guard against regressions, not a
measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.30.0 | `Wisp Notifier.app`: notifications from wisp itself, with its own name, icon, and row in Notification settings | The doctor's notifier line; `notifications.viaHelper` |

## 0.30.0

- **A notification helper of wisp's own** (in the backlog under "When wisp can be signed"; chosen by the operator on
  2026-10-22). `Wisp Notifier.app`, bundle identifier `com.pidster.wisp.notifier`, a small bundle with no Dock icon
  beside `wisp` in the formula's `libexec`, posts through `UserNotifications`, so banners come from "Wisp" with its
  icon (the homepage's wisp, cropped to its head) whether or not the terminal has focus, and a click brings the
  terminal wisp ran in forward. A new `helper` route, tried first by every face, used once the person has allowed
  it; until then, and whenever the helper is missing or `notifications.viaHelper` is off, the routes of today post
  as before. Probed on 2026-10-22: an ad hoc signed bundle may notify once the person allows it, so the helper needs
  no Developer ID; macOS refuses a bundle run from a temporary folder, and one run directly by its executable until
  LaunchServices knows it; the first request can fail while the prompt is still on screen. Built in stages: the
  helper; the route, the setting, and the doctor's line; the release's bundle, signed ad hoc or with the Developer
  ID and notarised when signing is on; the icon. A new ADR amends ADR 0030 and ADR 0044.

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
