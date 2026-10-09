# ADR 0059: One set of model actions, for the person and the model

Date: 2026-10-09. Status: proposed, for 0.22.0. Extends [ADR 0056](0056-models-enabled-and-disabled.md) (models
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
- Open, to be settled when this is built: whether `switch` is ever offered to the model; whether `check` for a model
  the operator never enabled should ask; how a pull started over MCP reports completion to a client that has moved on
  (a resource under `wisp://models`, or a notification).

## Tests (planned)

Without a model or network: each action through each face (CLI, `/models`, the tool) reaching `ModelActions`; the
tool's read-only actions bounded; every changing action asking, and refused when declined, timed out, or unanswered;
a pull never covered by a cached approval; `trust` refused to the model; the publisher dialog in chat and `wisp-tui`;
a background pull's progress, cancellation, and completion note; the audit fields.
