# ADR 0044: Host effects: what a tool asks the front end to do

Date: 2026-09-30. Status: accepted; the build follows. Amended 2026-09-30: fact approval, the second
request-and-answer effect, and its MCP mapping (below). Amends
[ADR 0011](0011-risk-classifier-and-approval.md) (approvers) and [ADR 0030](0030-notifications.md) (how a
notification is posted).

## Context

Some things a tool needs done belong to whoever owns the person's screen, not to wisp's process.

- **Approval already works this way.** `ApprovalGate` asks an `Approver`, and each entry point supplies
  its own: `TerminalApprover` asks on the terminal in plain chat, `JSONApprover` sends an `approval`
  line over `wisp chat --json` and `wisp-tui` draws the dialog, and `ElicitationApprover` asks an MCP
  client through elicitation, which Claude Code renders. The model's tool never knows which.
- **`notify` does not.** `Notifier` runs `osascript`'s `display notification` from the wisp process,
  whatever the face. macOS attributes the banner to Script Editor (ADR 0030 recorded this), so it
  neither shows the terminal wisp runs in nor brings it forward when clicked.
- **Terminals can post notifications themselves.** Ghostty, iTerm2, and WezTerm post one for the escape
  sequence OSC 9 (`ESC ] 9 ; text BEL`), and kitty for OSC 99, under their own name and icon, by each
  terminal's documentation; the build probes each before routing to it. Terminal.app has no such
  sequence. A terminal is identified by `TERM_PROGRAM` and `__CFBundleIdentifier` (on this
  Mac on 2026-09-30: `ghostty`, `com.mitchellh.ghostty`).
- **Under `wisp-tui`, the wisp process must not write to the terminal.** `wisp-tui` runs `wisp chat
  --json` as a child and owns the screen: the alternate screen, raw mode, and every frame's escape
  sequences. A child writing OSC 9 to `/dev/tty` would interleave with the TUI's frames from a second
  process, and a sequence split by another breaks both. Only the TUI can post it safely, between frames.

In discussion on 2026-09-30 this was named as a kind of tool that does not complete its work itself: it
passes an instruction back to the controller, which has, in effect, a tool of its own being invoked.

## Decision

- **A host effect** is something a tool asks the session's host (the face that owns the person's
  screen) to do. There are two kinds:

  | Kind | Instances | What the tool gets back |
  | --- | --- | --- |
  | Fire and forget | `notify` | The route taken; delivery is not awaited |
  | Request and answer | approval | The host's answer, within a bounded wait |

- **One `Host` per session** holds the effects its face can carry. Tools and the gate call the `Host`,
  never a face directly. `Approver` stays the protocol for the approval effect; the `Host` carries the
  session's approver alongside its notifier.
- **Each face declares what it can carry:**
  - plain chat and the one-shot CLI: what the process can do itself, including the terminal it runs in;
  - `wisp chat --json`: what the front end states in a new first line, `hello`, with its effects (for
    `wisp-tui`, `approve` and `notify`). No `hello` means today's behaviour: approval over the protocol,
    and notifications posted locally;
  - MCP: what the client advertises (elicitation for approval), and the rest locally.
- **A request-and-answer effect obeys ADR 0011's rule:** a bounded wait (`approval.timeoutSeconds`),
  denial by default, and an unanswered request audited as timed out. A host that cannot ask denies with
  a reason, as today.
- **`notify` takes the first route that works, in this order:**
  1. the front end, when it declared `notify`: wisp sends a `notify` line with the title, subtitle, and
     body, and `wisp-tui` writes OSC 9 (or OSC 99 for kitty) between frames;
  2. the terminal, when wisp has a terminal (`/dev/tty` opens) and `TERM_PROGRAM` names one that posts
     notifications: wisp writes the sequence to `/dev/tty`, never to stdout, which is the reply stream
     in chat and the protocol channel under MCP;
  3. the terminal app by bundle identifier, when `__CFBundleIdentifier` is set: `display notification`
     sent to that app (`tell application id …`), so it posts under the app's name. macOS asks once for
     Automation consent. This route is used only once a probe shows the banner attributed to the app on
     macOS 27; until then it is skipped;
  4. `osascript` in wisp's process, as today, attributed to Script Editor.
- **Unchanged from ADR 0030:** text bounds, the per-minute limit across the process, the off switch,
  and no approval. The limit and bounds apply before any route, so a front end sees only what wisp
  would post itself.
