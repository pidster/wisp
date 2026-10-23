# run_command

Runs a shell command on this Mac and returns its exit status and output. This is the generic exec tool: the
model uses it to build, test, list files, and inspect the system, and through it can reach any binary on the
machine.

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `command` | string | yes | A POSIX shell command line, executed with `/bin/sh -c`. |
| `workingDirectory` | string | no | Absolute path to run in. Default: wisp's current directory. A missing directory is an error. |
| `timeoutSeconds` | integer | no | Seconds this command may run, only to run longer than the default. Default: the thread's limit (MCP `respond`'s `commandTimeoutSeconds`), else `commandTimeoutSeconds` (120); a request shorter than that gets that instead ([ADR 0067](../decisions/0067-a-call-may-only-lengthen-its-time-limit.md)). Above `commandMaxTimeoutSeconds` (1,800) it is cut to that; below 1 the result is `error: timeoutSeconds must be at least 1 …` and nothing runs ([ADR 0063](../decisions/0063-command-time-limits.md)). |
| `outsideSandbox` | boolean | no | `true` asks to run this one command without the sandbox, for a command it refuses (`brew upgrade`, `cargo install`). The person is asked every time, whatever the command's risk, and approves that line once or not at all ([below](#running-outside-the-sandbox), [ADR 0064](../decisions/0064-an-approved-run-outside-the-sandbox.md)). Default: sandboxed. |

## Result

```
exit status: 0
stdout:
<tail of stdout>
stderr:
<tail of stderr>
```

Extra lines appear when relevant: `timed out: the command was killed after 120 s; ask for up to 1800 s with
timeoutSeconds` (or `…, the most allowed` when the limit was the cap), `stopped: the person stopped the command`,
a `sandbox:` line (below, and for a command asked to run outside the sandbox), and, when more was printed than
fits, a `held back:` note. Empty streams are omitted. A
killed process reports its signal negated (for example `-15` for SIGTERM).

**Output past the bound is held back, not dropped** ([ADR 0050](../decisions/0050-tool-output-budget-and-overflow.md)).
The result is bounded as a whole, its header and notes included, to the conversation's tool-output budget (an
eighth of the model's window, 4 to 64 KiB; [context-management.md](../context-management.md)). When a command
prints more, each stream shows its first and last lines, about half its share of the room each, cut at line ends,
with a marker between them, and the result ends with a note naming the lines held back and where the whole is:

```
exit status: 1
stdout:
Compiling Sources/File1.swift
…
[… 2,270 lines (180 KiB) held back …]
…
error: fatalError: 1 of 3 targets failed
held back: stdout lines 44–2,313 (180 KiB); the whole output is kept as output 3f9a2c1b (2,340 lines); memory "recall output 3f9a2c1b from line 44" pages it, "recall output 3f9a2c1b matching PATTERN" filters it, "summarise output 3f9a2c1b" gives the notable lines, "condense output 3f9a2c1b: QUESTION" answers from all of it; do not run the command again to see it
```

The whole output (the rendering with nothing held back: the header, `stdout:`, the stream, `stderr:`, the stream)
is kept in the conversation's output store, `~/.wisp/output/<audit session>/<id>`, under the audit call id of the
tool call, up to 16 MiB; past that it is cut and the note says the rest was not kept. The line numbers in the note
are the stored output's, so a recall from that line lands on the first held-back line. The room is shared between
stdout and stderr in proportion to their size, and a stream with something to show always gets at least a fifth
of it, so a short error is not crowded out by a long log. In a conversation without `memory` the note says the
output is kept and not to run the command again; without an output store (the audit off, an agent made directly)
it says the held-back lines were not kept. A command is never run again to see what it printed.

In memory the runner keeps a head and a tail of the bound per stream and counts the rest; the moment a byte would
be dropped it spills the whole stream to the store as it arrives, so a command printing 1 GiB costs memory of a
few times the bound. Before 0.22.0 every byte was held until the command ended and all but the tail of each
stream was then discarded.

## Limits

| Limit | Default | Configure |
| --- | --- | --- |
| Timeout | 120 s, then SIGTERM, then SIGKILL after 2 s; 0 is none | `commandTimeoutSeconds` in `config.json`; per call `timeoutSeconds`; per MCP thread `respond`'s `commandTimeoutSeconds` |
| Longest timeout a call or thread may ask for | 1,800 s; a request above it is cut to it | `commandMaxTimeoutSeconds` in `config.json` (1 to 86,400), the operator's alone |
| The result, as a whole | The tool-output budget: an eighth of the model's window, 4 KiB at least (the on-device model), 64 KiB at most; the first and last lines shown, the rest held back and kept whole | `commandMaxOutputBytes` in `config.json` replaces the budget for this tool |
| Output kept whole | 16 MiB per command, in the output store; cut past that, and the cut is stated | not configurable |
| stdin | `/dev/null` | not configurable |
| Descriptors | 0, 1, and 2 only: every other descriptor wisp holds is closed in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so one command never inherits another's pipe or a file wisp has open | not configurable |

