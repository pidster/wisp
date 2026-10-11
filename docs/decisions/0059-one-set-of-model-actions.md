# ADR 0059: One set of model actions, for the person and the model

Date: 2026-10-09. Status: accepted, 2026-10-11, built for 0.22.0; the open questions are settled below ("Settled when
built"). Extends [ADR 0056](0056-models-enabled-and-disabled.md) (models
enabled, disabled, and checked) and the 2026-10-09 amendment of [ADR 0052](0052-mlx-on-a-par-with-ollama.md) (pulls
from any publisher, confirmed by the person); applies [ADR 0011](0011-risk-classifier-and-approval.md) and
[ADR 0046](0046-approval-and-notifications-over-mcp.md) (approval) to a new kind of request.

## Context

The models wisp can use are managed in three places that share some rules and not others:

| Where | What it can do |
| --- | --- |
| `wisp models` (CLI) | list; `enable`, `disable`, `check`; `pull` (MLX), with the publisher question since 0.21.1 |
| `/models` (chat, `wisp-tui`) | the table, or in `wisp-tui` a picker whose rows are switched on and off and saved together; `enable`, `disable`, `check` |
| `/model [name]` (chat, `wisp-tui`) | switch the conversation to another model, keeping the transcript |

Two gaps showed on 2026-10-09. A pull exists only in the CLI, so in chat the person had to leave for a terminal, and
an `ollama pull` typed with `!` was killed by the 60-second command timeout part-way (that timeout is removed for typed
commands in 0.21.1). And the model has no way to take part: asked to find a model for a task, it can only run
`wisp models` through `run_command`, which the default policy refuses for the commands that change state, and it
cannot read the table in a structured form.

The operator asked for a tool for managing models in chat, "so the agent and user can both do it", and pointed out
that `/models` and `/model` already exist and should be adapted rather than duplicated.

## Decision

- **One action layer.** A `ModelActions` type in `WispCore` holds every model action: `list`, `show`, `pull`, `trust`,
  `enable`, `disable`, `check`, and `switch`. Each action declares what it reads and changes, and whether it needs
  the person. The CLI's `wisp models …`, chat's `/models` and `/model`, and the model's tool all call it, so a rule
  (a disabled model refused under any spelling, the publisher question, the capability check on enable) is written
  once.
- **The person's commands, adapted.**
  - `/models` gains `pull REPO` and `trust PUBLISHER`, as the CLI has them. The publisher question becomes a choice
    in the face's own dialog (pull once, trust from now on, refuse; refused by default).
  - `wisp-tui`'s picker gains a "pull a model…" row.
  - A pull shows its progress in the status line, does not block the conversation's display, and Ctrl-C cancels it,
    leaving the partial file to be resumed (ADR 0052's resume).
  - `/model` is unchanged. `/models` with no argument is unchanged.
- **The model's tool.** A `models` tool over the same actions, **off by default**, turned on by a list naming it or a
  setting (`tools` in a thread, as `memory` is turned on, [ADR 0057](0057-context-defaults-from-checkpoint-2.md)), so
  narrow threads such as the git thread never see it.

  | Action | For the model | Asks the person |
  | --- | --- | --- |
  | `list`, `show NAME` | yes | no: read-only; the reply is bounded (the table's columns that matter for choosing, paged) |
  | `pull REPO` | yes | always: the publisher, repository, licence, and download size; approved per pull, never remembered; the "trust from now on" answer is the person's alone |
  | `enable`, `disable`, `check` | yes | yes, as a change to `config.json`; may be remembered for the session, never always |
  | `trust PUBLISHER` | no | the person's only, through `/models trust` or the pull question |
  | `switch` | no | not offered to the model at first: a model choosing its own successor is a separate decision |

- **Through the approval gate.** A model's request is an approval request of its own kind, classified and keyed like
  `edit_file`'s (`models pull`, `models enable`, …), audited with `approval.requested` and `approval.decided`. A pull
  is never covered by a cached or standing approval. Under `wisp mcp` the tool is reachable only through `respond`, and
  its questions go through elicitation and `wisp approvals`, the first answer winning; silence refuses
  ([ADR 0046](0046-approval-and-notifications-over-mcp.md)).
- **Long work.** A pull the model asked for runs in the background once approved; the tool returns at once with
  "pulling …, about N GB" and the turn goes on; completion or failure arrives as a note in the conversation and in the
  audit log. The model does not wait in a loop, and does not run the pull again to see how it is going (the operator's
  rule that wisp never re-runs a command to see its output).
- **Audit.** The existing events (`model.pull`, `model.publisher`, `models.enabled`, `config.change`) gain the face and,
  for the model's requests, the approval's id; no new event kind unless the build finds one missing.

## Consequences

- One place for the rules: the CLI, chat, and the model cannot drift apart again (the 2026-10-09 review found the
  disabled-model check spelled differently in several places).
- The person can pull and trust in chat without a terminal; the model can find, check, and propose a model for a
  task, and the person decides.
- A pull is the largest effect any tool has had (gigabytes of disk and network): it is always asked, never remembered,
  and visible while it runs.
- More surface for the model to misuse: the tool is off by default, and every change it can make asks.
- The questions left open when this was proposed are settled below.

## Settled when built (2026-10-11)

- **`switch` is not offered to the model.** The tool refuses it (`switch is not offered to the model`), as it refuses
  `trust`. A model choosing its own successor changes what reads the conversation from the next turn on, which no
  approval dialog shows well; nothing in 0.22.0 needs it. Offering it would take a decision of its own.
- **`check` asks, whatever the model's state.** Every `check` the model asks for is an approval request
  (`models check <name>`), for a model the operator enabled or not: a check loads the model's weights (gigabytes of
  memory, up to three minutes) and writes its declaration to `config.json`, so the person decides. A check of a model
  whose runtime reports its own capabilities asks too, then says there is nothing to check; asking first keeps one
  rule for the model's changes.
- **A pull started over MCP reports its end in the thread.** No resource under `wisp://models` and no MCP
  notification: the end is a note the thread's next `respond` carries to the model (a `ThreadRecord.Kind.notice`
  entry), and a `model.pull` event in the thread's own audit log, so `wisp://threads/{thread_id}/audit` shows it with
  the approval's id. A caller that has moved on finds both when it comes back; nothing is pushed to a client that
  may not be listening. The person's notification of the approval request is unchanged (ADR 0046).
