# ADR 0048: Permanent facts over MCP

Date: 2026-10-03. Status: accepted; built 2026-10-03 (see "Built" at the end). Amends
[ADR 0045](0045-layered-context.md) (who admits a permanent fact, and where: only the person, now also from a
terminal or `wisp-tui` when an MCP caller asks) and [ADR 0046](0046-approval-and-notifications-over-mcp.md)
(the pending channel gains a second kind of request, a fact to keep). Settles the question
[ADR 0044](0044-host-effects.md)'s second amendment left to the operator: how permanent facts are managed over
MCP.

## Context

A permanent fact lives in `~/.wisp/facts.json` and is given to every conversation, in chat and over MCP. D2 of
the layered-context proposal, recorded in ADR 0045, keeps admission to that store with the person: a tool or the
model may propose one, and the proposal waits in its conversation until the person moves it. Through 0.16.0 the
person could do that only in chat (`/fact ID permanent`, or `/fact git/c3 permanent` for another conversation's
proposal), and `set_fact_scope` refused `permanent` and every `p…` fact. An agent delegating work to `wisp mcp`
could see a proposal (`respond`'s `facts`, `wisp://facts/proposed`) but had no way to put it to the person, and
the person, at a terminal or in the Claude mobile app, had no way to hear of it short of opening chat and
reading `/inspect facts`.

0.16.0 built the way for a question asked under `wisp mcp` to reach the person through another face: the pending
channel `~/.wisp/pending`, a notification naming the request, `wisp approvals approve|deny` from a terminal, and
`wisp-tui`'s dialog (ADR 0046). The operator decided on 2026-10-03 to use the same way for permanent facts.

Considered for whether `set_fact_scope` waits for the person's answer:

| Option | What it does | Why not, or why |
| --- | --- | --- |
| (a) Wait, bounded | The call stays open until the answer or `approval.timeoutSeconds`, as a command's approval does | A command blocks the turn that runs it; a fact blocks nothing. The calling agent's loop would stall for up to ten minutes (the default bound) on a question whose answer changes nothing it is doing, and a client's own tool-call timeout (Claude Code's `MCP_TOOL_TIMEOUT`) can end the call first, leaving the request to be answered with nobody listening |
| (b) Return at once | The call files the request and returns `pending` with its id; the outcome is read later on the fact's resource | Chosen. The agent goes on with its work, can say "I asked you to keep the codename" in its reply, and can read the outcome when it matters. The request is still bounded by `approval.timeoutSeconds`, so no question waits for ever ("no answer is not an answer"): silence keeps nothing |

Considered for how `wisp-tui` learns of fact requests:

| Option | What it does | Why not, or why |
| --- | --- | --- |
| (a) Ride `approve-mcp` | Send fact requests to any front end that declared `approve-mcp` | A 0.16.0 front end that declared it knows only command approvals: it would show a fact as a command dialog whose keys (`y`/`s`/`p`/`a`/`n`) mean nothing for a fact, and the relay would have to map `once` to something. An effect is a declared capability (ADR 0044); a new kind of question is a new capability |
| (b) A new effect, `keep-facts` | Send fact requests only to a front end that declared it | Chosen. Additive: a front end that does not declare it sees nothing new. The lines reuse `approval` (with `kind: "fact"`) and `withdrawn`, so the queue, the withdrawal, and the answer path are the ones 0.16.0 built |

## Decision

- **A caller asks; only the person keeps.** `set_fact_scope` with `scope: permanent` on a thread's fact (`c…`) or a
  session fact (`s…`) files a request in the pending channel and posts a notification through the session's
  routes, source `approval`: title "wisp: keep as a permanent fact?", body "release codename = BLUE HERON —
  wisp facts keep a1b2c3d4", subtitle naming who proposed it and the client and thread. The person answers where
  wisp asks: `wisp facts pending` lists what waits; `wisp facts keep ID` and `wisp facts drop ID` answer, from a
  terminal; a running `wisp-tui` shows the request as a dialog with `[k]eep [d]rop`. Nothing in MCP answers it.
- **The call returns at once**, with `state: "pending"`, the request's `id`, its `expiresAt`, and the URI of the
  fact, where the outcome shows as `request` (`pending`, `kept` with the permanent fact's id, `dropped`,
  `timed-out`, `withdrawn`, or `failed` with a reason); `wisp://facts/proposed` shows it on each proposal too.
  Asking again while a request waits returns the same request, and posts no second notification.
- **Keep** admits the fact to the shared store as the person's, exactly as `/fact ID permanent` does, provided the
  fact still says what the person was shown (an answer is bound to the fact's id, subject, name, value, and
  source); otherwise nothing is kept and the request ends `failed`. Audited as `fact.scope.changed` with
  `by: person` and the `request`.
- **Drop** leaves the fact where it is, in its thread (or the session, for a session fact); it is not deleted. A
  proposed permanent fact stops being proposed, in place, as a move to `thread` does, so it no longer waits in
  `wisp://facts/proposed`. The thread remembers the
  drop by the fact's subject, name, and value: asking about the same fact again is refused with the date and
  request of the drop, for as long as the thread is open.
