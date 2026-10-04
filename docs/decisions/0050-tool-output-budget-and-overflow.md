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
expected than fits in one go, provide a way to process it rather than drop it silently. The model should
be able to page through a long file when it needs to, and to get an overall summary or a smart one that
highlights what is notable: for a very long build log, a compact summary when the build succeeded, and
its root causes when it failed.

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
  [held back: lines 41–2,310 (180 KiB), exit status 1, first error at line 1,204 —
   memory "recall entry 7 from line 41" pages it; "summarise entry 7" gives the notable lines;
   "condense entry 7: <question>" answers a question from all of it]
  ```

  A result is never cut without a marker, and a marker never understates what was held back. What the
  marker says about the content is found exactly, without a model: the exit status, and the first line
  in a known failure format (the formats `triage` reads, [ADR 0039](0039-exact-condensers.md)).
- **Four ways to process more than fits, each reading what is stored.**
  - *Page it*: `memory` recall, which already pages, becomes the one route to every tool's held-back
    output, by the entry the marker names, and `read_file` keeps paging a file, both a budget at a time.
  - *Summarise it*: an overview, or the notable lines, of all of it (below).
  - *Filter it*: `memory "recall entry 7 matching <pattern>"` returns the stored lines that match, with
    their line numbers and a count of the rest, a budget at a time. The filter runs over what is stored;
    the command is not run again.
  - *Condense it*: `memory "condense entry N: <question>"` runs a chunked pass over the whole stored output
    on device, each chunk within the budget, and combines the chunks' answers into one that fits, with the
    lines it drew on. It is the mechanism `triage` and `condense_log` already use
    ([ADR 0023](0023-condensing-tools.md), [ADR 0032](0032-log-and-json-condensers.md)), driven by the
    model's question. Paging alone is not enough: a model reading page after page can lose the earlier
    pages to condensing, so it needs a way to ask about the whole output at once.
- **Wisp never runs a command again to see its output.** Every way above reads the stored output. A
  command may not give the same output twice (a build, a test run, a clock, the network), may be slow or
  costly, or may change something (a write, a push, a deletion), so running it again to read more of
  what it printed is never the route: not in a marker, not in a summary's advice, not in wisp's system
  prompt, which tells the model to read the stored output instead. A command run again is a new command,
  chosen as one, approved as one, and audited as one; where the stored output was cut at the 16 MiB
  ceiling, the marker says so, and says the rest was not kept, rather than suggesting the command again.
- **Summaries: an overview, or what is notable.** The model can ask for either, of a held-back output
  (`memory "summarise entry 7"`, `memory "summarise entry 7 overview"`) or of a file (`read_file` with
  `summary: notable` or `overview`, beside its paging), and gets a result within the budget, each point
  citing the lines it came from so the model can page to them.
  - *Overview*: what the content is, its size, how it ended, and its sections or kinds of line, compactly.
  - *Notable* (the default): what matters given how it ended. Where the outcome is known (an exit status,
    a test tally, a build's last line), it decides the emphasis. A build or test that succeeded gets a
    compact summary: the outcome, the counts, the warnings tallied, the time taken. One that failed leads
    with the root causes: the first error of each independent failure, with its location and the lines
    around it, the errors it set off grouped under it rather than listed beside it, then the tally. A log
    with no outcome leads with what is rare or severe (errors, warnings, the messages that occur once),
    with the frequent messages counted, not repeated.
  - *How*: exact readers first, a model only for what they do not explain, as `triage` does today. The
    content's kind picks the reader: build and test output, `triage`'s failure formats
    ([ADR 0039](0039-exact-condensers.md)); a log, `condense_log`'s templates; JSON, `json_shape`'s
    outline ([ADR 0032](0032-log-and-json-condensers.md)); anything else, a chunked model summary. A
    summary made with a model says so, and names the lines no exact reader explained.
  - *When*: on request. The marker carries the exact signals free (the exit status, the first error's
    line), so the model can tell whether to ask; making a summary costs model calls only where the exact
    readers fall short, and only when asked.
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
- `condense` costs model calls in proportion to the output's size, and a summary where the exact readers
  fall short; both run only when the model asks. A build log that failed in a known format is summarised
  without a model at all.
- Root causes are found by order and grouping (the first error of each failure, the errors that follow it
  in the same file or target grouped under it), not by understanding the build; a failure whose cause
  is in no error line (a missing tool, a killed process) is found only by the model's pass, and how well it
  is found is measured in the eval round before the build.
- The per-call view of `inspect(audit)` serves a model asked to check its own turn, but it does not make a
  model honest: the runs above show a model restating its claims over evidence it did not read. A check
  wisp makes itself, from the turn's audit events, is a separate decision, still open.
- Each tool's fixed constant goes; tests cover the budget for small, large, and unknown windows, a change
  of model mid-conversation, the floor and ceiling, the marker's account for each tool, paging and
  condensing over a stored output, both summaries of a succeeded and a failed build log, a log without an
  outcome, JSON, and plain text, the root cause leading a cascade of errors, the 16 MiB cut, `run_command`
  keeping its head, the audit's reference, and `/show` and the resource serving the whole output. None
  needs a model: `ScriptedModel` answers the condensing chunks.
- Documented in `docs/context-management.md`, each tool's page, `docs/tools/memory.md`, `docs/wisp.md`,
  `docs/mcp.md`, and `docs/logging.md`.
