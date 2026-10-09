# read_file

Reads a page of lines from a text file, numbered, and tells the model how to fetch the next page. The file is
streamed, so reading the first page of a multi-gigabyte log costs only the bytes up to the end of that page.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | Path of the file. |
| `offset` | integer | no | 1-based line number to start from. Default 1. |
| `limit` | integer | no | Maximum lines to return. Default 100. |

## Result

Numbered lines, then a marker.

```
1	# wisp
2
3	An on-device, tool-using AI microharness ...
[more: call again with offset 4]
```

The final line is either `[more: call again with offset N]` or `[end of file]`. A range past the end yields
`(no lines in range)` and `[end of file]`.

## Approval

Paths go through the approval gate's rule classifier as if they were `cat '<path>'`, the path shell-quoted, with
`# resolves to '<real path>'` after it when following links leads to a file the rules rate higher: credential-like paths (`.ssh`,
`.aws/credentials`, `.netrc`, keys), by the name given or the file it leads to and in any case (`.SSH/ID_RSA`),
are rated dangerous and ask, or are refused where nobody can answer, exactly as the command would be. Ordinary files pass without a model call. Refusals come back as
`error: read not approved: …`.

The gate is the only control on reads. The read happens in wisp's own process with your permissions:
there is no sandbox and no confinement to the launch directory, unlike `run_command`'s writes, so the
model can read anything you can, your home directory included ([trust.md](../trust.md)). Prefer `--tool`
to leave `read_file` out of a conversation that should not read at all.

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Bytes of line content per page | 4 KiB; the page ends early and the marker points at the next line | Fixed (`FileReader(maxBytes:)` in code); not a `config.json` setting |
| Line length | A single line longer than the budget is cut to the budget, on a character boundary | same |
| Binary files | Rejected if the first chunk contains a NUL byte | not configurable |
| Directories, missing files, `offset`/`limit` below 1 | Errors | |
| Wildcards (`*`, `?`, `[`) in a path that does not exist | `error: read_file takes one path, not a pattern: …; list matches with run_command, e.g. ls …`, so the model lists the files instead of retrying the path. A file really named with a wildcard character is read. | |

CRLF line endings are handled; the returned lines never include `\n` or `\r`.

It reads forward only: there is no search, no tail, and no binary content. To find a line in a large
file or see its end, have the model use `run_command` with `grep -n` or `tail`, then `read_file` at the
offset it learns.

## Implementation

`FileReader` and `LineScanner` in `harness/Sources/WispCore/Tools/FileReader.swift`, tested in `FileReaderTests`
including chunk-boundary and early-stop cases; `ReadFileTool` is the model-facing wrapper.
