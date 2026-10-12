# ADR 0050: A tool-output budget from the model's window, and nothing past it dropped

Date: 2026-10-04. Status: accepted on 2026-10-11, as built for 0.22.0 (the operator started 0.22.0 on 2026-10-11);
the choices the proposal left open are recorded under "Choices made in the build" below.

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

## Choices made in the build (2026-10-11)

The proposal left several things open or named them loosely; the build decided them as follows, and the pages
named at the end describe the result.

- **One budget object per conversation, kept current by the agent.** `ToolBudget` holds the window and is
  shared by the conversation's tools and its agent (`WispThread.setUp` makes it, `ToolRegistry` hands it to every
  tool, `Agent.contextSize` writes it as the window becomes known: at `openAgent` for a backend that states it, at
  the first overflow for one that does not). `/model` opens a new thread, so a new budget. The arithmetic is
  `min(64 KiB, max(4 KiB, window / 8 × 4 bytes))`: 4 KiB at 8,192, 26 KiB at 53,248, 64 KiB from 131,072 on, the
  floor for a window nobody knows. `commandMaxOutputBytes`, when set, replaces the budget for `run_command` alone,
  as the proposal said; unset (the new default) it is the budget.
- **The output store is a directory of files, keyed by the audit call id.** `~/.wisp/output/<audit session>/`,
  one file per kept output, user-only, with a `<id>.json` record beside it (size, lines, SHA-256, whether it was cut
  at the 16 MiB ceiling). The id is the audit call id the tool call's `tool.call` and `tool.result` already carry
  (`AuditedTool` sets it as a task-local, `ToolCallContext.call`, for the base tool's call), so the store, the
  audit, and the result are joined without a new identifier. The proposal's "a file beside the thread record" was
  not followed literally: the thread record is in memory and the audit session already names a conversation; the
  store is created when the first output is kept, and only while the audit is on, since recall reaches it through
  the audit's call ids. Each output kept is audited as `output.kept` (`tool`, `bytes`, `lines`, `sha256`, `cut`,
  `totalBytes`), under the call id, never with the content; `tool.result` goes on holding what the model saw, as
  everything that reads it expects.
