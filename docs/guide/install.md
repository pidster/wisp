# Install and first run

This guide takes you from nothing to a first answer, a first approval, and a conversation. The
[command reference](../wisp.md) has every flag; this page has the path through them.

## What you need

| Requirement | Why |
| --- | --- |
| An Apple silicon Mac on macOS 27 or later | wisp is built on the Foundation Models framework of macOS 27 ([ADR 0002](../decisions/0002-macos-27-baseline.md)); the on-device model needs Apple silicon |
| Apple Intelligence turned on in System Settings, and its model downloaded | The default model is Apple's on-device model; until it is ready, wisp has no model to run unless you add one of your own ([Local models](local-models.md)) |
| Homebrew | wisp is released through a Homebrew tap ([ADR 0012](../decisions/0012-homebrew-release.md)) |

Nothing else: no API key, no account, and no network for generation.

## Install

```bash
brew install pidster/tap/wisp
```

That installs three things: `wisp`, `wisp-tui` (the terminal front end `wisp chat` hands a terminal session to),
and MLX's Metal library, `mlx.metallib`, beside `wisp` in Homebrew's `libexec`, which wisp needs to run MLX models
([ADR 0047](../decisions/0047-mlx-in-the-release.md)). Homebrew also installs the shell completions for zsh, bash,
and fish. The binary is unsigned; Homebrew does not quarantine what it downloads, so Gatekeeper does not stop it.

Upgrade with `brew upgrade pidster/tap/wisp`, remove it with `brew uninstall wisp`, and delete `~/.wisp` to
forget everything it kept ([What wisp can do to your Mac](../trust.md), "Undoing").

## Check the install: `wisp doctor`

```bash
wisp doctor
```

`wisp doctor` checks what a working install needs and exits non-zero when anything fails: macOS 27, the
on-device model answering a one-word request, the risk classifier, MLX's Metal library, `sandbox-exec`, your
`config.json`, and a writable `~/.wisp`, along with the state wisp keeps. Each line is `ok` or not, with a detail.
From a development build of 0.24.2 with a fresh home, on 2026-10-14 (a Homebrew install names its own paths):

```
ok   macOS: 27.0.0
ok   model: on-device model available and answers
ok   classifier: coreml model risk@0.24.2-default (shipped) prepares
ok   context window: 8,192 tokens, reported by the framework
ok   MLX: Metal library …/default.metallib loads
ok   sandbox: /usr/bin/sandbox-exec present
ok   config: no …/config.json; defaults apply
…
ok   home: … writable
```

A line that is not ok says what to do; [Troubleshooting](troubleshooting.md) covers the common ones, and the
[reference](../wisp.md#wisp-doctor) lists every finding.

## Ask it something

```bash
wisp "What is the date in Tokyo?"
wisp "What is listening on port 8080, and how much disk is free?"
```

A bare `wisp "…"` is `wisp respond`: one prompt in, one reply out, streamed. Under the reply wisp prints what the
turn ran (`ran: …`), counted from its own audit log rather than from what the model says
([What wisp checks beside a reply](../verification.md)).

Some tasks change state. Running a project's tests, for one, is a `moderate` action, and a one-shot `wisp "…"`
has no way to ask you, so it refuses the command and the reply says so. Pass `--yes` when you mean it:

```bash
wisp --yes "Run the tests in $PWD and tell me if they pass"
```

`--yes` removes only the question. The deny list, the sandbox, the classifier, and the audit still apply
([Approvals and the sandbox](approvals-and-sandbox.md)).

## A conversation: `wisp chat`

```bash
wisp chat
```

On a terminal, with `wisp-tui` installed beside `wisp` (Homebrew's install has it), `wisp chat` hands the session to
`wisp-tui`: the conversation scrolls in your terminal's own history above a pinned input and status line, and the
model's tool calls show as they happen. `wisp chat --plain` keeps the plain line-based chat, and a piped session is
always plain. `wisp doctor`'s `front end` line says which you will get.

What to try first:

| Type | What happens |
| --- | --- |
| A message | The model answers, calling tools when they help |
| `/help` | Every chat command |
| `! git status` | Runs `git status` yourself, in the sandbox, without asking; the model is told what you ran on its next request ([ADR 0049](../decisions/0049-commands-typed-in-chat.md)) |
| `!!brew upgrade` | Runs it yourself outside the sandbox, for a chore the sandbox refuses; chat says so before it starts ([Approvals and the sandbox](approvals-and-sandbox.md#outside-the-sandbox-one-command-at-a-time)) |
| `/model [name]` | With no name, the model in use and what it can do; with one, switches the conversation to it |
| `/inspect context next` | What the model's next request carries, entry by entry, at no model cost |
| Ctrl-C during a reply | Stops the turn and any command it started |
| `/quit` | Leaves, saving the transcript when it has a name (`--save`, `--resume`) |

When the model asks to run a risky command, chat shows the level, the command, the directory, and the reasons,
and asks once: `[y]once [s]ession [p]roject 30d [a]lways 30d [n]o`. What each answer covers is in
[Approvals and the sandbox](approvals-and-sandbox.md).

## Where wisp keeps things

Everything wisp keeps is in `~/.wisp`, or in `$WISP_HOME` when it is set: an optional `config.json`, saved
transcripts, remembered approvals, permanent facts, the audit log (`logs/audit.jsonl`), large tool outputs, and
classifier versions. The [reference](../wisp.md#home-directory-and-configuration) lists every path. To try wisp
without touching your real state, point `WISP_HOME` at a scratch directory:

```bash
export WISP_HOME=/tmp/wisp-scratch
wisp doctor
```

## Next

- Let your coding agent use it: [Delegating from Claude Code and Codex](delegating.md).
- A larger window and stronger tool use: [Local models](local-models.md).
- One-job subcommands that need no prompt (`wisp scan`, `wisp redact`, `wisp watch`, `wisp draft`,
  `wisp notify`): the [command reference](../wisp.md#subcommands).
