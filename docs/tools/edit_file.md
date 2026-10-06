# edit_file

Writes a text file: the whole file, an addition at the end, or one exact replacement. The counterpart of
[read_file](read_file.md): read a page, then replace exactly what was shown. Decided in
[ADR 0024](../decisions/0024-edit-file.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | Path of the file. Its directory must exist; `edit_file` never creates directories. |
| `mode` | string | yes | `write` replaces the whole file, creating it if absent. `append` adds to the end, creating it if absent. `replace` changes one line, by number or by exact text. |
| `content` | string | yes | The text to write or append; for `replace` with `line`, the whole new line (see "Line edits" for the one case its indentation is supplied); for `replace` with `find` alone, the replacement for `find` only. |
| `line` | integer | for `replace` | The 1-based line to rewrite, as `read_file` numbered it. Past the end, nothing changes. Preferred: the model copies a number it just read instead of retyping the text. |
| `find` | string | for `replace` | Without `line`: the exact existing text to replace, which must occur exactly once. With `line`: text that line must contain (an empty `find` checks nothing); when it does not, the one line of the file that does is edited instead, and when none or several do, nothing changes. |

Read the file first, then replace by `line`:

```
Use read_file to read /repo/Package.swift. Then use edit_file with mode replace on /repo/Package.swift,
with line set to the number read_file showed for `let version = "0.1.0"` and content `let version = "0.2.0"`.
Report the tool results verbatim.
```

## Line edits

`replace` with `line` writes `content` as given, with two exceptions for the slips small models make most
(measured with Qwen3-1.7B on 2026-10-06, [ADR 0024](../decisions/0024-edit-file.md), refined that day). Neither
guesses: each acts only on an exact condition, and the result says what it did.

| Rule | When | What is written |
| --- | --- | --- |
| The line keeps its indentation | `content` starts with neither a space nor a tab, is not empty, and the old line starts with spaces or tabs, and the two differ by more than whitespace at their ends | The old line's indentation, then `content` (asked for `    return 10`, the model sent `return 10`: `    return 10` is written) |
| A stale number with `find` | The numbered line does not contain `find`, and exactly one line of the file does (once or more on that line) | That line, rewritten; the indentation rule applies to it too |

Every other line edit is written exactly, so a deliberate whitespace change works: indenting a line
(`return 1` to `    return 1`), dedenting one (`    y = 2` to `y = 2`, the stripped texts being equal), tabs
to spaces, trailing spaces stripped, or an indented line emptied. When `find` is on no line or on several, or the
number is past the end, nothing changes, with the errors below.

The blind spot: a text change and a dedent to column zero in one edit (`    return 1` to `print(1)` at the
margin) keeps the indentation. The result says so, and the model can make the edit in two steps, or by `find`.

## Result

One line, and for a replacement the edited line as it now reads, quoted with tabs, quotes, backslashes, and
carriage returns escaped and cut at 200 characters (a replacement by `find` that spans lines shows the first
three and says how many more):

```
created /repo/notes.md; now 42 bytes
appended to /repo/notes.md; now 60 bytes
replaced at line 3 of /repo/notes.md; now 58 bytes; line 3 now: "opening paragraph"
replaced at line 2 of /repo/b.py, keeping the line's indentation (4 spaces); now 42 bytes; line 2 now: "    return 10"
line 2 did not contain "return 1"; replaced line 3 of /repo/b.py, the one line that does; now 42 bytes; line 3 now: "    return 10"
```

Errors come back as text so the model can react: `error: text to replace not found: …`, `error: text to
replace occurs 2 times, include more surrounding text: …`, `error: cannot write …: outside the writable
directories (…)`, `error: edit not approved: …`.

## Confinement

Writes land only under the directories the sandbox lets `run_command` write under: the directory wisp
was launched in, the temporary directory, `/private/tmp`, the user cache directory, and
`sandbox.writablePaths` from `config.json`. The check canonicalises the path (symlinks resolved, so
`/tmp` is `/private/tmp`) and refuses anything else before touching the file system. With the sandbox
off (`sandbox.enabled: false` or `--unsafe`) there is no confinement, as for commands.

## Approval

Every edit is judged as the command `edit_file <mode> <path>` by the full classifier, rules and, when
configured, the model. The rules rate every edit at least `moderate` ("edits a file") and credential
paths (`.ssh/`, `.aws/credentials`, `.netrc`, keys) `dangerous`, so under the default threshold the
first edit in a conversation asks and the answer's scope applies to later ones: "this session" covers
every `edit_file` call, project and always scopes are keyed to the pattern `edit_file *` as for a
program. Where nobody can answer the edit is refused and the file is untouched.

## Limits

| Limit | Value |
| --- | --- |
| `replace` file size | 1 MiB; larger files are refused (`FileWriter(maxBytes:)`, fixed in code) |
| Line edits | One line per call: `content` is that line, one trailing newline is dropped, and any other newline (a pasted neighbour or the `[end of file]` marker) is refused with nothing changed; a line that is not there is an error, and so is one that does not contain `find` unless exactly one other line does |
| Shown lines | The edited line, or the first three lines a `find` replacement covers, each cut at 200 characters |
| Binary files | Refused for `replace` (a NUL byte); `write` and `append` do not read the file |
| Directories, missing parent directory, unknown `mode`, `replace` without `find` | Errors |
| Atomicity | Every write goes to a temporary file beside the target (same directory, the existing mode copied) and is renamed over it, so a reader never sees a partial file and a failure leaves the original untouched |

## Audit and receipts

Each edit that happens is recorded as `file.write` with `path`, `mode`, `created`, `bytesBefore`, and
`bytesAfter` ([logging.md](../logging.md)); the MCP receipt lists it under `files`. The content itself
is in the `tool.call` event's arguments.

## Measured with the model

The eval (`ToolEvalTests`, ten small files) reads a file and rewrites one numbered line; the recorded
result is in [measurements.md](../measurements.md) and on `wisp tools --markdown`. The `line`
argument exists because the first version, replace by `find` only, measured 3 of 5 on 2026-09-20: the
model copied `find` correctly and then put the neighbouring line into `content` too. A write outside
the writable set is refused with the directories named and no file created. A second measurement,
`edit_file.whitespace` (four files, three attempts each), rewrites only a line's whitespace: indent, dedent,
tabs to spaces, trailing spaces stripped; it is kept apart so `edit_file.replace` stays comparable across runs.
The line-edit rules above were measured before and after on 2026-10-06 ([measurements.md](../measurements.md),
"edit_file's line rules").

## Implementation

`FileWriter` in `harness/Sources/WispCore/Tools/FileWriter.swift` (confinement from
`CommandPolicy.writableRoots`, the list the Seatbelt profile is built from), tested in `FileWriterTests`;
`EditFileTool` is the model-facing wrapper, tested in `ToolWrapperTests`.
