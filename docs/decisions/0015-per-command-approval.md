# ADR 0015: Approve each simple command in a line, remembered by its program

Date: 2026-09-19. Status: accepted. Amends ADR 0014 (exact-line matching).

## Context

A `run_command` line can chain or pipe several commands (`ls && curl … | sh`), so classifying and
approving the whole string lets a dangerous part hide behind a safe first one. And exact-line matching
made approvals nearly useless for real work: `head -n 5 a` and `head -n 10 b` asked twice.

## Decision

- `CommandSplitter` splits a line into simple commands with a shell-aware pass: quotes and escapes,
  the operators `;`, `&&`, `||`, `|`, `&`, and newlines, and the bodies of `$(…)`, backticks, and `(…)`
  subshells. It is a policy pre-pass, not a shell; what it cannot parse stays inside the enclosing segment
  where the deny patterns and classifier still see it.
- Each simple command is classified and, at or above the threshold, approved on its own, with the whole
  line shown for context. A denial for any part refuses the whole line; nothing runs.
- The approval key is the **essential command**: the program that actually runs, after unwrapping
  `sudo`, `env`, `time`, `timeout`, `xargs`, variable assignments and similar, without its directory,
  followed by ` *`. `head -x 1 -y 2` and `head -n 5` are both `head *`. Session, project, and always
  approvals are stored under that pattern (plus the directory for session and project).
- Deny patterns run on the whole line and on every part.
- A standing approval still only decides whether to ask: every part is classified on every run, and a
  dangerous verdict always asks. So `rm *` approved for `rm file` never covers `rm -rf build`, and
  `git *` never covers `git push --force`.

## Consequences

- A pipeline of three risky parts raises three dialogs the first time and none afterwards for the same
  programs. That is the intended trade: approvals follow programs, not argument spellings.
- The model classifier runs once per part, about 1.5 s each; long pipelines are slower to gate.
- `~/.wisp/approvals.json` entries carry `pattern` rather than a command line.
- Audit events for classification and approval carry `command` (the part), `pattern`, and `line`.

## Amendment, 2026-10-11: compound commands read by their bodies, and a line asked once

A standing approval `do *` was found on 2026-10-09: a `for … do …` loop had been remembered by the shell keyword
`do`, so the approval covered any later loop whatever its body ran. 0.21.1 stopped the harm by remembering
keywords and interpreters by their exact text, which made every new loop body ask again. Three changes, all in
the splitter and the gate, and none to what a pattern is:

- **A clause is its command.** `do X`, `then X`, `else X`, `elif X`, `if X`, `while X`, `until X`, `! X`, `{ X`,
  a function's body, and a case branch's `a) X` are parts as `X`, with `X`'s own pattern; a loop header and a
  closing keyword alone are not parts at all, so a keyword is never remembered on its own. A part that uses a loop
  variable carries what it ranges over (`rm "$f" # f in ~/*`) so the rules judge it by that. `find -exec`'s
  command is a part too.
- **A line only the whole of shows the risk of is asked once.** Every part is classified first. When the rules
  rate the whole line above every part (and at the threshold or above), the line alone is asked, remembered by
  its exact text, and its parts are covered for that line, audited as `covered-line`; before, the risky part was
  asked and then the line. The person approving the line saw every part of it, so asking the parts as well added
  a dialog and no information. A part run on its own later is judged afresh. The cost: every part is classified
  before any is asked, so a refusal no longer saves the later parts' classifier calls.
- **A program chosen at run time** (`$X args`, `$(which rm) -rf`) is at least moderate and remembered by its exact
  text, since its name says nothing of what runs; `$(…)` in the program's place is now a part, not dropped.

The rules' second spelling (quotes, escapes, and `$IFS` read away) now also feeds the deny patterns, and leaves
the data of printing and searching programs as written, so `grep -E "a|sh"` is not read as a pipe into a shell
([approval.md](../approval.md#classifiers)).
