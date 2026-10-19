# ADR 0066: One thread store: every MCP thread saved, and resumed by a later server

Date: 2026-10-18. Status: accepted 2026-10-16 (the [one-thread-store proposal](../proposals/2026-10-16-one-thread-store.md),
every recommendation taken); phase 1 built 2026-10-18 for 0.27.0; phase 2, chat on the store (D2, D11), built 2026-10-19
for 0.27.0 (the amendment below).

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

## Amendment, 2026-10-19: chat on the store (phase 2)

Phase 2 of the proposal, D2 and D11, built for 0.27.0:

1. **Every chat is a thread.** Plain chat and `wisp chat --json` (and so `wisp-tui`) open their conversation as a
   thread in the store through `ChatThread`: a new one as `chat-<8 characters>`, owned by `chat`, its lock taken before
   `Session.begin` so the start-up sweep cannot take it and no other wisp opens it. It is saved after every turn, a
   failed one included, and after every command the person runs with `!`; at the end of the loop it is saved as
   `saved` and its lock released. A chat that never had anything to save (a record of instructions alone) leaves no
   directory behind. The chat's audit session is the session's own, so `thread.json` lists it as is, not as
   `<id>-<suffix>`.
2. **`/save NAME` renames** the thread: saved under the new id, locked there, deleted under the old. Refused for a name
   another thread has (`a thread named 'git4' is already saved`), one the store cannot take, and an agent's thread,
   whose agent names it by its id. A bare `/save` saves now. `--save NAME` names a new chat's thread, or renames a
   resumed one of the person's own; nothing writes to `~/.wisp/transcripts` any more.
3. **`--resume ID` opens any thread** from the store, an MCP agent's included (D3), then falls back to
   `~/.wisp/transcripts/<ID>.json` and saves what it finds into the store under that name at once, leaving the
   transcript in place. A transcript whose name the store cannot take (over 48 characters, or starting with a dot) is
   saved under a generated `chat-` id; the proposal did not say.
4. **An agent's thread keeps its settings in chat.** Its model, tools, and instructions become the session request's
   (`ChatThread.Opening.applied`), so `session.start` records them, and its thinking and command limit go to the agent;
   flags that differ are refused naming them, as D5 refuses an MCP caller. Chat shows them first:
   `git4: ollama:granite4.1:8b, tools run_command, instructions set (an agent's thread: claude-code's, 12 turns); its
   settings hold here, and /new starts a thread of your own`. Each save writes its record, turns, and last use under its
   own settings and owner, so the agent resumes it afterwards with the person's turns in it and its own settings still
   equal. Not in the proposal, and needed to keep that true: `/model`, `/think`, and `/save NAME` are refused on it.
5. **`/new` starts the chat's own thread** with the same instructions, tools, and command limit, the existing meaning
   of `/new`, which on an agent's thread is a thread of the person's own with that agent's tools. The proposal's "starts
   a fresh thread instead" does not say with which settings; carrying the conversation's keeps `/model` correct after
   it, since the session's tools are the ones it began with.
6. **A chat's own thread resumes on the flags and configuration as given**, `--model` included, as chat resumed a
   transcript before, and its saved model and thinking follow `/model` and `/think` at each save. The proposal's D5
   (saved settings on resume) is for agents; the person's own thread is theirs to change. A fallback to `system`
   (ADR 0056) applies to it as to any chat.
7. **The lock between chat and agents** (D6): while chat holds a thread an agent naming it is refused with
   `thread git4 is open in another wisp (pid 4242, chat)`, and chat refuses to open one another wisp holds the same way,
   naming its holder. A resumed chat's `session.start` carries `resume` (the id as typed) and `carriedFrom` (the
   thread's sessions from `thread.json`, or a transcript's store links' sessions) (D7).
8. **`/threads`** and `wisp chat --list` list every thread in the store, any owner's, most recently used first: id,
   owner, model, turns, last used, and state (`open` here, `open elsewhere` from the lock, `saved`), then the
   transcripts in `~/.wisp/transcripts` not yet in the store. Chat's commands reach `wisp-tui` as message lines and
   their answers as `output` and `note` lines, so neither `ChatProtocol` nor `wisp-tui` changed; the picker is phase 3.

Tested without the model (`ChatThreadTests`, `ChatLoopTests`, and `ThreadResumeWireTests.chatAndAnAgentHoldAThreadInTurn`):
every turn saved before the next prompt, `/save` renaming and its refusals, an agent's thread opened with its settings,
refusing flags, `/model`, and `/save NAME`, and saved under its owner, `/new` on it, a transcript read and saved into
the store, the generated id for a name the store cannot take, `/threads`' states, `session.start`'s `resume` and
`carriedFrom`, and the lock refusing a server while chat holds a thread and chat while a server does, the server then
resuming chat's turn. `ContextEquivalenceTests`' chat snapshot was recorded again: its requests, events, and saved
contexts are unchanged but for the renumbering of ids, and only its `/save` and `/new` notes and the saved transcript
differ, as the change intends. Checked live on 2026-10-19 on `system` in a scratch home: a turn saved as `chat-…`,
`/save first` renaming, `--resume first`, `--list`, and a chat quit at once leaving nothing.