## Policy and sandbox

Every command passes a `CommandPolicy` ([ADR 0009](../decisions/0009-command-policy-and-sandbox.md)),
configured under `commandPolicy` in `config.json`:

| Field | Default | Meaning |
| --- | --- | --- |
| `deny` | `sudo`, `rm -rf /` and `rm -rf /*`, `\| sh`, `mkfs`/`diskutil erase`, `dd of=/dev/…`, `wisp approvals approve`/`deny` (answering an approval is the person's, ADR 0046), `wisp facts keep`/`drop` (so is keeping a permanent fact, ADR 0048), `wisp questions answer`/`decline` (so is answering the model's question, ADR 0062), `wisp threads delete`/`hand` (so is deleting a saved thread or giving it to another client, ADR 0066), `wisp models pull` (so is fetching a model, ADR 0052), `wisp models uninstall` (so is removing one, ADR 0075), `wisp install`/`uninstall` (so is putting wisp on `PATH`, ADR 0073), `wisp update` (so is updating it, ADR 0074), and a nested wisp agent: `wisp respond`, `wisp chat`, `wisp mcp`, or the quoted bare `wisp "prompt"`, by any path, quoted or not, after options, `env` and its options, `exec`, `nohup`, `nice`, `time`, `command`, `caffeinate`, `xargs`, `timeout N`, `VAR=value`, or `{`, `then`, `do`, where wisp is the program a segment of the line runs (the approval, fact, question, and thread commands are refused quoted too); `wisp --version`, `doctor`, `logs`, `tools`, `models`, `config`, and its other subcommands stay allowed (ADR 0054) | Regexes; a match rejects the command. Each runs over the line and each of its parts as written and as normalised: quotes and escapes inside a word (`w''isp`, `\sudo`) and an unquoted `$IFS` between words read away, git's global options dropped, and the text of `echo` and a search pattern left as written ([approval.md](../approval.md#classifiers)). The built-in patterns read that data written `''`, so a search for `"grep\|bash -c"` is not refused as a pipe into a shell; a pattern the configuration adds reads it as written. Patterns are compiled once per process. |
| `allow` | `[]` | Regexes; when non-empty the command must match one. Deny wins. |
| `sandbox.enabled` | `true` | Run under `sandbox-exec`. |
| `sandbox.allowNetwork` | `true` | Set `false` to deny all networking inside the sandbox. |
| `sandbox.writablePaths` | `~/Library/Caches`, `~/.cargo/registry`, `~/.cargo/git` | Writable in addition to the directory wisp was launched in, `$TMPDIR`, the per-user cache directory (`getconf DARWIN_USER_CACHE_DIR`, where Clang keeps its module cache), and `/private/tmp`. A command's own `workingDirectory` never widens this. `~` expands. |
| `sandbox.allowOutsideSandbox` | `true` | Whether the model may ask to run one command outside the sandbox (`outsideSandbox`), which the person approves each time; `false` refuses every such request. The policy's one field `wisp config set` changes ([below](#running-outside-the-sandbox)). |

Inside the sandbox everything is readable and executable, but writes outside the writable set fail with
`Operation not permitted`. So do writes to wisp's own home (`~/.wisp`, or `WISP_HOME`), wherever it is: the
profile denies it after the allow rule (Seatbelt applies the last rule that matches), so a sandboxed command can
never change wisp's approvals, facts, configuration, or pending answers (one the person approved to run
[outside the sandbox](#running-outside-the-sandbox) can), even when the home lies inside the writable set (the
profile then carries a `; note:` comment saying so, and diagnostics log it). wisp itself writes its home in its
own process, outside the sandbox. A denied pattern comes back to the model as `error: command denied by policy: …`
so it can try something else.

When a confined command fails with `Operation not permitted`, wisp checks whether the sandbox refused it
([ADR 0054](../decisions/0054-the-sandboxs-refusals-checked.md)) and adds one line to the result, after the
output. It reads the paths the error names (`sh: PATH: …`, `touch: PATH: …`, `cp`, `mkdir`, `rm`, `mv … to PATH`,
GNU's `cannot create regular file 'PATH'`, Python's `[Errno 1] Operation not permitted: 'PATH'`), resolves each to
its real path as the profile does (`/tmp` is `/private/tmp`), and compares it with the writable roots. A tool that
checks its directories before it writes never reaches `Operation not permitted`, so a failed command's
`not writable` lines are read too: Homebrew's `The following directories are not writable by your user:` with its
indented list (`brew install` and `brew upgrade` under the sandbox print it for `/opt/homebrew` and
`~/Library/Logs/Homebrew`), and a line `PATH is not writable.`. Either way:

