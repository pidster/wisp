# ADR 0029: The terminal chat is a Rust front end over a headless wisp

Date: 2026-09-22. Status: accepted. Amends the chat's place in `design.md`. Amended by [ADR 0064](0064-an-approved-run-outside-the-sandbox.md) (2026-10-14): a third input mode, outside the sandbox, in a muted red.

## Context

`wisp chat` lived inside the terminal's line discipline: replies, notes, and approvals in one
stream, a status line reprinted above every prompt, no editing beyond what cooked mode gives. The
reference tools (Claude Code, Codex) pin input and status at the bottom and let the conversation scroll
above, inline, keeping scrollback. Five ways to get there were compared (`proposals/2026-09-22-tui-spike.md`);
ratatui by process split was spiked on a branch and judged on a real terminal the same day.

## Decision

- `wisp chat --json` is the headless chat: the same `ChatLoop`, session, tools, gate, and audit, with
  its IO mapped onto JSON Lines (`ChatProtocol`, `LineRouter`, `JSONApprover`). Any front end can drive
  it; the plain `wisp chat` stays for terminals without the front end and for pipes.
- `tools/wisp-tui` is the terminal front end: a Rust program on ratatui's inline viewport, spawning
  `wisp chat --json`, committing finished lines to the terminal's own scrollback and drawing a band at
  the bottom with the reply in progress, an approval dialog, the input, and the status. wisp becomes a
  two-language product on purpose: Rust for what owns the terminal, Swift for everything the model,
  the policy, and the audit touch.
- One palette for both faces (`palette.rs`, `Style.Palette`): a pale blue in four tones for what wisp
  says, amber for attention, ember for danger, white for the conversation. Chosen by eye on
  2026-09-22 after a greener, darker first set was rejected.
- Padding is cells: a one-cell text inset everywhere, the input's tint edge to edge with half-block
  strips above and below, since a terminal cannot tint less than a row.

## Consequences

- The protocol is a contract to keep and version; its shape is documented in `wisp.md` and may still
  change (a `turn` event, pre-rendered versus raw events) before it is called stable.
- Two binaries to build, test, and ship: the gate already runs both; the formula does not yet install
  the front end, and `wisp chat` does not yet hand off to it. Those, with line editing and history in
  the input, are the next work (`backlog.md`).
- Tests: the loop over the protocol without a model (`ChatProtocolTests`), the band rendered to
  ratatui's test backend, key handling, and event rendering; the viewport itself needs a real terminal.

## Amendment, 2026-09-25: the protocol's shape

The two open questions are settled.

- **A `turn` event.** `{"type":"turn","phase":"start","turn":n}` when a message goes to the model and
  `{"type":"turn","phase":"end","turn":n,"seconds":…,"outcome":"ok"|"error"}` when the reply is done.
  Before, a front end inferred a turn from its own submit and the next `status`, which also follows
  slash commands, and had no duration or outcome. The number is the one the turn's audit events carry,
  so a front end can group them. `wisp-tui` shows the running turn and the last one's time in the
  status line.
- **Raw events, with the rendered line beside them.** Each `event` keeps its raw `kind`, `call`,
  `turn`, and `details`, and gains `text`: the unstyled line the terminal chat shows for it
  (`ChatEvents.render` with `Style.plain`), null when it shows none. Raw alone meant every front end
  re-implemented the wording, and `wisp-tui`'s copy had already drifted (it lacked `current_date`'s
  time zone and `read_file`'s start line). Pre-rendered alone would have taken the facts away from a
  front end that wants its own view. `wisp-tui` now shows `text` and has no renderer of its own; its
  styling is chosen by `kind`.
- **Compatibility.** A front end ignores types and fields it does not know, so additions like these
  need no version negotiation. `wisp-tui` ships with the wisp of the same version (the release checks
  the two match), so neither side keeps a fallback for the other's older shape. A removal or a changed
  meaning needs a new amendment.

## Amendment, 2026-09-29: the turn's tokens, and the gate's decisions as event text

A `turn` line with `phase` `end` also carries `inputTokens` and `outputTokens` when the model reports
usage. They are the turn's totals across the requests its tool loop made, taken from the session's
running usage. `wisp-tui` shows them after the turn's time in its status line.

`classifier.verdict`, `approval.decided`, `policy.decision` (when not allowed), and `model.routed`
events now carry a rendered `text`. The front end shows them as it shows tool lines, with no change of
its own. The lines are listed in `docs/wisp.md`.

An `activity` line (`doing`, `asking`, `turnSeconds`) reports what the turn under way is doing each time
that changes, with `doing` null when it ends. `ChatActivity` derives it from the turn's events, so the
terminal chat's working line and `wisp-tui`'s say the same thing. `wisp-tui` times it on its own
clock. It redraws on an idle wake only when the text has changed, so the cursor still does not move four
times a second.

