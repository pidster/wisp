# ADR 0024: `edit_file` writes inside the sandbox's writable set, approved like a command

Date: 2026-09-20. Status: accepted. Amended 2026-09-21: `replace` also takes a line number.

## Context

The model could read files a page at a time (`read_file`) but could only change them through
`run_command` with shell redirection or `sed -i`, which a small model gets wrong (quoting, escaping,
whole-file overwrites) and which a reader of the audit log cannot easily interpret. A write tool is the
counterpart of `read_file`: the model reads a page, then changes exactly what it saw.

Three questions: how far a write may reach, how it is approved, and what edits it offers. And a fact
worth stating: the tools do not share one control path. Only `run_command` passes `CommandPolicy`, the
gate, and Seatbelt; `read_file` runs the gate's rules only; `inspect` and `current_date` have none.

## Decision

- **Reach.** `FileWriter` refuses any path outside the canonical writable set the Seatbelt profile is
  built from (`CommandPolicy.writableRoots`: the launch directory, the temporary directory,
  `/private/tmp`, the user cache directory, `sandbox.writablePaths`). One list, two enforcers, so
  `edit_file` can change no more than a command could. With the sandbox off there is no confinement,
  as for commands. Directories are never created. The write itself is in-process, not under Seatbelt,
  and the deny/allow command patterns do not apply to it; the writable list and the gate are its controls.
- **Approval.** Each edit is cleared by the gate as the synthetic command `edit_file <mode> <path>`
  through the full classifier. The rules rate every edit at least `moderate` and reuse the credential
  rule for `dangerous`, so thresholds, scopes, and persistence work exactly as for a program: the
  approval pattern is `edit_file *`. Unlike `read_file`, which runs the rules only, writes run the model
  classifier too when it is configured, because they change state.
- **Edits.** `write` (whole file, creating it), `append`, and `replace` of one exact occurrence of
  `find`. A `find` that matches zero or several times changes nothing and the error says which, so the
  model cannot change more than it showed it meant to. `replace` loads at most 1 MiB and refuses binary
  files. The first version had no line-number edits, on the argument that numbers drift and small
  models miscount. Amended 2026-09-21: the eval showed the opposite failure, the model retyping the
  anchor and its neighbour into `content` (3 of 5). `replace` now also takes `line`, the number
  `read_file` just showed, with `content` the whole new line and `find`, when given, a check that the
  line still holds it; a drifted number then changes nothing. The model copies a number instead of
  retyping text.
- **Audit.** A landed edit is recorded as `file.write` (path, mode, created, sizes); the content is
  already in the `tool.call` arguments. Receipts list writes under `files`.

## Consequences

- A conversation that should not write leaves `edit_file` out with `--tool` or `tools`; a conversation
  with it can write only where the sandbox would have let a command write, after the same approval.
- Writes are atomic (a temporary file beside the target, renamed over it, mode preserved), so a
  crash or a full disk leaves the original; the cost is one extra file operation. Amended the same
  day: the first version wrote in place.
- Measured in the eval harness (`edit_file.replace`, ADR 0026): 3 of 5 by `find` on 2026-09-20; the
  line form is measured on ten cases and the number recorded in `measurements.json`.
- Tests without the model: confinement including symlinks and look-alike siblings, every failure,
  each edit and its rendering (`FileWriterTests`); the tool's gate refusal, audit event, receipt
  entry, and classifier levels (`ToolWrapperTests`, `ReceiptTests`).

**Refined 2026-10-06: line edits forgive two slips, without guessing.** `scripts/check eval compare` on Qwen3-1.7B
(log `eval-20261006-143217.log`) classified the failed line edits, MLX then Ollama: the new line written without its
indentation (asked for `    return 10`, the model sent `return 10`) 8 and 7; the wrong line, off by one, 6 and 4;
further off, 5 and 3; no call, 3 and 1; several calls, 3 and 0. Larger models rarely fail this way (granite4.1:8b
28/30, gemma4:12b 30/30). Several of the wrong lines came with a `find` that named the right one. Three rules, each
acting only on an exact condition and saying what it did, so the principle above stands: exact text, nothing guessed.

- **Keep indentation, narrowly.** With `line`, when `content` is not empty and starts with neither a space nor a tab,
  the old line starts with spaces or tabs, and the two differ by more than whitespace at their ends, the line keeps
  its indentation, and the result says so ("keeping the line's indentation (4 spaces)"). Every other content is
  written exactly, so a deliberate indent, dedent (the stripped texts equal), tabs to spaces, or trailing spaces
  stripped is not touched. The blind spot is a text change and a dedent to column zero in one edit: it keeps the
  indentation, and the result line tells the model, which can redo it in two steps or by `find`.
- **Reconcile `line` with `find`.** When the numbered line does not contain `find` and exactly one line of the file
  does, that line is edited and the result says so ("line 2 did not contain "return 1"; replaced line 3 …, the one
  line that does"). On no line or several, nothing changes, with the error as before. A number past the end is
  still an error.
- **Show the result.** A replacement's result ends with the edited line as it now reads (`line 3 now: "    return
  10"`), escaped so whitespace shows and cut at 200 characters; a `find` replacement over several lines shows the
  first three.

Measured before and after the same day ([measurements.md](../measurements.md), "edit_file's line rules"), with a
new measurement `edit_file.whitespace` (four whitespace-only edits, three attempts each) kept apart so
`edit_file.replace` stays comparable: `mlx:Qwen3-1.7B-4bit` 11/30 to 27/30 and 9/12 to 11/12, `ollama:qwen3:1.7b`
16/30 to 19/30 and 9/12 to 11/12, `ollama:llama3.2:3b` 3/30 to 1/30 and 5/12 to 3/12 (its failures are a `line` sent
as text, refused before the tool runs), and `ollama:granite4.1:8b`, after only, 27/30 and 11/12 (its four failures an
empty `find` beside a right `line`, which changed nothing before the rules too). No dropped indentation or stale
number with `find` remained. Tested without the model in `FileWriterTests`.
