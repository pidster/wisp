# ADR 0046: Approval and notifications over MCP

Date: 2026-10-02. Status: accepted; built 2026-10-02 (see "Built" at the end). Amends
[ADR 0044](0044-host-effects.md) (the MCP face's host effects, left open there) and
[ADR 0011](0011-risk-classifier-and-approval.md) (approval for a client without elicitation, by design
impossible there). Settles the question paused on 2026-09-17 and the MCP part of the
[escalations proposal](../proposals/2026-09-20-escalations.md); the proposal's other parts (an inquiry verb,
the `result` channel) are not taken up.

## Context

Under `wisp mcp` a command that needs approval is asked through MCP elicitation, which the client renders.
Two things do not fit that:

- **Clients without a dialog.** On 2026-09-17 the operator found that the Claude mobile app does not show
  elicitation, so a delegated `git push` waited out the timeout and was refused. ADR 0011 made that
  refusal deliberate: a client without elicitation cannot approve, and the calling harness runs risky
  commands itself. The operator wants wisp to keep asking (not `--yes`, not a lower threshold) and for the
  question to reach them wherever they are. The question was paused that day as needing more thought.
- **A dialog that sticks.** Between 2026-09-19 and 2026-09-23, Claude Code's elicitation dialog stuck
  intermittently: visible, but Accept could not be reached; three of eight approvals in one session, two of
  them the `git push` right after a `git commit` on the same thread. The timeout bounds the damage; until
  this decision the only way out was `/mcp reconnect wisp`.

And for notifications: MCP has no notification primitive. ADR 0044 gave `notify` a route through each face;
under MCP it takes the process routes (the terminal app by bundle id, then `osascript`), never the
terminal route, since a server started by a client in a terminal shares that terminal (probed 2026-09-30).
The calling agent does not learn that a turn posted one.

Considered for approval without elicitation, in the discussion of 2026-09-17 and again on 2026-10-02:

