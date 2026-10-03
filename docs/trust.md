# What wisp can do to your Mac, and how you stay in control

This page answers the questions a careful person asks before letting an agent run commands: what it can
touch, what leaves the machine, what it remembers, how to see what happened, and how to undo. Every claim
here is enforced by code and covered by tests; the linked pages hold the detail.

## What runs, and where

The model has eight tools: `current_date`, `read_file`, `inspect`, `notify`, `system_info`, `memory`,
`edit_file`, and `run_command`. Only the last two change anything on the Mac; `notify` shows a banner, at
most a few a minute, through your terminal or `osascript`, and changes nothing ([notify](tools/notify.md));
`memory` reads only the conversation's own record and the audit log, and writes only the model's own facts
about the conversation, which rank below yours and a tool's and never reach the shared store without you
([memory](tools/memory.md)); `system_info` runs fixed read-only commands wisp chooses,
under the sandbox but without asking, since the model supplies no command ([system_info](tools/system_info.md)).
Tools you declare yourself in `~/.wisp/config.json` run their command through `run_command`'s policy,
classifier, approval, and sandbox, so they grant nothing `run_command` does not; a project cannot
declare one ([custom tools](tools/custom.md)). `edit_file` writes a text file under the same directories the sandbox allows
([edit_file](tools/edit_file.md)). `run_command` runs a shell command through `/bin/sh -c` with wisp's
own privileges, inside a Seatbelt sandbox ([run_command](tools/run_command.md)):

| The sandbox confines | It does not confine |
| --- | --- |
| **Writes**: only under the directory wisp was launched in, the temporary directory, `/private/tmp`, and configured build caches. A command's own working directory never widens this, and `edit_file` is held to the same list. | **Reads**: any file the user can read. `read_file` and `run_command` can read your home directory. Credential-like paths ask first. |
| **Network**, only if you set `sandbox.allowNetwork: false`. | **Network by default**: on, because builds fetch dependencies. |
| **The process tree**: a timeout kills the whole group. | **Inter-process messaging and the rest of macOS**: unchanged. |

Before a command runs it must also pass a deny list (`sudo`, `rm -rf /`, piping into a shell, disk
tools) and a risk check.

## What leaves the machine

Nothing, with the default model. The on-device model runs on your Apple silicon; prompts, files, and
command output stay local.

If you choose `--model private-cloud`, prompts and tool output go to Apple's Private Cloud Compute under
Apple's privacy guarantees. wisp prints a note on stderr when that model is selected and records it in
every session's audit event. The risk classifier always runs on the Mac (the on-device model or a Core
ML classifier), whatever the session runs on ([ADR 0013](decisions/0013-model-selection.md)).

## When you are asked

Every simple command in a line is classified `safe`, `moderate`, or `dangerous` by rules plus an
on-device classifier, by default the Core ML classifier the release ships, or the on-device model
(`approval.classifier`); a short list of
read-only commands the rules know, such as `ls` or `git status`, is `safe` without asking a classifier
([approval](approval.md)). At `moderate` and above a person is asked: on the terminal in
`chat`, in `wisp-tui`'s dialog, and never in plain `wisp "…"`, which refuses instead unless you pass
`--yes`. Under `wisp mcp` you are asked through your MCP client's dialog when it has one and, at the same
time, by a notification: answer with `wisp approvals approve <id>` or `deny <id>` in a terminal, or in a
running `wisp-tui`, and the first answer wins.

**Who can approve, and where.** Only you, in one of wisp's own faces: the chat's prompt, `wisp-tui`'s
dialog, `wisp approvals` at a terminal, or your MCP client's dialog. The agent that called wisp cannot:
nothing in the MCP conversation approves a command, and the answer is bound to the exact command,
directory, and thread you were shown. wisp's own model cannot: its commands cannot write `~/.wisp` from
the sandbox, and the default policy refuses `wisp approvals approve|deny`. `wisp approvals approve` and
`deny` refuse to run without a terminal on standard input, which an agent's shell tool does not give; that
is a hurdle, not a wall, so keep your agent's own approval for shell commands on
([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)).

