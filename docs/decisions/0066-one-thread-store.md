# ADR 0066: One thread store: every MCP thread saved, and resumed by a later server

Date: 2026-10-18. Status: accepted 2026-10-16 (the [one-thread-store proposal](../proposals/2026-10-16-one-thread-store.md),
every recommendation taken); phase 1 built 2026-10-18 for 0.27.0. Chat on the store (D11) is phase 2 and is not built.

## Context

An MCP server kept its `respond` threads in memory only. A reconnect, a new build, or a crash lost every one, and a
caller that named the old `thread_id` again silently got a new thread on the server's defaults. On 2026-10-15 the
git thread `git3` came back that way after each reconnect: on the default model, with every tool, and a 120 s
command limit, where `AGENTS.md` asks for `ollama:granite4.1:8b`, `run_command` alone, and 600 s. The caller had
no way to tell, since a start setting on an existing thread was refused and a new thread accepted any.

Chat already saved most of a thread: `TranscriptStore.save(_: ThreadRecord, as:)` writes the transcript (which
carries the instructions) and a `ThreadRecord.Snapshot` beside it, and `WispThread.openAgent` takes both back. What
the snapshot leaves out is what an MCP thread started with: its model, tools, thinking, and command limit, which
lived only in the server's memory and in the audit's `session.start`. The proposal mapped this on 2026-10-16 (at
`bc763e8`); its phase 0, four fixes found while mapping, shipped in 0.26.3.

## Decision

Phase 1 of the proposal, for MCP threads:

1. **The store** (D1). Every `respond` thread is saved under `~/.wisp/threads/<thread_id>/`, a user-only directory:
   `thread.json` (format version 1: the owner; the start settings, model, tools, the caller's instructions, think,
   and `commandTimeoutSeconds`; created, last used, and turns; every audit session it has had, oldest first; the facts
   the person dropped for it; and `open` or `saved`) beside `record.json` and `record.store`, which are what
   `TranscriptStore` writes, unchanged in format. Each file is 0600, staged and renamed, `thread.json` last, so a
   record without `thread.json` is not resumable and the id starts afresh. The proposal's "instructions present" is
   kept as the instructions themselves, so equal settings can be told from different ones (D5).
2. **When it is saved** (D4). After every turn, inside the thread's `TurnQueue`, so a snapshot is never taken
   mid-turn; at eviction, once the turn under way ends; and at the client's end, before `session.end`
   `disconnected`. A resume also writes `thread.json` at once with the new opening's session, so its resources find
   it even if the opening ends in a crash. Eviction drops a thread from memory only; `close_thread` deletes it from
   the store, and its history stays in the audit log.
3. **One process at a time** (D6). An `flock` on `threads/<id>/lock`, taken when the thread is opened or resumed and
   released when it is closed, evicted, or saved at the client's end; the kernel releases it when the process ends.
   The lock file records the pid and owner, and another process naming the thread is refused with
   `thread git4 is open in another wisp (pid 4242, claude-code)`. `flock` locks belong to an open file description,
   so two servers in one test process exclude each other as two processes do.
4. **Resume** (D5). A call naming a thread this server does not hold and the store has resumes it with its saved
   settings. The call's result has `resumed: true` and `resumedTurns: N` in `structuredContent` (`created` is false),
   and its text begins `resumed thread git4 (12 turns, saved 2026-10-16 09:12)`. Start settings the call gives are
   accepted when each equals the thread's and refused naming the ones that differ
   (`git4 was saved with model ollama:granite4.1:8b, tools run_command; these settings differ: model`); settings it
   does not give are not compared. A live thread takes equal settings too (`git4 is open with …`), so a caller that
   always sends its own, as `AGENTS.md` asks, either continues its thread or is told why not. A resume is checked as
   a new thread is: the model must be enabled and open, with no fallback; the tools must exist and the model take
   them; think must suit it; the command limit is cut to today's `commandMaxTimeoutSeconds` when a command runs.
5. **Owner** (D3). A thread's owner is the MCP client's `clientInfo.name`. A caller resumes only its own client's
   threads: another's is refused (`thread o belongs to codex, and this client is claude-code; only codex can resume
   it, so choose another thread_id`), is not listed, and cannot be closed. The refusal names no command to hand a
   thread over, since `wisp threads hand` is phase 3. The name is self-reported, so this keeps agents from colliding,
   not from each other.
6. **Audit** (D7). A resume's `session.start` carries `resume` (the thread id) and `carriedFrom` (the thread's earlier
   sessions, oldest first); `Session.thread` takes both instead of hardcoding nil. A thread deleted by the retention
   sweep is audited as `thread.swept`, a new kind.
7. **Resources** (D8). `wisp://threads` lists this server's threads and the client's saved ones, with `owner` and a
   `state` of `open`, `saved`, `open elsewhere`, `closed`, or `evicted`. `wisp://threads/{id}`, its `facts`, `summary`,
   and `context` read a saved thread from its files without a model; its `audit`, `output`, and `reasoning` read
   every session in `thread.json`, so they cover the thread's whole life, and `output` and `reasoning` rows say which
   `session` each is from, since turns are numbered per opening.
8. **What carries** (D9): entries and references, thread facts and the task, summary versions, the start settings,
   and the facts the person dropped (`FactKeeper.droppedFacts`, restored on resume). Not carried: "This session"
   approvals, session facts, parked questions, continuity counters, token totals, and the frames and receipts of
   earlier turns, so a saved thread's `context` lists no turns and `context/next` shows its record as a resumed
   turn's request would carry it before its facts.
9. **Retention and the output store** (D4, D10). At every `Session.begin`, a saved thread unused for
   `threads.keepDays` (30 by default, 0 to 3,650, 0 keeping them until closed) is deleted with the stored outputs of
   every session it had, unless a process holds it; at most 16 a start within 100 ms, as the output sweep is bounded.
   The output sweep that follows spares every saved thread's sessions, so a reference in a resumed thread still
   resolves.
10. **Ids** (D2). A `thread_id` that starts with a dot is refused, since it names a directory: `SafeName` admits `.`
    and `..`.

## Consequences

- An MCP thread survives its server: a restart, a reconnect, a new build, or a crash after its last turn. A crash
  loses at most the turn under way.
- The git3 trap is closed: a caller sending its settings to a thread saved with others is refused naming the
  difference, and one sending equal settings continues its thread.
- `respond`'s `ThreadFactory` takes a `ThreadStart` (the start settings, the opening's audit session, and what was
  saved) instead of six arguments; every test factory changed with it.
- Saved threads take disk until closed or swept: a record holds the thread's tool output in its transcript, as the
  audit log does, and is user-only for the same reason.
- Reading a saved thread's resources needs no model, but the contexts of its earlier turns are gone for good: the
  per-turn frames are not saved.
- Tested without the model (`ThreadStoreTests`, `ThreadResumeWireTests`): a save and load round trip, modes, torn
  saves, the version check, the lock between two servers on one home, owner and settings refusals, a closed thread
  not resumed, an evicted one resumed, a disabled model failing the resume, `resume` and `carriedFrom` on the new
  `session.start`, `disconnected` at the client's end, the resources spanning both sessions, and the sweep.
- Not built here: chat on the store (D11, phase 2: chat's `/save` and `--resume` still use `~/.wisp/transcripts`), and
  `wisp threads` (list, show, delete, hand), the sweep in `wisp doctor`, and `wisp-tui`'s picker (phase 3).
