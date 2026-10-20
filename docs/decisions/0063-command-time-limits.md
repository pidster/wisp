# ADR 0063: Command time limits a call or a thread may ask for

Date: 2026-10-14. Status: accepted; built 2026-10-14 for 0.24.2. Chosen by the operator on 2026-10-14. Point 5
amended by [ADR 0067](0067-a-call-may-only-lengthen-its-time-limit.md): a call's request may only lengthen the
limit it would otherwise get.

## Context

Every command the model ran through `run_command` was killed after `commandTimeoutSeconds`, 60 s unless the
operator set another. Neither the model nor an MCP caller could change it: the setting is the operator's, in
`config.json`, and no tool writes that file.

On 2026-10-13 a `git commit` run through wisp's MCP `respond`, as `AGENTS.md` has every git command run, was
killed at 60 s twice. The repository's pre-commit hook runs the full gate (`scripts/check`): about 40 s warm, and
well over 60 s after a change to a test-support module, which rebuilds most of the tests. The second kill came
while the gate was putting `harness/Package.resolved` back and left the lockfile half-restored. Builds and test
runs often take longer than 60 s on their own, and the model had no way to say that one would.

A typed command (`Origin.person`) has had no timeout since ADR 0049's amendment of 2026-10-09: the person stops
it. That stays.

While reading the runner for this change, a `commandTimeoutSeconds` of 0, which `ConfigEdit` and
`docs/wisp.md` described as "waits forever", turned out to set a watchdog of zero seconds, which fires at once
(`Alarm` clamps a delay to zero or more). It is fixed here: 0 is no limit.

## Decision

1. **A per-call limit.** `run_command` takes an optional `timeoutSeconds`, guided as "Seconds this command may
   run, for a long build or test. Omit for the default." Below 1 it is refused as text to the model
   (`error: timeoutSeconds must be at least 1 …`), and nothing runs.
2. **A per-thread limit.** MCP `respond` takes an optional `commandTimeoutSeconds` when a thread starts, as it
   takes `instructions`, `tools`, `model`, and `think`, and refuses it on a thread that exists with the same
   error. Below 1, or not an integer, it is an argument error. It is the limit of that thread's `run_command`
   calls that ask for none, carried by the thread's `RunCommandTool` alone: another thread, a custom tool (which
   keeps its own `timeoutSeconds`), and `system_info` (its floor of 30 s) never see it. The CLI's `respond` and
   `chat` get no flag: the operator who runs them sets `commandTimeoutSeconds`.
3. **A cap, the operator's.** A new setting, `commandMaxTimeoutSeconds`, from 1 to 86,400 (a file outside that
   does not load, and `wisp doctor`'s `settings` finding names it), 1,800 by default, settable with
   `wisp config set`. A requested limit above it is clamped to it, not refused: the command runs, under the cap,
   and the audit says it was clamped. The model still has no tool that changes configuration, so neither the
   model nor a caller can raise the cap.
4. **The default rises from 60 to 120 s**, in `Config.resolved` and in `CommandRunner.Options`.
5. **Precedence:** the call's `timeoutSeconds`, else the thread's `commandTimeoutSeconds`, else the operator's
   `commandTimeoutSeconds`. Each requested value is clamped to `commandMaxTimeoutSeconds`. The operator's own
   default is not clamped: it is the operator's setting as much as the cap is, so a `commandTimeoutSeconds` of
   3,600 under a cap of 1,800 gives an unprompted command 3,600 s, and a `commandTimeoutSeconds` of 0 gives it
   none. A request always wins over the default, shorter or longer. A typed command keeps no limit.
6. **Audit.** `command.outcome` records, for a model's command, `timeoutSource` (`call`, `thread`, or
   `default`), `timeoutSeconds` (the limit applied, absent when there was none), and `timeoutClamped: true` when
   a request was cut to the cap. A thread's `session.start` records the `commandTimeoutSeconds` it was given.
7. **The timed-out result says how to ask for more**, briefly: `timed out: the command was killed after 120 s;
   ask for up to 1800 s with timeoutSeconds`, or `…, the most allowed` when the limit was the cap. Only a result
   whose caller can ask (`run_command`) carries the hint; `triage`, `wisp watch`, and custom tools give the limit
   alone. `run_command`'s `limits` text states the default this thread's commands get and the cap.

## Consequences

- A git thread started with `commandTimeoutSeconds: 600` survives a commit whose hook runs the gate, and
  `AGENTS.md` says to start it so. A model that knows a build is long asks for longer on that one call.
- The model can make a command run up to half an hour by default without asking anyone. The command still
  passes the policy, the classifier, approval, and the sandbox; the limit bounds how long, not what.
- Five arguments are now refused on an existing thread; the message names all five.
- `WispServer.ThreadFactory` gains a parameter, the thread's limit, which every injected factory takes.
- An operator who set `commandTimeoutSeconds` to 60 keeps 60; one who left it unset gets 120.
- Tests (`CommandTimeLimitTests`, `RespondCommandTimeoutTests`) drive the real sandbox with `sleep` commands of
  one to three seconds under limits of one to five, and need no model.