- **Silence keeps nothing.** A request unanswered within `approval.timeoutSeconds` (`0` waits for ever) ends
  `timed-out`; the fact stays as it was, and the caller may ask again. A thread that closes or is evicted, and a
  server that stops, withdraw their requests (`withdrawn`).
- **A caller cannot remove or demote a permanent fact.** Permanent facts are the person's: `set_fact_scope`
  refuses every `p…` fact, whatever the target. A caller that disagrees with one records a newer fact in its
  thread, which shows as a conflict (`conflict` in the facts resources) for the person to settle in chat.
- **No banner for the model's proposals.** A permanent fact the model distils or a tool extracts in an MCP thread
  waits silently in `wisp://facts/proposed`, as before. `respond`'s result says how many wait, as
  `structuredContent.factsProposed` (`count` for the server, `thread` for this thread, and `uri`), so the calling
  agent can mention it and ask for the ones that matter.
- **The same channel, a second kind.** A fact request is a pending request of kind `fact` in `~/.wisp/pending`,
  filed as `<id>.fact.json` beside the commands' `<id>.request.json`, with the same mode, binding, first-answer-wins
  answer file, staleness (its server gone or its wait expired), and sweeps. The suffix is its own so that a 0.16.0
  `wisp`, which lists and sweeps `.request.json` files it can read, never sees a fact request. Each kind takes its
  own answers: `keep` or `drop` for a fact, the scopes and `no` for a command; `wisp approvals approve` on a fact
  request, or `wisp facts keep` on a command, is refused with a pointer to the right command.
- **The same rules for answering**, kept from ADR 0046: `wisp facts keep|drop` answer only with standard input a
  terminal, which an agent's shell tool does not have (a speed bump, not a wall, as there); the sandbox does not
  let a command write under `~/.wisp`; and the default policy refuses `wisp facts keep|drop` outright, so wisp's
  own model cannot keep a fact it proposed.
- **Audited, every step**, with the kinds ADR 0046 added: `approval.pending` when filed, the `notification`,
  `approval.answered` in the answering process (`via` `cli` or `tui`), and `approval.settled` on the asking
  thread (`answered` with `decision` `keep` or `drop` and `kept`; `timed-out`; `withdrawn`; `failed`; `stale`),
  each with `kind: "fact"` and the fact's fields in place of the command's. `wisp facts` records under entry
  point `facts`.

## Consequences

- A caller can now get a fact into the shared store, with the person's consent, from any client: the Claude
  mobile app's user keeps it from a terminal on the Mac or in `wisp-tui`, prompted by a banner.
- Every request posts a banner. Proposals the model makes do not, so the banners are as many as the caller's
  requests; if that proves noisy, the caller is the one to ask less.
- A drop is remembered only for the thread's life: a new thread may ask about the same fact again. Remembering
  drops across threads and sessions would need a store of declined facts; not built.
- `wisp chat --json` gains an effect a front end may declare, `keep-facts`, under which fact requests arrive as
  `approval` lines with `kind: "fact"` and are answered `keep` or `drop`. Additive.
- Plain terminal chat (`wisp chat --plain`) does not show waiting fact requests, for ADR 0046's reason.
- ADR 0045 is amended: the person admits permanent facts from chat, and now also from `wisp facts` and `wisp-tui`
  when a caller asks. ADR 0046 is amended: the pending channel carries two kinds of request.

## Built

Built 2026-10-03. `PendingApprovals` gained `Kind` (`command`, `fact`) and `ProposedFact`, a fact request's own
binding and file suffix, and `waiting(_ kind:)`; a request without a kind, as 0.16.0 filed them, decodes as a
command. `FactKeeper` files a request, notifies, starts a watch that polls the channel every 200 ms, applies the
answer through a closure the server gives it (`ThreadActor.keepAsked` and `dropAsked`, over `Agent.keepAsked`
and `dropAsked`, which check the fact is still what was shown), remembers drops per thread, and withdraws a
thread's requests when it closes. `WispServer` routes `set_fact_scope` `permanent` to it and adds
`factsProposed` to `respond`; the facts resources gained `request`. `wisp facts pending|keep|drop` is
`FactsCommand`; `PendingRelay` takes the kinds a front end declared; `wisp-tui` declares `keep-facts` and shows a
fact dialog in wisp's colour, `[k]eep [d]rop`, with Ctrl-C dropping as it refuses a command. Tested without the
model: the channel's fact kind (filing apart, each kind's answers, binding, an altered request, a replayed or
mistyped answer, staleness, a 0.16.0 request), the keeper (kept, dropped and remembered, asked twice, silence,
a closing thread, an answer that cannot be applied, a channel that cannot be used), the agent's keep and drop,
the policy, the listing, the relay, the MCP path over the wire (asked, kept from the command line, dropped,
refused again, a closing thread, `factsProposed`, a permanent fact never moved), and the TUI's dialog.
