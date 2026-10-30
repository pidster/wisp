# Troubleshooting

Start with `wisp doctor`. It checks what an install needs, exits non-zero when anything fails, and each line
that is not ok says what is wrong; it is the first thing to ask for when someone reports a problem. Then find the
symptom below. `WISP_LOG=debug wisp …` mirrors wisp's own diagnostics to stderr, and `wisp logs --last 20` shows
what just happened ([Logging](../logging.md)).

## The model

| Symptom | Cause and fix |
| --- | --- |
| `Apple Intelligence is not enabled; turn it on in System Settings and wait for the model to download` | Turn it on in System Settings, then wait; `fm available` reports the model's state too |
| `the model is still downloading or preparing; try again in a few minutes` | The model is not ready yet; wait |
| `this Mac cannot run the on-device model (Apple silicon is required)` | Use a local model instead ([Local models](local-models.md)) |
| `doctor` says the model is available but every request fails, mentioning `modelmanagerd` or "Too many open files" | Apple's model service has failed, not wisp or the model. Restart it, and launchd starts it again on the next request (below) |
| `no Ollama server at …` | Start Ollama (`brew services start ollama`, or open the app), or set `ollama.baseURL` |
| `Ollama has no model '<name>'; installed: …` | `ollama pull <name>`, or pick one of those listed |
| `model 'X' is disabled; enable it with …` | `wisp models enable X` |
| `no llama.cpp server at …` | Start `llama-server`, or set `llamacpp.baseURL`; under `llamacpp.server llama-app`, the message says to start Llama.app, or that it is not installed |
| `wisp's llama.cpp server does not answer at …: wisp will not start its llama-server: …` | Under `llamacpp.server wisp`, the approved `llama-server` is not set, not approved, or has changed (after `brew upgrade llama.cpp`); run the `wisp config set llamacpp.serverPath …` command the message names |
| `wisp's llama.cpp server does not answer at …: its LaunchAgent is not registered; …` | `wisp config set llamacpp.server wisp` registers and starts it |
| `… its Login Item waits for your approval in System Settings > General > Login Items & Extensions …` | Turn on Wisp there; macOS asks before an app's background item runs |
| `… wisp registers no LaunchAgent here (…); start it yourself with wisp llamacpp serve` | `WISP_HOME` or `WISP_LLAMACPP_AGENT=off` is set; run `wisp llamacpp serve` in another terminal, or unset them |
| `wisp's llama.cpp server has not started yet: …` or `… is registered and the server is not running, or still starting …` | Read `~/Library/Logs/Wisp/llamacpp.log` (the message names it), then `wisp config set llamacpp.server wisp` to start it again; `wisp doctor` shows the whole state |
| `wisp's llama.cpp server at … refused the key in wisp's key file …` | It runs with another key; `wisp config set llamacpp.server wisp` restarts it with the one in the key file |
| Chat says it is using `system` instead of your configured model | That model was unavailable as chat started; fix it, then `/model <name>` ([ADR 0056](../decisions/0056-models-enabled-and-disabled.md)) |
| `MLX` in `doctor` is not ok | MLX's Metal library is missing from beside `wisp`. A Homebrew install puts it there; reinstall with `brew reinstall pidster/tap/wisp` ([ADR 0047](../decisions/0047-mlx-in-the-release.md)) |

### Restarting Apple's model service

On 2026-10-13, after 26 days up, `modelmanagerd` ran out of open files: the model reported itself available, yet
every request failed, from wisp and from Apple's own `fm` alike. `wisp doctor` asks the model for a one-word reply
rather than trusting the availability flag, and when the request fails with the service's own error the finding
says so and gives the fix:

```bash
sudo killall modelmanagerd
```

launchd starts the service again on the next request; restarting the Mac does the same.

## Commands the model runs

| Symptom | Cause and fix |
| --- | --- |
| `error: command not approved: …` from a one-shot `wisp "…"` | It cannot ask you, so it refuses at `moderate` and above. Pass `--yes`, or use `wisp chat` |
| `error: command denied by policy: …` | The deny list refused it (`sudo`, `rm -rf /`, a pipe into a shell, a wisp agent of its own), or an `allow` list you set did not match. Run it yourself if you mean it |
| A `sandbox: refused writing to /x; commands may write only under …` line | The command wrote outside the sandbox's writable set. Start wisp in the directory to be changed, add a cache to `commandPolicy.sandbox.writablePaths`, or, for a chore that cannot run sandboxed, let the model ask with `outsideSandbox` or type it yourself after `!!` ([Approvals and the sandbox](approvals-and-sandbox.md#outside-the-sandbox-one-command-at-a-time)) |
| Commands write only to the temporary folders; `wisp doctor`'s `sandbox` line says wisp was started in a privileged folder | Started in your home folder, a folder above it, `~/Library`, or a system folder, wisp gives commands and `edit_file` no project folder. Start wisp in the project to be changed ([ADR 0077](../decisions/0077-no-project-folder-in-privileged-folders.md)) |
| `sandbox: not the sandbox: …` | The path is inside the writable set; file permissions, flags, or system protection refused it |
| `execvp() of '/bin/ps' failed: Operation not permitted` | Seatbelt will not run a setuid program (`ps`, `top`); ask about processes, and `system_info` reads them through `libproc` instead |
| `log: Cannot run while sandboxed` | `/usr/bin/log` refuses any sandbox; the MCP tool `condense_log` with `last` reads the unified log in process |
| `sandbox_apply: Operation not permitted` from SwiftPM | A tool that applies its own sandbox cannot nest inside wisp's. Use `swift build --disable-sandbox` and `swift test --disable-sandbox`; Cargo needs nothing ([run_command](../tools/run_command.md#nested-sandboxes)) |
| `brew upgrade` stops with "You should change the ownership of these directories" | Homebrew writes outside the sandbox and runs a sandbox of its own: `!!brew upgrade` in chat, or approve the model's `outsideSandbox` request |
| A command is killed after 120 s | The default `commandTimeoutSeconds`. The model may ask for more per call, an MCP thread per thread (`commandTimeoutSeconds`), both up to `commandMaxTimeoutSeconds` ([ADR 0063](../decisions/0063-command-time-limits.md)) |

