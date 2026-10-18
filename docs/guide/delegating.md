# Delegating from Claude Code and Codex

`wisp mcp` makes wisp an MCP server over stdio, so a coding agent can hand it the local work that would
otherwise fill the agent's own context: run the tests and return the failures, condense a log, summarise a diff,
draft a commit message. The raw material stays on the Mac; the agent gets back something small. This guide sets
it up and walks through the patterns that work. [The MCP server](../mcp.md) is the reference for every tool,
argument, result field, and resource.

## Register the server

Claude Code reads `.mcp.json` in a project (or your user configuration):

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

Codex reads `~/.codex/config.toml`:

```toml
[mcp_servers.wisp]
command = "/opt/homebrew/bin/wisp"
args = ["mcp"]
```

`/opt/homebrew/bin/wisp` is where Homebrew links it on Apple silicon; `which wisp` says where yours is. Restart the
agent, or in Claude Code run `/mcp`, and the server's tools appear: in Claude Code as `mcp__wisp__respond` and
the like. Codex needs wisp 0.1.5 or later, which accepts the `experimental` capability Codex sends at start-up
([The MCP server](../mcp.md#client-compatibility)).

`wisp mcp` takes the flags `respond` and `chat` take (`--model`, `--tool`, `--instructions`, `--no-tools`,
`--yes`, `--unsafe`), as defaults for every thread; a `respond` call can choose its own when its thread starts.

## What the agent gets

| Tool | Gives back |
| --- | --- |
| `respond` | The model's reply to a task, run with wisp's tools on a named thread the agent can continue; with a JSON Schema, a reply of that shape |
| `triage` | Only the failures from a build or test run, read exactly from known formats or judged by the model |
| `summarise_diff`, `draft_change` | A diff as a line per file with review flags; a commit message, PR description, or changelog line |
| `scan_secrets`, `redact` | Where credentials and personal data occur, values masked; the text with them replaced by markers |
| `condense_log`, `json_shape` | A log as its distinct messages ranked by severity; a JSON document's structure without its data |
| `dependency_audit`, `flaky_tests`, `hot_paths` | An npm, cargo, or pip audit as what needs action; tests that pass in some runs and fail in others; where a profile's time goes |
| `set_fact_scope`, `close_thread` | Moves a thread's fact, or asks you to keep it as permanent; frees a thread |

wisp's own tools (`run_command`, `read_file`, `edit_file`, `system_info`, and the rest) are not MCP tools. The
agent reaches them only by asking `respond`, so every command runs as a turn of wisp's model, under the policy,
the sandbox, the classifier, your approval, and the audit ([ADR 0006](../decisions/0006-mcp-server-over-stdio.md)).
The agent can read what the model can do from the `wisp://tools` resource (or `wisp tools --markdown` at a
terminal), which gives each tool's arguments, limits, and a prompt shape that works.

## Threads

`respond` runs on a thread. Name one with `thread_id` and pass the same id to continue it; omit it and wisp makes
one up and returns it. A thread is a conversation of its own, with its own facts, summary, and record; the server
holds up to 32 (`maxThreads`) in memory, dropping the least recently used, and `close_thread` frees one when the
work is done. Every thread is saved after each turn, so naming it again after a reconnect, a new build, or a
dropped thread resumes it with its own settings, and the result says `resumed: true`
([mcp.md](../mcp.md), "Saved and resumed threads"). A thread belongs to the client that opened it, and one wisp
holds it at a time.

Five arguments shape a thread and are taken only when it starts; on an existing or saved thread they are accepted
only when they equal the thread's own, so a client may send them on every call, and different ones are an error
naming them:

| Argument | Use it for |
| --- | --- |
| `instructions` | The conversation's own instructions, added under wisp's system prompt and the operator's extension ([ADR 0017](../decisions/0017-three-layer-instructions.md)) |
| `tools` | Exactly the tools the task needs: `["run_command"]` for a thread that only runs commands, `[]` for text only. Every tool's schema is in every prompt, so fewer is better on a small window |
| `model` | `system` (the default), or a local model such as `ollama:granite4.1:8b` ([Local models](local-models.md)) |
| `think` | `false` keeps a thinking model from thinking, for fixed quick tasks; `true` or a level for a hard one |
| `commandTimeoutSeconds` | A longer limit for the thread's commands, such as `600` for one that commits through a slow pre-commit hook; capped by the operator's `commandMaxTimeoutSeconds`, 1,800 s by default ([ADR 0063](../decisions/0063-command-time-limits.md)) |

`task` (a sentence the model sees beside each request) can be given at any call, and `schema` shapes one reply.

Each result carries the reply and, in `structuredContent`, a receipt of what the turn did: `ran` (what was
called, counted from the audit log), `calls` (each call, its output inline when small and otherwise a
`wisp://threads/{thread_id}/output/{id}` reference), `refusals`, and `verification`, which names any result the
reply reports that no call produced ([What wisp checks beside a reply](../verification.md)). An agent that checks
`ran` and `verification` before trusting a reply catches a model that says it ran something it did not.

## The condensing tools

The condensing tools need no thread and keep their input on the Mac. `triage` is the one to reach for first:
given a command, it runs it through the same gate as `run_command` and returns a headline and the failures:

```json
{ "command": "swift test 2>&1", "working_directory": "/Users/me/src/project" }
```

Most failures are read exactly from known formats (Swift and clang diagnostics, swift-testing, rustc, cargo test,
pytest, go test), with no model turn at all; the model judges only what those do not explain
([ADR 0039](../decisions/0039-exact-condensers.md)). Given `path` instead of `command`, it reads an output file
already on the Mac. The other tools take the text, a path, or a command in the same spirit; each one's arguments
are in [the reference](../mcp.md#tools), with what was measured of it.

## Approvals reach you, never the agent

When the model inside `respond` wants to run something risky, wisp asks you two ways at once, and the first answer
wins ([ADR 0046](../decisions/0046-approval-and-notifications-over-mcp.md)):

- **Your client's dialog**, when it supports MCP elicitation (Claude Code does). Accept runs the command with the
  scope chosen in the form; Decline refuses it.
- **Another of wisp's faces.** The request waits in `~/.wisp/pending`, and if the dialog has not been answered
  within 10 seconds (`approval.bannerDelaySeconds`) a notification names it: "wisp: approval needed", with the
  command and `wisp approvals approve <id>`. Answer from any terminal, in a running `wisp-tui`, or with
  `/approvals approve <id>` in a plain `wisp chat`.

```bash
wisp approvals pending
wisp approvals approve a1b2c3d4 --scope session
wisp approvals deny a1b2c3d4
```

Nothing in the MCP conversation can approve a command, so the agent cannot answer for you: wisp's own model is
refused `wisp approvals approve|deny` by policy, and those commands run only with a terminal on standard input.
A request nobody answers within `approval.timeoutSeconds` (600 s) is refused. The same channel carries a fact the
agent asks you to keep (`wisp facts keep|drop`) and, when the thread has the `ask` tool, the model's question to
you (`wisp questions answer|decline`); an agent should tell you such an id and wait, never answer it itself.
[Approvals and the sandbox](approvals-and-sandbox.md) covers what is asked and what each scope covers.

## A worked example: a thread for git

This repository runs every git command its agents issue through wisp, as a dogfooding rule (`AGENTS.md`,
"Working through wisp's MCP server"), so each one is classified, sandboxed, approved, and audited. The pattern
suits any fixed, repeated job. Open one thread and reuse it:

```json
{
  "thread_id": "git",
  "tools": ["run_command"],
  "model": "ollama:granite4.1:8b",
  "commandTimeoutSeconds": 600,
  "instructions": "You run git commands for a coding assistant. Run exactly the command line given between backticks, once, in the working directory given, with the run_command tool. Do not modify the command, add flags, or run anything else. Reply with the exit status and the output verbatim, and nothing else.",
  "prompt": "Use run_command with working directory /Users/me/src/project to run exactly the command line between the backticks:\n`git status --short`\nReport the exit status and output verbatim, nothing else."
}
```

Why each part is there:

- **`tools: ["run_command"]`** leaves the model nothing else to reach for.
- **`ollama:granite4.1:8b`** follows a fixed instruction reliably, at about 2 s a request, and its window is far
  larger than the on-device model's 8,192 tokens, so the thread survives many commits ([Local models](local-models.md)).
  Without Ollama, use `system` and keep prompts short.
- **`commandTimeoutSeconds: 600`**: a pre-commit hook that runs a project's whole test suite can pass the default
  120 s.
- **The command between backticks** keeps a trailing full stop from being taken as part of it.

Later calls pass only `thread_id` and `prompt`. Put a commit message in a file and commit with
`set -o pipefail; git commit -q -F /tmp/msg 2>&1 | tail -3`, so a hook's output does not fill the reply, and keep
`pipefail` wherever output is piped: without it the exit status is `tail`'s, and a failed push reports 0. The
first `git commit` or `git push` on the thread asks for approval; answering "This session" covers the same shape
for the rest of the server's life; a resumed thread asks again. `close_thread` with `thread_id: "git"` ends it and
deletes it from the thread store.

## When the server does not connect

The usual causes are a wrong `command` path and an old wisp; [Troubleshooting](troubleshooting.md) has the rest,
including a dialog that seems stuck and, for contributors, the release build this repository's own `.mcp.json`
runs.