| Option | What it does | Why not, or why |
| --- | --- | --- |
| (a) Refuse | ADR 0011 as it stood: the reply says approval was needed, and the caller runs the command itself | Leaves the person who delegated from a phone with nothing; the paused question asked for better |
| (b) Through the conversation | The result carries an approval id bound to the command; the agent asks the person in chat and calls again with the id (the escalations proposal's `result` channel) | The agent is the party being gated: it can call again with the id without asking anyone, and wisp cannot tell. The operator's words: the calling agent can never approve on the person's behalf |
| (c) Through another face | The request waits; the person is told by a notification and answers where wisp itself asks: `wisp approvals`, or a running `wisp-tui` | Chosen, on 2026-10-02 |

## Decision

- **Approval through another face.** When a command needs approval under `wisp mcp`, the request waits,
  bounded by `approval.timeoutSeconds` (`0` waits for ever), and the person is told: a notification through
  the session's routes, source `approval`, naming the command and how to answer it ("wisp: approval
  needed" — "git push origin main — wisp approvals approve a1b2c3d4"). The person answers where wisp asks:
  - `wisp approvals pending` lists what waits; `wisp approvals approve ID [--scope once|session|project|always]`
    and `wisp approvals deny ID` answer, from a terminal;
  - a running `wisp-tui` shows each waiting request as its approval dialog, marked as coming from
    `wisp mcp`, queued behind any dialog already open.

  An unanswered request is denied and audited as timed out (ADR 0011's rule). The scopes mean what they
  mean in chat, with the same downgrade of a dangerous command to `session` (ADR 0014).
- **Nobody approves through the MCP conversation.** No tool argument, resource, or result answers a
  request. The calling agent learns that approval was asked for (the progress line, the receipt, the
  `notifications` list) but has no way to give it.
- **With elicitation as well: both at once, the first answer wins.** The dialog and the out-of-band request
  are raised together; whichever is answered first decides, and the other is withdrawn: the request file
  removed (a `wisp-tui` dialog showing it closes with "answered elsewhere"), or the dialog cancelled with
  `notifications/cancelled`. **On by default**, under `approval.outOfBand` (true). The reasons: it is the
  way out when the client's dialog sticks, which happened often enough to name; the person at the
  terminal answers the dialog as before and the out-of-band request is withdrawn within a poll; the cost is
  one notification per request. Off restores ADR 0011 as it stood: elicitation only, and a client without
  it refused with the reason.
- **The call waits.** `tools/call` stays open until the answer, as with elicitation. A client's own
  tool-call timeout may end it first (Claude Code's `MCP_TOOL_TIMEOUT`). A client that then sends
  `notifications/cancelled` cancels the handler: the request is withdrawn and audited as `abandoned`. A
  client that stops waiting without cancelling leaves the request until it is answered or times out, and
  the result goes nowhere.
- **`notify` over MCP keeps the process routes** (the app route under the client terminal's bundle id,
  `osascript` otherwise), and `respond`'s result lists every notification its turn posted, or tried to, as
  `structuredContent.notifications`: title, body, source, outcome, route taken, and time. MCP has no
  notification primitive; this is how the caller knows.
- **The terminal route stays refused under MCP**, for ADR 0044's reason: the server's controlling terminal
  is the client's screen, and a sequence written from the server would interleave with the client's frames.

### The channel

The MCP server and the face that answers are separate processes. The channel between them is a directory,
`~/.wisp/pending/`, chosen over a Unix domain socket:

| | Directory of request files | Unix domain socket |
| --- | --- | --- |
| Discovery | `wisp approvals pending` reads one directory, whatever servers are running | One socket per server, so a directory of sockets to find and connect to |
| A crash | A request names its server's process; a request whose process has gone, or whose wait has expired, is stale: never listed, removed by the next sweep | A stale socket file to detect and remove, the same problem |
| Answering | Write one file | A protocol, a connection, framing, partial reads |
| Watching | Poll at 200 ms, a `stat` and a missing file per waiting request | Event-driven, no polling |
| Trust | The same boundary as `approvals.json`: user-only files under the user's home | The same, with socket permissions |

Polling is the price of the directory, and it is small: a waiting request costs one file check every
200 ms. FSEvents was not used: its batching adds latency to an answer the person is waiting on, and it
gives nothing a poll of one file does not.

- **Files.** `pending/` is mode 0700 and must be a directory of the user's that no one else can open, or
  the channel refuses to use it (`wisp doctor` reports it). A request is `<id>.request.json`, mode 0600,
  written by rename from a temporary file so it is never read half-written. An answer is
  `<id>.answer.json`, written by a hard link from a temporary file, which fails if an answer is already
  there: the first answer wins and is always whole.
- **Binding.** A request carries a SHA-256 over its id, command, whole line, pattern, directory, level,
  thread, server process, and creation time. The answering process recomputes it from the fields it shows
  the person and refuses a request whose file no longer matches (altered after it was filed); the answer
  carries the recomputed binding; the server takes only an answer whose binding equals the one it computed
  when it filed the request, from memory. So an answer approves only the command the person was shown, in
  that directory, for that thread. The id is fresh for every request and taking an answer removes both
  files, so an answer cannot be replayed onto another command or used twice.
- **The id is not a secret.** Any process running as the person can list the directory, so the id's
  randomness is not what stops an agent answering. What does:
  - nothing in MCP answers;
  - wisp's own model cannot: the sandbox does not let a command write under `~/.wisp`, and the default
    policy refuses `wisp approvals approve|deny` outright;
  - `wisp approvals approve|deny` answer only from a terminal (standard input a TTY), which an agent's
    shell tool does not have. This is a speed bump, not a wall: a process can obtain a pseudo-terminal.
    The wall for an agent's own shell is the agent's harness, which asks the person before running a
    command of its own.
- **Clean-up.** The server removes its request when it stops waiting for any reason, and sweeps its own
  leftovers when the client disconnects. `wisp approvals pending` and `approve` sweep stale requests,
  orphaned answers, and temporary files first, and audit each stale request as `approval.settled` with
  outcome `stale`.
- **Audited, every step:** `approval.pending` when filed (or `failed`), the `notification`,
  `approval.answered` in the answering process (`via` `cli` or `tui`, with whether the server took it),
  and `approval.settled` on the asking thread (`answered` with `via` `elicitation`, `cli`, or `tui`;
  `timed-out`; `abandoned`; `failed`; `stale`), then `approval.decided` as for every face.

## Consequences

- A client without elicitation can delegate risky work again: the Claude mobile app's user approves from
  a terminal or `wisp-tui` on the Mac, prompted by a banner. If they are not at the Mac, the request times
  out as before.
- A stuck Claude Code dialog has a way out without reconnecting: `wisp approvals approve`, or the
  `wisp-tui` dialog.
- With a working dialog, every approval also posts a banner. If that proves noisy, the choice is between
  turning `approval.outOfBand` off and delaying the banner until the dialog has gone unanswered for a
  while; the second is not built.
- The person must be at the Mac. Answering from a phone, or anywhere off the Mac, is not provided.
- `wisp chat --json` gains an effect a front end may declare, `approve-mcp`, and a line, `withdrawn`. Both
  are additive: a front end that does not declare it sees nothing new.
- Plain terminal chat (`wisp chat --plain`) does not show waiting MCP requests: it reads a line at a time
  and has no place to put a dialog that arrives between prompts.

## Built

Built 2026-10-02. `PendingApprovals` is the channel; `OutOfBandApprover` files, notifies, and races the
channel against the client's dialog; `Session.mcpApprover` composes it from the configuration, and
`WispServer` gives it the elicitation leg. The `Approver` protocol gained `decide(_:audit:)`, which the
gate calls with the asking thread's log, and `ApprovalRequest` gained `thread`. Where the build chose:

- **Withdrawing a dialog.** The MCP SDK does not return the JSON-RPC id of a request it sends, so each
  approval dialog carries a key in its `_meta` (`wisp/approval`), and the server's transport wrapper,
  which sees every outgoing message, records the id of the `elicitation/create` carrying it. Cancelling
  the dialog's task sends `notifications/cancelled` with that id. Whether Claude Code closes the dialog on
  it is not yet probed; the specification says a client should.
- **A dialog that cannot be sent is not a refusal** while the other way can still answer: a failure of
  one way leaves the other asking, and only when both have failed is the command refused.
- **`wisp-tui` declares `approve-mcp`** in its `hello`; `wisp chat --json` then lists the channel every
  500 ms and sends each new request as an `approval` line with `source: "mcp"`, `thread`, `client`, and
  `request`, under the id `mcp-<id>`, and a `withdrawn` line when it no longer waits. The dialog says
  "waiting in wisp mcp for claude-code, thread git" and its title ends "· wisp mcp".
- **The approval notification goes through the per-minute limit** like any other, so a burst can lose a
  banner; the request still shows in `wisp approvals pending` and `wisp-tui`.
- **Tested without the model:** the channel (filing, answering, binding, an altered request, a replayed
  answer, the first answer winning, staleness and sweeping, an open directory refused, concurrent
  requests), the approver (each way winning, the other withdrawn, silence, cancellation, a failed way), the
  MCP path over the wire (a client without elicitation approved and denied from the command line; with
  elicitation, each way answering first, and the client receiving `notifications/cancelled`), the relay
  and the TUI's queue and withdrawal, and `respond`'s `notifications`.
