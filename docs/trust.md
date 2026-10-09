# What wisp can do to your Mac, and how you stay in control

This page answers the questions a careful person asks before letting an agent run commands: what it can
touch, what leaves the machine, what it remembers, how to see what happened, and how to undo. Every claim
here is enforced by code and covered by tests; the linked pages hold the detail.

## What runs, and where

The model has eight tools: `current_date`, `read_file`, `inspect`, `notify`, `system_info`, `memory`,
`edit_file`, and `run_command`. Only the last two change anything on the Mac; `notify` shows a banner, at
most a few a minute, through your terminal or `osascript`, and changes nothing ([notify](tools/notify.md));
`memory`, which a conversation has only with `context.memory` on or a tool list that names it (off by default),
reads only the conversation's own record and the audit log, and writes only the model's own facts
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
| **Writes**: only under the directory wisp was launched in, the temporary directory, `/private/tmp`, and configured build caches. A command's own working directory never widens this, and `edit_file` is held to the same list. Never wisp's own home (`~/.wisp`), wherever it is. | **Reads**: any file the user can read. `read_file` and `run_command` can read your home directory. Credential-like paths ask first. |
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

An MLX or Core AI model runs in wisp's own process, on the Mac. An Ollama, llama.cpp, or LM Studio model
runs in that runtime's server, and wisp sends it every request over HTTP: the conversation, the tools'
descriptions, and their output. By default each server is on this Mac (`http://127.0.0.1:11434`,
`:8080`, and `:1234`), so nothing leaves it. `ollama.baseURL`, `llamacpp.baseURL`, and `lmstudio.baseURL`
take any address, and wisp does not check that one is local: pointed at another machine, prompts, files the
model reads, and command output go to that machine. A llama.cpp or LM Studio key (`WISP_LLAMACPP_API_KEY`,
`WISP_LMSTUDIO_API_KEY`, or `apiKey` in `config.json`) is sent to that server alone, as `Authorization`, and
never logged or shown ([ADR 0058](decisions/0058-a-shared-http-executor.md)).

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
directory, and thread you were shown. wisp's own model cannot: the sandbox denies its commands any write to
`~/.wisp` even when that lies inside the writable set, `edit_file` refuses it, and the default policy refuses
`wisp approvals approve|deny`, quoted or behind a wrapper. `wisp approvals approve` and
`deny` refuse to run without a terminal on standard input, which an agent's shell tool does not give; that
is a hurdle, not a wall, so keep your agent's own approval for shell commands on
([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)).

Your answer has a scope. "This turn" covers the rest of the current prompt. "This session" covers the
process. "This project" and "Always" are written to `~/.wisp/approvals.json` for 30 days, keyed by the
program (`head *`), never by exact arguments and never for a dangerous verdict. An approval covers only
commands judged at its level or below: approving a moderate `rm` never approves `rm -rf`, and a dangerous
command is remembered for the turn or session by its exact text alone. A shell keyword or an interpreter
(`do`, `sh`, `python3`, …) is always remembered by its exact text. `wisp approvals` lists them; `wisp approvals revoke <id>` and `clear` remove them. A dialog nobody answers within ten minutes
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

wisp downloads a model only when you run `wisp models pull <organisation>/<name>` in a terminal and answer yes
after it has said which files, how many bytes, and where. It fetches only the files a model directory needs, with
plain names, and checks each against Hugging Face's listing; wisp's own model is refused the command by the
default policy. The files go into the Hugging Face cache, shared with Hugging Face's own tools,
and the models directory links to them; a file cut off part-way resumes from where it stopped and is checked
whole, and the intact files of a real directory already at `~/.wisp/models/mlx/<name>` are copied into the cache
instead of fetched again; a directory already there is moved to the Trash only if you answer yes
to a second question ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)).

