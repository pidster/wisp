# AGENTS.md

Instructions for any coding agent working in this repository: Claude Code, Codex, or another harness.
Everything here applies to all of them. Anything that only applies to one harness is in the last section,
under that harness's name, or in that harness's own file (`CLAUDE.md` for Claude Code, which imports this
one). If you are a different harness, read this file in full and take only your own subsection.

## What wisp is

An on-device, tool-using AI microharness for macOS, written in Swift on Apple's Foundation Models framework
(the model behind Apple Intelligence and the `fm` CLI). One binary, `wisp`, with two faces: a CLI
(`respond`, `chat`, `tools`, `models`, `logs`, `config`, `doctor`, `approvals`, `facts`, `notify`, `scan`, `redact`, `watch`, `draft`, `classifier`) and an MCP server over stdio (`mcp`) that other
harnesses delegate local work to. Every command the model runs passes a policy, a Seatbelt sandbox, a risk classifier, and,
when risky, human approval; everything is written to a verbatim audit log.

`docs/README.md` is the map. Read the page for the area you are touching before changing it; the decision
records under `docs/decisions/` explain why things are the way they are, and you must not reverse one
without a new ADR. Language- and area-specific rules live in `.claude/rules/` (`swift.md`, `rust.md`,
`docs.md`, `shell.md`); each file's header lists the paths it applies to. Claude Code loads them by path
automatically; every other agent reads the matching file before touching those paths. This file holds
only what applies everywhere and to every agent.

## Layout

| Path | Contents |
| --- | --- |
| `harness/` | Swift package. Targets: `WispCore` (all logic), `WispCoreAI` (Core AI model backend), `WispMLX` (MLX backend, real only under the `MLX` trait), `WispMCP` (MCP server), `wisp` (CLI, argument parsing only, registers backends), tests, and `WispTestSupport` (`ScriptedModel` and friends, also a library product). |
| `harness/Evals/` | A second Swift package, depending on the harness by path: the model evaluations (`ModelEvalTests`, needing a model). The gate and coverage never build it; `scripts/check eval` does. |
| `tools/` | Cargo workspace. `wisp-tui`, the terminal front end over `wisp chat --json` (ADR 0029); future tool binaries go here too. The gate runs fmt, pedantic clippy, and tests on it. |
| `docs/` | Documentation and ADRs. Part of every change (see Definition of done). |
| `training/` | Labelled training sets for the fast classifiers, with their adversarial reviews (ADR 0038). Only `risk/train.tsv` is built in, copied to `Resources/risk-examples.tsv` by `scripts/check classifier-default`. |
| `scripts/check` | The quality gate and the pre-commit hook's body. |

## Commands

Swift commands run inside `harness/`; the gate runs from anywhere.

```
scripts/check install-hooks        # once per clone
scripts/check                      # hygiene + strict lint + warnings-as-errors build + tests (the gate)
scripts/check format               # swift-format and rustfmt auto-fix
scripts/check coverage             # per-file line coverage (not in the gate)
scripts/check eval [context] [record]  # model evaluation (harness/Evals); slow; not in the gate; every suite but the context eval, or only it; record rewrites measurements.json
scripts/check mlx-live <model dir> # MLX live test on real weights, built with --traits MLX; not in the gate
scripts/release X.Y.Z --dry-run    # release preflight, build, package; remote steps printed (docs/release.md); --skip-eval when the eval passed on this code

cd harness && swift build                                        # -> .build/debug/wisp
cd harness && swift test --filter CommandRunnerTests             # one suite; append /testName for one test
cd harness && swift build -c release                             # -> .build/release/wisp (what .mcp.json runs)
```

Smoke-testing against the live model (never in unit tests):

```
export WISP_HOME=/tmp/wisp-scratch     # keep smoke state out of the real ~/.wisp
harness/.build/debug/wisp tools
harness/.build/debug/wisp --yes "Use run_command to run: uname -m"
harness/.build/debug/wisp chat --plain    # /help lists every command: /status, /approvals, /audit, /config, /models, /model, /stats, /tokens, /inspect context|facts, /fact, /task, /show, /save, /new, /quit; y/s/p/a/n to approvals
(cd tools && cargo build) && WISP_BIN=harness/.build/debug/wisp tools/target/debug/wisp-tui   # the front end
harness/.build/debug/wisp logs --last 20  # audit summaries; --json for raw events
WISP_LOG=debug harness/.build/debug/wisp "…"   # mirror diagnostics to stderr
```

