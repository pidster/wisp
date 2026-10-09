# ADR 0049: Commands the person types in chat

Date: 2026-10-04. Status: accepted. Amended by [ADR 0054](0054-the-sandboxs-refusals-checked.md): the note for a
command the sandbox refuses comes from a check of the paths in its error, not a guess.

## Context

In chat the person can only ask the model to run a command; to run one themselves they leave wisp for
another terminal, and the model then knows nothing of what they did or saw. Claude Code and other agent
harnesses take a line that starts with `!` as a command the person runs directly, whose output joins the
conversation. The operator asked for the same in wisp's chat and `wisp-tui` (the roadmap's 0.18.0), and
settled its terms on 2026-09-30.

It is the first command in wisp that does not come from the model. Every command until now has passed
the same path ([ADR 0011](0011-risk-classifier-and-approval.md),
[ADR 0046](0046-approval-and-notifications-over-mcp.md)):
the policy's deny and allow lists, the risk classifier, the person's approval when the risk is moderate or
above, the Seatbelt sandbox, and the audit log. That path exists because the model chooses the command;
here the person does, which changes what each step is for.

## Decision

- **A line in chat that starts with `!` is a command the person runs.** `! git status --short` runs
  `git status --short` in the conversation's working directory, as `run_command` would, with its bounds
  (the output tail, the timeout). It does not call the model and does not start a model turn. A line that
  is only `!` runs nothing.
- **The checks that protect the Mac stay; the ones that stand in for the person go.**

  | Step | For a model's command | For a typed `!` command |
  | --- | --- | --- |
  | Policy deny and allow lists | yes | yes: a denied command is refused with the reason |
  | Seatbelt sandbox, writable roots | yes | yes: the same profile |
  | Risk classifier | yes | no: it decides whether to ask the person, who has just typed the command |
  | The person's approval | at `moderate` and above | no: typing it is the approval |
  | Audit log | yes | yes, marked as the person's |

  The person keeps the sandbox's protection against a mistyped or pasted command; a command the sandbox
  refuses (writing outside the writable roots) fails as it would for the model, and the message says so.
- **The output is shown in full,** as tool output is ([ADR 0045](0045-layered-context.md), D12): the
  person sees what the command printed, folded beyond `shownOutputLines`, with `/show` for the rest.
- **The model is told, as a reference after the turn.** The command and its output enter the thread record
  as the person's own action: on the next request the model sees one entry such as "the person ran `git
  status --short` (exit status 0, 4 lines)" with the output's reference, recallable with `memory`, exactly
  as a tool output becomes a reference after its turn. Tool facts are extracted from it as from
  `run_command` (the working directory, a test result), with source `person`. It is never presented as
  something the model did.
- **Chat and `wisp-tui` only.** An MCP caller types nothing; `respond` runs commands through the model, as
  before. Nothing changes over MCP.
- **Command mode is a state of the input box, in `wisp-tui`.** Typing `!` into an empty box switches it
  to command mode: the `!` is taken as the switch, not kept as text, and what follows is the command.
  Backspace or Delete in an empty box in command mode switches back to the normal prompt, so a stray `!`
  costs one key to undo. Sending in command mode runs the command; the box returns to the normal prompt
  afterwards. Plain chat has no box, so there a line that starts with `!` is the command, as above.
  Refined by the operator on 2026-10-04, before release: Backspace with the cursor at the start of the
  line also switches back, keeping the text typed so far as an ordinary message; and the opposite, `!`
  typed at the start of a line that has text switches it to command mode, the text becoming the command.
  Also on 2026-10-04: a fact from a typed command's output keeps the source `person`, but a value is held
  once across sources, so the workdir fact a chat records at its start and the same one from `! pwd` do
  not stand side by side; the stronger source keeps it ([context-management.md](../context-management.md),
  "Versions and precedence").
- **The input box shows command mode.** In command mode the input box's background changes from `Deep`
  (#253B4E) to a muted pale amber, slightly more orange than yellow, with black text: a new palette
  colour, `command`, **#E8B577**, chosen by the operator on 2026-10-04 from three rendered candidates
  (#E8B577, #E2BC8C, #E5AA6E), defined in both palettes and checked by the gate's palette check. It is
  distinct from `Amber` (#F2B950), which marks approvals and warnings, so typing a command never looks
  like a warning. In the scrollback the command's line is a stripe in a darker, faded variant,
  `commandSent`, as an ordinary prompt's line is `Sent` (#121D27) where the box is `Deep`: **#745A3C**,
  half the box colour's brightness as `Sent` is of `Deep`, with light text, chosen by the operator from a
  render on 2026-10-04 over a fainter #856B4C with black text. Plain chat, which has no box, colours the
  prompt marker instead.
- **The input box shows when wisp is busy.** While a turn is processing, the input box is visibly inactive:
  dimmed, with a short status in place of the cursor (for example "working: read_file"), and typing is held
  until the turn ends rather than accepted invisibly. This is the same release's second input-box change
  (the roadmap's 0.18.0), recorded here because both change how the box reads.
- **Audited** as `command.typed` (the line, the directory, the policy decision, the outcome, and the output's
  size), with the existing `command.outcome` event; documented in `logging.md`.

## Consequences

- The person can check something without leaving chat, and the model then knows what they saw.
- A typed command can do anything the sandbox allows without asking; that is the point, and the sandbox's
  writable roots still bound it. A command pasted from elsewhere runs as typed, which `!` makes explicit.
- `!cd` does not change the conversation's working directory: each command runs in its own shell, as the
  model's do. Changing the directory is left open; `/cd` would be the natural form if it is wanted.
- The thread record gains an entry kind for the person's command; composition, the context view, and the
  sidecar carry it.
- Tests without the model: the parsing (`!`, `! `, a bare `!`, a `!` inside a message), entering and
  leaving command mode in `wisp-tui` (`!` in an empty box, Backspace or Delete in an empty box, a `!`
  typed after other text staying text), each check applying or not as the table says, a denied command, a
  sandbox refusal, the output shown and folded, the entry the next request carries, the facts extracted,
  the audit, the TUI's colours (`command` and `commandSent` in both palettes, the gate's check) and the
  busy state, and that MCP is unchanged.

**Refined on 2026-10-09 (0.21.1), after a code review.** A fact from a typed command's output no longer takes the
source `person`. Ranked with the person, an observation pinned a stale value: a passing `! swift test` outranked
the model's later failing run of the same command, and nothing but the person's own word could replace it. What a
command printed is an observation, whoever ran it, so its facts are recorded with the source `tool` and the detail
`the person's command` (shown as `from the person's command, turn N, entry M`), and the newer observation wins.
`person` stays for what the person states (`/fact`, `/task`). The workdir a chat records at its start keeps its
source, and a `! pwd` that gives the same value still adds nothing. Also: a typed command is no turn of its own in
condensing; it goes with the turn after it, so the floor of one turn keeps the last turn the model took part in
([context-management.md](../context-management.md), "Condensing"), and its notice without `memory` says not to
run it again, as any command's reference does (ADR 0057).