- **The threshold and `--yes`.** A model's request about models is asked whatever `approval.threshold` says, `never`
  included: the threshold rates commands, and these are changes to what wisp runs. `--yes` (`AutoApprover`) approves
  `enable`, `disable`, and `check` as it approves a command, but does not answer a pull, which is refused: a flag given
  ahead of time is not the person seeing a publisher, licence, and download size.
- **What "approved per pull" means at the gate.** A pull's request (`ApprovalRequest.Kind.modelAction(pull: true)`)
  takes only `once`, and that once covers only that pull, not the rest of the turn; a wider answer from any face is
  narrowed and `approval.decided` records `downgradedFrom`. `enable`, `disable`, and `check` take `once` or `session`,
  `project` and `always` narrowed to the session, so nothing the model asks reaches `approvals.json`. They are keyed
  by pattern, as `edit_file`'s are (`models enable *`). Each request gets an id, recorded as `approvalID`, and every
  event the change writes carries it as `approval`.
- **The person's pull in chat runs in the foreground of the chat loop**, as a command typed after `!` does: the plan
  and the questions first, then the download with its progress as the activity (`pulling … 1.2 GB of 4.5 GB, file 2
  of 7`), which the terminal's working line and `wisp-tui`'s busy box show while notes keep arriving. Ctrl-C reaches it
  through the same `ChatInterrupt` and `CommandStop` as a typed command (the `interrupt` line from `wisp-tui`), which
  cancels the fetch; the part of the file stays as `.incomplete` and the next pull resumes it (ADR 0052's resume).
  The questions are the face's choice dialog: refuse, pull once, or trust from now on, refuse current so Enter alone
  refuses; yes or no for the download and a directory to replace, no current.
- **The model's background pulls** are the session's (`Session.modelPulls`), one per repository; asking for one
  already running is refused. `/models cancel [REPOSITORY]` stops one, and the session's end cancels them all, the
  note and `model.pull` saying `cancelled`. A directory at the link's path is never replaced for the model: only the
  person may agree to that.
- **The setting** that turns the tool on for every conversation is `tools.models` (default false), beside
  `tools.disabled`, as `context.memory` turns `memory` on.
- **Audit.** No new event kind: `model.pull` gains `source` and `approval` and the outcome `cancelled`;
  `model.publisher` gains `approval` (its `source` now `cli`, `chat`, or `tool`); `model.verified` gains `source` and
  `approval`; `config.change` gains `approval` and the source `tool`. ADR 0056's "models.enabled" is
  `config.change` of `models.disabled`; there is no such event. The model's changes are recorded in the asking
  conversation's log, an MCP thread's included.
- **Where the code is.** `ModelActions` in `WispCore` holds the actions and the pull's questions; `PublisherCheck`
  moved there from `WispMLX` so the publisher question is asked the same way by every face; the fetch itself stays in
  `WispMLX` (`ModelPull`), reached through a `ModelPuller` the executable registers (`MLXPuller`), as backends are.

## Tests

Without a model or network (`FakePuller` and the fake Hub, `ScriptedModel`, temporary homes and caches): each action
through each face reaching `ModelActions` (the CLI's wiring is the executable's; chat's `/models` and the picker in
`ChatLoopTests` and `ChatModelPullTests`, the tool in `ModelsToolTests`, MCP's `respond` in `ModelsToolWireTests`);
the tool's read-only actions bounded and paged; every changing action asking, and refused when declined, timed out,
or unanswered; a pull never covered by a cached approval, and refused under `--yes`; `trust` and `switch` refused to
the model; the publisher dialog in chat (scripted choice) and `wisp-tui` (the picker's action row, Ctrl-C on a pull);
a background pull's progress, cancellation, and completion note, and the note reaching the model's next turn; a
cancelled fetch keeping its part and the next resuming it (`MLXPullerTests`); the audit fields.
