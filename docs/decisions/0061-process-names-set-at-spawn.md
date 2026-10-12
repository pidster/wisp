# ADR 0061: Process names set at spawn

Date: 2026-10-12. Status: accepted; built 2026-10-12 for 0.23.0. Settles the roadmap's "process title decided"
(0.23.0), raised by the operator on 2026-10-04.

## Context

On 2026-10-04 the operator asked whether a wisp process can describe itself in the process list, so that one
`wisp mcp` can be told from another (which harness started it, which session is stuck). Every server looked
alike: `ps` showed each as `…/harness/.build/release/wisp mcp`, and on 2026-10-12 two of them were running side
by side on this Mac with nothing to tell them apart.

What macOS offers, established on 2026-10-04 and probed again on this Mac on 2026-10-12:

| Where a name shows | Where it comes from | Can wisp set it? |
| --- | --- | --- |
| `ps -o args`, `ps -o comm`, `pgrep -f` | The process's own argument list, `argv[0]` first | At spawn, by the parent (`exec -a`, `posix_spawn`'s argv, Rust's `CommandExt::arg0`); or by rewriting the argument memory in place afterwards (PostgreSQL's "clobber argv"), limited to the original length and needing unsafe pointer work in Swift |
| Activity Monitor, `ps -o ucomm` | The kernel's accounting name: the executable's file name, 16 characters | No: macOS has no `prctl(PR_SET_NAME)` or `setproctitle()`; `pthread_setname_np` names threads only |

The probe of 2026-10-12: `exec -a "wisp mcp (probe)" /bin/sh mcp` under macOS's `/bin/sh` showed
`wisp mcp (probe) mcp` for `ps -o args`, `wisp mcp (probe)` for `ps -o comm`, and `bash` for `ps -o ucomm`.

Considered:

| Option | What it does | Why not, or why |
| --- | --- | --- |
| (a) Rewrite the argument list in process | A live title such as `wisp mcp · claude-code · 3 threads · 1 approval waiting` | Unsafe pointer writes over `argv` and `environ`, bounded by their original length, kept up to date from many places; the live state it would show is already in `wisp://status`, `wisp approvals pending`, and `wisp doctor`. And Activity Monitor would still show `wisp` |
| (b) Name at spawn only | The parent chooses the child's `argv[0]`: `wisp mcp (claude-code)`, `wisp chat (tui)` | Chosen. No unsafe code and nothing to keep current; it answers the question asked (which harness, which face started this process) with one line in the launcher and one in `wisp-tui` |
| (c) Nothing | | The question was real: two servers were indistinguishable |

## Decision

- **Names are set at spawn, by the parent; wisp never rewrites its own argument list.**
- **`scripts/wisp-mcp`** starts the server as `wisp mcp`, or `wisp mcp (CLIENT)` when `WISP_MCP_CLIENT` names the
  harness that runs it. The repository's `.mcp.json` sets `claude-code`; a Codex configuration may set `codex`.
  The name is kept to letters, digits, dot, underscore, and hyphen, at most 32 of them. The launcher uses `exec -a`,
  which macOS's `/bin/sh` (bash) has; a shell without it starts the server unnamed, as before. `ps` then shows
  `wisp mcp (claude-code) mcp`: the chosen name, then the arguments wisp parses.
- **`wisp-tui`** starts its child as `wisp chat (tui)` (`CommandExt::arg0`), so `ps` shows
  `wisp chat (tui) chat --json …`.
- **wisp finds its own executable by the kernel's path, never by `argv[0]`.** `ExecutablePath` reads
  `_NSGetExecutablePath` and falls back to `Bundle.main.executableURL`, which Foundation also takes from the kernel;
  with neither it gives no answer rather than guess. Before this, `FrontEnd.runningExecutable` fell back to
  `argv[0]`, which after this decision is a name, not a path. `wisp chat` hands a terminal to `wisp-tui` with
  `WISP_BIN` set from it, so a renamed `wisp` still starts the right binary.

## Consequences

- `ps`, `pgrep -f`, and `ps -o comm` tell a Claude Code session's server from a Codex one's, and a chat behind
  `wisp-tui` from one typed at a terminal. Activity Monitor still shows `wisp`, as macOS gives no way to change it.
- A pattern such as `pgrep -f "wisp mcp"` still matches every server; one that matched the full path of the
  release build no longer does, since `argv[0]` is no longer the path.
- `ArgumentParser` reads the arguments after `argv[0]`, so parsing is unchanged; help and usage text name the
  command `wisp`, from its configuration.
- No live state in the title. If one is wanted later, it is a new decision weighing (a) again.
- Tested without the model: `ExecutablePath` preferring the kernel's path, resolving links, and never falling back
  to a name; the running test process found by the kernel's path; `wisp-tui`'s command naming its child (a stand-in
  child printing its own arguments as `ps` shows them); and `scripts/check launcher`, part of the gate, running a
  copy of the launcher with a stand-in binary for no client, `claude-code`, and a name with characters stripped.
