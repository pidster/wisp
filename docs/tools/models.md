# models

The models wisp can run, for the model: the same actions the person has in `wisp models` and `/models`
([ADR 0059](../decisions/0059-one-set-of-model-actions.md)), less the person's own. The model can read the listing and
one model's facts at once, and ask the person to pull, enable, disable, or check a model; it cannot trust a publisher,
remove a model, or switch the conversation to another model. Every rule (a disabled model refused under any spelling, the capability
check on enable, the publisher question before a pull) is the person's own, from one place, `ModelActions`.

**Off by default.** Like `memory` ([ADR 0057](../decisions/0057-context-defaults-from-checkpoint-2.md)), a
conversation gets it only when its tool list names it or the setting turns it on for every conversation given every
tool:

```
wisp config set tools.models true
```

or `/config set tools.models on` in chat, or `"tools": { "models": true }` in `~/.wisp/config.json`; it applies from
the next conversation.

| Conversation | `models` |
| --- | --- |
| Every tool (no `--tool`, MCP `respond` without `tools`, chat), `tools.models` off (the default) | No |
| Every tool, `tools.models: true` | Yes |
| A named list (`--tool models`, MCP `tools: ["models"]`) | Only when the list names it, whatever the setting says |
| `tools.disabled: ["models"]` | No, anywhere |

So the MCP git thread of `AGENTS.md` (`tools: ["run_command"]`) never sees it.

## Contract

| Field | Value |
| --- | --- |
| Name | `models` |
| Description (what the model sees) | The models wisp can run: list, show NAME, or ask the person to pull REPO (an MLX model from Hugging Face, `<organisation>/<name>`), enable NAME, disable NAME, or check NAME. A pull runs in the background; its end arrives as a note, so never call again to see how it goes. |
| `action` | `list`, `show`, `pull`, `enable`, `disable`, or `check` |
| `name` | The model as `list` names it (`ollama:granite4.1:8b`, `mlx:Qwen3-4B-4bit`); for `pull`, the repository |
| `page` | For `list`: the page, from 1 |

| Action | Answers | Asks the person |
| --- | --- | --- |
| `list` | A line per model, 20 a page: the name (`*` for this conversation's), runtime, parameters, size, context, enabled or disabled, capabilities; a model that cannot be used followed by why; a backend that did not answer in parentheses; `page 1 of 3; list with page 2 for more` | No |
| `show NAME` | Every fact the listing has for the model, a line each, and whether it is usable | No |
| `pull REPO` | At once, once approved: `pulling REPO in the background (approval ID): about 2.3 GB in 4 of 7 files. Its end will arrive as a note in this conversation; do not call models to check on it.` | Always, every pull |
| `enable NAME`, `disable NAME`, `check NAME` | The lines `/models enable\|disable\|check` would note, once done | Yes; an answer of "this session" covers the same action for the session, never longer |
| `trust`, `switch` | `error: trusting a publisher is the person's alone: …`, `error: switch is not offered to the model` | Never asked |

Every reply is at most 4 KiB. A refusal is `error: not approved: <reason>`; a name that is not a model or a
repository is `error: …` naming what a name must be.

## Approval

A change the model asks for is an approval request of its own kind (`ApprovalRequest.Kind.modelAction`), judged as the
command `models pull <repo>`, `models enable <name>`, and so on by the full classifier, as `edit_file`'s edits are
judged as `edit_file <mode> <path>`, and asked whatever `approval.threshold` says: the rules rate them `moderate`
(`downloads a model from Hugging Face`, `changes the models wisp can run`). The request names what the person needs:

- for a pull, the download (`downloads 2.3 GB in 4 of 7 files from Hugging Face, as mlx:<name>`, or that nothing needs
  fetching), the publisher (trusted, or not trusted: approving pulls it this once, and only the person can trust it,
  with `/models trust`), and the licence;
- for the rest, what changes in `config.json`.

| Request | Scopes an answer may give | Covered by an earlier answer |
| --- | --- | --- |
| `models pull <repo>` | once; a wider answer is narrowed to it (`downgradedFrom` in `approval.decided`) | Never: every pull is asked |
| `models enable\|disable\|check <name>` | once, this session; "project" and "always" are narrowed to the session | This turn's or this session's approval of the same pattern (`models enable *`) |

The terminal's dialog offers only those keys (`[y]once  [n]o` for a pull). Declined, timed out, or unanswered, the
request is refused and nothing changes. Under `wisp mcp` the tool is reachable only through `respond`, and its
requests go to the client's elicitation and to `wisp approvals` (with `approval.outOfBand`, the default), the first
answer winning; silence refuses ([../mcp.md](../mcp.md), "Approval").

## A pull in the background

Once the person approves, the pull runs beside the conversation (`Session.modelPulls`), at most one per repository:
the tool returns at once, the turn goes on, and the model is told not to call again to check on it, because wisp
never re-runs a call to see how it went. A pull of a publisher not trusted goes on as an answer of "once" would; the
person's approval named the publisher and licence. A real directory at the link's path is kept (only the person may
agree to replace it).

When it ends, a note is posted to the conversation that asked (by its audit session: chat's own, an MCP `thread_id`):

```
[wisp: the pull of mlx-community/Qwen3-4B-4bit you asked for (approval 7f3a2c1d) finished: fetched 2.3 GB; it is mlx:Qwen3-4B-4bit. Its capabilities are undeclared until it is checked: models enable mlx:Qwen3-4B-4bit asks to turn it on and check it]
```

A failure, or a cancellation (`/models cancel` in chat, or the session ending), says so; what arrived is kept for the
next pull to resume. Chat shows the note as it arrives; the model reads it with its next turn, where the agent stores
it as a notice (`ThreadRecord.Kind.notice`), which, like a command the person typed, is no turn of its own. Under
`wisp mcp` a client that has moved on finds the note on the thread's next `respond`, and the outcome in the thread's
audit (`wisp://threads/{thread_id}/audit`, `model.pull`).

## Audit

Each call is `tool.call` and `tool.result`. A change asked for records `classifier.verdict`, `approval.requested`, and
`approval.decided` (its `approvalID` the request's id), then what the change writes with `source` `tool` and
`approval` that id: `config.change`, `model.verified`, `model.publisher`, `model.pull` ([../logging.md](../logging.md)).

## Limits

- List pages of 20 models; every reply at most 4 KiB.
- Pulls are MLX models from Hugging Face, as `wisp models pull` fetches them ([../wisp.md](../wisp.md)); the same
  names, files, sizes, digests, lock, and link rules apply.
- The listing asks every backend, as `/models` does: an Ollama that is not running is one line in parentheses.
- Not offered: `trust` (the person's, `/models trust PUBLISHER` or `t` to a pull's question), `uninstall` (the
  person's, after typing the model's name; ADR 0075), and `switch` (a model choosing its own successor is a decision
  not taken; ADR 0059).
