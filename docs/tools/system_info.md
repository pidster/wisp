# system_info

Answers questions about this Mac without the model composing shell: which process is on a port, how
much space is free, what fills a folder, which of your processes are busiest, memory, one process,
battery, macOS and hardware, network. wisp runs fixed, read-only commands (or reads the process table
through `libproc`), parses them, and returns a short table. Decided in
[ADR 0034](../decisions/0034-system-info.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `topic` | enum | yes | `ports`, `freeSpace`, `folderSizes`, `processes`, `memory`, `process`, `battery`, `system`, `network`. |
| `port` | integer | no | For `ports`: the port asked about; without it, every listening TCP socket. |
| `process` | string | yes | For `process`: the app or process name (matched case-insensitively) or its id; empty for other topics. Required so the model does not leave the name out. |
| `path` | string | no | For `folderSizes`: the folder; `~` expands; the home directory when absent or blank. |

## What each topic reads

| Topic | Source | Result |
| --- | --- | --- |
| `ports` | `lsof -nP -iTCP -sTCP:LISTEN`, or `lsof -nP -i :<port>` | command, pid, protocol, address, state |
| `freeSpace` | `df -k -l` | `/`, `/System/Volumes/Data`, and `/Volumes/*`: size, used, free, capacity |
| `folderSizes` | `du -x -k -d 1 <path>` | the folder's total and its 15 largest items; when `du` could not read some folders (privacy protection, the sandbox) the report says the sizes may be low |
| `processes` | `libproc`, sampled over 0.5 s | your 15 busiest processes by CPU: pid, CPU%, memory share, resident size, elapsed, name |
| `memory` | `hw.memsize`, `memory_pressure -Q`, `libproc` | installed memory, the free percentage, your 15 largest processes |
| `process` | `libproc`, `KERN_PROCARGS2`, `lsof -p` | matching processes; for a single match its command line (secrets redacted) and listening ports |
| `battery` | `pmset -g batt` | the power source and charge |
| `system` | `sw_vers`, `sysctl`, `uptime` | macOS version and build, model, CPU and cores, memory, uptime |
| `network` | `scutil --nwi` | interfaces, addresses, reachability |

## Limits and controls

| Control | Value |
| --- | --- |
| Output | At most 15 rows per table and 4096 bytes; cut at a line end with a note |
| Reach | Your own processes only: without root, `libproc` and `lsof` do not describe other users' (system daemons'); the result says so |
| Sandbox | Every command runs through `run_command`'s runner: policy, Seatbelt, timeout (at least 30 s, for `du`), output bound, `command.outcome` audit |
| Approval | None: the model supplies a topic and validated values, never a command. Leave the tool out with `--tool` or `tools` if it should not look |
| Why not `ps` | `/bin/ps` and `/usr/bin/top` are setuid root and Seatbelt will not execute them, so `run_command` cannot run them either |

Errors come back as `error: …`: a port outside 1 to 65535, a path that is not a folder, or `process`
without a name (the message says how to call again).

## Measured

`SystemInfoEvalTests` (`scripts/check eval`): eight plain questions that do not name the tool, twice
each, with `run_command` also offered. On 2026-09-24 on the system model, after the process name became
required, 15, 16, and 16 of 16 on three runs; the recorded figure is in
[measurements.md](../measurements.md). Before that change (2026-09-23) the question naming an app failed
about half the time, the model leaving out the name and falling back to `ps`.
