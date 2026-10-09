# wisp

**An AI agent that lives on your Mac, and keeps your data there.**

```bash
brew install pidster/tap/wisp
wisp "What is listening on port 8080?"
wisp chat
```

- **Local AI only.** Apple's on-device model, or yours in Ollama or MLX. No cloud, no key, no account.
- **Nothing runs unchecked.** A sandbox, a deny list, a sub-millisecond risk classifier, and you.
- **Trained on your data.** Teach the risk classifier from your own command history.
- **Redact before you share.** Secrets and personal data stripped from a file, on the Mac.
- **Watches while you work.** Reruns your tests on save; pings you when they break.
- **Your coding agent's local helper.** A 14,000-line log comes back as its top 30 messages.
- **Shows its work.** Every reply says what actually ran; every action is logged.

```bash
wisp redact crash.log | pbcopy                 # secrets and personal data replaced
git diff --cached | wisp scan                  # block a commit that leaks a key
wisp watch 'swift test 2>&1'                   # a notification when tests start or stop failing
wisp classifier train --from-audit --use       # a risk classifier trained on this Mac
```

## What it is

**wisp** is a small AI agent that runs on your Mac and stays there. It drives Apple's on-device
Foundation Model, the one behind Apple Intelligence, and gives it tools: it can run a command, read
and edit a file, report on the machine, send you a notification, and recall what its context no longer
holds. You use it from the terminal, as
a command or a chat, and your coding agent uses it as an MCP server, handing it the local chores that
would otherwise fill the agent's context: run the tests and return the failures, condense a log,
summarise a diff, scan a commit for secrets. Every command the model runs passes a policy, a sandbox,
a risk classifier, and, when it matters, you, and every step is written to an audit log you can read
back.

You and your coding agent reach the same session, and a command the model asks for passes the gate
before it touches your Mac:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.svg">
  <img alt="You at the terminal (wisp, wisp chat, wisp-tui) and your coding agent over MCP (respond, ten condensing tools, set_fact_scope, and close_thread) both open one wisp session. The session holds the config, approvals, threads, and facts, and runs the model, on device or through Ollama, with its eight tools. A command the model asks for passes the gate in order: the policy deny list, the risk classifier, you when it matters, and the Seatbelt sandbox, and only then reaches your Mac. The session, the model, and the gate all write to one audit log." src="docs/images/overview-light.svg" width="960">
</picture>

The model never carries the whole conversation. The audit log keeps everything, and wisp composes each
request from it, most stable first, while you see every tool's full output whatever the model carries
([context-management.md](docs/context-management.md), [ADR 0045](docs/decisions/0045-layered-context.md)):

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/context-dark.svg">
  <img alt="The audit log is the source of truth: every prompt, tool call, output, and reply, written once, verbatim. The thread record refers to it: entries by id, versioned facts, the running summary, and references to earlier output. For each request wisp composes the context from the record, most stable first: instructions and the tool catalogue, permanent facts, dynamic facts and the summary, recent turns word for word with tool output whole and then a reference, and last the task, ephemeral facts, and the request. The model sees only that, and, when it is turned on, its memory tool recalls earlier material or notes a fact. You see the transcript, built from the audit log, with every tool's full output; /show, /inspect context, /inspect facts, /fact, /task, and the wisp://threads resources cost the model no context. You reach it inline, in chat and wisp-tui, and through your coding agent over MCP." src="docs/images/context-light.svg" width="960">
</picture>

## What you can do with it

### At the terminal

Ask it something, or hand it a task:

```bash
wisp "What is the date in Tokyo?"
wisp "What is listening on port 8080, and how much disk is free?"
wisp --yes "Run the tests in $PWD and tell me if they pass"
wisp chat                              # a conversation; /help lists the commands
```