- **The marker names the output by its id, not by its entry.** The proposal's marker named `entry 7`, but a
  store entry exists only when the turn ends, and the model needs the way to more of an output *in the turn that
  produced it*. So the note on a held-back result names the stored output: `memory "recall output 3f9a2c1b from
  line 44"`, with `matching PATTERN`, `summarise output …`, and `condense output …: QUESTION` beside it. After the
  turn, the entry's reference stands for the output as before, and `recall entry N` of such an entry gives the
  whole from the store (its header says so), with the stored file's own line numbers, so both routes reach the
  same lines. In a conversation without `memory` the note says the output is kept and, for a command, that it is
  not to be run again to see it, and names no tool the model does not have (ADR 0057's rule).
- **Head and tail, each about half the room, cut at line ends, with a one-line marker between them.** The
  marker inside the text (`[… 2,270 lines (180 KiB) held back …]`) says how much lies between; the note at the
  end says which lines of the stored output they are and how to reach them. A `run_command` result is bounded
  as a whole, its header, frames, and notes included: the room is shared between stdout and stderr in proportion
  to their size, and never less than a fifth of it for a stream that has something to show, so a short error is
  not crowded out by a long log. The stored output of a command is the rendering with nothing held back (the
  exit-status header, `stdout:`, the stream, `stderr:`, the stream), so the line numbers the note gives are the
  stored file's.
- **The command runner holds twice the bound per stream in memory and spills the rest as it streams.**
  `OutputBuffer` keeps a stream's first and last `bound` bytes and counts everything; the moment a byte would be
  dropped it opens a spill file in the store (writing what memory holds first) and every later chunk goes there,
  so a command printing 1 GiB costs about four times the bound in memory. When the command ends the runner
  composes the kept output from the header and the spill files (streamed, bounded memory) and removes them.
  Without a store the excess is dropped from memory and counted, and the note says the output was not kept. The
  `output truncated: only the tail of each stream is shown` line is gone, and so is the head's loss.
- **Exact readers for the summaries; a model only for the question.** `summarise` is `OutputSummary`, no model:
  the failure formats `triage` reads (`KnownFailures`), grouped by file or test with the first error of each, the
  lines after it, the later errors in the same place counted under it, and warnings tallied; a log's severities
  and rare or severe templates (`LogDigest`); JSON's shape (`JSONShape`); else the lines that mention an error,
  else the first and last lines. Every point cites its line (`L154`). It says what no reader explained. The
  proposal's model fallback for a summary was not built: the model step is the `condense` verb, on request, with
  the model's question, so no summary costs a model call. `read_file`'s `summary:` argument was not built either;
  `memory "summarise entry N"` serves a file read whole into the store the same way, and a file is paged already.
- **`condense` runs on the conversation's own model, off the agent's path.** `OutputCondenser` holds a function
  the thread attaches when its agent opens: a fresh tool-less `Agent` on the same resolved model per chunk, as
  `triage` judges a chunk. Chunks are the budget less room for the prompt, at most 48 (one question is bounded
  in calls; the result says when the output had more), each asked the question and told to answer "nothing here"
  when the chunk has nothing; the answers that say something are joined, and when they do not fit the budget the
  model is asked once more to combine them. Tests attach a scripted function; `ScriptedModel` is not needed for
  it, and no test needs a model. Without an attached model the verb says so and points at `summarise` and the
  filters.
- **Filters are a clause of a recall, applied before paging.** `matching PATTERN` (a regular expression,
  case-insensitive, or a literal when it does not compile), `lines A-B`, `head N`, `tail N`, each line numbered in
  the whole, and `from line N` after them for the next page; the page's hint repeats the filter.
- **`inspect` gains `calls` and `turn`.** `what: calls` lists a turn's tool calls one line each (the tool, its
  arguments, its outcome: an exit status, a verdict, an error, or the result's size), this turn by default;
  `audit` with `turn` gives every event of that turn of this conversation rather than the last N.
- **A repeated call is answered with a line, not refused.** `CallLedger` counts each turn's calls by tool and
  arguments; the second and later identical calls get `[repeated call: this is the same inspect call, with the
  same arguments, as 1 earlier call this turn; the earlier result is already in your context]` above the result,
  and `tool.result` records `repeat`. A command run again after an edit is a new command and is not stopped.
- **The system prompt is unchanged.** The note on every held-back command result carries "do not run the command
  again to see it", and the reference wording of ADR 0057 already says it after the turn, so no sentence was added
  to the prompt the on-device model pays for on every request.
- **The person's views.** `wisp://threads/{thread_id}/output/{id}` serves the whole stored output when there is
  one, paged at 16 KiB, and the output list marks such calls with `stored`, `storedBytes`, and `storedLines`;
  chat's `/show` still prints what the tool returned (its head, marker, and tail), and showing the stored whole
  there is left for the chat work of 0.22.0. `doctor`'s report of the store's size is not built; the store is
  bounded per output by the ceiling and otherwise grows with the conversations kept, like the audit. (Both
  superseded on 2026-10-12, below: the store is swept by age, and `doctor` reports it.)
- **The rest of the 2026-10-09 review, in the same code.** `wisp://threads/{thread_id}/audit`, `wisp://audit/
  {session}`, and `wisp://audit` are paged (`?page=N&limit=M`, 100 events a page, up to 500; JSON with `events`,
  `page`, `pages`, `total`, `next`, and `last`, in place of unbounded JSON Lines); each `respond` thread gets an
  audit session of its own, `<thread_id>-<suffix>`, recorded in `ThreadDirectory` and shown as `auditSession`, so a
  `thread_id` reused after `close_thread` has resources of its own and `wisp://audit/{session}` refuses a thread's
  session by either name; a spawned command gets exactly three descriptors (`POSIX_SPAWN_CLOEXEC_DEFAULT`, and the
  pipes' ends `FD_CLOEXEC`), and `read_file` and the store open their files `O_CLOEXEC`; `read_file` refuses a
  FIFO, a device, or a socket before opening it and reads a file with no newlines a page at a time (`LineScanner`
  keeps a page of an open line and counts the rest); `edit_file`'s `write` replaces without reading and `append`
  copies the file in 64 KiB chunks to a temporary file and renames it, so neither loads the file.

- **2026-10-12: the store is swept by age.** The operator decided that a store growing with every conversation
  kept is not a store to leave unbounded. A session's stored outputs, `output/<audit session>/`, are removed
  `context.outputDays` days after the session's last use (default 30, as approvals last; 0 to 3,650, 0 never
  sweeps; validated at load and by `wisp config set`). **Last use** is the newest modification time among the
  session's directory and its files: every output kept creates files there, which moves the directory's own
  time, and a file still being written moves its own, so it costs one listing per session and no marker file to
  keep in step; reading a stored output moves neither, so a conversation that only reads its old outputs for
  that long is swept too. The sweep runs in `Session.begin`, before `session.start` is recorded, and is bounded so
  start-up never waits on a large store: one listing of `output/`, then the sessions whose directory is older
  than the cutoff, oldest first, at most 16 removed a start (`OutputSweep.removalLimit`) and none examined once
  100 ms have passed (`OutputSweep.deadline`); the rest waits for the next start. Synchronous and bounded rather
  than off the critical path, so the start's audit says what it removed. It never touches the current session,
  nor anything that is not wisp's: only a directory with a safe name holding only regular files with safe names
  is removed; a file, a link, a directory with a subdirectory or an unexpected name in it, are left alone. The
  sweep is audited as `outputSweep` on `session.start` (`removed`, the sessions, `bytes`, and `deferred`, those
  the bound left), present only when it removed or left something. `wisp doctor`'s `output store` finding says
  how many sessions the store holds and their size, what the next sweep would remove, and what it leaves alone.
  A conversation idle for longer than the setting inside a running `wisp mcp` server loses its stored outputs;
  its references then say the output is not held.

- **2026-10-12: "The person's views" built.** Chat's `/show` and `/last` show the stored whole of an output the
  model was given only in part, not its head, marker, and tail: the output is found by the `tool.result`'s call
  id, a typed command's by `command.typed`'s new `stored` detail, or by the id the held-back note names (in the
  output's own audit session, so a resumed conversation's older outputs are found too). A line on stderr says
  what is shown: the whole, its lines and size, and the cut when the store stopped at its 16 MiB ceiling; or,
  when the store has nothing, why, and what the tool returned follows: nothing was held back, the conversation
  had no store (the audit off), or the output is no longer there (swept, or removed). On a terminal a stored
  output goes through the pager, `$PAGER` or `less -R`, with Ctrl-C left to the pager while it runs and the pipe
  set not to raise `SIGPIPE` when the pager quits early; when standard output is not a terminal it is printed
  whole, bounded only by the ceiling, so a pipe or a file gets all of it. An output that was not held back is
  printed as before: it is never larger than the budget. `wisp-tui`'s expanded view (Ctrl-O) and a `/show` or
  `/last` under it load the output on demand through a new inbound line, `{"type":"output","id":…,"page":N}`,
  answered with a `view` of kind `output`: pages of 64 KiB that end at a line (each found from two reads of the
  file, so a page of a 16 MiB output costs two small reads, not a read of the file), joining back to the output
  exactly; the panel holds four pages at most and asks for the next or the previous as it scrolls past them,
  keeping the rows in view where they were. Never the whole 16 MiB at once, in either process.

## Consequences

- A larger model sees more of each result at once, and every model can reach all of it, by page or by
  question, where today the excess is out of reach or gone.
- The output store grows with each large result; it lives and is removed with the thread record, and the
  16 MiB ceiling bounds one call. `doctor` reports the store's size beside the saved transcripts. (As built, the
  store outlives the thread record and is swept by age, `context.outputDays` after a session's last use; above.)
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
  2026-10-04: decided in [ADR 0051](0051-the-turns-tool-calls-beside-the-reply.md), a line of what the turn
  ran beside each reply.
- Each tool's fixed constant goes; tests cover the budget for small, large, and unknown windows, the agent
  keeping it at the window as an overflow reports one, the floor and ceiling, a fit's head, tail, and marker, a
  result kept in the store under its call id and audited, paging, filtering, summarising, and condensing a stored
  output, both summaries of a failed build log with a cascade led by its root cause, a log, JSON, and plain text,
  the 16 MiB cut, `run_command` keeping its head and spilling a 1 MiB output whole, a command seeing no
  descriptor of wisp's, a FIFO refused, a file without newlines paged, `append` without loading, the repeated
  call, `inspect`'s `calls`, the audit resources' pages, one audit session per opened thread, and the resource
  serving the whole output (`ToolBudgetTests`, `HeldBackOutputTests`, `CommandRunnerTests`,
  `ThreadResourcesTests`). None needs a model: a scripted function answers the condensing chunks.
- Documented in `docs/context-management.md`, each tool's page, `docs/tools/memory.md`, `docs/wisp.md`,
  `docs/mcp.md`, and `docs/logging.md`.
