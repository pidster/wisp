# Proposal: layered context, composed for each request

Date: 2026-09-29. Status: for review. Becomes an ADR when accepted. It would reverse design rule 4 of
[context-management.md](../context-management.md) ("the transcript stays a faithful record"), amend
[ADR 0025](../decisions/0025-context-estimation.md), and leave [ADR 0017](../decisions/0017-three-layer-instructions.md)
unchanged.

## Problem

wisp keeps one transcript, and it grows. The model, the audit, and the person all see the same thing, and
the only way to keep it inside the window is to cut the oldest turns off. Measured on 2026-09-29 with the
on-device model, which has an 8,192-token window ([context-management.md](../context-management.md), "On
the on-device model, and what condensing costs"):

- **Facts go with the turns that held them.** A fact planted in turn 1 was dropped by the first
  condensation, and the model then said it did not know it.
- **Nothing tells the model what it lost.** Asked which file it read first, the model named the oldest one
  still in its window, confidently and wrongly.
- **It cannot go back.** The dropped turns exist in the audit log and, since `/inspect context`, in saved files. The
  model has no way to reach them.
- **Once full, it condenses every turn.** Four turns of file reading sit near the 85% budget, so from then
  on the transcript lost a turn before almost every prompt.
- **Most of the window is output nobody needs twice.** Tool output was most of the tokens: 4 KiB of file
  text a turn, often retyped by the model in its reply for the person to read.

These are not tuning problems. As long as the transcript is both the record and the model's view, keeping
it small means forgetting.

## Goals

1. Nothing is lost. Every turn, tool output, and reply is stored verbatim, as the audit log already is.
2. The model sees a context composed for each request: recent turns word for word, older ones as a
   summary and facts, and a way to recall anything in full.
3. What the person is shown is decided separately from what the model carries.
4. Content that came from the conversation never gains the authority of instructions.
5. Measured: an eval shows the design recalls more than today's dropping, at a stated cost in tokens and
   time per turn.

## Non-goals

- New tools for what output handling can do. `run_command("cat <path>")` shows a file; how its output is
  routed is the question, not how to fetch it.
- Retrieval over documents or the file system. This is about the conversation's own history.
- Sharing memory across sessions or threads. Each conversation's store is its own; carrying facts between
  sessions is a later, separate decision.

## Design

### Three views of one conversation

| View | Holds | For |
| --- | --- | --- |
| **Stored** | Every entry verbatim, once: prompts, tool calls, tool output, replies. Also the facts and summaries derived from them, each linked to its source entries. | The record, `recall`, the audit, `/inspect context`. |
| **Active** | The context composed for the next request, within a token budget. | The model. |
| **Shown** | What the person sees: the conversation, output in full or summarised, notes. | The person, in chat, `wisp-tui`, or the MCP caller's own view. |

Today all three are one `Transcript`. Here they are separate, and the stored view is the faithful one.

### The active context, in layers

In the order the model reads them:

| Layer | Where | Contents | Size |
| --- | --- | --- | --- |
| 1. Instructions | the instructions entry | wisp's system prompt, the operator's extension, the caller's instructions (ADR 0017, unchanged), and one standing rule on how context reaches the model and how to recall. | Fixed, the same every turn, so the prefix is stable for caching. |
| 2. Earlier | one prompt-side entry at the start | A summary of the turns older than the literal segment, then the facts. Each fact cites its source entries and says who it came from: the person, the model, or a tool. Labelled as a record, not as instructions. | Capped. |
| 3. Literal | the turns themselves | The most recent turns word for word, with their tool calls and output. | What the budget leaves, scaled to the model's window. |
| 4. Current | the prompt | The task frame (the task, its state, and how to recall it in full), then the request. | Small. |

**Authority is set by position.** Content derived from the conversation (summaries, facts, and above all
anything a tool returned) goes on the prompt side, never into the instructions. A README that says "ignore
your instructions" can reach the model only as a fact labelled as tool-derived. A test checks this.

**Chronological order.** Layer 2 stands where the turns it summarises happened, before the literal
segment. The task comes last, just before the request, where a small model weighs it most.

### Output handling decouples display from context

Every output is stored once, verbatim. Each view then holds its own rendering of it:

| Output | Stored | Shown | Active context |
| --- | --- | --- | --- |
| A command's or tool's output | full | full, a summary, or a one-line note, by the request and the size | full while in the literal segment; then a summary, facts, or a reference; or nothing, if nothing came of it |
| The model's reply | full | full | analysis, answers, and decisions kept (and distilled into facts); presentational text cut |

**Presentational text** is text the model wrote for the person to read, restating output that is stored
anyway: a retyped file, a table of a command's results. Once shown, it has done its job, and the composer
cuts it from the active context. It leaves a marker such as "(showed you the output of call 3)". It is
found mechanically: a stretch of the reply that largely reproduces a tool output of the same turn, by
word-sequence overlap. That is deterministic, fast, and testable without a model. Analysis does not
reproduce the output, so it stays.

### Recall

A `recall` tool, bounded and paged like `read_file`, restores stored material for the current turn only:

- a turn, or an entry, by its id;
- a fact's sources;
- the task in full: its original statement and the turns that shaped it.

The standing rule in layer 1 says it exists and when to use it. What it returns lives only in that turn's
literal segment, and ages out like anything else.

### Facts

- **Short statements about earlier situations and outcomes**, such as "the codename is BLUE HERON" or
  "the gate passed at `cbec7db`".
- **Each fact carries** its source entries, its origin (the person, the model, or a tool), and when it was
  recorded.
- **Visible to the person:** `/inspect facts` in chat, and a matching MCP resource for a thread. Whether the
  person can edit, pin, or delete them is open.

### Condensing becomes distilling

When a turn leaves the literal segment, its content is distilled into facts and into the running summary,
and cut from the active context. It is not dropped from the store. The model sees less detail, not less
history, and knows how to get the detail back.

## What changes in wisp

- **A store per conversation.** Entries by id, with facts and summaries linked to their sources. It lives
  beside the transcript and the audit, in `~/.wisp`, user-only.
- **A composer.** It builds each request's `Transcript` from the store, within a budget per layer. The
  framework already allows it: `LanguageModelSession(model:tools:transcript:)` starts a session from any
  transcript, which is how condensing works today. `Agent` asks the composer instead of continuing one
  session.
- **Output handling** after each turn: routing for display, and cutting presentational text.
- **A distiller** that writes facts and summaries.
- **The `recall` tool** and the standing rule.
- **`/inspect facts` and a facts resource.** `/inspect context` already shows the active view as it is.
- **Audit.** New events for distillation, recall, and cuts, each naming what it touched, so the
  composition is reconstructable.
- **Docs.** `context-management.md` (the design rules), `logging.md`, `wisp.md`, `mcp.md`, and an ADR.

## Evaluation

The scripted chat from 2026-09-29 becomes an eval, run with `scripts/check eval` like the others:

1. Plant several facts across the early turns, and state a task.
2. Fill the window with tool output, including a long digression away from the task.
3. Ask about each fact, about what came first, and ask the model to return to the task.

It is scored on facts recalled, correct "what came first" answers, a correct return to the task, tokens
per turn, and time per turn. It is run for today's dropping, then for layers without recall, then for the
full design, on the on-device model and on `ollama:granite4.1:8b`. The bar: better recall than dropping
at a small, fixed cost per turn.

## Open questions

Each question lists its options, and where the proposal leans.

1. **Can the person edit facts?** Options: view only; pin and delete; full edits. Edits change what the
   model believes, so each is audited and marked as the person's. *Lean:* view, pin, and delete first.
   Edits later, if pinning is not enough.
2. **Who distils, and when?** Options:
   - the conversation's own model, after each turn (a model call every turn);
   - when a turn ages out of the literal segment (fewer calls, later facts);
   - in the background, between turns;
   - a small specialised model.

   *Lean:* distil when a turn ages out, on the conversation's model, and measure. The summary and the
   facts could come from different distillers.
3. **Staleness.** Facts go out of date: "tests fail" becomes "tests pass". Options: facts supersede one
   another by subject; a newer fact from the same source wins; the distiller is shown the existing facts
   and asked to revise them. *Lean:* supersede by subject, with the old fact kept in the store and marked
   superseded.
4. **Budgets per layer.** Fixed shares, or a floor for the literal segment with the rest split between
   summary and facts? *Lean:* instructions and task as they are, facts and summary capped at a share of
   the window, the rest literal, all scaled to the model's window. The shares come from the eval.
5. **What is the task?** In an MCP thread: the thread's first prompt, or an explicit `task` argument. In
   chat: set by the person, or proposed by the model and confirmed. *Lean:* explicit where the caller
   gives one, else the first prompt, revised when the person restates it.
6. **Should relevant facts be repeated in the current prompt?** Repeating the few that bear on the request
   next to it helps small models, and costs tokens. *Lean:* decide by the eval.
7. **Audit of displayed output.** Today tool results are logged in full. Options: keep logging in full;
   log the path, size, and hash of output that is only shown. *Lean:* keep full, since the store needs the
   content anyway. The audit and the store are one record.
8. **MCP.** A caller such as Claude Code has its own view. "Shown" there means returning output to the
   caller without it entering the thread's active context, as the condensing tools already do. What does a
   `respond` result carry: the reply only, or the routed output too? *Lean:* the reply plus references
   the caller can resolve through a resource.
9. **Tool output scaled to the window.** Every tool result, `read_file` page, and model-pass chunk is 4
   KiB whatever the model: five or six results fill the on-device model's 8,192 tokens, while a model
   with a 128k window pages needlessly. Each `Agent` knows its window (`contextSize`) but nothing uses it
   for output. Options: a budget derived from the window, with a floor and a ceiling and a per-model
   override; or, under this design, full output stored and shown and only the active slice sized to the
   window. *Lean:* the second; whether to scale the bound sooner, on its own, is decided with question 4.
10. **A model switch recomposes.** `/model` builds a new `Agent` over the old transcript, and its window
   becomes the new model's. Switching to a smaller model today condenses turns away for good. Under this
   design a switch recomposes the active view for the new window and the new model's instructions, and
   the store is untouched, so switching back loses nothing. It depends on the window being known when
   the model is selected, for every backend.
11. **Caching.** Runtimes cache a stable prefix. The instructions stay stable, but the earlier block
   changes as turns age out. Does recomposition cost measurable time on the on-device model and on Ollama?
   To be measured in the eval.

## Phasing

1. The eval, run against today's dropping, as the baseline.
2. The store and the composer, reproducing today's behaviour exactly (literal turns only), so the change
   of structure is proven before behaviour changes.
3. Output handling: routing and cutting presentational text.
4. Facts and the summary, `/inspect facts`, and `recall`.
5. The ADR, with the eval's figures.