Running tests changes state, so it counts as a `moderate` action: `chat` asks you before doing it, and
plain `wisp "…"` cannot ask, so it refuses unless you pass `--yes`. In `chat` you answer each request
once, for the session, for this project, or always, and `/model` switches models mid-conversation. A
long conversation keeps short facts (a codename, the task, whether the tests pass) and a summary of the
turns it had to drop; `/inspect facts` and `/inspect summary` show them and `/fact` corrects one. A line
that starts with `!` (`! git status`) runs the command yourself, in the sandbox and without asking, and the
model is told what you ran on its next request. On a
terminal the chat runs in `wisp-tui`, installed beside `wisp`: the conversation scrolls in your
terminal's own history above a pinned input and status line, with the model's tool calls shown as they
happen.

Some subcommands need no prompt at all. They put the model, or plain rules, to one job each:

```bash
wisp watch 'swift test 2>&1'           # rerun on every save; a notification when it starts or stops failing
git diff --cached | wisp scan          # credentials in a commit, before it is made; exits 1 on a finding
wisp redact crash.log | pbcopy         # secrets and personal data replaced by markers, ready to paste
wisp draft > /tmp/msg && $EDITOR /tmp/msg && git commit -F /tmp/msg   # a commit message from the staged diff
make test; wisp notify "Tests finished" --sound                        # a macOS notification
wisp logs --last 20                    # what just happened, from the audit log
wisp approvals                         # what it has been told to remember; revoke or clear here
```

`wisp --help` lists every subcommand; [wisp.md](docs/wisp.md) is the reference.

### From your coding agent

Register wisp as an MCP server and Claude Code, Codex, or any other MCP client can delegate work to it.
For Claude Code, in `.mcp.json`:

```json
{
    "mcpServers": {
        "wisp": {
            "command": "/opt/homebrew/bin/wisp",
            "args": ["mcp"]
        }
    }
}
```

The agent then has `respond`, which runs a task on the local model with wisp's tools and returns the
reply with a receipt of what it did; ten condensing tools that read something large on your Mac and
return something small; and two that manage `respond`'s threads:

| Tool | Gives back |
| --- | --- |
| `respond` | The model's reply to a task, on a named thread you can continue; with a JSON Schema, a reply of that shape |
| `triage` | Only the failures from a build or test run, read exactly from known formats or judged by the model |
| `summarise_diff` | A diff as one line per file, with review flags: a deleted test, a credential, a binary |
| `draft_change` | A commit message, PR description, or changelog line from a diff |
| `scan_secrets` | Where credentials, and optionally personal data, occur, with the values masked |
| `redact` | The text with them replaced by numbered markers |
| `condense_log` | A log as its distinct messages, ranked by severity; a crash report as what explains it |
| `json_shape` | A JSON document's structure without its data |
| `dependency_audit` | An npm, cargo, or pip audit as what needs action, most severe first |
| `flaky_tests` | Tests that pass in some runs and fail in others |
| `hot_paths` | A profile's folded stacks as where the time goes |
| `set_fact_scope` | Moves a fact of a `respond` thread to the thread or the session, or asks you to keep it as a permanent fact |
| `close_thread` | Frees a `respond` thread |

A failing `swift test` run comes back as a headline and a few `file:line: message` findings; two
minutes of the unified log, 14,333 lines, came back as its top thirty message templates in about 10 KB. The raw output never
leaves the Mac and never enters the calling agent's context. When the model inside `respond` wants to
run a risky command, you are asked through your client's dialog and, at the same time, by a notification
naming `wisp approvals approve <id>`, which answers it from any terminal (a running `wisp-tui` shows it as
its own dialog); the first answer wins. A client with no dialog, such as the Claude mobile app, is approved
that way; a request nobody answers is refused, never run silently. A fact the agent asks you to keep across
sessions reaches you the same way, and you answer with `wisp facts keep <id>` or `drop <id>`; the agent can
never keep one itself. [mcp.md](docs/mcp.md) has each tool's arguments and result.

## Why it is different

