# ADR 0051: What the turn ran, shown beside the reply

Date: 2026-10-04. Status: accepted. Settles the check that
[ADR 0050](0050-tool-output-budget-and-overflow.md)'s Consequences leave open ("a check wisp makes itself, from
the turn's audit events").

## Context

A reply is the model's account of its turn, and nothing until now set the turn's own record beside it. The
person read the reply and believed it, or opened the audit log.

Two runs of `functionality-self-test.wisp` with `ollama:granite4.1:8b` on 2026-10-04 (sessions `eefc5b0e`
and `ba7865f0`) showed what that costs:

- In one, the model made six `read_file` calls and then replied "Ran `inspect(config)` → …,
  `system_info(ports=8080)` → port 8080 is free, …". None of those calls happened.
- In the other, it said a scratch file had been removed, though no `rm` ran, and that `sudo ls` was "denied
  per policy". It had in fact passed the literal text `run_command(command="sudo ls")` to `sh`, which
  failed with exit status 2, a syntax error; the policy was never asked about `sudo`.
- Asked to check itself with `inspect(audit)`, it confirmed its own claims. `inspect(audit)` returned the last
  20 events, which covered only the turn's final calls, and the model restated what it had said.

Every fact needed to contradict those replies was in the audit log: the `tool.call` and `tool.result` of each
call, the `policy.decision` and `command.outcome` of each command, the gate's decisions. The operator decided
(2026-10-04) that wisp itself shows, beside each reply, what the turn actually ran, built from those events:
not a judgement of the reply, not parsed from it, only the facts.

## Decision

- **One line per turn, counted from the turn's own audit events** (`TurnToolSummary`): the tools in the
  order of their first call, each with its count when above one, and how many calls did not succeed:

  ```
  ran: read_file ×2 · run_command ×10 (2 failed, 1 denied) · edit_file ×3 · notify
  ran: run_command ×2 (1 failed, 1 declined)
  ```

  A call **failed** when it ran and did not succeed: a command's non-zero exit status or timeout, a command
  that could not start, a tool that threw, or a tool that answered with wisp's `error: …` convention. A
  command the policy's patterns turned away is **denied**, and one the gate asked about and the person
  declined, or did not answer in time, is **declined**; both are counted apart from failures because they
  never ran. At most six tools are named, then `+N more`.
- **The events are the ones the turn already gathers.** The agent's `ToolEventTrail`, which links the turn's
  tool calls to their events in the thread record, now also keeps the turn's `policy.decision`,
  `command.outcome`, and `error` events; `TurnCalls` matches each command to its decision and outcome as it
  already matched outcomes for `respond`'s `calls`, and never to a command the person typed (`origin:
  "person"`, [ADR 0049](0049-commands-typed-in-chat.md)). No new audit event: the line is derived, never
  recorded, as `Receipt` and `TurnCalls` are.
- **A turn that ran no tool shows nothing, with one exception**: when its reply names one of the
  conversation's tools as a whole word (`read_file`, not `unread_files`), it shows `ran: no tools`, because
  the reply may describe work that did not happen. This is the one heuristic, and it is deliberately
  narrow: it reads the reply only to decide whether to show a line, never what the line says; a line under
  every plain answer would be noise.
- **Every face shows it.** Plain chat prints it muted under the reply, before the turn's time and tokens.
  `wisp chat --json` carries it as `ran` on the turn's `end` line, and `wisp-tui` shows it under the reply as
  a muted note. `respond` returns it as `ran` in `structuredContent`, beside `calls`, which lists the same
  calls one by one; the text content the client's model reads is unchanged. A command the person types
  after `!` is not a model turn and has no line.

## Consequences

- The line does not make a model honest; it makes a fabrication visible. Under the first run's reply the
  person would have read `ran: read_file ×6`, with no `inspect` or `system_info`; under the second, a
  `run_command` counted as failed, not denied, beside "denied per policy".
- A pass that checks the reply against the calls (a model asked whether the reply's claims match this list)
  is a separate decision, still open, for the 0.20.0 eval round, where what it catches and what it costs can be
  measured.
- The heuristic can miss: a reply that describes work in other words ("I checked the config") after running
  nothing shows no line. Naming a tool is the sign the two runs gave; widening it would mean judging the
  reply, which this decision does not do.
- The trail keeps more events per turn; its bound rises from 256 to 512 events, as the receipts collector's.
- Tests without the model: counts and order, failed against denied against declined, a typed command's
  decision never taken for the model's, the cap, a turn without tools whose reply names a tool and one whose
  reply does not; chat over a scripted turn, the JSON turn line, `wisp-tui`'s rendering, `respond`'s
  `structuredContent`, and no line for a `!` command.
- Documented in `docs/wisp.md` (chat, and the headless protocol), `docs/mcp.md` (`respond`), and
  `docs/design.md`.