## Amendment, 2026-10-09: keys a dialog takes, and leaving

A code review found two ways a letter typed for the input box answered an approval: a dialog that appeared
while the person typed took the next key, and keys held while a turn ran were replayed into a dialog open
when it ended (and into the one queued behind it). `wisp-tui` now replays held keys only into the input
box; with a dialog or a choice open they stay held until it closes. A dialog takes its keys only once the
keyboard has been quiet for 500 ms after it appears; a key sooner is held for the box and restarts the
wait. A grace was chosen over a key then Enter because it keeps every answer one key, as the plain chat
asks it, and it removes both paths: typing on never answers, and a person who stops to read the dialog
loses nothing. Ctrl-C still refuses at once, since refusing is safe.

Ctrl-C or Ctrl-D used to wait for wisp with its stdin still open, so `wisp-tui` hung and the transcript
was not saved. It now sends `/quit`, closes wisp's stdin, waits up to five seconds before killing it,
prints the rest of wisp's stderr after the band is gone, and exits with wisp's status when wisp failed.

## Amendment, 2026-10-11: Ctrl-C during a model's turn

Ctrl-C quit `wisp-tui` at once during a model's turn, and a command the model had started could outlive it. It now
stops the turn, as it stops a command typed after `!` ([ADR 0049](0049-commands-typed-in-chat.md), amended
2026-10-11): while the turn's `activity` line says it is `stoppable`, the first Ctrl-C (or Ctrl-D) sends `interrupt`
and the busy box reads `stopping the turn · Ctrl-C again quits`; wisp cancels the model's request, stops the command
the turn started, and returns to the prompt with `stopped by you`; a second press quits, and wisp, its input closed,
kills what the turn still had running. A wisp that does not say a turn is stoppable is quit at once, as before. The
front end keeps no policy of its own: it only sends the line.

## Amendment, 2026-10-12: an interactive status bar

The operator asked for `questions: 1` in the status row and for the row to be interactive: Down from the input's
last row focuses the model, then the other items, and activating one opens what it names. The row is now a bar of
items, each opening a view or a dialog that already exists; none is a new way to answer anything.

- **Items.** The model (sends `/model`), the context gauge (the Ctrl-T panel), `questions: N` (the first waiting
  question's picker), `approvals: N` (the first waiting approval's dialog), and the last turn (`/inspect context
  turns`), in the order shown, each focusable only while it can do something: the counts only above zero, the
  gauge only when wisp reports it, the turn once one has ended. The directory, branch, and approval mode stay
  text, as no view of theirs exists. `approvals: N` replaces `⚠ N waiting`, which lumped approvals and questions
  together: separate counts say which dialog opens, and the approvals keep the amber they had. Both counts include
  the one on screen, since `questions` counts this chat's open question by the operator's wording.
- **`/model` with no name** printed the model and its capabilities; there was no model picker to reuse. In a face
  with a chooser of its own (`wisp-tui`) it now also offers the models it can switch to, enabled and able to serve
  the conversation's tools, as a `choice`, and choosing one switches as `/model NAME` does. The plain chat, which
  reads a line at a time, still only prints. The bar's model item sends `/model`, so typing it and activating the
  item are the same path. `/models`, the table of models to turn on and off, was the other candidate; it does not
  switch, which is what pressing on the model's name asks for.
- **Keys.** Up and Down move the cursor a row in a message of several rows before they recall, so Down from an
  upper row moves the cursor and only Down from the last row (or the only one) moves the focus, as the operator
  asked. In the bar Left and Right move (Tab and Shift-Tab wrap), Enter or Space opens, Up or Esc returns to the
  input as it was, and any other key returns to the input and does there what it always does, so a character typed
  is never lost and Ctrl-C still quits.
- **No answer from the focus.** Opening an approval from the bar starts the dialog's grace (amendment of
  2026-10-09), so the key that opened it, or one straight after, is held for the box. A dialog or choice that
  arrives while the bar has the focus takes the keys, and the focus returns to the input when it closes. A picker
  opened over a typed line parks the line and gives it back when it closes, since a picker's typed answer uses the
  same editor and closing it used to clear it.
- **Narrow rows.** Parts go in turn rather than being cut mid-word: the directory shortens, then the mode and the
  turn go, then the directory, then the gauge; the waiting counts and the item with the focus stay. The highlight
  is black on the item's own colour, so it adds no colour to either palette.

