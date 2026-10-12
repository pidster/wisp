# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01 (0.16.0, the first, 0.17.0,
0.18.x, 0.19.0, 0.20.0, 0.21.0, 0.21.1, 0.21.2, and 0.22.0 have shipped, 0.22.0 on 2026-10-12; 0.23.0, the last
release planned, whose items are all built, is the release being made). Each release carries one or two
larger items and a few smaller ones; a small item sits with the larger one it touches. These are plans,
not commitments: an item may move when its work shows it should, and the page is edited when it does.
When an item ships it leaves this page for [CHANGELOG.md](../CHANGELOG.md), and anything not yet
scheduled stays in [backlog.md](backlog.md). Analysis, evals, and tuning were given to 0.20.0 (the operator,
2026-10-02), which ran them. Each release's preflight still runs the eval's floors, as a guard against
regressions, not a measurement.

| Release | Larger | Smaller |
| --- | --- | --- |
| 0.23.0 | A verification pass: a reply checked against the turn's calls | Larger eval sets; a stored output shown whole in chat and `wisp-tui`; three details of permanent facts settled; the terminal-only answers reviewed; the process title decided |

## 0.23.0

Every item below is built (2026-10-12); what each left open is under "Not scheduled".

- Built: **a verification pass** (larger), [ADR 0051](decisions/0051-the-turns-tool-calls-beside-the-reply.md)'s
  open option: after a reply, a classifier or a model is given the reply and the turn's complete call list
  from the audit log, not a slice the model fetched, and answers one narrow question: does the reply report
  a result from a call that is not in the list? Flagged beside `ran:` when it does, behind a setting, with
  an eval of its own built from the fabricated runs of 2026-10-04 (sessions `eefc5b0e`, `ba7865f0`,
  `ce87576a`). Built and [ADR 0060](decisions/0060-a-verification-pass.md) accepted on 2026-10-12: exact readers,
  on by default (`verification.mode: readers`), flag 8 of the 9 fabricated turns and none of 14 honest replies; the
  model step is built and off by default, since on the on-device model it flagged 6 of 14 honest replies
  ([verification.md](verification.md)).
- Built 2026-10-12: **a stored output shown whole in chat and `wisp-tui`**, left over from 0.22.0's budget (ADR
  0050, "The person's views"): `/show` and `wisp-tui`'s expanded view printed what the tool returned, head, marker,
  and tail, while the whole was in the output store and only `wisp://threads/{thread_id}/output/{id}` served it.
  Now `/show` and `/last` show the stored whole, through `$PAGER` on a terminal, and Ctrl-O loads it 64 KiB at a
  time through the protocol's `output` request.
- Built 2026-10-12: **larger eval sets** for `edit_file`, `system_info`, and `draft_change`: their floors swing from
  run to run (`edit_file` 16 to 23 of 30 across 0.17.0 to 0.19.0's preflights), so a release can pass or stop on
  chance. Now 110, 54, and 44 cases, each floor set from the suite's pooled history; the release runs a fixed
  subset and `WISP_EVAL_FULL=1` the whole sets ([measurements.md](measurements.md)).
- Built 2026-10-12: **three details of permanent facts settled**, left unconfirmed since 0.17.0 (ADR 0048): a fact
  request's wait reused `approval.timeoutSeconds`; a drop is remembered only for the thread's life; a drop takes the
  proposal off the proposed list. The operator settled them: a request has no time limit and outlives its thread
  and its server; the other two stay as built ([ADR 0048](decisions/0048-permanent-facts-over-mcp.md), amended).
- Done 2026-10-12: **the terminal-only answers reviewed.** `wisp approvals approve|deny` and `wisp facts keep|drop`
  answer only from a terminal, kept on 2026-10-02 to see how it behaves; reviewed with the use since and kept
  ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md), "Review, 2026-10-12").
- Built 2026-10-12: **the process title decided.** Whether wisp describes itself in the process list (`ps` shows a
  rewritten argument list; Activity Monitor only the executable's name), or only names the processes it starts at
  spawn. Decided for naming at spawn ([ADR 0061](decisions/0061-process-names-set-at-spawn.md)): `scripts/wisp-mcp`
  starts `wisp mcp (CLIENT)` from `WISP_MCP_CLIENT`, and `wisp-tui` its child as `wisp chat (tui)`.

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
