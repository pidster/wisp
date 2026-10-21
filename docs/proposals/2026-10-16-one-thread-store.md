# One thread store: every thread saved, and resumed by any face

Date: 2026-10-16. Status: accepted 2026-10-16, every recommendation taken; phase 0 built for 0.26.3; phase 1 built
2026-10-18 for 0.27.0, recorded in [ADR 0066](../decisions/0066-one-thread-store.md), with the retention sweep
(`threads.keepDays`, `thread.swept`) in it; phase 2 (chat) built 2026-10-19 for 0.27.0, recorded in the ADR's
amendment of that date; phase 3 planned for 0.28.0 on 2026-10-20 ([roadmap.md](../roadmap.md)) and built the same day (ADR 0066, the phase 3 amendment).

## The problem

A thread is the same object in every face: `respond` and `chat` both open a `WispThread` through `Session.begin`,
with the same record, facts, summary, and context composition. What differs is only around the edges, and the
difference costs:

| | Chat thread | MCP thread |
| --- | --- | --- |
| Name | none, or the name given to `/save` | `thread_id` |
| Saved | only on `/save` or exit with a name | never |
| Resumed | `wisp chat --resume NAME` | never: "MCP threads are not resumed today" (`docs/mcp.md`) |
| Start settings | flags and config | per call: model, tools, instructions, think, commandTimeoutSeconds |

An MCP server keeps its threads in memory only, so a reconnect, a new build, or a crash loses every one. A caller
that names the old `thread_id` again silently gets a new thread with default settings: on 2026-10-15 the git
thread `git3` came back that way after each reconnect, on the default model with every tool and a 120 s command
limit, where `AGENTS.md` asks for `granite4.1:8b`, `run_command` only, and 600 s.

## The proposal in one paragraph

Every thread, from any face, is saved as it goes under one store, `~/.wisp/threads/<id>/`: its start settings
beside the record chat's `/save` already writes. A face that names a thread it does not hold, and the store has,
resumes it with its saved settings, under a new audit session that links the old ones. A thread is held by one
process at a time, by a lock. Chat's names and `--resume` become names in that store, so you can open an agent's
thread in chat to read or continue it, and an agent can continue a conversation you hand it.

## Goals and non-goals

Goals:

- An MCP thread survives its server: a restart, a reconnect, a new build, a crash after its last turn.
- One store and one resume path for chat and MCP; `--resume` and `respond` resume the same way.
- A caller can tell a resumed thread from a new one, and cannot resume one with different settings by accident.
- The person can list every thread and open any of them in chat.

Non-goals:

- Resuming a turn that was under way when the server died: the thread resumes from its last finished turn.
- Carrying what is deliberately a session's: "This session" approvals, session-scope facts, parked questions.
- Access control between agents on one Mac: every `wisp mcp` runs as the same user, and a client's name is
  self-reported (below, D3).

## What exists, as mapped on 2026-10-16

The facts the decisions rest on, from the code at `bc763e8`:

- **Chat's save already holds most of a thread.** `TranscriptStore.save(_: ThreadRecord, as:)` writes
  `<name>.json` (the transcript, which carries the instructions) and `<name>.store` (a `ThreadRecord.Snapshot`:
  entries, thread-scope facts with the task, summary versions), both 0600, staged and renamed. `loadThread` checks
  the store's version and that it matches the transcript. `WispThread.openAgent(on:transcript:links:store:)`
  already takes them.
- **What the snapshot leaves out:** the model, the tool names, think, and commandTimeout. They live only in the
  MCP server's memory (`OpenThread`, `ThreadDirectory`) and in the audit's `session.start`. `Agent` needs tools
  matching the names the transcript refers to.
- **What cannot be rebuilt:** the `LanguageModelSession`'s processed prefix (the first request recomposes, as a
  resumed chat does today), token totals, `ThreadRecord.continuity` (generation, condensation count, assessment,
  earlier calls), and per-turn frames and receipts.
- **Audit.** Each MCP thread opening is an audit session `<thread_id>-<8 chars>`, child of the server session.
  `Session.thread` hardcodes `resume: nil` and passes no `carriedFrom`. The resources for a thread's audit, output,
  and reasoning find its session through `ThreadDirectory`, in memory.
- **Session-wide state stays with the process:** `SessionApprovals` (one per server, shared by its threads),
  session-scope facts, `FactProposals`, and the notices a parked question's answer arrives by. Parked questions are
  withdrawn when the server stops and swept by pid. Permanent-fact requests already outlive the server.
- **Output store:** `~/.wisp/output/<audit session>/`, swept at each `Session.begin` by the newest file's age
  (`context.outputDays`, 30), sparing only the starting session.
- **Client identity:** `clientInfo.name` from `initialize`, self-reported; `WISP_MCP_CLIENT` is set by
  `scripts/wisp-mcp` and unread by Swift. Nothing authenticates a client.