**Nothing leaves your machine.** The default model runs on your Apple silicon, so prompts, files, and
command output stay local, and there is no API key, no account, and no bill. Apple's Private Cloud
Compute is an explicit opt-in (`--model private-cloud`), noted on stderr and in the audit log; it needs
an entitlement that an unsigned command-line binary cannot carry, so it is refused from this build
([backends.md](docs/backends.md)). Any model a local Ollama serves can be chosen with `--model
ollama:<name>` when a task needs a larger window than the on-device model's 8k tokens, and a model in MLX
layout with `--model mlx:<name>`, run in wisp's own process on the GPU; `wisp models` lists what will
work, `wisp models pull` fetches an MLX model into the Hugging Face cache after asking, and `wisp models
disable` hides one you do not want offered.

**Every command passes a gate, and the gate is fast.** Before a command runs it must clear a deny list
(`sudo`, `rm -rf /`, piping into a shell, disk tools, starting a wisp of its own), and it runs under a Seatbelt sandbox that
confines writes to the directory wisp was launched in, the temporary directory, and configured build
caches. Then a classifier rates each simple command in the line `safe`, `moderate`, or `dangerous`.
Rules set the floor and a Core ML text classifier, shipped with each release and trained on 2,135
labelled commands, 1,075 of them real, can only raise the level; it answers in under a millisecond
however busy the Mac is. On 996 real commands it rated 817 exactly, against 664 for the on-device
language model at 2.5 seconds a verdict ([approval.md](docs/approval.md)). A command the rules know
to be read-only, such as `git status`, never reaches a classifier at all. You can train a version on
your own history with `wisp classifier train --from-audit`.

**You decide, at the level you choose.** At `moderate` and above wisp asks. Your answer has a scope,
this turn, this session, this project for 30 days, or always for 30 days, and is remembered by the
program and its verb, so approving `git commit` never approves `git push`. A `dangerous` verdict is
never remembered beyond the session, so a stored `rm` approval never covers `rm -rf build`. A dialog
nobody answers is a refusal. `wisp approvals` shows what is remembered; `revoke` and `clear` forget it;
`pending` lists the commands an MCP client's session is waiting on, and `approve` or `deny` answers one.

**You can see exactly what happened.** `~/.wisp/logs/audit.jsonl` records every prompt, reply, tool
call, policy decision, classifier verdict, approval, and command outcome, verbatim, in order. `wisp
logs` reads it, and `respond` returns each turn's receipt folded from the same events, so a calling
agent can check delegated work without reading the log. [trust.md](docs/trust.md) states in one page
what wisp can and cannot do to your Mac.

**It is a microharness.** One binary, one session, a registry of eight tools, and the smallest correct
agent loop; the framework runs the loop and wisp puts the care around it. Your own tools are command
templates in `~/.wisp/config.json`, run through the same gate as everything else
([tools/custom.md](docs/tools/custom.md)). State is a directory, `~/.wisp`, that you can read, edit,
and delete.

## Features, and where to read more