To drive `wisp mcp` by hand, pipe JSON-RPC lines and keep stdin open (`; sleep 5` in the producing
subshell); the server exits on EOF. `docs/mcp.md` has a ready-made example.

## Architecture in one paragraph

`Agent` wraps one `LanguageModelSession` created by a `ResolvedModel` (`ModelSelection`: `system` or
`private-cloud`, or `ollama:<name>` through wisp's own executor, ADR 0016; adapters are obsoleted on macOS 27, ADR 0013); the framework runs the tool loop. `ToolRegistry` is the single
list of tools the model sees (`current_date`, `run_command`, `read_file`, `edit_file`, `inspect`, `notify`, `system_info`, `memory`), each wrapped by `AuditedTool`.
`CommandRunner` checks `CommandPolicy` (deny/allow regexes), consults `ApprovalGate` (rules plus an on-device
classifier, the language model or a Core ML version from `ClassifierStore`; ask at `moderate` and above
through the `Approver` of the face's `SessionHost`, which also routes notifications, ADR 0044; under `wisp mcp`
an `OutOfBandApprover` asks through the client's elicitation and files the request in `~/.wisp/pending`
(`PendingApprovals`) for `wisp approvals approve|deny` or `wisp-tui` at once, the first answer winning, ADR 0046), then runs `/bin/sh -c` under `sandbox-exec` with a generated profile, bounded output and a timeout. `FileReader` pages files.
`Home`, `Config`, `TranscriptStore`, and the permanent facts' store are `~/.wisp`. `Prompting` layers wisp's own system prompt (the
file `harness/Sources/WispCore/Resources/system-prompt.md`, embedded at build time by the
`EmbedSystemPrompt` plugin), the operator's `systemPromptExtension`, and the caller's instructions (ADR 0017). `AuditLog` writes JSON Lines; `Diagnostics` wraps
unified logging. `Agent` keeps each conversation in a `ThreadRecord` that refers to the audit log, and
`ContextComposer` composes every request from it: facts (`Facts/`), a running summary, recent turns with
earlier tool output as references, and the request; `ContextPolicy` condenses it to a token target ahead
of the window and on overflow, and the model's `memory` tool recalls what was dropped (ADR 0045). `Session.begin` is
the single set-up path for every face; `respond` and `chat` open the session's own `WispThread`, and
`WispMCP` opens one per `thread_id` through `Session.thread` (threads held by
`ThreadRegistry`/`ThreadActor` actors), so all of them share one config, approval store, and
session-approval set. `WispMCP` exposes `respond`, `triage` (build or test output condensed to a failure list on device,
ADR 0023), `summarise_diff` (a diff condensed to per-file lines and review flags), `draft_change` (a commit message, PR, or changelog line from a diff, ADR 0035), `scan_secrets` and `redact` (ADR 0031), `condense_log` and `json_shape` (ADR 0032), `dependency_audit`, `flaky_tests`, and `hot_paths` (ADR 0039), `set_fact_scope` (a fact moved between `thread` and `session`, ADR 0044, or put to the person to keep as permanent, ADR 0048), and `close_thread`; wisp's own tools are reachable only through `respond`. `ChatLoop` is the chat for every face: the
plain terminal chat, and `wisp chat --json`, which maps it onto JSON Lines (`ChatProtocol`) for
`tools/wisp-tui`, the ratatui front end that `wisp chat` hands a terminal session to (ADR 0029). Details: `docs/design.md`.

## Rules

- **Definition of done.** A change is done when it is tested (without the model), documented in code, and
  documented under `docs/` in the same commit: tool page, `wisp.md`, `mcp.md`, `logging.md`, `design.md`,
  or an ADR as appropriate. If no doc needs changing, say so in the commit message. The hook reminds you.
  A user-visible change also gets a line under `## Unreleased` in `CHANGELOG.md`; the release script
  publishes that section as the release notes and refuses to release without one.
- **Gate.** `scripts/check` must pass before every commit; the hook runs it. Strict lint, warnings as
  errors, strict concurrency, no escape hatches. Language rules are in `.claude/rules/`.
- **Tests never need the model.** The model evaluations are the one model-dependent suite. They are a package of
  their own, `harness/Evals`, that the gate never builds; `scripts/check eval` runs them; `OllamaLiveTests` runs only under `WISP_OLLAMA_TESTS=1`. To drive the agent,
  the tool loop, or the MCP server end to end without a model, use `ScriptedModel` from
  `Tests/WispTestSupport` (ADR 0016); `WispServerWireTests` shows the pattern over a real client.
- **Bound every tool result** (4 KiB or paged); the on-device model's window is 8,192 tokens on macOS 27. Keep tool
  descriptions short. See `docs/context-management.md`.
- **Audit new behaviour.** New event kinds go in `AuditEvent.Kind` and `docs/logging.md`.
- **Commits** are small and single-purpose; subject says what, body says why. Do not pass an explicit
  `user.email` to git; the configured noreply identity is required for pushes.
- **Releases** run the full test suite and `scripts/check coverage-gate` in preflight. Line coverage
  must not fall below `harness/coverage-baseline`; after adding tests, record the new figure with
  `scripts/check coverage-baseline` and commit it (`docs/release.md`).
- **Docs sweep before every release, before `scripts/release` is run.** Read the pages a user and an
  agent meet first against the code as it stands, fix what is stale, and commit the sweep on its own
  ("Bring the docs up to date for X.Y.Z", or "Docs sweep for X.Y.Z: nothing stale"). The list is in
  `docs/release.md`, step 0. The per-change rule keeps each feature's own page right; the sweep catches
  what a feature changes elsewhere (a tool list, a layout table, a quick start). The release preflight
  checks mechanically that every page is in the docs index; everything else is the sweep's job.
- **CI is disabled** until a macOS 27 runner exists; the hook is the only automated gate.

## Gotchas that cross languages

- Seatbelt refuses a nested profile that differs from the outer one. Inside wisp's sandbox, SwiftPM
  needs `swift build --disable-sandbox` (Cargo is unaffected); wisp inside a sandbox detects the refusal
  and runs commands under the outer sandbox instead (`docs/tools/run_command.md`).
- Seatbelt matches real paths; profile paths go through `realpath` (`/tmp` and `/var` are symlinks).
- Stdout is the MCP protocol channel while `wisp mcp` runs; diagnostics go to stderr or unified logging.

## Working through wisp's MCP server

**Run every git command through wisp's `respond` tool**, never through your own shell: status, log,
diff, add, commit, push. There is no direct `run_command` MCP tool by decision; the model behind
`respond` runs the command with its own `run_command` tool, so each one is classified, sandboxed,
approved, and audited as a turn. The tool is named by your harness's convention for the `wisp` server
(Claude Code: `mcp__wisp__respond`; Codex: the `respond` tool of the `wisp` server).

Open one thread for git and reuse it. When the thread starts, pass all four of these; they are refused on
an existing thread:

- `thread_id`: `git` (or `git2`, `git3` if the thread was closed).
- `tools`: `["run_command"]`, so the model has nothing else to reach for.
- `model`: `ollama:granite4.1:8b`, the default local Ollama model (see the model choice below). It
  follows a fixed instruction reliably and its context window is far larger than the on-device model's,
  so a thread survives many commits with hook output. If Ollama is not running the thread fails to start
  with a clear error; then use the default `system` model and keep prompts short.
- `instructions` (the conversation layer; wisp's own system prompt and the config extension stay
  underneath it):

  ```
  You run git commands for a coding assistant. Run exactly the command line given between backticks,
  once, in the working directory given, with the run_command tool. Do not modify the command, add flags,
  or run anything else. Reply with the exit status and the output verbatim, and nothing else.
  ```

Prompt shape for each turn, with the command between backticks so a trailing period is never taken as
part of it:

```
Use run_command with working directory <repo> to run exactly the command line between the backticks:
`<command>`
Report the exit status and output verbatim, nothing else.
```

Put commit messages in a file and commit with `set -o pipefail; git commit -q -F <path> 2>&1 | tail -3`
so the hook's test output does not fill the reply; push with `set -o pipefail; git push origin main 2>&1 |
tail -3`. Keep `set -o pipefail` whenever output is piped: without it the exit status is `tail`'s, so a
failed push or a failing hook reports 0 (a push refused on 2026-09-23 came back as exit 0 with only the
last line of git's error). Expect an approval
dialog for commands that change repository state; choose "This session" for repeated shapes. The same
request is announced by a notification naming its id, and the user can answer it instead from a terminal
with `wisp approvals approve ID` (`--scope session` for repeated shapes) or `wisp approvals deny ID`;
`wisp approvals pending` lists what waits. You cannot answer it yourself: those commands need a terminal,
and the default policy refuses them to the model. The
pre-commit hook then runs inside wisp's sandbox, which `scripts/check` detects. If wisp is not
connected, say so and ask the user to reconnect it rather than falling back to your own shell.

The `wisp` server is this repository's own release build, for dogfooding, launched through
`scripts/wisp-mcp`. **If the server fails to connect at start-up, the cause is almost always a missing
release build**: tell the user to run `cd harness && swift build -c release` and reconnect, and offer to
run the build yourself. The build is also stale after code changes until it is rerun. Use `respond` to
delegate small, self-contained tasks to a local model (pass back `thread_id` to continue) and
`close_thread` when done.

Which model to pass as `model` when a thread starts (measured in the Ollama section of `docs/backends.md`):

| Work | Model | Why |
| --- | --- | --- |
| Default: git, single commands, fixed instructions, short lookups | `ollama:granite4.1:8b` | As fast as the larger models on these, at 5.4 GB |
| Complex: multi-step tasks, reading and reasoning over several files or outputs | `ollama:qwen3.8:27b` | The newest Qwen; it reasons before it answers, about 10 s more per turn |
| Ollama not running | `system` | Always there; keep prompts short for its 8k-token window |

If `wisp models` does not list the model, `ollama pull <name>` fetches it; ask before pulling. Read the `wisp://tools` resource (or run `wisp tools --markdown`) for the
model's tools and the prompt shapes that work; `wisp://config`, `wisp://status`, `wisp://approvals`,
and `wisp://threads` show its state, and `wisp://threads/{thread_id}` a thread's: its `context` (what the
model carries, per turn), `output`, and `audit`. Commands the model runs that need approval are asked
through MCP elicitation and, with `approval.outOfBand` (the default), through `wisp approvals` and
`wisp-tui` too; a client without elicitation waits for that answer, up to `approval.timeoutSeconds`, and
silence is a refusal (`docs/mcp.md`, "Approval").

## Harness-specific notes

Mark anything you add here with the harness it is for. Nothing in this section applies to every agent.

### Claude Code

- Reads `CLAUDE.md`, which imports this file, and loads `.claude/rules/*.md` by path automatically.
- MCP servers come from `.mcp.json`: `wisp` (above) and `codex` (`codex mcp-server`, the OpenAI Codex
  CLI, for delegating to Codex; needs `codex` on `PATH`). Tools are named `mcp__<server>__<tool>`.
- Reconnect a server with `/mcp`. When a wisp approval dialog is stuck, the user can answer it with
  `wisp approvals approve ID` from a terminal; failing that, `/mcp reconnect wisp` and retry the turn.
- Ask the user a question with `AskUserQuestion`; that is the harness's dialog, not wisp's.

### Codex

- Reads this file directly. There is no automatic path-scoped loading: open `.claude/rules/<lang>.md`
  for the language you are editing before you start.
- Connect wisp as an MCP server in `~/.codex/config.toml` as shown in `docs/mcp.md`; the release build
  must exist (`cd harness && swift build -c release`) or the server exits at start-up with instructions.
- wisp 0.1.5 or later accepts Codex's `initialize` (earlier versions refused its `experimental`
  capability; see `docs/mcp.md`).
