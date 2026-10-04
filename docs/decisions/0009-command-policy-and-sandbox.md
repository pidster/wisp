# ADR 0009: run_command is governed by a CommandPolicy and a Seatbelt sandbox

Date: 2026-09-17. Status: accepted. Amends ADR 0005 (the "unsandboxed" clause). Amended by
[ADR 0054](0054-the-sandboxs-refusals-checked.md): the default deny list refuses a nested wisp agent.

## Context

`run_command` lets the model execute anything with the harness's privileges. The investigation in
`policy-and-sandboxing.md` found that the framework offers nothing for this, that the `Tool.call` boundary
is the right place for policy, and that `sandbox-exec` (Seatbelt) is the only practical kernel-enforced
confinement for an unsigned CLI's child processes. Verified on macOS 27: it blocks writes and network as
profiled, SwiftPM works inside it with `--disable-sandbox`, and Cargo works unmodified.

## Decision

`CommandPolicy` in `WispCore`, configured by `commandPolicy` in `config.json`, applied by `CommandRunner`
on every run:

- **Patterns.** `deny` regexes reject a command; if `allow` is non-empty the command must also match one.
  Deny wins. The default deny list covers `sudo`, `rm -rf /`, piping into a shell, filesystem creation, and
  `dd` to a device. Patterns are validated when the config loads.
- **Sandbox.** On by default. The shell runs under `sandbox-exec` with a profile that allows everything except
  file writes outside the working directory, the temporary directory, `/private/tmp`, and configured extra
  paths (defaults: SwiftPM and Cargo caches), and, when `allowNetwork` is false, all networking. Network is
  allowed by default because builds fetch dependencies; the owner's open question stands and the switch is
  one config field.
- Paths in the profile are canonicalised with `realpath`, because Seatbelt matches real paths and `/tmp` and
  `/var` are symlinks.
- A denial is returned to the model as tool output, not thrown, so the model can adapt instead of the
  response failing.
- `--unsafe` on `respond`, `chat`, and `mcp` selects `CommandPolicy.unrestricted` and prints a warning.

## Consequences

- Seatbelt refuses a nested profile that differs from the outer one. `swift build` needs
  `--disable-sandbox` under wisp's sandbox, and wisp running inside a sandbox (as it does when it runs
  its own tests through MCP) runs commands under the outer sandbox instead. Amended 2026-09-19 after
  review: nesting is decided once per process by a probe command, never from a user command's output, and
  a command is never launched twice; the writable root is the launch directory, never a per-command
  working directory; commands run in their own process group so timeouts kill the whole tree. Documented
  in `docs/tools/run_command.md`.
- `sandbox-exec` is deprecated by Apple but still shipped and relied on by major tools. If it disappears,
  the pattern layer remains and the sandbox flag becomes a no-op to be handled in a new ADR.
- Reads are unrestricted. Confining reads is possible with the same mechanism but was not asked for.
- Tests exercise the real sandbox (write inside, write outside, network off, unrestricted), so they are
  macOS-only, which the whole project already is.