| Area | Feature | Read |
| --- | --- | --- |
| Models | The on-device model by default; Ollama, MLX, and Core AI models by name; Private Cloud Compute as an explicit opt-in | [backends.md](docs/backends.md) |
| | A context window sized from the Mac's free memory for each local model | [wisp.md](docs/wisp.md#context-window), [ADR 0043](docs/decisions/0043-context-window-from-memory.md) |
| | `wisp models`: every model this Mac can run as one table; enable or disable a model, and have its capabilities checked when you enable it | [wisp.md](docs/wisp.md#wisp-models), [ADR 0056](docs/decisions/0056-models-enabled-and-disabled.md) |
| | `wisp models pull`: an MLX model fetched into, or reused from, the Hugging Face cache, after asking | [backends.md](docs/backends.md#mlx-swift), [ADR 0052](docs/decisions/0052-mlx-on-a-par-with-ollama.md) |
| | A reasoning model's thinking shown while it thinks, kept for you and never sent back to the model; `ollama.think` | [ADR 0053](docs/decisions/0053-the-models-thinking-shown.md) |
| Safety | The policy's deny and allow lists, the Seatbelt sandbox, and what a refused write is reported as | [tools/run_command.md](docs/tools/run_command.md), [ADR 0054](docs/decisions/0054-the-sandboxs-refusals-checked.md) |
| | Risk classifiers: rules, the shipped Core ML classifier, or the on-device model | [approval.md](docs/approval.md#classifiers) |
| | **Custom classifiers**: train one on your own audit log or labelled commands, measure it, and switch to it | [wisp.md](docs/wisp.md#wisp-classifier), [approval.md](docs/approval.md#training-and-measuring-a-classifier) |
| | Approvals with a scope (turn, session, project, always), and answering an MCP session's request from another terminal | [approval.md](docs/approval.md#approval-over-mcp-through-another-face) |
| | One page on what wisp can and cannot do to your Mac, and how to undo it | [trust.md](docs/trust.md) |
| Conversation | `wisp chat` and the `wisp-tui` front end; `! command` to run something yourself; save and resume a conversation | [wisp.md](docs/wisp.md#wisp-chat), [ADR 0049](docs/decisions/0049-commands-typed-in-chat.md) |
| | Facts, the running summary, references to earlier output, and the model's `memory` tool (off by default) | [context-management.md](docs/context-management.md#facts), [tools/memory.md](docs/tools/memory.md) |
| | Your own instructions on top of wisp's system prompt, per conversation or for every one | [ADR 0017](docs/decisions/0017-three-layer-instructions.md) |
| | Settings changed from chat (`/config set`) or the command line (`wisp config set`) | [wisp.md](docs/wisp.md#wisp-config) |
| Seeing what happened | The audit log and `wisp logs`; `wisp doctor` | [logging.md](docs/logging.md), [wisp.md](docs/wisp.md) |
| | `ran:` beside every reply, and references to entries that do not exist flagged | [ADR 0051](docs/decisions/0051-the-turns-tool-calls-beside-the-reply.md), [ADR 0055](docs/decisions/0055-cited-entries-checked.md) |
| | What the model carried on any turn, without spending its context (`/inspect context`) | [context-management.md](docs/context-management.md) |
| Everyday jobs | `wisp watch`, `wisp scan`, `wisp redact`, `wisp draft`, and `wisp notify` | [wisp.md](docs/wisp.md) |
| | Notifications from your terminal or its app, with what routes each takes | [tools/notify.md](docs/tools/notify.md), [ADR 0044](docs/decisions/0044-host-effects.md) |
| Extending | **Custom tools**: a command template in `config.json`, run through the same gate | [tools/custom.md](docs/tools/custom.md) |
| | wisp as an MCP server for Claude Code, Codex, or any MCP client | [mcp.md](docs/mcp.md) |
| | A front end of your own over `wisp chat --json` | [wisp.md](docs/wisp.md), [ADR 0029](docs/decisions/0029-tui-front-end.md) |

## Install

An Apple silicon Mac on macOS 27 or later with Apple Intelligence enabled, and Homebrew.

```bash
brew install pidster/tap/wisp   # installs wisp, wisp-tui, and MLX's Metal library
wisp doctor                     # checks the model, MLX, sandbox, classifier, config, home, notifications, and pending requests
wisp "What is the date in Tokyo?"
```

State lives in `~/.wisp`: an optional `config.json` (change it with `wisp config set` or `/config set`
in chat), saved transcripts, remembered approvals, the facts you keep (`facts.json`), the audit log, and
the classifier versions. Upgrade
with `brew upgrade pidster/tap/wisp`; remove with `brew uninstall wisp` and `rm -rf ~/.wisp`.

## Documentation

Everything is under [docs/](docs/README.md). Start with the row that matches your question.

| If you want to… | Read |
| --- | --- |
| Understand what wisp is for and what is out of scope | [objective.md](docs/objective.md) |
| Use the command line: subcommands, flags, `config.json`, exit codes | [wisp.md](docs/wisp.md) |
| See what the model can do and the limits on each tool | [tools/](docs/tools/README.md) |
| Know how well each delegated task works, as measured | [measurements.md](docs/measurements.md) |
| Choose a model or a local backend | [backends.md](docs/backends.md) |
| Connect it to another harness over MCP | [mcp.md](docs/mcp.md) |
| Know what it can do to your Mac, what it remembers, and how to undo | [trust.md](docs/trust.md) |
| Know how commands are confined and when you are asked | [tools/run_command.md](docs/tools/run_command.md), [approval.md](docs/approval.md) |
| Know what the model carries in a long conversation: facts, the summary, references, condensing | [context-management.md](docs/context-management.md), [tools/memory.md](docs/tools/memory.md) |
| Read or query the audit log, or debug wisp itself | [logging.md](docs/logging.md) |
| Understand how the code is put together | [design.md](docs/design.md) |
| Know why a decision was made | [decisions/](docs/decisions/) (one record per decision) |
| Work on the code to the project's standard | [engineering.md](docs/engineering.md) |
| Cut a release | [release.md](docs/release.md) |

A background page records what we learned about the platform:
[policy-and-sandboxing.md](docs/policy-and-sandboxing.md), on what macOS and the framework offer for
confinement.

## Developing wisp

You need macOS 27 and Xcode 27 (the Command Line Tools alone lack the `@Generable` macro plugin), and
Rust 1.98 or later for the terminal front end in `tools/`.

```bash
git clone git@github.com:pidster/wisp.git
cd wisp
scripts/check install-hooks                        # once: enables the pre-commit gate
swift build --package-path harness
harness/.build/debug/wisp tools
harness/.build/debug/wisp "What is the date in Tokyo?"
cargo build --manifest-path tools/Cargo.toml       # wisp-tui, the terminal front end
WISP_BIN=harness/.build/debug/wisp tools/target/debug/wisp-tui
```

To see every tool working together on your Mac, ask wisp to run the functional evaluation in
`functionality-self-test.wisp`. It is a step-by-step guide to wisp's tools and checks, which wisp itself
wrote during a self-test:

```
$ harness/.build/debug/wisp chat
› Read functionality-self-test.wisp and carry out each step, then report pass or fail for each.
```

Expect it to ask before commands that change anything, and to refuse `sudo` by policy. Some probes exit
non-zero when they find nothing: `lsof` on an unused port, and `du` or `find` on folders macOS will not
let them read. One step appends a line to the guide itself to exercise `edit_file`, and the last posts
a notification; `git checkout -- functionality-self-test.wisp` undoes the edit. It is a quick smoke
check, not a measurement; `scripts/check eval` measures the model.

| Path | What it is |
| --- | --- |
| `harness/` | The Swift package: the `wisp` binary, `WispCore`, `WispMCP`, and the model backends |
| `harness/Evals/` | The model evaluations, a package of their own that `scripts/check eval` runs |
| `tools/` | The Cargo workspace: `wisp-tui`, the terminal front end over `wisp chat --json` |
| `docs/` | Documentation and decision records |
| `training/` | Labelled training sets for the fast classifiers, with their reviews |
| `scripts/check` | The quality gate: lint, warnings-as-errors build, tests, hygiene, coverage, model eval |

How we work, in short:

- `scripts/check` is the whole gate and the pre-commit hook runs it. Lint is strict, warnings are
  errors, Swift 6 strict concurrency stays on, and there are no escape hatches.
- Tests never need the model. The model is exercised by running the binary, and by `scripts/check eval`
  for the classifier and every delegated task ([measurements.md](docs/measurements.md)).
- A change is done when it is tested, documented in code, and documented in `docs/`, in the same
  commit. A choice that is non-obvious or hard to reverse gets a decision record.
- Dogfooding: `.mcp.json` registers this repository's own release build (`swift build -c release`) as
  an MCP server, so Claude Code sessions here use it.

[engineering.md](docs/engineering.md) is the full standard, and [AGENTS.md](AGENTS.md) the orientation
given to AI agents working in this repository.
