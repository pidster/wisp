# run_command

Runs a shell command on this Mac and returns its exit status and output. This is the generic exec tool: the
model uses it to build, test, list files, and inspect the system, and through it can reach any binary on the
machine.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | yes | A POSIX shell command line, executed with `/bin/sh -c`. |
| `workingDirectory` | string | no | Absolute path to run in. Default: wisp's current directory. A missing directory is an error. |

## Result

```
exit status: 0
stdout:
<tail of stdout>
stderr:
<tail of stderr>
```

Extra lines appear when relevant: `timed out: the command was killed` and
`output truncated: only the tail of each stream is shown`. Empty streams are omitted. A killed process
reports its signal negated (for example `-15` for SIGTERM).

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Timeout | 60 s, then SIGTERM, then SIGKILL after 2 s | `commandTimeoutSeconds` in `config.json` |
| Output per stream | 4 KiB, tail kept | `commandMaxOutputBytes` in `config.json` |
| stdin | `/dev/null` | not configurable |

## Policy and sandbox

Every command passes a `CommandPolicy` ([ADR 0009](../decisions/0009-command-policy-and-sandbox.md)),
configured under `commandPolicy` in `config.json`:

| Field | Default | Meaning |
| --- | --- | --- |
| `deny` | `sudo`, `rm -rf /` and `rm -rf /*`, `\| sh`, `mkfs`/`diskutil erase`, `dd of=/dev/…`, `wisp approvals approve`/`deny` (answering an approval is the person's, ADR 0046), `wisp facts keep`/`drop` (so is keeping a permanent fact, ADR 0048) | Regexes; a match rejects the command. Patterns are compiled once per process. |
| `allow` | `[]` | Regexes; when non-empty the command must match one. Deny wins. |
| `sandbox.enabled` | `true` | Run under `sandbox-exec`. |
| `sandbox.allowNetwork` | `true` | Set `false` to deny all networking inside the sandbox. |
| `sandbox.writablePaths` | `~/Library/Caches`, `~/.cargo/registry`, `~/.cargo/git` | Writable in addition to the directory wisp was launched in, `$TMPDIR`, the per-user cache directory (`getconf DARWIN_USER_CACHE_DIR`, where Clang keeps its module cache), and `/private/tmp`. A command's own `workingDirectory` never widens this. `~` expands. |

Inside the sandbox everything is readable and executable, but writes outside the writable set fail with
`Operation not permitted`. A denied pattern comes back to the model as `error: command denied by policy: …`
so it can try something else.

```json
{ "commandPolicy": { "deny": ["sudo"], "allow": ["^(swift|cargo|git|ls|cat) "],
                     "sandbox": { "enabled": true, "allowNetwork": false, "writablePaths": [] } } }
```

`--unsafe` on `respond`, `chat`, and `mcp` turns both layers off with a warning on stderr.

### Risk classification and approval

A line is split into its simple commands (chains, pipes, subshells, substitutions), and each part is
classified `safe`, `moderate`, or `dangerous` by rules plus a classifier (by default the Core ML classifier the release ships, or
the on-device model; commands on the rules' read-only list skip it); at `moderate` or above a
human is asked for that part, with the line shown for context, and approvals are remembered by program
(`head *`): on the terminal in `chat`; in `mcp`, through the client's elicitation dialog and, with
`approval.outOfBand` (the default), through `wisp approvals approve|deny` and `wisp-tui` at once, the first
answer winning; and refused in non-interactive `respond` unless `--yes`. Denials come back as
`error: command not approved: …`. Configure with `approval.threshold` and `approval.classifier`. See
[approval.md](../approval.md).

The person can run a command through the same runner by typing it in chat after `!`
([ADR 0049](../decisions/0049-commands-typed-in-chat.md); [wisp.md](../wisp.md), "Commands you run yourself").
Such a command passes the same policy lists and runs under the same sandbox, bounds, and timeout, but is not
classified and never asks: typing it is the approval. Its `policy.decision` and `command.outcome` carry
`origin: "person"`.

### Symlinks

Seatbelt matches real paths, so wisp resolves every profile path with `realpath(3)` before generating the
profile (`/tmp` and `/var` are symlinks into `/private`; a not-yet-existing path resolves its longest existing
prefix). At run time the kernel resolves the target of each write, not the name used. Verified on macOS 27:

| Case | Result |
| --- | --- |
| Write through a symlink inside the working directory that points outside | Denied; no file created |
| Create, rename, or delete such a symlink | Allowed (the link itself is inside); following it stays denied |
| Write through a symlink outside that points inside | Allowed (the target is inside) |
| Write via `/tmp/…` to a `/private/tmp/…` target | Allowed (resolved by the kernel) |

The invariant: a write succeeds if and only if the real file lands inside the writable set. Hard links are the
one different mechanism, but creating one needs write access to the destination directory and the same
volume, so it can only alias files the command could already reach.

### Programs that will not run sandboxed

Seatbelt will not execute a setuid binary, so `/bin/ps` and `/usr/bin/top` fail inside the sandbox
(`execvp() of '/bin/ps' failed: Operation not permitted`, verified on macOS 27 on 2026-09-23). The
`system_info` tool reads the process table through `libproc` instead ([system_info](system_info.md)).
`/usr/bin/log` checks for a sandbox itself and exits (`log: Cannot run while sandboxed`), even under a
profile that allows everything (verified 2026-09-24); `condense_log` with `last` reads the unified log
in process instead ([mcp.md](../mcp.md)).

### Nested sandboxes

Seatbelt lets a process re-apply an identical profile but refuses a different one
(`sandbox_apply: Operation not permitted`). Two consequences, both verified on macOS 27:

- Tools that apply their own sandbox cannot run inside wisp's. Run SwiftPM as
  `swift build --disable-sandbox` and `swift test --disable-sandbox`; Cargo needs nothing.
- When wisp itself runs inside a sandbox (for example wisp running its own tests through its MCP
  server), its `sandbox-exec` would be refused. wisp decides this **once per process** with a probe
  command of its own (`CommandRunner.isNestedSandbox`), records `nested: true` on each `policy.decision`,
  and runs commands plainly because the outer sandbox is already confining them. The decision never
  depends on a command's output and a command is never launched twice: an earlier version keyed on the
  refusal text in stderr, which a command could print to get itself re-run unsandboxed (found by review,
  fixed 2026-09-19). Tests that assert enforcement skip when nested; `scripts/check` runs the runner
  suites inside an outer sandbox on every commit and fails if they fail.

### Writable root and working directory

The sandbox's writable set is rooted at the directory wisp was launched in (`Options.writableRoot`),
plus the temporary directory, the per-user cache directory, `/private/tmp`, and configured paths. A
`workingDirectory` chosen by the
model changes where the command runs, never what it may write: a command run in `/Users/me` with the
root at the project can read there but its writes fail. Before 2026-09-19 the per-command directory was
the writable root, so `workingDirectory: "/"` made everything writable.

### Process tree and timeouts

Commands are spawned in their own process group (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`), stdin from
`/dev/null`. On timeout the whole group gets SIGTERM, then SIGKILL two seconds later, so background
children (`sleep 30 &`, a server the model started) die with the shell instead of holding the output pipe
open. Output capture after exit is bounded by one second in case a descendant escaped the group.

Reads are not restricted; omit the tool (`--tool current_date`, or the MCP `respond` `tools` argument)
where even that is too much. There is no direct MCP `run_command`; other harnesses reach it only through
the model.

## Implementation

`CommandRunner` in `harness/Sources/WispCore/Exec/CommandRunner.swift` does the work and is tested by running
real commands in `CommandRunnerTests`; `RunCommandTool` is the thin model-facing wrapper.