Found while mapping, and fixed first whatever is decided (phase 0):

1. `factsProposed(thread:)` filters proposals by the bare `thread_id`, while `FactProposal.threadID` is the audit
   session (`<thread_id>-<suffix>`); the counts `respond` returns may always be zero.
2. A client that disconnects leaves its open threads without a `session.end`.
3. A `thread_id` of 64 characters makes an audit session longer than `SafeName`'s 64.
4. A call that passes start settings on an existing thread is refused only after `findOrCreate`, and a `schema` the
   model cannot take only after it too, so a refused call can still evict another thread. (Corrected while fixing it:
   the start-settings refusal only marks its thread used; the schema refusal on a new `thread_id` is the one that
   creates a thread and can evict another.)

## Decisions

Each was a recommendation; those that had alternatives were settled on 2026-10-16, as recommended, and say so.

### D1. The store

`~/.wisp/threads/<id>/`, mode 0700, one directory per thread, holding:

| File | Contents |
| --- | --- |
| `thread.json` | Version; id; owner (D3); the start settings: model selection, tool names, instructions present, think, commandTimeoutSeconds; created, last used, turns; the audit sessions it has had, oldest first; the facts it was asked not to propose again (D9); state (`open`, `saved`) |
| `record.json`, `record.store` | What `TranscriptStore` writes today, unchanged in format |

Each file is staged and renamed, as `TranscriptStore` does, `thread.json` last, so a reader never sees settings
for a record that is not there. Files are 0600: a record holds tool output, which may hold secrets, as the audit
log does.

### D2. Ids and names

A thread's id is its name in the store: `SafeName`, at most 48 characters, so the audit session
(`<id>-<8 chars>`) fits in 64 (fixes item 3). An MCP caller names it with `thread_id`, as now; a call with none
gets a generated one, as now. A chat starts a thread with a generated id (`chat-<8 chars>`); `/save NAME` renames
it to `NAME` (refused if taken); `--resume NAME` opens it.

`~/.wisp/transcripts` stays readable: `--resume NAME` looks in the store first, then there, and a thread resumed
from there is saved into the store. Nothing is moved; the old directory is left for the person to delete.

### D3. Owner, and who may open what

Each thread records an owner: `chat`, or the MCP client's `clientInfo.name`. It prevents collisions between
agents; it is not access control, since any process running as the person can claim any name.

- The person, in chat, may open any thread.
- **Decided:** an MCP caller may resume threads its own client name owns, and one the person hands it
  (`wisp threads hand ID CLIENT`, phase 3). A `thread_id` owned by another client is refused with
  `thread X belongs to codex; wisp threads hand X claude-code gives it to you`.
- Not chosen: one flat namespace, any client resumes any thread. Simpler, but two agents choosing `git` collide.

### D4. When it is saved, and when it is deleted

- **Saved after every turn**, inside the thread's `TurnQueue`, so a snapshot is never taken mid-turn and a crash
  loses at most the turn under way. Also at eviction and at disconnect.
- **Eviction** (`maxThreads`) drops the thread from memory only; it stays saved and resumable.
- **`close_thread` deletes it** from the store: closing is the caller saying it is finished. Its history stays in
  the audit log. (Not chosen: keeping it read-only for the retention period, listable but not resumable.)
- **Retention:** a saved thread unused for `threads.keepDays` (30, matching the output store; 0 keeps them) is deleted by a sweep at
  `Session.begin`, as the output sweep runs, bounded the same way (at most 16 a start, 100 ms).

### D5. Resuming, and the start settings

When a call names a thread no live server holds and the store has:

- It is resumed with its saved settings. The result says so: `resumed: true` and `resumedTurns: N` in
  `structuredContent`, and a first line in the text, `resumed thread git4 (12 turns, saved 2026-10-16 09:12)`.
- **Start settings on a resume:** accepted when they equal the saved ones, refused when they differ:
  `git4 was saved with model ollama:granite4.1:8b, tools run_command; these settings differ: model`. Accepting
  equal settings means a caller that always sends its settings, as `AGENTS.md` asks, never falls into the git3
  trap: it either resumes its own thread or is told why not.
- **On a live thread** start settings stay refused, as now, but equal ones are accepted too, for the same reason.
  (Not chosen: refusing all of them on a live thread.)
- **Re-checked on resume:** the model must still be enabled and available (no fallback to `system`; the call
  fails naming the model, as a new thread does today); the tools must still exist and the model support them;
  think must suit the model; the command timeout is clamped to today's `commandMaxTimeoutSeconds`.

### D6. One process at a time

A thread is held by one process while it is live, by an `flock` on `~/.wisp/threads/<id>/lock`, taken when the
thread is opened or resumed and released when it is closed, evicted, or the process ends (the kernel releases it on
a crash). A second process naming it is refused: `thread git4 is open in another wisp (pid 4242, claude-code)`.
The lock file records the pid and owner for that message. `SharedFacts` already uses `flock` this way.