## The MCP server

**The server fails to connect.** Run the configured command yourself: `/opt/homebrew/bin/wisp mcp` (or whatever
your `command` names) should start and wait silently for input; Ctrl-D ends it. A wrong path, or an old wisp, are
the usual causes. Codex needs wisp 0.1.5 or later. Stdout is the protocol channel, so nothing is printed there;
`WISP_LOG=debug` in the server's environment mirrors its diagnostics to stderr.

**In this repository** (contributors), `.mcp.json` runs `scripts/wisp-mcp`, which runs the release build at
`harness/.build/release/wisp`. When the server fails at start-up the cause is almost always that the build is
missing: the launcher says `wisp MCP server: no release build at …`. Build it, then reconnect (`/mcp` in Claude
Code):

```bash
scripts/check mcp-build
```

The build is also stale after code changes until it is rerun. Use `scripts/check mcp-build`, not a bare
`swift build -c release`, which rewrites the lockfile (below).

**An approval dialog seems stuck.** The request also waits in `~/.wisp/pending`, so answer it from a terminal; the
notification named its id:

```bash
wisp approvals pending
wisp approvals approve a1b2c3d4        # or: wisp approvals deny a1b2c3d4
```

A running `wisp-tui`, or `/approvals` in a plain `wisp chat`, answers it too. Failing that, in Claude Code,
`/mcp reconnect wisp` clears the dialog; retry the turn afterwards. A request nobody answers is refused after
`approval.timeoutSeconds` (600 s), never run.

**A reply ends `[a question waits for the person: …]`.** The model asked you a question with its `ask` tool.
Answer it yourself with `wisp questions answer <id>`, in `wisp-tui`, or with `/questions answer <id>` in chat; the
answer reaches the thread's next turn. The agent cannot answer it for you ([ask](../tools/ask.md)).

## State

| Symptom | Cause and fix |
| --- | --- |
| Notifications come from your terminal or Script Editor, not from Wisp | `wisp doctor`'s `notifier` line says why. `not yet allowed`: the next notification asks, or `wisp notify --route helper "test"` asks now. Notifications for Wisp are off: turn them on in System Settings, Notifications, Wisp. `no Wisp Notifier.app beside wisp`: a Homebrew install has it; `brew reinstall pidster/tap/wisp`. `off (notifications.viaHelper)`: `wisp config set notifications.viaHelper true` ([notify](../tools/notify.md)) |
| `config` in `doctor` is not ok, or every command exits 64 naming `config.json` | The file does not parse, or a `commandPolicy` pattern is invalid; the message names it. Fix the file, or `wisp config unset` the setting |
| `facts store` in `doctor` is not ok | `~/.wisp/facts.json` did not parse, was set aside, or is readable by others; the detail says which and how to fix it |
| `pending approvals` in `doctor` is not ok | `~/.wisp/pending` is open to others or not yours: `chmod 700` it |
| `--resume` says `thread X is open in another wisp (pid N, …)` | Another chat or `wisp mcp` has the thread open; leave it there, or let that process end. `/threads` and `wisp threads` show it as `open elsewhere` |
| `--resume` says `thread X is an agent's, saved with …; these settings differ` | You gave `--model`, `--tool`, or `--instructions` for an agent's thread, whose settings hold; leave them out |
| `--resume` refuses a transcript from `~/.wisp/transcripts` | It has no `.store` beside it, or one that does not match; `doctor`'s `saved transcripts` lists them |

## For contributors: the lockfile and MLX

The release builds with `--traits MLX`, so `harness/Package.resolved` must pin the packages only that trait
resolves (`mlx-swift`, `mlx-swift-lm`, `swift-numerics`, `swift-syntax`). Any build without the trait, a plain
`swift build` among them, rewrites the lockfile without those pins. `scripts/check` puts the lockfile back after its
own builds and refuses a commit whose lockfile lacks them. If yours lost them, restore it:

```bash
git checkout HEAD -- harness/Package.resolved
```

When the dependencies really changed, resolve with the trait (`scripts/check mlx-build`) so the new lockfile keeps
the pins ([Engineering standards](../engineering.md#the-lockfiles-mlx-pins)).
