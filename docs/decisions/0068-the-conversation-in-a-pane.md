# ADR 0068: wisp-tui draws the conversation in a pane of its own

Date: 2026-10-22. Status: accepted. Chosen by the operator on 2026-10-22. Amends
[ADR 0029](0029-tui-front-end.md): the conversation no longer goes into the terminal's scrollback while it runs.

## Context

ADR 0029 put `wisp-tui` on ratatui's inline viewport: each finished line was written once into the terminal's own
scrollback above a band holding the input and the status. A line written there cannot be changed. So a long tool output
was cut at its first `shownOutputLines` lines (20) with `… 84 more lines · ctrl-o shows all`, and the only way to see
the rest was the Ctrl-O panel, which showed the *last* output alone. A stretch of thinking was printed the same way. A
long turn's twenty-line blocks pushed its reply off the screen, and nothing earlier in the conversation could be
reached from the keyboard. The owner asked on 2026-10-15 for outputs that fold and for each element to be reachable.

Two ways were compared on the roadmap (`roadmap.md`, 0.29.0) and put to the operator on 2026-10-22:

- **A pane of its own**: `wisp-tui` draws the whole conversation itself, on the alternate screen, above the band. It can
  fold, unfold, select, and scroll anything in it. The cost is that the terminal's scrollback, search, and selection no
  longer hold the conversation while it runs.
- **The Ctrl-O panel extended**: the scrollback stays as it is, and the panel lists the session's elements with folding
  and navigation. A smaller change, but the scrollback itself never folds, so the problem the owner named stays on
  screen.

The operator chose the pane, to replace the inline view outright rather than sit beside it as an option, with the
conversation printed into the scrollback on quitting, and all four of the roadmap's stages in one release.

## Decision

1. **The conversation is a list of elements in memory** (`transcript.rs`): a line sent (a prompt, a command typed after
   `!` or `!!`, a help request), a tool call with its result lines and output, a stretch of thinking with its text, a
   reply, a run of notes, a slash command's output, an error. Lines from wisp are grouped as they arrive, by the rule
   that already set a new part of a turn apart with a blank line (`starts_part`): a sent line, a `⚙` or `∴` line, a
   reply's first line, and the `ran:` line each start an element. A tool's output and a stretch of thinking's text are
   kept whole as the event carried them (up to 16 KiB each, ADR 0050) as the element's body.
2. **The pane draws it** on the alternate screen, every row above the band, inset by the margin as before, a sent line
   tinted edge to edge between half-block strips as before. It follows the end of the conversation while the person
   has not scrolled; `PageUp` and `PageDown` (when no panel is open) scroll it, and scrolling back to the end follows
   again. **The mouse stays the terminal's** (chosen by the operator on 2026-10-22, over capturing it for the wheel):
   dragging selects text as it always has. Many terminals send the wheel on the alternate screen as Up and Down
   (alternate scroll mode, DECSET 1007), which in `wisp-tui` would recall earlier input, so `wisp-tui` turns that mode
   off while it runs and back on when it leaves; the wheel then does nothing in the pane.
3. **Folding.** An output or a stretch of thinking longer than wisp's `shownOutputLines` folds to an info line and its
   last three lines, which for a build or a test run are where the result is: `▸ 248 lines · 12.0 KiB · exit 0`, the
   exit status taken from the call's `command.outcome` details. Unfolded, the info line reads `▾ …` and the whole of
   what the event carried follows, with `… N more lines: ctrl-o pages the whole` when wisp held more back. Replies,
   notes, and sent lines never fold. The bodies held are bounded at 32 MiB together; past that the oldest are let go,
   keeping their info line, and Ctrl-O pages them from wisp's output store (ADR 0050).
4. **Navigation.** Shift-Up from the input selects the last element, and Shift-Up and Shift-Down (or Up and Down while
   one is selected) step through them; the selected element is marked in the margin and kept in view. Shift-Right or
   Right unfolds it, Shift-Left or Left folds it, Enter toggles. Ctrl-O pages the selected element's output whole in
   the panel, as it does the last output's with nothing selected. Esc, or any character typed, returns to the input;
   the character goes in.
5. **Copying.** Ctrl-Y copies the selected element, or with nothing selected the last reply, to the clipboard through
   OSC 52, the terminal's own clipboard sequence, as plain text: the element's lines, and its body whole as the event
   carried it, folded or not. A note says what was copied, or that the terminal may not support it.
6. **Quitting prints the conversation** into the scrollback once the alternate screen is left, each element as the pane
   last drew it (a folded output folded), so it is still there to search and copy with the terminal's own tools. The
   saved thread and the audit log keep it whole, as they did.
7. **Nothing changes in wisp.** The protocol (`ChatProtocol`) already carries everything the pane needs: each event's
   rendered line, its details, and its output.

## Consequences

- One renderer: the inline viewport, `insert_before`, and the band's regrowing are gone, and with them the terminal
  remade on each change of the band's height. The band is drawn at the bottom of the screen at the height it needs.
- While `wisp-tui` runs, the terminal's scrollback holds nothing of the conversation, and its own search does not reach
  it; quitting puts it back. A crash that leaves the alternate screen without printing loses only the on-screen copy:
  the thread is saved after every turn.
- Memory grows with the conversation's lines and up to 32 MiB of bodies; an output beyond its event's 16 KiB was never
  held here and still is not.
- The wheel does not scroll the pane; capturing the mouse for it would have made selecting text with the terminal
  need a modifier key, and the operator chose plain selection. PageUp and PageDown, and Shift with the arrows over
  elements, are the pane's ways through the conversation.
- Shift with the arrows reaches the elements only in a terminal that sends Shift with them, which not every
  terminal does by default; once an element is selected, plain Up and Down step through them too.
- Tests: the grouping into elements, folding, the pane's rows at a width, scrolling, navigation, copying's sequence, and
  the printing on quit, all on ratatui's test backend or plain buffers; the alternate screen itself needs a terminal.