Your answer has a scope. "This turn" covers the rest of the current prompt. "This session" covers the
process. "This project" and "Always" are written to `~/.wisp/approvals.json` for 30 days, keyed by the
program (`head *`), never by exact arguments and never for a dangerous verdict. `wisp approvals` lists
them; `wisp approvals revoke <id>` and `clear` remove them. A dialog nobody answers within ten minutes
counts as a refusal.

**Who keeps a permanent fact, and where.** Only you. A permanent fact (a codename, a settled decision, a
preference) is written to `~/.wisp/facts.json` and given to every conversation, so wisp never writes one on
anyone else's word. In chat you state one or move one there (`/fact ID permanent`). An agent calling
`wisp mcp` can only ask: you are told by a notification ("wisp: keep as a permanent fact?") and answer with
`wisp facts keep <id>` or `drop <id>` in a terminal, or in a running `wisp-tui`. The rules are the ones for
approval above: nothing in the MCP conversation answers, the answer is bound to the exact fact you were
shown, wisp's own model is refused `wisp facts keep|drop` by the default policy, and both run only with a
terminal on standard input. Unanswered, nothing is kept. A caller cannot change or remove a permanent fact;
only you can, from chat ([ADR 0048](decisions/0048-permanent-facts-over-mcp.md)).

## Switches that remove protection

| Switch | Removes | Leaves |
| --- | --- | --- |
| `--yes` | every human approval | deny list, sandbox, classification, audit |
| `--unsafe` | the deny list and the sandbox | approval, classification, audit |
| `approval.threshold: "never"` | approval prompts | everything else |
| `--model private-cloud` | on-device only | approval, sandbox, audit |

Both flags print a warning on stderr. There is no switch that turns off the audit log except
`audit.enabled: false` in `config.json`.

## Seeing what happened

`~/.wisp/logs/audit.jsonl` records every prompt, reply, tool call and result, policy decision,
classifier verdict, approval, and command outcome, verbatim, in the order they happened, user-only on
disk. `wisp logs` reads it; `wisp logs --kind approval.decided` shows every approval and what it was
remembered as ([logging](logging.md)).

## Undoing

- Revoke a remembered approval: `wisp approvals revoke <id>` or `wisp approvals clear`.
- Forget a conversation: delete `~/.wisp/transcripts/<name>.json` and `<name>.store`.
- Forget a fact: `/fact delete <id>` in chat; delete `~/.wisp/facts.json` to forget every permanent fact.
  Only you put facts there: what a tool or the model proposes waits for you to move it, and what an MCP
  caller asks for waits for `wisp facts keep`.
- Remove everything wisp keeps: delete `~/.wisp`. Nothing else is written outside the sandbox's
  writable set.
- Uninstall: `brew uninstall wisp`.

## Files wisp writes

| Path | Contents | Permissions |
| --- | --- | --- |
| `~/.wisp/config.json` | your settings, written by you or by `wisp config set` and chat's `/config set` | yours; user-only once wisp writes it |
| `~/.wisp/logs/audit.jsonl` | the audit log, rotated | user-only |
| `~/.wisp/approvals.json` | remembered approvals | user-only |
| `~/.wisp/pending/` | commands waiting for your approval under `wisp mcp`, facts a caller asked you to keep, and your answers, until taken | user-only (directory 0700, files 0600) |
| `~/.wisp/transcripts/*.json`, `*.store` | saved chats, and each one's links to the audit log | user-only |
| `~/.wisp/facts.json` | permanent facts: the ones you stated or kept, which every conversation is given | user-only |
| `~/.wisp/context/` | the exact context a model saw, saved by `/inspect context` and around each condensation | user-only |
| `~/.wisp/classifiers/risk/` | risk classifier versions: the release's default and those `wisp classifier train` makes | models read-only |