### D7. Audit

- A resume opens a new audit session (`<id>-<suffix>`), whose `session.start` carries `resume: <id>` and
  `carriedFrom: [the earlier sessions]`, as a resumed chat's does; `Session.thread` takes them instead of
  hardcoding nil.
- `session.end` gains reason `disconnected`, for threads open when their client goes (fixes item 2), beside
  `closed` and `evicted`; a thread deleted by the sweep is audited as `thread.swept` (new kind, `docs/logging.md`).
- The thread's resources read every audit session in `thread.json`, so `wisp://threads/{id}/audit`, `/output`,
  and `/reasoning` cover its whole life, not only the current opening.

### D8. The thread resources and listing

- `wisp://threads` lists live and saved threads this client may open, with `state` (`open`, `saved`, or
  `open elsewhere`), owner, model, turns, and last used.
- `wisp://threads/{id}` and its `context`, `facts`, and `summary` read a saved thread from its files, without
  loading a model; `audit`, `output`, and `reasoning` from the audit log and output store as above.

### D9. What carries over, and what does not

| Carries | Does not |
| --- | --- |
| Entries, references, thread facts and the task, summary versions | "This session" approvals: a resumed thread asks again |
| Instructions, model, tools, think, command timeout | Session-scope facts: they are the server's |
| The facts it was asked not to propose again (now in `thread.json`) | Parked questions: withdrawn when their server stopped |
| | Continuity counters, token totals, frames and receipts of earlier turns |

### D10. The output store

Outputs stay in `~/.wisp/output/<audit session>/`. The sweep stops treating a saved thread's directories one by
one: they are kept while the thread is kept, and go with it, so a reference in a resumed thread still resolves.

### D11. Chat

- Every chat thread is saved as it goes (D4), not only on `/save` or exit with a name.
- `/threads` lists the threads you may open (all of them); `--resume ID` opens one, MCP ones included.
- Opening a thread with restricted settings shows them first: `git4: ollama:granite4.1:8b, tools run_command,
  instructions set (an agent's thread)`. The settings hold in chat; `/new` starts a fresh thread instead.
- While a thread is open in chat it is locked (D6), so its agent is refused until you leave it, and told why.
- `wisp-tui` gets the same through chat's commands; a picker for `/threads` is phase 3.

## Phases

Each phase is releasable on its own.

| Phase | Contents | Release |
| --- | --- | --- |
| 0 | The four fixes found while mapping, each with a test | patch, 0.26.3 |
| 1 | The store, save after each turn, the lock, resume on MCP with settings checks, audit and resources, `close_thread` deleting; ADR 0066; `docs/mcp.md`, `docs/logging.md`, `docs/design.md` | 0.27.0 |
| 2 | Chat on the store: saved as it goes, ids and `/save` renaming, `--resume` by id, `/threads`, opening an MCP thread, the legacy transcripts read | 0.27.0 or 0.28.0 |
| 3 | `wisp threads` (list, show, delete, hand), the retention sweep's report in `wisp doctor`, `wisp-tui`'s picker | 0.28.0 |

The foldable log pane planned for 0.27.0 moves to the release after phase 2.

## Tests

All without the model, over `ScriptedModel`:

- The store: a save and load round trip of settings and record; a torn write (record without `thread.json`) is not
  resumable; files and directory modes; the version check.
- Resume over the wire (`WispServerWireTests`' pattern): a turn on a thread, the server torn down, a new server on
  the same home, a call naming the thread resumes it with its settings and earlier turn; equal settings accepted,
  different refused with the field named; a closed thread is not resumed; a disabled model fails the resume.
- The lock: two servers on one home, the second refused while the first holds the thread, and allowed after the
  first closes it or its process ends.
- Audit: `resume` and `carriedFrom` on the new `session.start`; `disconnected` at a client's end; the resources
  spanning both sessions.
- Chat: every turn saved; `--resume` of an MCP thread shows its settings and keeps them; legacy transcripts read.

## Settled on review

Answered on 2026-10-16, each as recommended:

1. D3: an MCP caller resumes only its own client's threads, and those the person hands it.
2. D4: `close_thread` deletes the thread from the store.
3. D4: retention is 30 days (`threads.keepDays`), matching the output store.
4. D5: equal start settings are accepted on a live thread too.
5. Phases: phase 0 is 0.26.3; phases 1 and 2 are 0.27.0; the foldable log pane follows.

Answered on 2026-10-20, for phase 3, each as recommended:

6. Phase 3 is 0.28.0 alone; the foldable log pane moves to 0.29.0.
7. `wisp threads hand` and `delete` are the person's only: they need a terminal, and the command policy refuses
   them to wisp's model, as it refuses `wisp approvals approve`.
8. `wisp-tui`'s picker switches thread in place, through a chat command `/resume ID` that the plain chat has too.