- **Audited.** The `notification` event gains `route` (`host`, `terminal`, `app`, `osascript`). Approval
  events already name the entry point.
- **Amended 2026-09-30 by the operator: fact approval is the second request-and-answer effect.** Only the
  person admits a fact to the shared store of permanent facts (D2 and D3 of the
  [layered-context proposal](../proposals/2026-09-29-layered-context.md)); a permanent fact a tool or the
  model proposes waits in its conversation until they do. The host carries a fact-approval effect
  (`FactApprover`) beside the command approver, in `SessionHost` (the `Host` above; Foundation already has
  a type of that name). What each face does with it:

  | Face | How the person approves a proposed permanent fact |
  | --- | --- |
  | Plain chat, `wisp chat --json`, `wisp-tui` | No dialog: `/fact approve ID`, as before. `/inspect facts` also lists the proposals of the process's other conversations, and `/fact approve` takes them by reference (`git/c3`) |
  | MCP, client with elicitation | One fieldless Accept/Decline dialog per proposal, after the call's result |
  | MCP, client without elicitation | No dialog: the proposal waits in `wisp://facts/proposed` |

  Choices made with it, each for the reason given:
  - **After the turn, never during it.** The server claims the proposals at the end of each `tools/call`
    and queues the dialogs; they are sent once the call's response has been written (at most five seconds
    later), one at a time across threads. A tool call is never held open on the person. Waiting for the
    response was measured to matter: the SDK's client handles its messages in order, and a dialog sent from
    inside the handler reached it before the result, which then waited for the person's answer.
  - **One question per proposal, not one per turn.** A fieldless dialog can only accept or refuse exactly
    what it shows, and over MCP there is no other place to approve: an "accept all" dialog would make the
    person decline facts they want in order to refuse one they do not. Several in one turn are asked in a
    row, titled "(1 of 3)". Distillation proposes at most twelve facts a condensation, and only permanent
    kinds are asked about.
  - **Fieldless**, as the command dialog was after a form picker made Claude Code's dialog unresponsive
    (ADR 0011).
  - **ADR 0011's rule, with "not admitted" for "denied":** the same bounded wait
    (`approval.timeoutSeconds`, `0` waits forever); no answer leaves the proposal waiting, not admitted,
    and is audited as `timed-out`.
  - **Accept** admits the fact as approved by the person, ranking with the person, exactly as `/fact
    approve` does. **Decline** (and Cancel) leaves it as the conversation's proposal, not deleted, and is
    remembered by subject, name, and value for the life of the process, so wisp does not ask again about
    the same thing from any thread. A value the shared store already holds is not asked about.
  - **`--yes` does not approve facts.** It stands for the person on commands; D2 keeps admission to the
    shared store with the person.
  - **Audited** on the proposing conversation's log: `fact.approval.asked`, `fact.approval.decided`
    (`approved`, `declined`, `cancelled`, `timed-out`, `failed`), and `fact.approved` with `via`
    (`chat`, `elicitation`).

## Consequences

- In Ghostty, iTerm2, WezTerm, and kitty, and in `wisp-tui` inside them, banners come from the terminal
  and clicking one returns to it. Terminal.app waits on the third route's probe.
- `wisp-tui` gains two things: it sends `hello`, and it handles `notify` lines. The protocol change is
  additive; an older front end sends no `hello` and keeps today's behaviour.
- The next effects fit the same shape without new plumbing: showing output (D12 of the
  [layered-context proposal](../proposals/2026-09-29-layered-context.md) already has the host render
  tool output), a choice among options, and a question to the person.
- **Open, for MCP:** MCP has no notification primitive, and a client without elicitation still cannot
  approve a command (ADR 0011, and the question of approval reaching every client, paused on 2026-09-17).
  The amendment of 2026-09-30 maps fact approval onto elicitation; commands and notifications remain for
  that discussion.
- **Not yet probed:** a dialog that arrives after a tool call's result, in Claude Code. The protocol allows
  a server request at any time; whether Claude Code shows it while the model is still working is to be
  checked with the release build.
- Tests without the model: route selection for each face and environment (terminal names, no tty, no
  bundle identifier, a `hello` with and without `notify`), the sequences written, the protocol lines
  both ways, and the `route` field in the audit.
