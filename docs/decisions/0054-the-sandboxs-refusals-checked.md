# ADR 0054: The sandbox's refusals checked

Date: 2026-10-04. Status: accepted. Amends [ADR 0049](0049-commands-typed-in-chat.md) (the note for a typed command
the sandbox refuses) and the default deny list of [ADR 0009](0009-command-policy-and-sandbox.md).

## Context

wisp runs every command under a Seatbelt profile that allows writes only under its writable roots: the launch
directory, the temporary directory, `/private/tmp`, the per-user cache directory, and the configured
`sandbox.writablePaths`. Seatbelt is passive. A refused operation fails with `EPERM`, which the command prints as
`Operation not permitted`, and nothing else reports it. Probed on macOS 27 on 2026-10-04: the kernel logged no `deny`
record for a `sandbox-exec` profile, neither with `(debug deny)` nor with `(deny default)`; `(with report)` is
refused on a deny rule; and `(with send-signal …)` delivered nothing.

Until now wisp guessed. `CommandRunner.refusedBySandbox` called any failed, confined command whose error output
contained "Operation not permitted" a sandbox refusal, and only commands the person typed after `!` used it, as a
note in chat. The model was told nothing, and read the error as best it could.

Session `ce87576a` (granite4.1:8b, `wisp-tui` 0.18.1, 2026-10-04) showed what that costs. At 12:51Z the model ran
`wisp respond "Execute the self-test script functionality-self-test.wisp."`, which the person approved once. The
nested wisp could not write `~/.wisp` under the sandbox and failed with exit status 1 and the error output `Error:
Operation not permitted`, naming no path. The model told the person the command was blocked by the policy's deny
list. No policy denial happened: the command had passed the policy and run.

The same run showed a second problem: the model could start a wisp of its own at all. `wisp respond`, `wisp chat`,
`wisp mcp`, and the bare `wisp "prompt"` (which is `respond`) start a nested agent with its own model, tools, and
approvals. Under the sandbox it fails anyway, but it should not be asked for. The default deny list already refuses
the model `wisp approvals approve|deny` ([ADR 0046](0046-approval-and-notifications-over-mcp.md)) and `wisp facts
keep|drop` ([ADR 0048](0048-permanent-facts-over-mcp.md)), by pattern.

## Decision

- **A check, not a guess, for writes** (`SandboxRefusal`). When a confined command fails and its error output
  contains `Operation not permitted`, wisp reads the paths that output names: a tool's or the shell's `name: PATH:
  Operation not permitted` (`sh`, `sh: line 1:`, `touch`, `cp`, `mkdir`, `rm`, and the like), GNU's `cannot create
  regular file 'PATH'`, `mv`'s `rename A to PATH`, and Python's `PermissionError: [Errno 1] Operation not permitted:
  'PATH'`. Each path is made absolute from where the command ran (or the home directory for `~`) and resolved to its
  real path, as the profile's roots are (`/tmp` is `/private/tmp`, `/etc` is `/private/etc`). A path outside every
  writable root is the sandbox's refusal (`refused`); when every path named is inside them, something else refused
  it, such as file flags or System Integrity Protection (`not-the-sandbox`).
- **Network and process refusals name no path, and stay a guess** (`guess`), marked as one wherever it is shown.
- **The model is told plainly**, as one line after the output in `run_command`'s result:
  `sandbox: refused writing to /x; commands may write only under <roots>`; `sandbox: not the sandbox: /x is inside
  the writable roots, so something else refused it (…)`; or, with no path, `sandbox: the sandbox may have refused
  this (Operation not permitted, no path to check: a network connection, a process, or a file the error does not
  name); no policy rule denied it`. The guess names the policy because that is the misreading `ce87576a` made: a
  command that ran had passed the policy, so the claim is always true. The line names at most three paths and about
  240 bytes of roots.
- **Audited** on `command.outcome` as `sandboxRefusal` (`refused`, `not-the-sandbox`, or `guess`) with
  `sandboxPaths`, the real paths checked. `command.typed` keeps `sandboxRefused`, now true for `refused` and
  `guess`, and carries the same two fields.
- **The person's note uses the same check**: `· the sandbox refused writing to /x, …`, `· not the sandbox: …`, or
  `· the sandbox may have refused it (no path to check), …; no policy rule denied it`.
- **ADR 0051's `ran:` line is unchanged.** A refused command already counts as failed; a new category would say
  nothing the result's own line does not.
- **The model cannot start a wisp of its own.** A default deny pattern (`CommandPolicy.nestedWisp`) refuses `wisp`,
  by any path and after `env`, `exec`, `nohup`, or `VAR=value`, when, after its options, it runs `respond`, `chat`,
  `mcp`, or a quoted prompt (the bare `wisp "prompt"`, which is `respond`). So `wisp respond`, `wisp chat`, `wisp
  mcp`, `wisp "prompt"`, `wisp -m system "prompt"`, and `harness/.build/debug/wisp respond` are refused, and `wisp
  --version`, `wisp doctor`, `wisp logs`, `wisp config set … "…"`, and `wisp` alone are not. It is anchored at the
  start of a simple command, and the runner checks each segment of a line by itself, so `cd x && wisp respond` is
  refused and `grep wisp README.md` or `echo "wisp chat"` is not. It names the agent-starting forms rather than
  allowing the rest because the configuration view (`inspect(config)`, bounded at 4 KiB) lists the deny patterns,
  and a pattern that listed every other subcommand did not fit; an unquoted bare prompt (`wisp hello`) is therefore
  not matched.
- **The person is held to it too.** The deny list applies to commands typed after `!` (ADR 0049), and this pattern
  stays there rather than in the risk classifier or a model-only rule. A nested wisp typed after `!` would fail the
  same way the model's did, unable to write `~/.wisp` under the sandbox, and `wisp chat` would have no terminal; the
  deny refuses at once with its reason instead of failing with a bare `Operation not permitted`, and costs the person
  nothing that works. The classifier would only ask the person about a command they had just typed, and a model-only
  list would be a second policy where one serves. The person runs a nested wisp from another terminal.

## Consequences

- A refused write is named as one, with where the model may write instead, so it can retry in the right place
  rather than report a refusal that did not happen.
- The check reads text the command printed, which a command could forge; the verdict changes only what the model
  and the person are told, never what runs or what the sandbox allows.
- An error that names a path in a shape not listed falls back to the guess, which says it is one.
- The configuration view the model reads with `inspect(config)` lists the deny patterns and was within about 40
  bytes of its 4 KiB bound in a test home; with the new pattern it rendered 4,185 bytes and lost its last keys. It is
  now pretty JSON when that fits and compact JSON when it does not.
- The deny pattern is illustrative, as the list is: a nested wisp hidden in `sh -c "…"` or a script is not matched,
  and the sandbox remains the barrier.
- Tests without a model: each error shape, a path inside and outside the roots, relative and `..` paths, a root's
  name as a prefix, symlinked roots, no path as a guess, the model's tool result with session `ce87576a`'s exact
  error, the bounded note, the audit fields, the typed note, and a real refusal of a harmless `touch` into a scratch
  directory the test makes under the home directory, outside the roots. For the deny: each denied form, the allowed
  subcommands and mentions, options and paths, segments of a longer line, and a typed command.
- Documented in `tools/run_command.md`, `trust.md`, `logging.md`, `wisp.md`, and `design.md`.
