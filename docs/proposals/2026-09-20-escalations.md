# Proposal: escalations, with two verbs and a choice of channels

Date: 2026-09-20. Status: for review. Becomes the next ADR (amending ADR 0011 and 0014) when accepted.
Update 2026-10-02: approval for clients without elicitation was settled by
[ADR 0046](../decisions/0046-approval-and-notifications-over-mcp.md), through another of wisp's faces; the
`result` channel below was considered and rejected there, because the calling agent could redeem the id
without asking anyone. The inquiry verb is still open.

## Problem

wisp has one way to reach its operator: `Approver`, one protocol with one question ("may this command
run?") and one channel hard-wired per face (terminal for `chat`, MCP elicitation for `mcp`, deny for
`respond`, auto for `--yes`). Two things do not fit:

- **Clients without a dialog.** The Claude mobile app does not render elicitation, and the terminal
  dialog sticks intermittently. Every question then waits out the timeout and is declined. The paused
  question from 2026-09-17 ("make the ask work in every client") is still open.
- **The model has no way to ask anything.** A small model that cannot tell which file was meant, or
  whether to overwrite, guesses. There is no bounded, audited way to put a question to the operator.

## Goals

1. Two verbs: **approval** (the gate's yes/no with scope, unchanged in meaning) and **inquiry** (a
   question from the model with a free-text or schema-shaped answer).
2. A **channel** chosen per server process, independent of the verb, so an operator can pick how
   escalations reach them: a blocking dialog where one exists, or a non-blocking hand-off to the calling
   agent where it does not.
3. Every channel keeps the standing rules: a bounded wait, silence is a refusal, dangerous commands never
   become standing approvals, and every decision is audited with its channel.
4. No change to policy, sandbox, classifier, store, or the audit envelope.

## Non-goals

- Proving who answered. A channel that hands the question to a calling agent cannot tell a human's
  answer from the agent's. The design records the channel honestly and leaves attestation to the client.
- A native macOS dialog and a shell-side queue. Both fit the channel abstraction and are listed so the
  abstraction is shaped for them, but they are not built in this change.

## Verbs

| Verb | Raised by | Request | Outcome | Safe default | Remembered |
| --- | --- | --- | --- | --- | --- |
| approval | `ApprovalGate` before a risky command or credential-like read | `ApprovalRequest` as today: command, line, pattern, directory, assessment | `.approved(scope)`, `.denied(reason)`, `.unanswered(waited)` | denied, audited `timed-out` | per scope, as today |
| inquiry | the model, through a new `ask_operator` tool | `InquiryRequest`: question text, optional `GenerationSchema` for the answer, the thread and turn | `.answered(text)`, `.declined(reason)`, `.unanswered(waited)` | the tool returns `error: no answer from the operator: …` and the model continues | never |

`ask_operator` is a `WispTool` like the others: bounded output (the answer is capped at 4 KiB), audited
as `tool.call` and `tool.result`, listed in `wisp://tools` with an example prompt, selectable with
`--tool`. Its description tells the model to ask only when it cannot proceed and to ask one thing.

## Channels

