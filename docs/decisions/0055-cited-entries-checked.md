# ADR 0055: Cited entries checked

Date: 2026-10-04. Status: accepted. A second check beside [ADR 0051](0051-the-turns-tool-calls-beside-the-reply.md)'s
`ran:` line, of the same kind: deterministic, from wisp's own records, with no model.

## Context

wisp names what a conversation's store holds by entry number, and the model reads those names: a tool output after
its turn is `[output of entry 7 not repeated: …; to see it: memory "recall entry 7"]`, a recalled turn is headed
`turn 4: entries 12-15`, and `/show` and `/inspect context` use the same numbers.

In session `ce87576a` (granite4.1:8b, 2026-10-04), at 12:54Z, having run only `inspect(config)` and
`system_info(ports)`, the model replied with an eight-step report citing "Result (entry 19)" through "(entry 30)"
for steps that never ran, and ended "(All steps logged in entries 16-30; timestamps omitted for brevity.)". The
thread's store held about 18 entries: 16 to 18 were real, 19 to 30 did not exist. The references were in wisp's
own form, so the report looked checked. ADR 0051's line showed that the turn ran two tools; nothing showed that the
entries the reply leaned on were invented.

## Decision

- **After each reply, the entries it cites are checked against the store** (`CitedEntries`). The forms read, in any
  case: `entry N` and `entry #N` (which covers `memory "recall entry N"` and `output of entry N`), `entries N-M` with a
  hyphen, an en dash, or an em dash, `entry N–M`, and lists such as `entries 19, 20 and 21` or `entries 3, 5-7, or 9`.
  Ranges are expanded, at most 100 numbers per reply in all; past that the rest are not checked and the line says
  so. A number no stored entry has is missing. The turn's own entries are stored before the check, and every stored
  entry was recorded in this turn or an earlier one, so existing is the whole check; there is no later entry to
  cite.
- **A muted line beside `ran:`**, consecutive numbers as ranges, at most eight groups and then how many more:

  ```
  ran: inspect · system_info
  cited but not in this conversation: entries 19–30 (12)
  ```

  None is shown when the reply cites nothing, or only entries that exist.
- **The same channels as `ran`**: plain chat prints it under the reply; `wisp chat --json` carries it as `cited` on
  the turn's `end` line, which `wisp-tui` shows after `ran`; `respond` returns `unknownEntries` (the numbers, in the
  order cited) and `cited` (the line) in `structuredContent`. The text the caller's model reads is unchanged.
- **Not audited.** Like `ran`, the line is derived from the reply and the store and can be derived again.

## Consequences

- An invented reference in wisp's own form is visible where it is made: under the 12:54Z reply the person would have
  read `cited but not in this conversation: entries 19–30 (12)`, and not 16 to 18, which existed.
- It checks that an entry exists, not that it says what the reply claims. Whether a cited entry supports the claim
  beside it is a judgement for the 0.20.0 evals, as ADR 0051 left the reply-against-calls check.
- Numbers in other forms ("step 19", "line 19") are not entries and are not read; a reply that invents work without
  citing entries shows no line.
- Tests without a model: each form, ranges with each dash, lists, the cap, the 12:54Z reply's shape with 18 entries
  stored, real against invented entries, no citation, the line's grouping and bound, the chat footer, the JSON turn
  line, `wisp-tui`'s note, and `respond`'s `unknownEntries`.
- Documented in `wisp.md` (chat, and the headless protocol), `mcp.md` (`respond`), and `design.md`.