| The error names | The model is told |
| --- | --- |
| a path outside every writable root | `sandbox: refused writing to /x; commands may write only under <roots>` |
| only paths inside the roots | `sandbox: not the sandbox: /x is inside the writable roots, so something else refused it (file permissions, flags, or system protection)` |
| no path | `sandbox: the sandbox may have refused this (Operation not permitted, no path to check: a network connection, a process, or a file the error does not name); no policy rule denied it` |

The last is a guess, and says so. It names the policy because a model read a bare `Error: Operation not
permitted` from a nested `wisp` as the deny list's refusal (session `ce87576a`, 2026-10-04): a command that ran
passed the policy. Seatbelt reports nothing of its own on macOS 27 (probed on 2026-10-04: no kernel `deny`
record for a `sandbox-exec` profile, with `(debug deny)` or `(deny default)`; `(with report)` is refused on a deny
rule; `(with send-signal …)` delivered nothing), so the error output is all there is to check. The line lists
at most three paths and about 240 bytes of roots. `command.outcome` records the verdict as `sandboxRefusal`. For a
`refused` or a guess, while `sandbox.allowOutsideSandbox` is on, the line ends `; if it must, ask again with
outsideSandbox true (the person approves each run)` ([ADR 0064](../decisions/0064-an-approved-run-outside-the-sandbox.md)).

```json
{ "commandPolicy": { "deny": ["sudo"], "allow": ["^(swift|cargo|git|ls|cat) "],
                     "sandbox": { "enabled": true, "allowNetwork": false, "writablePaths": [] } } }
```

`--unsafe` on `respond`, `chat`, and `mcp` turns both layers off with a warning on stderr.

### Running outside the sandbox

Some chores cannot run under the sandbox at all ([ADR 0064](../decisions/0064-an-approved-run-outside-the-sandbox.md)).
Probed on 2026-10-14: `cargo update` in the project works, but `cargo install` writes `~/.cargo/bin` and
`~/.cargo/.crates*.toml`, `rustup update` writes `~/.rustup`, and every Homebrew write goes to `/opt/homebrew/…` or
`~/Library/Logs/Homebrew`, all outside the writable roots; `brew upgrade --dry-run` stops with Homebrew's "You should
change the ownership of these directories". Widening `writablePaths` cannot fix Homebrew: Homebrew 7 runs its own
`sandbox-exec` for fetching, post-install steps, and source builds, Seatbelt refuses a nested profile that differs
(below), and Homebrew's opt-out is refused for the default prefix. Widening by default would also make
`~/.cargo/bin` and `/opt/homebrew/bin`, both on `PATH`, writable to every command.

So the model may ask for one command to run without the sandbox, with `outsideSandbox: true`:

1. The policy's `deny` and `allow` patterns apply as to any command.
2. With `sandbox.allowOutsideSandbox` false, it is refused: `error: command denied by policy: running outside the
   sandbox is turned off here (commandPolicy.sandbox.allowOutsideSandbox is false); …`.
