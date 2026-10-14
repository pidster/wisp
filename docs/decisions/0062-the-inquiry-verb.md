# ADR 0062: The inquiry verb: the model asks the person a question mid-turn

Date: 2026-10-12. Status: accepted, 2026-10-12, for 0.24.0; built 2026-10-12 (see "Built" at the end). The operator accepted every
recommendation of D1 to D15 except D10, which is revised below to their decision. Takes up the open half of the
[escalations proposal](../proposals/2026-09-20-escalations.md), whose approval half
[ADR 0046](0046-approval-and-notifications-over-mcp.md) settled. Amends [ADR 0044](0044-host-effects.md) (a third
host effect, the question that ADR's "Consequences" foresaw), [ADR 0046](0046-approval-and-notifications-over-mcp.md)
and [ADR 0048](0048-permanent-facts-over-mcp.md) (the pending channel carries a third kind of request), and
[ADR 0060](0060-a-verification-pass.md) (a reader for claims about the person's answers), once built. Each choice
keeps its options and recommendation, marked with what the operator decided.

### The operator's review, 2026-10-12

| Item | Decided |
| --- | --- |
| D1 to D9, D11 to D14 | As recommended |
| D10, the wait | Revised: "Sometimes the operator has left the terminal, but will return - timing out isn't necessary if the harness can just safely and quietly await their return." `inquiry.timeoutSeconds` defaults to `0`, waiting until the person answers; a deadline is still available. Section 6 |
| Under MCP | A `respond` call must not block while the person is away: the turn parks and the answer reaches the thread's next turn. Section 6 |
| D15, the dialog's hold under MCP | As recommended: the call holds the dialog for 60 s, fixed, not a setting, then withdraws it and parks the turn. Section 6 |
| Plain chat's approval prompt | Kept with no timeout (`TerminalApprover` reads a line, no deadline): the person is at the terminal. Not to be raised again |

## Context

A model that is stuck mid-turn has two moves today: guess, or stop. Neither is good when the gap is one only the
person can fill: which of two files with the same name was meant, which of two readings of "the config", a value
that is in no file it can read, whether an existing file may be replaced. The 2026-10-04 sessions read back for ADR 0060
show what a small model does with a gap: it reports results that no call produced.

What exists that a question could build on, verified in the code at `df6ecc0`:

| What | Where | What it gives an inquiry |
| --- | --- | --- |
| The approval effect | `Approver` (`Approval/Approval.swift`), carried by each face's `SessionHost` (ADR 0044) | The shape: one protocol, one implementation per face, the tool never knowing which |
| Plain chat's dialog | `TerminalApprover` writes to stderr, reads one line; no timeout, end of input refuses (`docs/approval.md`) | A place to ask, and proof that a turn can wait inside a tool call for as long as the person takes: a plain-chat approval already does |
| Notes between turns | `ConversationNotices`, taken by `Agent` as a turn begins and stored as `ThreadRecord.Kind.notice` entries the turn's request carries; how a background pull's end reaches the model (ADR 0059) | The way an answer given after a turn ended reaches the model's next turn |
| `wisp chat --json` and `wisp-tui` | `JSONApprover`, and `ChatProtocol.ask` for a `ChatChoice`, both bounded by `approval.timeoutSeconds`, a lapsed one sent `withdrawn` | A choice line that `wisp-tui` already renders, with typed text (`acceptsText`, `tools/wisp-tui/src/protocol.rs`) |
| MCP elicitation | `ElicitationApprover`: a form with one optional enum field (`scope`), bounded, withdrawn with `notifications/cancelled` | A dialog the client renders to its person. A text field has never been sent: in 2026-09 a form picker made Claude Code's dialog unresponsive (ADR 0011), and the picker came back with ADR 0014 |
| The pending channel | `PendingApprovals`: kinds `command` (`.request.json`) and `fact` (`.fact.json`), binding by SHA-256, first answer by hard link, staleness, sweeps (ADR 0046, ADR 0048) | Out-of-band answers from `wisp approvals`-style commands and `wisp-tui`, with the integrity rules already built |
| `OutOfBandApprover` | files, notifies, and races the channel against elicitation; the first answer wins, the other withdrawn | The race, reusable for a question |
| The person-only rules | terminal-only `approve|deny` and `keep|drop` (kept on review, 2026-10-12); the default policy's deny patterns for both (`CommandPolicy.defaultDeny`); the sandbox refusing writes under `~/.wisp` | The same three walls for answering a question |
| Opt-in tools | `memory` (`context.memory`, ADR 0057) and `models` (`tools.models`, ADR 0059) are left out of the default set by `ToolRegistry.defaultNames` | The pattern for a tool that is off by default |
| `ChatChoice` | its doc comment: "Only chat commands ask; the model never does." | The line this decision would change |

Three things make a question unlike an approval. It is not a permission: no answer runs anything, and every command
the model runs after it still passes the policy, the classifier, the gate, and the sandbox. Its text is the model's,
written to the person, so it can carry anything the model writes, including a request for a password. And its answer
may be personal, where an approval's is one of five words.

And one thing the model can already do: end its turn with a question in its reply. In chat the person answers on the
next turn. That costs the turn's state (the files read, the plan) only as far as condensing loses it, and over MCP it
sends the question to the calling agent, not the person. A tool keeps the turn going with the answer in hand, and
over MCP can reach the person directly.

## Decision

### 1. A tool, and whether the model gets it

The question is a tool call: the framework runs the tool loop (`Agent`), and a tool is the only point mid-turn at
which wisp holds the model's request and can wait. The tool's call is audited by `AuditedTool` like every other, its
result bounded like every other.

**Decided as recommended, 2026-10-12 (D1): build the tool, or rely on the reply.**

| Option | For | Against |
| --- | --- | --- |
| (a) No tool: the model asks in its reply and stops | Nothing to build; already works in chat | Over MCP the question goes to the calling agent, never the person; the turn ends where a tool would have gone on; no audit of what was asked as a question |
| (b) A tool, `ask` | Mid-turn; reaches the person over MCP; bounded and audited as a request with an outcome | A new effect through four faces; a small model may ask too often or not at all, which only an eval shows |

*Recommendation: (b), off by default (D2), with (a) kept as what the model is told to do on silence (D7).*

**Decided as recommended, 2026-10-12 (D2): on or off by default.**

| Option | For | Against |
| --- | --- | --- |
| (a) Off by default, like `memory` and `models`: a setting `tools.ask` (default false) adds it to the default set, a named list (`--tool ask`, `tools: ["run_command", "ask"]`) has it, `tools.disabled` removes it | Every tool's schema is in every prompt (`docs/tools/README.md`), and ADR 0057 measured that a tool that does not help costs; narrow threads (the git thread) never see it; nothing changes for anyone until they choose it | The person who would benefit most (chat) must turn it on |
| (b) On in chat and `wisp-tui`, off over MCP and `wisp respond` | Chat is where a person is always present | A default that differs by face; untested on any model |
| (c) On everywhere a person can answer | Simplest to explain | A delegated thread asks the person when the caller knew the answer; untested |

*Recommendation: (a) for 0.24.0, and an eval in `harness/Evals` (does the model ask when the prompt is ambiguous, and
not when it is clear) before (b) is considered. That is the rule ADR 0057 and ADR 0059 followed.*

**Decided as recommended, 2026-10-12 (D3): its name.** `ask` (short, as the roadmap names it), `ask_person` (says who is
asked, so a model does not take it for a lookup), or `ask_operator` (the proposal's). *Recommendation: `ask`, with the
description saying a person answers.*

The description is prompt text and short, about this:

```
Ask the person one question when you cannot go on without their answer: which of two things they meant, or a value
you cannot find. Not for permission (commands ask for themselves), not for secrets. Give options when there are few.
```

### 2. What the model may ask

| Shape | Arguments | The person answers | The model gets |
| --- | --- | --- | --- |
| Free text | `question` | a line of text | `answer: <text>` |
| Choice | `question`, `options` (2 to 6) | one option, or "none of these" | `chose: <option>`, or `none of these` |
| Yes or no | a choice of `yes` and `no` | one of them | `chose: yes` |

Yes or no is a choice of two, not a third kind: one dialog, one parser. A choice does not take typed text besides
"none of these"; a model that wants both asks a free-text question.

**Decided as recommended, 2026-10-12 (D4): the limits.** *Recommended values:*

| Limit | Recommended | Why |
| --- | --- | --- |
| Questions waiting per thread | 1 | A second `ask` while one waits is refused at once (`error: a question is already waiting`), whatever order the framework runs calls in |
| Questions per turn | 2 | Enough for a follow-up; a model that asks a third time is told to say what it needs in its reply |
| The same question twice in a turn | refused | The call ledger already counts repeats (ADR 0050) |
| `question` | 1 to 300 characters, one paragraph | Fits every dialog, the notification's body, and `wisp questions pending` |
| Each option | 1 to 80 characters | Fits a picker row and an elicitation `enumNames` entry |
| The answer | 2,000 bytes, longer cut with a note | Inside the 4 KiB tool-result bound (AGENTS.md) with room for the framing |

Everything shown from the question and options has control characters and bidirectional overrides escaped, as
`ApprovalRequest.visible` does for commands, because the model wrote it. The dialog is visibly the model's ("the
model asks", the thread named), never styled as an approval and never offered with approval's keys, so a question
such as "Approve `rm -rf build`? [y/n]" cannot pass for wisp's own gate.

**Decided as recommended, 2026-10-12 (D5): a question that asks for a secret.**

| Option | What happens |
| --- | --- |
| (a) Refused by rule | Before anything is shown, the question is checked against words for credentials (password, passphrase, token, API key, secret, private key, PIN, one-time or 2FA code, credentials); a match returns `error: ask does not ask for secrets; tell the person what is needed and where to set it` and is audited as `refused`. No model call |
| (b) Asked with a warning | The dialog says "never type a password here" above the question |
| (c) Nothing special | The person decides |

*Recommendation: (a), and on the answer side, whatever the question, the answer is passed through `SecretScanner`'s
`secret` rules (ADR 0031, no model): a credential-shaped value is replaced with its numbered marker in what the model
gets and everywhere wisp records the answer, and the person is told it was not passed on. A rule can be talked round
("the thing you log in with"); the answer scan is the backstop, and neither is a wall.*

### 3. How the answer reaches the model

The tool's result, bounded as above, in fixed forms the model can read and the readers (section 8) can check:

| Outcome | The tool returns |
| --- | --- |
| Answered | `answer: …` or `chose: …`, then `(from the person, via chat)` |
| None of these | `the person chose none of these options` |
| Declined | `the person declined to answer. Do not ask this again; say in your reply what you needed` |
| Waiting, under MCP (the turn parks, section 6) | `waiting for the person: "<question>" (question a1b2c3d4). Their answer reaches you as a note on a later turn. Do not guess it. Say in your reply what you asked and what depends on it, and stop` |
| Unanswered, only when a deadline is set (section 6) | `no answer within 30 min. Do not guess what the person would say. Say in your reply what you need, and stop` |
| Nobody to ask | `no person can answer here (wisp respond); say in your reply what you need` |
| Refused | `error: …` (a secret, a limit) |

**Decided as recommended, 2026-10-12 (D6): on silence, stop or assume.**

| Option | For | Against |
| --- | --- | --- |
| (a) Stop: say what is needed, do nothing that depends on it | Silence is never an answer (the operator's rule); nothing is done on a guess | A long task stops for one small question |
| (b) Proceed with a stated assumption, marked `assumed, not the person's answer: …` in the reply | Long tasks go on | The model's own guess, written next to the person's answers, is the thing this verb exists to prevent; a small model drops the marking |

*Recommendation: (a). The text tells the model to stop, and section 8's reader flags a reply that claims the person
answered when no call says so.*

### 4. Through which channels

The same faces as an approval, each its own `Asker` (the third effect a `SessionHost` carries, beside the approver
and the notifier):

| Face | How it asks | How it is answered |
| --- | --- | --- |
| Plain chat | The question, numbered options when there are any, then a prompt line (`ChatChoice.numbered`, `answer(typed:)`) | A line: a number or the text; an empty line declines |
| `wisp chat --json`, `wisp-tui` | A `choice` line with `kind: "question"` and `acceptsText` for free text, so any `wisp-tui` that renders choices shows it | The `choose` line; `withdrawn` when the question is withdrawn or a deadline lapses |
| `wisp mcp`, elicitation | A form: a `string` field `answer` (`maxLength` 2000) for free text, an enum for a choice; up while the `respond` call holds the turn (D15) | Accept with the field; Decline declines; Cancel is no answer, and the question goes on waiting out of band |
| `wisp mcp`, out of band | Filed in `~/.wisp/pending` as `<id>.question.json` and announced by one notification: "wisp: the model asks" — "Which config: ~/.wisp or ./wisp.json? — wisp questions answer a1b2c3d4" | `wisp questions answer ID` from a terminal, or a running `wisp-tui` that declared the effect `answer-questions`, for as long as it waits |
| `wisp respond`, `--yes` | Not asked | `ask` returns "no person can answer here" at once |

Over MCP the two ways race and the first answer wins, the other withdrawn, as ADR 0046 decided for approvals, under
the same `approval.outOfBand` switch. The pending file follows the channel's rules: mode 0600 in a 0700 directory,
written by rename, a binding over its id, question, options, thread, server process, creation, and expiry (none by
default), an answer by hard link carrying the recomputed binding, both files removed when taken. Unlike a fact
request, a question is stale when its server has gone or its thread has closed, since only that thread can take the
answer; and when a deadline is set and has passed. Its suffix is its own, so a wisp of
0.23 or earlier, which lists `.request.json` and `.fact.json`, never sees one.

**Decided as recommended, 2026-10-12 (D7): the command that answers out of band.**

| Option | Form |
| --- | --- |
| (a) Reuse `wisp approvals` | `wisp approvals answer ID` |
| (b) A command of its own, beside `wisp facts` | `wisp questions pending`, `wisp questions answer ID [TEXT]`, `wisp questions decline ID` |
| (c) A verb | `wisp ask answer ID` |

*Recommendation: (b): an answer is not an approval, and `wisp facts` set the pattern of one command per kind. And
`answer ID` with no text prompts for it on the terminal, which is the form the notification names: an answer typed as
an argument lands in the shell's history and is visible in `ps` while it runs. A choice is answered by number or
value. Terminal-only, as `approve` and `keep` are; the default policy gains a deny pattern for `wisp questions
answer|decline`.*

**Decided as recommended, 2026-10-12 (D8): the elicitation form.** A text field in Claude Code's dialog is untested, and
a form control once made that dialog unresponsive (ADR 0011). *Recommendation: probe it first, by hand against Claude
Code on this Mac, before the MCP leg is built: a string field, an enum of three. If either sticks, the MCP face asks out
of band only for that shape and the ADR records the probe.*

### 5. Who may answer

The person only, by the same walls as approvals: nothing in the MCP conversation answers (no argument, resource, or
result); wisp's own model cannot run `wisp questions answer` (the deny pattern) or write the channel (the sandbox);
the CLI answers only from a terminal (a speed bump, as ADR 0046 says, not a wall: the calling agent's own shell runs
as the person and is held back by its own harness's approval, not by wisp). Elicitation is rendered by the client to
its person; wisp cannot tell a client that hands elicitation to its own model, which ADR 0046 accepted for approvals.

**Decided as recommended, 2026-10-12 (D9): may the calling agent answer an inquiry at all?**

For: a question is not a permission. The caller often knows the answer (it wrote the task), already controls every
prompt the thread receives, and so gains no power over the model by answering; asking the person instead stalls a
delegated turn for minutes on something the caller could have said.

Against: an answer recorded as the person's when the caller gave it is a false record, and the reply then says "you
chose X" to a person who chose nothing. The proposal's `result` channel, the only way to let the caller answer, was
rejected for approvals because the caller could redeem it without asking anyone; for a question the harm is
attribution rather than permission, but it is the same mechanism.

| Option | What happens |
| --- | --- |
| (a) The person only | As above. While the question waits, the model says what it needs; `respond`'s result lists the turn's questions (`structuredContent.questions`: the text, the options, the outcome), so the caller can reply in its next prompt, which is recorded as the caller's words, as every prompt is |
| (b) Per thread, chosen at start: `ask: "person"` or `"caller"` | With `caller`, nobody is asked: `ask` returns at once with "your question was passed to the caller; say what you need and stop", and the result carries it. Still no answer through the conversation; the caller's next prompt answers, as its own words |
| (c) The caller answers through `respond` | Rejected: the escalations proposal's `result` channel, with the attribution problem above |

*Recommendation: (a) for 0.24.0, with (b) as the follow-up if delegated threads stall on questions the caller could
answer; neither ever records the caller's words as the person's.*

The person is told in the dialog where the answer goes: "your answer goes to the model, and to claude-code, which can
read this thread". A thread's output, context, and audit are readable through `wisp://threads/{thread_id}`, so an
answer given over MCP is never private from the caller; the dialog says so rather than imply otherwise.

### 6. Waits, silence, and a turn parked

**Decided (D10), revised by the operator on 2026-10-12.** The recommendation was a deadline of its own, 300 s by
default with `0` refused. The operator chose otherwise: "Sometimes the operator has left the terminal, but will
return - timing out isn't necessary if the harness can just safely and quietly await their return."

- **`inquiry.timeoutSeconds`, default `0`: wait until the person answers.** A positive value, 10 to 86400, sets a
  deadline, after which the question ends `unanswered`. It is a setting of its own, not `approval.timeoutSeconds`.
- **Silence is still never an answer.** Waiting for ever is not taking silence as a yes: nothing the question asked is
  done until the person answers, and the model is told to stop rather than guess (D6).
- **Safe:** a waiting question holds nothing but its own turn. Other threads run (an MCP server's threads run
  concurrently, `docs/mcp.md`), the server answers every other call, other faces go on, and under MCP not even the
  turn's `respond` call is held (below). It can always be withdrawn: Ctrl-C in chat and `wisp-tui`,
  `wisp questions decline ID`, `close_thread` or eviction, the server stopping.
- **Quiet:** one notification when the question is asked, through the session's routes, never repeated and never a
  reminder. On the person's return it is still there: the dialog still open in plain chat and `wisp-tui`, listed by
  `wisp questions pending`, shown by `wisp-tui` for questions waiting in `wisp mcp` servers.

**In chat and `wisp-tui` the turn simply waits**, inside the `ask` call, as a plain-chat approval already waits inside
`run_command` with no deadline: it is the person's own session. Plain chat's read has to be one that Ctrl-C (and a
deadline, when set) can end, which a blocking `readLine` is not; `wisp-tui`'s choice line already waits as long as it
is given (`ChatProtocol.ask` with no timeout).

**Under MCP the call does not wait for the person to come back.** Clients end long calls (`MCP_TOOL_TIMEOUT` in Claude
Code, `docs/mcp.md`), and Claude Code's dialogs stuck before (ADR 0046). So the turn parks, as a fact request returns
at once (ADR 0048, amended 2026-10-12):

1. `ask` files the question in the pending channel, posts the one notification, and shows the client's dialog for a
   fixed 60 s (D15). Answered there, the answer is the tool's result and the turn goes on as in chat.
2. Otherwise the dialog is withdrawn (`notifications/cancelled`, as ADR 0046 built), the question stays filed, and
   `ask` returns the waiting text (section 3). The model ends its turn saying what it asked; `respond` returns, with
   the question in its text ("a question waits for the person: … — wisp questions answer a1b2c3d4; its answer
   reaches this thread's next turn; do not answer it yourself") and in `structuredContent.questions` (`id`, `question`,
   `options`, `state: "waiting"`, and the thread's URI). The turn is recorded `inquiry.parked`.
3. The server watches the channel for the answer, as `FactKeeper` watches for a keep (every 200 ms). When the person
   answers (`wisp questions answer`, or `wisp-tui`), the answer is held for the thread as a note in
   `ConversationNotices`: "The person answered your question "`<question>`": `<answer>` (via wisp questions, 14:02)". The
   thread's next turn begins by storing it as a notice (`ThreadRecord.Kind.notice`), so the model reads it with that
   turn's request, exactly as a background pull's end reaches it (ADR 0059). `wisp://threads/{thread_id}` shows the
   question `answered`, with the answer, from the moment it is taken; nothing is pushed to a client that may not be
   listening. The person's command says so: "answered; thread git reads it on its next turn".
4. The caller's next `respond` on the thread resumes the work: any prompt carries the note, a bare "continue"
   included. A different prompt while the question still waits runs as usual, and its turn begins with the notice
   "your question "`<question>`" still waits for the person; do not assume its answer", and a second `ask` is refused
   while one waits (D4). With a deadline set and passed, the note says it went unanswered.

*Considered and rejected for the park: keeping the turn's task suspended in `ask` after `respond` returns, and handing
its reply to the next call.* The tool would get the answer as its result, the cleanest form; but calls on one thread
run one turn at a time and a second `respond` waits for the turn under way (`docs/mcp.md`), so the caller's next call,
whatever it said, would block until the person answered: the wait the operator asked to avoid, moved one call later.
The framework's tool loop cannot be paused and taken up by another call (the turn is one `Agent.respond`), so the
notice is what the code can do, with the mechanism it already has.

**Decided as recommended, 2026-10-12 (D15): how long an MCP `respond` holds the dialog before the turn parks.**

| Option | For | Against |
| --- | --- | --- |
| (a) Park at once, the dialog left up after the call returns | No call held at all | An elicitation outstanding after its tool call has ended is unprobed in Claude Code, and an answer there would arrive with no turn to take it but the notice |
| (b) Hold the call for a short, fixed while (60 s) with the dialog up, then withdraw it and park | The common case, the person watching the client, gets the answer inside the turn, with its state; 60 s is well inside a client's tool-call timeout; withdrawing a dialog is built (ADR 0046) | A call held up to a minute; a person who answers the dialog at 61 s finds it gone and answers out of band |
| (c) Park at once, never elicitation for questions | Simplest; nothing outstanding | The person at the client must leave it for a terminal or `wisp-tui` every time |

*Recommendation: (b), fixed at 60 s rather than a setting; the probe of D8 also checks the withdrawal closes Claude
Code's dialog, which ADR 0046 left unprobed.*

| Event | Outcome | The model is told |
| --- | --- | --- |
| Answered while the turn waits | `answered`, delivered `tool` | the answer, as the tool's result |
| Answered after the turn parked | `answered`, delivered `notice` | the answer, as a note on the thread's next turn |
| A deadline set and passed | `unanswered` (only then) | the unanswered text, or the note saying so |
| Decline (empty line, Decline, `[n]`, Esc, `wisp questions decline`) | `declined` | the declined text, or the note |
| Ctrl-C in `wisp-tui`'s dialog | `declined`, as Ctrl-C refuses an approval there | the declined text |
| Ctrl-C at plain chat's prompt, or a second Ctrl-C in `wisp-tui` | `stopped`: the turn stops (`TurnStop`, ADR 0049) | nothing; the turn ends `stopped by you` |
| `notifications/cancelled` while the call holds the dialog | `abandoned`; the question withdrawn | nothing; the call is gone |
| `close_thread` or eviction | `withdrawn` at once, the pending file removed: close waits for a turn under way (`docs/mcp.md`), so a question held in the call must not hold it | nothing; the thread is gone |
| The server stops | `withdrawn`; its pending file is swept as stale | nothing |
| An answer to a question already withdrawn | refused to the person: "thread git closed first; your answer was not used" | nothing |

### 7. Audit

**Decided as recommended, 2026-10-12 (D11): the event kinds.** The operator's sketch names `inquiry.requested`,
`inquiry.answered`, and `inquiry.unanswered`. ADR 0046's split fits the cross-process case better: an answer given by
`wisp questions` is recorded in the answering process, and the outcome on the asking thread. *Recommendation:*

| Kind | Where | Fields |
| --- | --- | --- |
| `inquiry.requested` | the asking thread | `inquiry` (id), `question`, `options`, `ways` (`terminal`, `json`, `elicitation`, `pending`), `timeoutSeconds`, `call` (the `ask` call) |
| `inquiry.parked` | the asking thread, under MCP, when the turn ends with the question waiting (section 6) | `inquiry`, `waitedSeconds` (how long the call held the dialog) |
| `inquiry.answered` | the answering process, for `cli` and `tui` | `inquiry`, `via`, `taken` |
| `inquiry.settled` | the asking thread | `inquiry`, `outcome` (`answered`, `none`, `declined`, `unanswered`, `stopped`, `withdrawn`, `abandoned`, `refused`, `failed`), `via`, `delivered` (`tool`, or `notice` after a park), `answer`, `redacted` (markers applied), `seconds` |

`unanswered` is then an outcome, not a kind, as `timed-out` is for `approval.settled`, and since D10's revision it
occurs only when a deadline is set; a question that simply waits has no outcome until it is answered, declined, or
withdrawn. `inquiry.parked` is the revision's addition: a parked question is not settled. The alternative was the
sketch's three kinds, with `declined`, `stopped`, and the rest folded into `inquiry.unanswered`'s `reason`.

**Decided as recommended, 2026-10-12 (D12): what is recorded of the answer.** The audit log stores content verbatim by
decision (`docs/logging.md`), and the answer is in `tool.result` whatever `inquiry.settled` holds, because `AuditedTool`
records every tool's output, and in the thread's record and output store as any tool output is.

| Option | For | Against |
| --- | --- | --- |
| (a) Verbatim, with the secret-rule markers of D5 | The log is the record of what the model was told; the turn can be reconstructed | A personal answer sits in a user-only file for `audit.keepFiles` rotations |
| (b) Its length and a hash only, everywhere wisp records it | Nothing personal kept | `tool.result` and the output store would have to treat one tool apart; the thread's transcript must still hold the answer for the model, so it is not gone, only unaudited; ADR 0060's readers lose the answer to check against |
| (c) (a), and a setting to choose (b) | The person chooses | A second path to keep correct |

*Recommendation: (a). The question and answer are the person's own words in the person's own file, which is where
the prompt they type is kept already.*

### 8. Beside the verification pass, facts, and thinking

- **Verification (ADR 0060).** An `ask` call is a call in the turn's list with its result, so the existing readers
  already treat a quoted answer as a call's output. **Decided as recommended, 2026-10-12 (D13): a reader for claims
  about the person.** A reader `answer` would flag "you chose", "you said", "as you confirmed", "the person answered"
  when no `ask` call in this turn or an earlier one was answered. *Recommendation: add it. A model claiming the person
  agreed is the worst fabrication this verb makes possible, and the forms are few.*
- **Facts (ADR 0045, ADR 0049).** **Decided as recommended, 2026-10-12 (D14): does an answer become a fact?** (a) No: it
  stays a tool output, a reference after its turn and recallable with `memory`. (b) A thread fact, source `person`,
  subject `answer`, the question (cut to 80 characters) as its name and the answer as its value, so condensing never
  loses it; never permanent, since admission to the shared store stays with the person (D2 of ADR 0045, ADR 0048). A
  redacted answer records the marker. *Recommendation: (b), for answered and chosen outcomes only, through the fact
  extraction that already gives `person` to a typed command's output (ADR 0049).* An answer taken after a park is
  recorded as the fact when it is taken, so it is in the facts layer of the thread's next turn beside the note.
- **Thinking (ADR 0053).** Nothing changes. The question is written in the turn's own request, with the conversation's
  thinking; the thinking before it is recorded as the turn's as always. The checks on a question (D4, D5) are rules,
  so no side call is added. The time a question waits is the person's, not the model's, and is shown apart from the
  turn's model time in `/stats`.

### 9. How it differs from an approval and a fact request

| | Approval (ADR 0011, 0046) | Fact request (ADR 0048) | Inquiry (this) |
| --- | --- | --- | --- |
| Raised by | the gate, before a risky command | a caller, `set_fact_scope permanent` | the model, `ask` |
| What it is | a permission | consent to admit to the shared store | a request for information |
| The answer | a scope or no | keep or drop | text, or one option |
| Blocks | the turn (and under MCP its `respond` call) | nothing; returns at once | in chat, the turn; under MCP nothing past a 60 s hold (D15): the turn parks and the answer reaches the next turn |
| Wait | `approval.timeoutSeconds` (600; `0` for ever) | none, by the operator's choice of 2026-10-12 | `inquiry.timeoutSeconds`, `0` by default: until the person answers (D10) |
| Silence | refused, `timed-out` | nothing kept | nothing done on it: the model stops and says what it needs; `unanswered` only past a deadline set |
| Notified | once per request | once per request | once, never repeated |
| Remembered | per scope; `project` and `always` in `approvals.json` | the drop, for the thread's life | never; the answer is a thread fact if D14 (b) |
| Answered | chat, `wisp-tui`, elicitation, `wisp approvals` | `wisp-tui`, `wisp facts` | chat, `wisp-tui`, elicitation, `wisp questions` (D7) |
| The calling agent | never | never | never (D9) |
| `--yes` | approves once | nothing | nothing; not asked |
| Pending file | `<id>.request.json` | `<id>.fact.json` | `<id>.question.json` |
| Text shown | wisp's, from the command | wisp's, from the fact | the model's, escaped and labelled |

## Consequences

- A stuck model has a third move, audited, that never takes silence for an answer. In chat the answer arrives inside
  the turn, however long the person is away. Over MCP the question reaches the person, not the caller; the caller
  learns of it from `respond`'s result, and the answer reaches the thread's next turn as a note.
- A question waits as long as the person is away and costs nothing meanwhile: no call held past the short hold, no
  thread but its own waiting, one notification. A question nobody answers stays filed until it is declined or its
  thread closes; `wisp questions pending` shows it.
- A parked turn's state is what the thread record keeps (its tool outputs as references, the facts, the summary), not
  the framework's session at the moment of asking: the model takes the answer up from the note, on a new request, not
  inside the tool call. That is the cost of not holding the call; the D15 hold keeps the common case inside the turn.
- A caller that never calls again leaves an answered question's note waiting for a turn that does not come; the
  thread's resource shows the answer, and closing the thread discards it.
- Off by default: nothing changes until `tools.ask` or a named list turns it on, and whether a model uses it well is
  for an eval to show, not this decision.
- A third host effect and a third kind in the pending channel: ADR 0044, 0046, and 0048 gain "Amended by" lines.
  `ChatChoice`'s rule that the model never asks ends; a model's question is a choice with `kind: "question"`.
- `wisp chat --json` gains an effect, `answer-questions`, for questions waiting in `wisp mcp` servers; additive. Plain
  chat does not show those, for ADR 0046's reason.
- Plain chat gains a read for questions that Ctrl-C and a deadline, when set, can end. Its approval prompt keeps
  having no timeout, as the operator decided on 2026-10-12.
- A question is not private from the calling agent, and the dialog says so.

**Tests it would need, all without a model** (`ScriptedModel` for the tool loop, `WispServerWireTests` for the wire):
the tool's arguments and every limit (shape, length, options, one waiting, two a turn, a repeat); the secret rule on
questions and the answer scan with its markers; each face's asker (plain chat's numbered list, typed text, empty line,
Ctrl-C, a deadline when set, and no deadline by default; the JSON `choice` line, `choose`, `withdrawn`); the pending
kind (filing apart from the other two, binding, an altered request, a replayed answer, the first answer winning, no
expiry by default, staleness when the server or thread has gone, a 0.23 wisp not seeing it);
`wisp questions pending|answer|decline` with the terminal check and the prompt for text; the race of elicitation and
the channel during the hold, each way first, the other withdrawn; the park (the hold lapsing, the dialog withdrawn,
`respond` returning with `questions` waiting, `inquiry.parked`); an answer after the park held as a note and carried
by the next turn's request, over the wire, a bare "continue" included; a different prompt while a question waits
(the still-waiting notice, a second `ask` refused); the thread resource showing waiting and answered; exactly one
notification however long it waits; decline, stop, cancellation, `close_thread` and eviction withdrawing at once, a
server stopping, an answer after withdrawal refused; a deadline set and passing; `wisp respond` and `--yes` not
asking; the deny pattern; the audit fields; the
`answer` reader on positive and negative cases (D13); the `person` fact (D14); `wisp-tui`'s dialog and queue in
Rust. An eval in `harness/Evals` for whether models ask when they should (outside the gate, for D2).

**Docs it would touch:** `docs/tools/ask.md` (new) and `docs/tools/README.md`; `docs/approval.md` (a section on
questions beside approvals, or a page of its own if it grows); `docs/wisp.md` (`wisp questions`,
`inquiry.timeoutSeconds`, `tools.ask`, the chat dialog, the protocol's `kind` and effect); `docs/mcp.md` (the
elicitation form and its hold, the park, `questions` in `respond` and the thread resource, the rule that a caller never
answers); `docs/logging.md` (the four kinds); `docs/design.md` (the `Asker` effect); `docs/verification.md` (the
reader); `docs/context-management.md` (the answer fact); `AGENTS.md` (a calling agent never answers wisp's questions,
and reads `questions` in the result); `CHANGELOG.md`; the roadmap and backlog entries.

**Size: larger, about as large as ADR 0048 was** (an estimate, not a measurement): the tool and its checks, the
`Asker` protocol and four implementations, a pending kind, a CLI command, the JSON and TUI additions, a reader, the
setting, the park and its notes, and the tests above. Four commits, each a working state: the tool with plain chat and
`wisp-tui`; the pending kind and `wisp questions`; the MCP leg, its hold and park, after the probe (D8); the reader and
the fact.

**Deliberately left out:** reverse delegation through MCP sampling (asking the caller's model) stays unscheduled; a
caller answering (D9 (c)); answering from off the Mac, as ADR 0046 leaves out; questions from tools other than the
model's `ask` (the gate keeps approvals, the models tool its own questions); a remembered answer reused across threads.

## Built

Built 2026-10-12, as decided (D1 to D15 with D10 as revised), in four parts that each leave a working state.

- **The tool and the chat faces.** `AskTool` (`Tools/AskTool.swift`), off by default: `tools.ask` adds it to the
  default set, a list naming it has it, `tools.disabled` removes it; `ToolRegistry.builtInNames` gained `ask`, and
  the assessment's catalogue a clause for it. `Question` (`Approval/Inquiry.swift`) holds the limits of D4
  (`validate`), the rule on secrets of D5 (`asksForSecret`, the words as words), the answer scan
  (`Outcome.masked`, `SecretScanner`'s `secret` rules and `Redactor`'s markers, 2,000 bytes), and the fixed texts
  of section 3 (`AskTool.text`). The third host effect is `Asker` on `SessionHost`, returning a `Question.Reply`
  (the outcome and where the person answered): `NobodyAsker` for `wisp respond`, `--yes`, and a server with
  `approval.outOfBand` off; `TerminalAsker` for plain chat, whose read is `LineReader` (`CLI/LineReader.swift`), a
  `poll(2)` loop on a dispatch queue of its own that a `TurnStop` and a deadline end, so nothing is left blocked on
  standard input; `JSONAsker` for `wisp chat --json`, a `choice` line with `kind` `question` (`ChatChoice.kind` and
  `.origin`), `withdrawn` on a lapse or a stop. `ChatLoop` was not touched: the asker lives in the host, as the
  approver does, and `ChatActivity` learnt `inquiry.requested` so the working line yields to the dialog.
  `wisp-tui` renders the question as a picker titled "the model asks" with where the answer goes, Esc and Ctrl-C
  declining, and queues questions behind an open choice or typed text as it queues MCP approvals.
- **The pending kind and `wisp questions`.** `PendingApprovals.Kind.question`, `<id>.question.json`, bound over
  the id, question, options, thread, server process, creation, and expiry; an answer carries `decision`
  (`answer`, `chose`, `none`, `decline`) and `text`, checked against the options; stale when its server has gone
  or a deadline has passed; a 0.23 wisp never lists the suffix. `wisp questions pending|answer|decline`
  (`QuestionsCommand`, entry point `questions`): `answer` shows the question and prompts for the text, so an
  answer is in neither the shell's history nor `ps`; both run only from a terminal, and the default policy
  refuses them to the model. `PendingRelay` and `wisp-tui`'s `answer-questions` effect show questions waiting in
  servers as `choice` lines with `source` `mcp`.
- **The MCP leg.** `OutOfBandAsker` files the question, posts the one notification ("wisp: the model asks",
  source `inquiry`), and races the channel against the client's form for the hold (`OutOfBandAsker.hold`, 60 s,
  fixed; shortened by a deadline shorter than it), then hands the question to the thread's `InquiryBox.park`,
  whose watch (every 200 ms) delivers the answer as a `ConversationNotices` note to the thread's next turn,
  records the fact through `ThreadActor.recordAnswer`, and audits `inquiry.settled` with `delivered` `notice`.
  `respond` posts the still-waiting notice before a turn, appends the waiting line to the reply's text, and
  returns `structuredContent.questions`; `wisp://threads/{thread_id}` lists `questions`; `close_thread`,
  eviction, and the server stopping withdraw at once. **The elicitation form (`ElicitationAsker`, a `string`
  field `answer` with `maxLength` 2000, or an enum of the options and `none of these`) is built behind
  `inquiry.elicitation`, off by default, until the operator's hand test of D8**; the procedure is in
  `docs/mcp.md` ("Questions"), and its outcome is to be recorded here.
- **Audit, facts, verification.** The four kinds of D11 (`inquiry.requested`, `inquiry.parked`,
  `inquiry.answered`, `inquiry.settled`), `docs/logging.md`. An answered or chosen question becomes the thread's
  `answer` fact, named by the question cut to 80 characters, source `person`, through `FactExtraction` inside
  the turn and `Agent.recordAnswer` after a park; `answer` is a subject kind the resource ships (`dynamic`,
  `trim`, not distilled). The verification pass gained the `answer` reader of D13 ("you chose", "you said", "as
  you confirmed", "the person answered", "per your answer"), supported by an answered `ask` call of this turn or
  an earlier one, or by an `answer` fact the thread holds (a note after a park is no call).

**What differed from the text above.** The audit records a refused question (a secret, a limit, nobody to ask) as
`inquiry.settled` with `outcome` `refused`, with no `inquiry.requested` before it, since nothing was asked. The
chat's `/stats` does not yet show the time a question waited apart from the model's; the turn's `seconds` include
it. `wisp questions answer` takes no text argument at all (section 4 offered `[TEXT]`), by the operator's brief:
the prompt keeps the answer out of history and `ps`. The settings are `inquiry.timeoutSeconds` (0, as revised) and
`inquiry.elicitation` (false, D8); `tools.ask` (false, D2). The hand test of D8 has not been run: the switch
stays off, and the ADR is to be updated with the probe's result.

Tested without a model (`InquiryTests`, `InquiryWireTests`, the `wisp-tui` tests in Rust): the list in
"Consequences", less the eval of D2, which stays outside the gate.