| Channel | Faces | Reaches | Blocks the call | Approval | Inquiry |
| --- | --- | --- | --- | --- | --- |
| `terminal` | chat | the person at the keyboard | yes | as today | prints the question, reads one line |
| `elicitation` | mcp (default) | clients that render it | yes | as today | elicits a form with one text field (or the schema's fields) |
| `result` | mcp | any client whose agent will ask | no | returns `pending` in the reply; redeemed on the next call | same, with the answer text redeemed |
| `auto` | any, `--yes` | nobody | no | approves once | declines with "no operator (auto)" |
| `deny` | respond | nobody | no | denies with the usual advice | declines with "no operator; use chat or MCP" |
| `dialog` (later) | any | the person at this Mac | yes | native alert | native prompt |
| `queue` (later) | any | any shell | no | `wisp escalations` lists and answers | same |

The `result` channel is the new one and is what makes the mobile case work. Its contract:

1. wisp refuses the command (or declines the inquiry) for this turn, records `approval.requested` (or
   `inquiry.requested`) with `channel: result`, and files a **pending escalation**: a `ShortID`, the verb,
   the exact request, the thread, and an expiry (`escalation.pendingSeconds`, default 600).
2. The `respond` result carries `pending`: an array of `{id, kind, command|question, pattern, level,
   reasons, expiresAt}`, alongside the existing `refusals`.
3. The calling agent puts the question to its operator and calls `respond` again on the same thread with
   `answers: [{id, scope}]` for approvals or `{id, text}` for inquiries. The prompt may be a nudge such as
   "continue".
4. wisp checks each answer's id is pending, unexpired, and belongs to this thread; on a match it grants
   the approval with the given scope (through the same gate path as a dialog answer, so the dangerous
   downgrade and the store apply) or delivers the inquiry answer to the waiting tool call, records
   `approval.decided` (or `inquiry.decided`) with `channel: result`, and removes the id. A stale,
   unknown, or mismatched id is refused and audited; it never runs anything.
5. An id nobody redeems expires. Expiry is audited as `timed-out`, the same as an unanswered dialog.

For inquiries on the `result` channel the model's turn ends with the tool having returned "pending; the
operator will be asked", and the answer arrives as the tool result on the next turn. The framework's
tool loop cannot suspend across calls, so the tool returns immediately and wisp replays the answer as a
`toolOutput` on the next prompt, before the new prompt. That replay is the one piece of transcript
surgery in the design and is recorded as such in the ADR.

## Shape in code

```swift
public enum Escalation: Sendable {
    case approval(ApprovalRequest)
    case inquiry(InquiryRequest)
}

public enum EscalationOutcome: Sendable, Equatable {
    case approved(ApprovalScope)
    case answered(String)
    case declined(String)          // denied, for approvals
    case unanswered(Duration)
    case pending(id: String)       // result channel only
}

public protocol EscalationChannel: Sendable {
    var name: EscalationChannelName { get }     // recorded in the audit
    func raise(_ escalation: Escalation) async -> EscalationOutcome
}
```

- `Approver` becomes `EscalationChannel`; `ApprovalDecision` becomes the approval subset of
  `EscalationOutcome`. `TerminalApprover`, `ElicitationApprover`, `AutoApprover`, `DenyingApprover` are
  renamed `…Channel` and gain the inquiry case. `ResultChannel` is new and owns the `PendingEscalations`
  actor (per session, shared by threads like `SessionApprovals`).
- `ApprovalGate` raises `.approval` and maps `.pending` to a refusal whose reason names the id, so the
  model is told "pending approval <id>" and the refusal list carries it.
- `AskOperatorTool` raises `.inquiry` through the conversation's channel and renders the outcome.
- `Conversation.setUp` takes the channel instead of the approver. `Session.Request` gains
  `escalationChannel: EscalationChannelName?`; the CLI sets it from `--escalation` on `mcp`
  (`elicitation`, `result`, `auto`), `--yes` remains the spelling for `auto` everywhere.
- Config: `escalation: { channel, timeoutSeconds, pendingSeconds }` replaces `approval.timeoutSeconds`;
  `approval` keeps `threshold`, `useModel`, `persistDays`. The old key is read for one release.
- MCP: `respond` gains `answers` (array) and the result gains `pending` (array); `close_thread` drops that
  thread's pending ids. The tool description and `wisp://tools.md` explain the redeem flow in two
  sentences.
- Audit: new kinds `inquiry.requested` and `inquiry.decided`; `approval.requested` and
  `approval.decided` gain `channel` and, for the result channel, `escalationID`; `fields(for:)` and
  `AuditEvent.Details` constructors extended; `logging.md` rows added.

## Docs

- `docs/escalation.md` replaces `docs/approval.md` (approval becomes its first half; the page keeps the
  decision order, scopes, and the trust story, and adds inquiry, channels, and the redeem flow).
- `docs/tools/ask_operator.md`, row in `docs/tools/README.md`.
- `docs/mcp.md`: `answers`, `pending`, the rule for calling agents.
- `docs/wisp.md`: `--escalation`, the `escalation` config section, chat's inquiry prompt.
- `docs/logging.md`: the new kinds and fields.
- `CLAUDE.md`: the rule "when a `respond` result carries `pending`, ask with `AskUserQuestion`, then
  call `respond` again on the same thread with `answers`", next to the git thread instructions.
- ADR 0018; ADR 0011 and 0014 gain "Amended by" lines; the paused item leaves `docs/backlog.md`.

## Tests, all without the model

- Channel conformance: every channel answers both verbs; `auto` and `deny` give the documented outcomes.
- `ResultChannel` and `PendingEscalations`: file, list, redeem once, refuse a second redeem, refuse a
  mismatched thread, expire and audit as timed out.
- Gate over the result channel: refusal names the id; a redeemed approval runs the command on the next
  call with the same scope semantics (dangerous downgraded to session, project persisted with source).
- `AskOperatorTool`: renders answered, declined, unanswered, and pending outcomes; output capped.
- `WispServer`: `pending` in results, `answers` redeemed, unknown ids reported, replay of an inquiry
  answer as a tool output before the next prompt (over the scripted `LanguageModel`, so the whole loop
  runs with no model).
- `PolicyScenarioTests` unchanged, proving the decision order did not move.
- Audit: constructors versus `fields(for:)` for the new kinds.

## Commit sequence

1. **Channel abstraction, no behaviour change.** `Escalation`, `EscalationOutcome`, `EscalationChannel`,
   renames, `channel` in the audit details, config key with the old one read. Every existing test
   passes with the same events plus one field.
2. **Result channel for approvals.** `PendingEscalations`, `ResultChannel`, `pending` and `answers` on
   `respond`, `--escalation`, docs and the `CLAUDE.md` rule. This alone closes the mobile case.
3. **Inquiry verb.** `InquiryRequest`, `ask_operator`, terminal and elicitation prompts for it, the
   replay on the result channel, tool page, eval prompt shapes.

Each is a working, documented state on its own; review can stop after any of them.

## Open questions for review

1. **Naming.** `escalation` as the umbrella, `approval` and `inquiry` as the verbs, `channel` for the
   route. Alternatives: `interaction`, `prompt`, `route`.
2. **Where the channel is chosen.** Per server process (`--escalation`, config) as proposed, or also per
   thread through a `respond` argument? Per thread lets one client mix, but lets a calling agent choose
   the channel that hands the answer to itself. The proposal keeps it operator-only.
3. **Redeem by the same thread only?** Proposed yes: a pending id belongs to the thread that raised it.
   Allowing another thread to redeem would let a `git` thread approve a `build` thread's command.
4. **Inquiry over the result channel replays a tool output into the transcript.** It is the honest
   representation of what happened, but it is the first place wisp writes a transcript entry itself.
   The alternative is to deliver the answer as part of the next prompt text, which is simpler and less
   faithful.
5. **Should `auto` answer inquiries?** Proposed: decline, because `--yes` means "I accept the risk of
   commands", not "invent answers". The model is told there is no operator and carries on.
6. **Pending expiry versus dialog timeout.** One setting or two? Proposed two: a dialog wait is seconds
   to minutes; a pending id may reasonably live longer while a person is asked in chat.
7. **Attestation.** Should `answers` carry an optional `answeredBy: human|agent` that wisp records
   verbatim without trusting it? Cheap, and it gives an honest client a way to say so.