**A model from a publisher you have not trusted.** Any Hugging Face organisation can be pulled, but only one in
`mlx.trustedPublishers` (`mlx-community`, the organisation that publishes MLX conversions, always is) is pulled
without asking who published it. For any other, the pull first names the publisher, the repository, the licence
the Hub gives (or `unknown`), and the download, and refuses unless you answer `o` (this once) or `t` (trust the
publisher from now on, written to `config.json`); without a terminal it is refused unless you pass
`--trust-publisher`. What you are agreeing to: the publisher's weights, tokenizer files, and chat template are
loaded into wisp's own process and run whenever you choose `mlx:<name>`. They are data, not programs: the weights
are `safetensors` (tensors and a JSON header, no pickled code), the model's architecture is one of those built
into wisp (mlx-swift-lm's, picked by `model_type` in `config.json`; a repository cannot supply its own code), and
the chat template is Jinja rendered by wisp's own interpreter (swift-jinja, through swift-transformers), which has
no access to files, the network, or processes. What a hostile or careless publisher can still do: give you a
model that answers badly or misleadingly, or a template that adds text of its own to every prompt, such as
instructions to call tools; ask for commands, which pass the policy, the sandbox, the classifier, and your
approval like any model's; or ship files crafted against a bug in the parsers that read them. The licence shown is
what the publisher declared, not a check of it. The name rules, the file rules, the size and digest checks, and
the link rules are the same for every publisher, and each decision is audited as `model.publisher`
([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), amended 2026-10-09).

Turning a model off (`wisp models disable`, `/models` in chat, `wisp-tui`'s picker) changes only
`models.disabled` in `config.json`, and turning one on takes it out of that list. Enabling a complete MLX model already in the Hugging Face cache links it and
downloads nothing. Enabling an MLX model whose capabilities `config.json` does not declare, or `wisp models check`,
loads the model into wisp's own process and asks it three short questions, each within a time limit, with no tool
of wisp's: the only tool it is offered is the check's own `record_word`, which records a word and touches nothing.
What passes is written to `config.json` (`mlx.models.<name>`) and audited as `model.verified`
([ADR 0056](decisions/0056-models-enabled-and-disabled.md)). A llama.cpp model is checked the same way, through its
server, and what passes is written under `llamacpp.models.<name>`.

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
  writable set, except the models you pulled into the Hugging Face cache, which Hugging Face's own tools share
  (delete `<cache>/models--<organisation>--<name>` to remove one), and the completion script `wisp completions
  install` wrote for your shell (delete the file it named).
- Uninstall: `brew uninstall wisp`.

## Files wisp writes

| Path | Contents | Permissions |
| --- | --- | --- |
| `~/.wisp/config.json` | your settings, written by you, by `wisp config set` and chat's `/config set`, and by `wisp models enable`, `disable`, and `check` and chat's `/models` (`models.disabled`, and the capabilities a check passed), and by `wisp models pull` when you trust a publisher (`mlx.trustedPublishers`) | yours; user-only once wisp writes it |
| `~/.wisp/models/mlx/<name>` | links to the Hugging Face cache's snapshots, made by `wisp models pull` and by enabling a cached model | links |
| the Hugging Face cache (`HF_HUB_CACHE`, `$HF_HOME/hub`, or `~/.cache/huggingface/hub`) | the files `wisp models pull` fetched, in Hugging Face's own layout | readable by all (0644) |
| `~/.zsh/completions/_wisp`, bash-completion's or fish's per-user completions directory | the shell completion script, only when you run `wisp completions install`; it replaces only a file wisp wrote ([wisp.md](wisp.md), "`wisp completions`") | your default (umask) |
| `~/.wisp/logs/audit.jsonl` | the audit log, rotated | user-only |
| `~/.wisp/approvals.json` | remembered approvals | user-only |
| `~/.wisp/pending/` | commands waiting for your approval under `wisp mcp`, facts a caller asked you to keep, and your answers, until taken | user-only (directory 0700, files 0600) |
| `~/.wisp/transcripts/*.json`, `*.store` | saved chats, and each one's links to the audit log | user-only |
| `~/.wisp/facts.json` | permanent facts: the ones you stated or kept, which every conversation is given | user-only |
| `~/.wisp/context/` | the exact context a model saw, saved by `/inspect context` and around each condensation | user-only |
| `~/.wisp/classifiers/risk/` | risk classifier versions: the release's default and those `wisp classifier train` makes | models read-only |
