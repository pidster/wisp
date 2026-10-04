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
tools, answering an approval, keeping a permanent fact, fetching a model, and starting a wisp agent of its own: `wisp respond`,
`chat`, `mcp`, or `wisp "prompt"`) and a risk check.

**What the model is told when the sandbox refuses.** The sandbox fails a refused operation with `Operation not
permitted` and says nothing else. wisp checks the paths in that error against the writable roots and tells the
model plainly: that the sandbox refused writing to a path and where it may write; that a path inside the roots was
refused by something else; or, when the error names no path, that the sandbox may have refused it and no policy
rule did, since the policy let the command run
([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md), [run_command](tools/run_command.md)).

**Commands you type yourself.** In `wisp chat` and `wisp-tui`, a line that starts with `!` (`! git status`)
runs that command as yours, through the same runner as `run_command`
([ADR 0049](decisions/0049-commands-typed-in-chat.md)). It passes the same deny and allow lists and runs
under the same sandbox, with the same bounds and timeout, so it can change only what the model's commands
can: files under the sandbox's writable directories, and the network unless you turned it off. It skips the
risk check and is never put to you for approval, since typing it is the approval, so it runs at once
whatever its level. The deny list includes a nested wisp agent here too: `! wisp respond …` is refused with
its reason, where under the sandbox it would only fail, unable to write `~/.wisp`; run it in another terminal.
It is audited (`command.typed`, and `policy.decision` and `command.outcome` marked
`origin: "person"`), and the model is told on its next request that you ran it, never that it did. `--unsafe`
removes the deny list and the sandbox for these commands too. An MCP caller cannot type one: `respond`
gives `!` to the model as text.

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

wisp downloads a model only when you run `wisp models pull mlx-community/<name>` in a terminal and answer yes
after it has said which files, how many bytes, and where. It fetches from `mlx-community` alone, only the files
a model directory needs, and checks each against Hugging Face's listing; wisp's own model is refused the
command by the default policy. The files go into the Hugging Face cache, shared with Hugging Face's own tools,
and the models directory links to them; a directory already there is moved to the Trash only if you answer yes
to a second question ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)).

Turning a model off (`wisp models disable`, `/models` in chat, `wisp-tui`'s picker) changes only
`models.disabled` in `config.json`, and turning one on takes it out of that list. Enabling a complete MLX model already in the Hugging Face cache links it and
downloads nothing. Enabling an MLX model whose capabilities `config.json` does not declare, or `wisp models check`,
loads the model into wisp's own process and asks it three short questions, each within a time limit, with no tool
of wisp's: the only tool it is offered is the check's own `record_word`, which records a word and touches nothing.
What passes is written to `config.json` (`mlx.models.<name>`) and audited as `model.verified`
([ADR 0056](decisions/0056-models-enabled-and-disabled.md)).

## Switches that remove protection

| Switch | Removes | Leaves |
| --- | --- | --- |
| `--yes` | every human approval | deny list, sandbox, classification, audit |
| `--unsafe` | the deny list and the sandbox, for the model's commands and the ones you type after `!` | approval, classification, audit |
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
  writable set, except the models you pulled into the Hugging Face cache, which Hugging Face's own tools share;
  delete `<cache>/models--mlx-community--<name>` to remove one.
- Uninstall: `brew uninstall wisp`.

## Files wisp writes

| Path | Contents | Permissions |
| --- | --- | --- |
| `~/.wisp/config.json` | your settings, written by you, by `wisp config set` and chat's `/config set`, and by `wisp models enable`, `disable`, and `check` and chat's `/models` (`models.disabled`, and the capabilities a check passed) | yours; user-only once wisp writes it |
| `~/.wisp/models/mlx/<name>` | links to the Hugging Face cache's snapshots, made by `wisp models pull` and by enabling a cached model | links |
| the Hugging Face cache (`HF_HUB_CACHE`, `$HF_HOME/hub`, or `~/.cache/huggingface/hub`) | the files `wisp models pull` fetched, in Hugging Face's own layout | readable by all (0644) |
| `~/.wisp/logs/audit.jsonl` | the audit log, rotated | user-only |
| `~/.wisp/approvals.json` | remembered approvals | user-only |
| `~/.wisp/pending/` | commands waiting for your approval under `wisp mcp`, facts a caller asked you to keep, and your answers, until taken | user-only (directory 0700, files 0600) |
| `~/.wisp/transcripts/*.json`, `*.store` | saved chats, and each one's links to the audit log | user-only |
| `~/.wisp/facts.json` | permanent facts: the ones you stated or kept, which every conversation is given | user-only |
| `~/.wisp/context/` | the exact context a model saw, saved by `/inspect context` and around each condensation | user-only |
| `~/.wisp/classifiers/risk/` | risk classifier versions: the release's default and those `wisp classifier train` makes | models read-only |