No protocol change: the counts are what `wisp-tui` already holds. Tested without a terminal: the key routing, the
items and their order, the counts at zero, activation and the grace, the parked draft, and widths down to zero with
wide characters (`tools/wisp-tui/src/main.rs`, `app.rs`, `editor.rs`); the `/model` picker in `ChatLoopTests`.

## Amendment, 2026-10-15: the status line's left half, and version control by detection

The owner asked for the left half to read `$model ($think) $n% used · $path $vcs($branch)`, and for the version
control to be detected rather than assumed: git and Subversion now, others (Jujutsu) later. It now reads
`ollama:granite4.2:8b (off) 15% used · ~/src/wisp git(main)+12-3`, in both the plain chat and `wisp-tui`.

- **The model's part.** The thinking (ADR 0053, amended the same day) moves from a separate `· think off` to the
  model's own brackets, the value alone, `(off)`, as the owner chose over `(think off)`; the gauge follows after a
  space, where a colon was. A model with no thinking to set has no brackets. In `wisp-tui` the value is an item of
  the bar, as the model is, between the model and the gauge in the bar's order, and Enter on it sends `/think`.
- **The place.** The directory, then the system's name and its branch in brackets, then the line counts after the
  bracket, `git(main)+12-3`, or a star for a dirty tree without counts, as the owner chose over counts inside. A
  system that cannot tell its branch shows its name alone, `svn`. Outside a working copy only the directory shows.
- **Detection.** `VersionControl` walks up from the directory to the nearest ancestor holding a system's marker,
  `.git` (a directory, or the file of a worktree or a submodule) or `.svn` (Subversion 1.7 and later keep one at
  the working copy's root); where one directory holds two, the first system in its list wins, so a colocated
  Jujutsu repository, which keeps `.jj` beside `.git`, can be put ahead of git when it is added. Each system has a
  reader: git's is the one `GitState` had (the branch from `HEAD`, the counts from `git diff --numstat HEAD`);
  Subversion's takes the branch from `svn info --show-item relative-url` by the standard layout (`trunk`, or the
  name under `branches/` or `tags/`), whether anything changed from `svn status --quiet`, and only then the counts
  from `svn diff`'s `+` and `-` lines. The `svn` tool is not on this project's Mac, so its reader is tested on
  sample output through a stand-in for the tool, not live.
- **Time limits that hold.** The owner pointed out that one fixed limit could cost `svn diff`, which reads every
  changed file against its pristine copy. Looking at it showed the limit never held at all: the runner read the
  command's output to its end before it checked the clock, so a slow command stalled the status line for as long as
  it ran, git's included. The output is now read on another thread and the command stopped at its limit: two
  seconds for what reads only the working copy's own records (git's branch and counts, `svn info`, `svn status`),
  five for `svn diff`, and only when `svn status` found a change. A part past its limit is left out rather than
  waited for, so a tree too slow to count still shows its star, `svn(trunk)*`, since the line is drawn before
  every prompt.
- **Protocol.** `status` gains `vcs` (`git`, `svn`, or null); `wisp-tui` reads it as absent from an older wisp.

Tested without a terminal or a model: detection by marker for both systems, Subversion's branch and counts from
sample output, the plain line and `wisp-tui`'s row with and without thinking, a system, and a branch, the bar's
order and the item's `/think`, and the protocol field.

## Amendment, 2026-10-15: the version control read off the prompt's path

The owner asked whether the version control check was asynchronous, with an updater that does not block the status
line. It was not: the loop read it before drawing each prompt, and `wisp-tui` holds its input until the `status`
line comes, so a slow read held both, up to nine seconds for Subversion's three commands at their limits.
`VersionControlWatch` now keeps the last read's answer for the chat's directory and runs one read at a time on
another thread. Each prompt is drawn with the last answer; only the first call waits, up to 200 ms, for a first read
(the branch fact recorded as chat starts is that call), and every prompt after returns at once. A fresh read starts
once the status has been sent, so its answer always comes after it; the first read, when it finishes within the first
call's wait, is that status's to carry and is not sent again. When the answer differs from the last, `wisp chat
--json` sends a `vcs` line with the version control's fields, which `wisp-tui` puts into the status line it holds,
leaving the turn, the held input, and everything else as they were. A `status` line could not carry it: it tells the
front end the turn is over, and a late one would release the input during the next turn. The plain chat cannot
redraw a printed line, so it shows the answer at its next prompt, at most one prompt behind. The context gauge is
still worked out before the prompt; for the on-device model its count is a framework call, which this change leaves
as it was. Tested without a terminal: the watch's single wait, one read at a time, and telling only a change; the
loop's prompts not held by a slow read and the update told after the status it missed; the protocol line; and
`wisp-tui` redrawing the place and leaving a running turn alone.
