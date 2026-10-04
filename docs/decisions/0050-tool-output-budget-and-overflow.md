# ADR 0050: A tool-output budget from the model's window, and nothing past it dropped

Date: 2026-10-04. Status: proposed.

## Context

Every tool result is bounded so that one call cannot flood the model's context (`AGENTS.md`, "Bound every
tool result"). The bound is a fixed 4 KiB, chosen for the on-device model's window of 8,192 tokens, and it
is applied to every model. The window varies by model: wisp already knows it per model, sized from memory
for Ollama ([ADR 0043](0043-context-window-from-memory.md)), and granite's was 53,248 tokens in the chat
below. The rule is wrong for every model but the smallest.

The bound is written in five places, separately:

| Where | Bound | What happens past it |
| --- | --- | --- |
| `run_command` | `commandMaxOutputBytes`, default 4,096 per stream | The whole output is captured, then all but the tail is discarded. The model is told only the tail is shown; the head is in neither the result nor the audit log, so nobody can recover it. |
| `inspect` | `InspectTool.maxBytes`, 4,096 | Cut, marked `[truncated: N bytes, showing 4096]`. No paging; `audit` narrows only by `last` (default 20 events), `kind`, and `session`. |
| `system_info` | `SystemInfo.maxBytes`, 4,096 | Cut and marked, no paging. |
| `read_file` | `FileReader().maxBytes`, 4,096 a page | Paged by `offset`. |
| `memory` recall | `Recall.pageBytes`, the same | Paged by `from line N`. |

Two runs of `functionality-self-test.wisp` on 2026-10-04 (granite4.1:8b, sessions `eefc5b0e` and
`ba7865f0`) showed the cost. In the second, the person asked the model to check its own work against the
audit log; `inspect(audit)` returned the last 20 events, which covered only the turn's final three calls,
and the model confirmed claims it could not see. Some output was cut, the cut was marked, and the model
went on as if it had seen everything; output past the bound could be neither read nor processed.

The operator's direction (2026-10-04): derive the budget from the model's window, and when more output is
expected than fits in one go, provide a way to process it rather than drop it silently.

## Decision

- **A tool-output budget from the current model's window.** One budget for every tool result: an eighth of
  the window, as bytes at the composer's bytes-per-token estimate, at least 4 KiB and at most 64 KiB. The
  on-device model keeps today's 4 KiB; granite at 53,248 tokens gets 26 KiB. It is read at each call, not
  at start-up, because `/model` changes the model within a conversation and condensing works against the
  same window. A model whose backend reports no window yet (Core AI and MLX, until their metadata is read)
  gets the floor. `read_file` pages, recall pages, and the condensing chunks below use the same budget. An
  explicit `commandMaxOutputBytes` still overrides it for `run_command`, as the operator's own setting.
- **Nothing past the budget is discarded.** A tool's whole output is kept in the thread's output store, a
  file beside the thread record, up to a ceiling of 16 MiB per call; past that the output is cut, and the
  cut is stated, as a cut, in the result, the store, and the audit. The audit event refers to the stored
  output by size and SHA-256 rather than carrying it, so the log does not grow with it. `run_command` stops
  discarding the head: what the model is not shown is kept like everything else.
- **The model sees what fits and an exact account of the rest.** Within the budget it gets the head and
  the tail, and between them a marker naming what is held back and how to reach it:

  ```
  [held back: lines 41–2,310 (180 KiB) — memory "recall entry 7 from line 41" pages it;
   memory "condense entry 7: <question>" answers a question from all of it]
  ```

  A result is never cut without a marker, and a marker never understates what was held back.
- **Three ways to process more than fits.**
  - *Page it*: `memory` recall, which already pages, becomes the one route to every tool's held-back
    output, by the entry the marker names.
  - *Narrow it*: the marker suggests running the command again with a filter (`grep`, `--since`, `jq`)
    where the output was a command's.
  - *Condense it*: `memory "condense entry N: <question>"` runs a chunked pass over the whole stored output
    on device, each chunk within the budget, and combines the chunks' answers into one that fits, with the
    lines it drew on. It is the mechanism `triage` and `condense_log` already use
    ([ADR 0023](0023-condensing-tools.md), [ADR 0032](0032-log-and-json-condensers.md)), driven by the
    model's question. Paging alone is not enough: a model reading page after page can lose the earlier
    pages to condensing, so it needs a way to ask about the whole output at once.
- **`inspect` and `system_info` use the same store and markers**, and `inspect(audit)` gains a `turn` filter
  and a view of one line per tool call (the tool, its arguments, its outcome), so a turn's calls fit where
  its raw events did not.
- **The person sees all of it.** `/show`, Ctrl-O in `wisp-tui`, and `wisp://threads/{thread_id}/output/{id}`
  serve the whole stored output, paged where it is large; today they serve what the tool returned.
- **The rule changes.** `AGENTS.md`'s "Bound every tool result (4 KiB or paged)" becomes "bound every tool
  result to the model's tool-output budget, keep the rest in the output store, and mark what is held back".

## Consequences

- A larger model sees more of each result at once, and every model can reach all of it, by page or by
  question, where today the excess is out of reach or gone.
- The output store grows with each large result; it lives and is removed with the thread record, and the
  16 MiB ceiling bounds one call. `doctor` reports the store's size beside the saved transcripts.
- `condense` costs model calls in proportion to the output's size; it runs only when the model asks.
- The per-call view of `inspect(audit)` serves a model asked to check its own turn, but it does not make a
  model honest: the runs above show a model restating its claims over evidence it did not read. A check
  wisp makes itself, from the turn's audit events, is a separate decision, still open.
- Each tool's fixed constant goes; tests cover the budget for small, large, and unknown windows, a change of
  model mid-conversation, the floor and ceiling, the marker's account for each tool, paging and condensing
  over a stored output, the 16 MiB cut, `run_command` keeping its head, the audit's reference, and `/show`
  and the resource serving the whole output. None needs a model: `ScriptedModel` answers the condensing
  chunks.
- Documented in `docs/context-management.md`, each tool's page, `docs/tools/memory.md`, `docs/wisp.md`,
  `docs/mcp.md`, and `docs/logging.md`.