3. The person is asked about the whole line, every time: whatever the classifier and `approval.threshold` say (a
   read-only `ls` and `never` included), at `moderate` at least, with "runs OUTSIDE the sandbox: it may write anywhere
   you can, ~/.wisp included; this one run only" first among the reasons. No earlier approval covers it, and the
   answer covers nothing after it. It is approved once or not at all: the faces offer only that, and a wider answer
   given anyway (`wisp approvals approve ID --scope session`) is taken as once ([approval.md](../approval.md#running-outside-the-sandbox)).
4. Where no person can be asked (`--yes`, non-interactive `respond`, an MCP client with no dialog while
   `approval.outOfBand` is off), it is refused with the reason: `error: command not approved: running outside the
   sandbox is asked of a person every time, and no one can be asked here …`.
5. Approved, it runs without `sandbox-exec`, under the same time limit, output bound, and output store, and the
   result ends `sandbox: ran outside the sandbox, as the person approved, this once`.

Without the sandbox, nothing protects wisp's home: the command can write anywhere the person can, `~/.wisp`
included. That is what the person approves, for that exact line, and why it is asked every time and named on every
face. With the sandbox off (`sandbox.enabled` false, `--unsafe`) the argument changes nothing and asks nothing more:
`sandbox: outsideSandbox changed nothing: the sandbox is off here`. When wisp itself runs inside another sandbox,
wisp cannot leave it, so the command runs under that one as every command does there: `sandbox: outsideSandbox
changed nothing: wisp runs inside another sandbox, which confined this command`. A command the person types after
`!` never carries the argument; one typed after `!!` runs outside the sandbox without asking (below). `policy.decision`, `approval.requested`, `approval.decided`, `approval.pending`, and
`command.outcome` record `outsideSandbox` ([logging.md](../logging.md)).

The person can run a command outside the sandbox themselves, in chat, by typing it after `!!` (`!!brew upgrade`;
`wisp-tui`'s outside mode, its input box red): the same runner path as a command typed after `!`, with
`outsideSandbox` set and no one asked, since typing it is the approval (ADR 0064, amended 2026-10-14). The deny and
allow lists apply, `sandbox.allowOutsideSandbox` false refuses it (`… type it after a single ! to run it in the
sandbox`), and with the sandbox off or nested it changes nothing, as above. It has no time limit, as any typed
command; Ctrl-C stops it. Its events carry `origin: "person"` and `outsideSandbox: true`
([wisp.md](../wisp.md#commands-you-run-yourself)). The model is never offered it: `!!` is a line the person types,
not an argument.

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
Such a command passes the same policy lists and runs under the same sandbox and output bound, but is not
classified and never asks: typing it is the approval. It has no timeout: the person stops it with Ctrl-C, which
ends its process group as the timeout does (SIGTERM, then SIGKILL two seconds later, or at once on a second
Ctrl-C), and records `stopped: true` (ADR 0049, amended 2026-10-09). Its `policy.decision` and
`command.outcome` carry `origin: "person"`.

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
`/dev/null`, and SIGINT at its default (chat ignores it to take Ctrl-C itself, and an ignored signal would
otherwise be inherited). On timeout the whole group gets SIGTERM, then SIGKILL two seconds later; a command the
person typed has no timeout and gets the same when they stop it. And whenever the shell
exits, on its own or at the timeout, the group is sent SIGKILL until it is empty (for up to two seconds): nothing a
command starts outlives it, neither a background job (`sleep 30 &`, a server the model started) nor a child that
ignores SIGTERM. Before 0.21.1 the watchdog stopped when the shell was reaped, so both lived on. A descendant that
left the group (`setsid`) is beyond this; output capture after exit is bounded by one second in case one holds the
pipe.

Which limit a model's command runs under ([ADR 0063](../decisions/0063-command-time-limits.md)), first that applies; the
call's `timeoutSeconds` applies only when it is longer than the limit below it, else that limit does
([ADR 0067](../decisions/0067-a-call-may-only-lengthen-its-time-limit.md)):

| Source | Set by | Clamped to `commandMaxTimeoutSeconds` |
| --- | --- | --- |
| The call's `timeoutSeconds` | the model, per command | yes |
| The thread's `commandTimeoutSeconds` | an MCP caller, when the thread starts (`respond`, [mcp.md](../mcp.md)) | yes |
| `commandTimeoutSeconds` in `config.json` | the operator; 120 s by default, 0 for none | no: it is the operator's own setting |

The cap is the operator's: no tool changes `config.json`, so neither the model nor an MCP caller can raise it. A
timed-out result names the limit and, under the cap, how to ask for more; `command.outcome` records the limit as
`timeoutSource` (`call`, `thread`, or `default`), `timeoutSeconds`, `timeoutClamped`, and `timeoutAsked` for a call's
shorter request that kept the longer limit ([logging.md](../logging.md)). On 2026-10-19 a git thread's model asked for
30 s on its own, under a thread limit of 600 s, and its `git commit` was killed mid-hook; since ADR 0067 that request
keeps the 600 s.
Before 0.24.2 every model's command had the operator's one limit, 60 s by default, which killed a `git commit` whose pre-commit hook ran
the full gate (2026-10-13), and a `commandTimeoutSeconds` of 0, documented as no limit, set a watchdog of zero
seconds instead, which fires at once. Custom tools keep their own `timeoutSeconds` and `system_info` its floor of 30 s; neither reads the thread's.

The timeout and the two-second grace are timers on a dispatch queue of wisp's own, not Swift tasks, so they fire on
time whatever else the process is doing. Until 2026-10-10 they were `Task.sleep`s on Swift's cooperative pool, and
when other work blocked every thread of it (2026-10-10, under the gate's parallel tests) a 200 ms timeout went
unenforced for the whole of a 30 s command (`docs/design.md`, "Concurrency"). The wait for the shell to exit has a
thread of its own too.

Reads are not restricted; omit the tool (`--tool current_date`, or the MCP `respond` `tools` argument)
where even that is too much. There is no direct MCP `run_command`; other harnesses reach it only through
the model.

## Implementation

`CommandRunner` in `harness/Sources/WispCore/Exec/CommandRunner.swift` does the work and is tested by running
real commands in `CommandRunnerTests`; `RunCommandTool` is the thin model-facing wrapper.
