# What wisp can do to your Mac, and how you stay in control

This page answers the questions a careful person asks before letting an agent run commands: what it can
touch, what leaves the machine, what it remembers, how to see what happened, and how to undo. Every claim
here is enforced by code and covered by tests; the linked pages hold the detail.

## What runs, and where

The model has ten tools: `current_date`, `read_file`, `inspect`, `notify`, `system_info`, `memory`, `models`, `ask`,
`edit_file`, and `run_command`. Only the last two change anything on the Mac by themselves; `ask` puts a question
to you and changes nothing (off by default; who answers it is below); `models` asks you
before it pulls, enables, disables, or checks a model (below); `notify` shows a banner, at
most a few a minute, through `Wisp Notifier.app` once you allow it, your terminal, or `osascript`, and changes
nothing ([notify](tools/notify.md));
`memory`, which a conversation has only with `context.memory` on or a tool list that names it (off by default),
reads only the conversation's own record and the audit log, and writes only the model's own facts
about the conversation, which rank below yours and a tool's and never reach the shared store without you
([memory](tools/memory.md)); `models`, which a conversation has only with `tools.models` on or a tool list that
names it (off by default), lists the models and shows one freely, asks you for every pull and for each enable,
disable, or check, and is refused trusting a publisher or switching the model ([models](tools/models.md));
`system_info` runs fixed read-only commands wisp chooses,
under the sandbox but without asking, since the model supplies no command ([system_info](tools/system_info.md)).
Tools you declare yourself in `~/.wisp/config.json` run their command through `run_command`'s policy,
classifier, approval, and sandbox, so they grant nothing `run_command` does not; a project cannot
declare one ([custom tools](tools/custom.md)).
`edit_file` writes a text file under the same directories the sandbox allows; a line edit keeps each line's
own ending (CRLF, CR, or LF), and a guard refuses, with nothing written, any edit that would change a line it does
not name ([edit_file](tools/edit_file.md), [ADR 0024](decisions/0024-edit-file.md)).
`run_command` runs a shell command through `/bin/sh -c` with wisp's
own privileges, inside a Seatbelt sandbox ([run_command](tools/run_command.md)):

| The sandbox confines | It does not confine |
| --- | --- |
| **Writes**: only under the directory wisp was launched in, the temporary directory, `/private/tmp`, and configured build caches. A command's own working directory never widens this, and `edit_file` is held to the same list. Never wisp's own home (`~/.wisp`), wherever it is. A command you approve to run outside the sandbox is not confined at all (below). | **Reads**: any file the user can read. `read_file` and `run_command` can read your home directory. Credential-like paths ask first. |
| **Network**, only if you set `sandbox.allowNetwork: false`. | **Network by default**: on, because builds fetch dependencies. |
| **The process tree**: a timeout kills the whole group. | **Inter-process messaging and the rest of macOS**: unchanged. |

Before a command runs it must also pass a deny list (`sudo`, `rm -rf /`, piping into a shell, disk
tools, answering an approval, keeping a permanent fact, fetching a model, and starting a wisp agent of its own: `wisp respond`,
`chat`, `mcp`, or `wisp "prompt"`) and a risk check.

**What the model is told when the sandbox refuses.** The sandbox fails a refused operation with `Operation not
permitted` and says nothing else; Homebrew checks its directories first and reports the same refusal as directories
that are `not writable`. wisp checks the paths in either error against the writable roots and tells the
model plainly: that the sandbox refused writing to a path and where it may write; that a path inside the roots was
refused by something else; or, when the error names no path, that the sandbox may have refused it and no policy
rule did, since the policy let the command run. When the sandbox refused it or may have, and running outside the
sandbox is allowed, the note adds that the model may ask to run it outside the sandbox (below)
([ADR 0054](decisions/0054-the-sandboxs-refusals-checked.md), [run_command](tools/run_command.md)).

**A command run outside the sandbox, with your approval.** Some chores cannot run sandboxed at all: `brew upgrade`
(Homebrew runs a sandbox of its own, which cannot nest in wisp's), `cargo install`, `rustup update`. The model may ask
to run one such command without the sandbox. You are asked every time, whatever the command's risk and your
threshold, for that exact line, once; nothing remembers the answer, `--yes` does not give it, and every dialog and
notification says `OUTSIDE the sandbox`. Approved, that command runs with your privileges and no confinement:
it can write anywhere you can, `~/.wisp` included, as it could if you typed it in your own terminal. Read the line
before you approve it. You can also run one yourself in chat by typing it after `!!` (`!!brew upgrade`; in
`wisp-tui` the input box turns red): typing it is the approval, so nothing asks, and the same exposure applies. To
turn both off, `wisp config set commandPolicy.sandbox.allowOutsideSandbox false`
([run_command](tools/run_command.md#running-outside-the-sandbox),
[ADR 0064](decisions/0064-an-approved-run-outside-the-sandbox.md)).

**Commands you type yourself.** In `wisp chat` and `wisp-tui`, a line that starts with `!` (`! git status`)
runs that command as yours, through the same runner as `run_command`
([ADR 0049](decisions/0049-commands-typed-in-chat.md)). It passes the same deny and allow lists and runs
under the same sandbox, with the same output bounds, so it can change only what the model's commands
can: files under the sandbox's writable directories, and the network unless you turned it off. It skips the
risk check and is never put to you for approval, since typing it is the approval, so it runs at once
whatever its level. It has no time limit: Ctrl-C stops it. A line typed after `!!` runs outside the sandbox
instead (above). The deny list includes a nested wisp agent here too: `! wisp respond …` is refused with
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

wisp asks whether it is current only when you ask it to ([ADR 0074](decisions/0074-wisp-update.md)): `wisp update`
and `wisp update --check` send one HTTPS request to GitHub's API for wisp's latest release, with the user agent
`wisp` and nothing about you or your Mac beyond what any HTTPS request carries, and an update then downloads the disk
image and its checksum from GitHub to `~/Downloads`. `updates.check`, off by default, makes the same request at most
once a day, when a chat starts, `wisp doctor` runs, or `Wisp.app` is opened, and never installs; each check is an
`update.check` event in the audit log. A downloaded image is used only when its checksum matches and its app is signed
by wisp's team and notarised by Apple.

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
`--yes`. Under `wisp mcp` you are asked through your MCP client's dialog when it has one and by a
notification, which waits `approval.bannerDelaySeconds` (10 by default) for the dialog and is not posted if you
answer there first; a client with no dialog gets the notification at once. Answer with `wisp approvals approve
<id>` or `deny <id>` in a terminal, in a running `wisp-tui`, or with `/approvals approve <id>` or `deny <id>` in a
plain `wisp chat` at a terminal, and the first answer wins.

**Who can approve, and where.** Only you, in one of wisp's own faces: the chat's prompt or its `/approvals`,
`wisp-tui`'s dialog, `wisp approvals` at a terminal, or your MCP client's dialog. The agent that called wisp cannot:
nothing in the MCP conversation approves a command, and the answer is bound to the exact command,
directory, and thread you were shown. wisp's own model cannot: the sandbox denies its commands any write to
`~/.wisp` even when that lies inside the writable set (a command you approved to run outside the sandbox is the
exception, above), `edit_file` refuses it, and the default policy refuses
`wisp approvals approve|deny`, quoted or behind a wrapper, or spelt `w''isp` or with `${IFS}` between the words. `wisp approvals approve` and
`deny`, and plain chat's `/approvals approve` and `deny`, refuse to run without a terminal on standard input, which an agent's shell tool does not give; that
is a hurdle, not a wall, so keep your agent's own approval for shell commands on
([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)).

Your answer has a scope. "This turn" covers the rest of the current prompt. "This session" covers the
process. "This project" and "Always" are written to `~/.wisp/approvals.json` for 30 days, keyed by the
program (`head *`), never by exact arguments and never for a dangerous verdict. An approval covers only
commands judged at its level or below: approving a moderate `rm` never approves `rm -rf`, and a dangerous
command is remembered for the turn or session by its exact text alone. An interpreter (`sh`, `python3`, …), or a
program named by a variable (`$X args`), is always remembered by its exact text. A loop or conditional is
judged and remembered by the commands inside it (`for f in *; do git add "$f"; done` is `git add *`), never by
its keyword, so an approval of one loop's body covers that command in the next loop and nothing else. When only
the whole line shows the risk (`curl … | python3`) you are asked once, about the line, and your answer covers
its parts for that line alone. `wisp approvals` lists them, marking a project approval whose folder is gone,
which can never match again; `wisp approvals revoke <id>`, `clear`, and `clear --gone` remove them. A request to
run a command outside the sandbox has no scope: whatever you choose it is approved once, and nothing held covers it
(above). A dialog nobody answers within ten minutes counts as a refusal.

**Who keeps a permanent fact, and where.** Only you. A permanent fact (a codename, a settled decision, a
preference) is written to `~/.wisp/facts.json` and given to every conversation, so wisp never writes one on
anyone else's word. In chat you state one or move one there (`/fact ID permanent`). An agent calling
`wisp mcp` can only ask: you are told by a notification ("wisp: keep as a permanent fact?") and answer with
`wisp facts keep <id>` or `drop <id>` in a terminal, in a running `wisp-tui`, or with `/facts keep <id>` or
`drop <id>` in a plain `wisp chat` at a terminal. The rules are the ones for
approval above: nothing in the MCP conversation answers, the answer is bound to the exact fact you were
shown, wisp's own model is refused `wisp facts keep|drop` by the default policy, and both run only with a
terminal on standard input. A request has no time limit and nothing is kept until you answer: it waits in
`~/.wisp/pending`, outliving the thread and the server that asked (once the server has stopped, `wisp facts keep`
or `wisp-tui` keeps the fact itself), until you keep or drop it; `wisp facts pending` lists what waits.
A caller cannot change or remove a permanent fact;
only you can, from chat ([ADR 0048](decisions/0048-permanent-facts-over-mcp.md)).

**Who answers the model's question, and what is recorded.** Only you. With its `ask` tool (off by default;
`tools.ask` or a tool list that names it, [tools/ask.md](tools/ask.md)) the model can ask you one question
mid-turn: which of two files you meant, a value it cannot find. It is not a permission: no answer runs anything,
and every command after it passes the same gate. A question that asks for a password, key, token, or code is
refused by rule before you see it, and a credential-shaped value in an answer is replaced by a marker before the
model, the thread, or the audit sees it, and you are told. In chat and `wisp-tui` the dialog is labelled the
model's and waits for you as long as you take (`inquiry.timeoutSeconds` sets a deadline; `0`, the default, waits);
Ctrl-C stops the turn. Under `wisp mcp` you are told by one notification ("wisp: the model asks") and answer with
`wisp questions answer <id>` (which prompts for the text, so it is in neither your history nor `ps`) or `decline
<id>` in a terminal, in a running `wisp-tui`, or with `/questions answer <id>` or `decline <id>` in a plain `wisp
chat` at a terminal; the rules are the ones for approval above: nothing in the MCP
conversation answers, the answer is bound to the exact question you were shown, wisp's own model is refused
`wisp questions answer|decline` by the default policy, and the command runs only with a terminal on standard
input. The turn parks after a minute and your answer reaches the thread's next turn. What is recorded: the
question and your answer, verbatim (markers applied), in the thread's audit log (`inquiry.settled`, and the `ask`
call's result), in the thread's record, and as a fact of the thread (`answer`, yours), never as a permanent fact
on its own. Your answer is not private from the agent that called wisp, which can read the thread under
`wisp://threads/{thread_id}`; the dialog says so ([ADR 0062](decisions/0062-the-inquiry-verb.md)).

wisp downloads a model only when you ask for it, with `wisp models pull <organisation>/<name>` in a terminal or
`/models pull` in chat, and answer yes after it has said which files, how many bytes, and where; or when the model,
given its `models` tool (off by default), asks and you approve that one pull, which names the publisher, the
licence, and the download, and is asked every time, never covered by an earlier answer or by `--yes`
([ADR 0059](decisions/0059-one-set-of-model-actions.md)). It fetches only the files a model directory needs, with
plain names, and checks each against Hugging Face's listing; wisp's own model is refused the command by the
default policy, and trusting a publisher from now on is never the model's to ask. The files go into the Hugging Face cache, shared with Hugging Face's own tools,
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
| `--yes` | every human approval (a request to run outside the sandbox is refused instead) | deny list, sandbox, classification, audit |
| `--unsafe` | the deny list and the sandbox, for the model's commands and the ones you type after `!` | approval, classification, audit |
| `approval.threshold: "never"` | approval prompts, but not for a command run outside the sandbox | everything else |
| `--model private-cloud` | on-device only | approval, sandbox, audit |

Both flags print a warning on stderr. There is no switch that turns off the audit log except
`audit.enabled: false` in `config.json`.

## Seeing what happened

`~/.wisp/logs/audit.jsonl` records every prompt, reply, tool call and result, policy decision,
classifier verdict, approval, and command outcome, verbatim, in the order they happened, user-only on
disk. `wisp logs` reads it; `wisp logs --kind approval.decided` shows every approval and what it was
remembered as ([logging](logging.md)). A reasoning model's thinking is recorded there too (`model.reasoning`)
and shown to you (`/show`, `/inspect thinking`), and is never sent back to the model; wisp's own side calls
(classifier verdicts, schema replies, the summary and facts) ask a thinking model not to think
([ADR 0053](decisions/0053-the-models-thinking-shown.md)). A tool output too large for the model is kept whole in
`~/.wisp/output/<session>/` (audited as `output.kept` by size and hash, not content) until it is swept; `/show`,
`/last`, and `wisp-tui`'s Ctrl-O show you the whole of it.

**What the line under a reply means.** Beside each reply wisp shows what the turn ran (`ran:`), the entries the
reply cites that the conversation does not hold, and, from the verification pass (on by default,
`verification.mode`), `unsupported:` for a result the reply reports that no call in the turn produced: a command
said to have run that did not, an exit status or denial no command had, output no call printed. Each is read
from wisp's own audit log, never from the reply. An `unsupported:` line means the reply claimed something the
calls do not show; no line does not mean the reply is right: the pass reads only the forms of claim it knows, does
not judge whether a conclusion follows from the output, and misses a result put in other words
([verification.md](verification.md), [ADR 0060](decisions/0060-a-verification-pass.md)).

## Undoing

- Revoke a remembered approval: `wisp approvals revoke <id>` or `wisp approvals clear`.
- Forget a conversation, chat's or an MCP thread: `wisp threads delete <id>`, which deletes `~/.wisp/threads/<id>/`
  and the stored outputs in `~/.wisp/output/<session>/` of each audit session it had that no other thread names, and
  is refused while a wisp has it open (`wisp threads` lists them; an MCP client can also `close_thread` its own). A
  chat saved before 0.27.0 is `~/.wisp/transcripts/<name>.json` and `<name>.store`, and stays there after `--resume`
  copies it into the store: delete both.
- Forget a fact: `/fact delete <id>` in chat; delete `~/.wisp/facts.json` to forget every permanent fact.
  Only you put facts there: what a tool or the model proposes waits for you to move it, and what an MCP
  caller asks for waits for `wisp facts keep`.
- Remove everything wisp keeps: delete `~/.wisp`. Nothing else is written outside the sandbox's
  writable set, except what a command run outside the sandbox wrote (one you approved, or typed after `!!`), the
  models you pulled into the Hugging Face cache, which Hugging Face's own tools share (delete
  `<cache>/models--<organisation>--<name>` to remove one), and the completion script `wisp completions install`
  wrote for your shell (delete the file it named).
- Uninstall: `brew uninstall wisp`.

## Files wisp writes

| Path | Contents | Permissions |
| --- | --- | --- |
| `~/.wisp/update.json` | when `updates.check` last asked GitHub, and the version it named or why it failed | yours |
| `~/Downloads/Wisp-X.Y.Z.dmg` and `.sha256` | the release `wisp update` downloaded, left for you to keep or delete | yours |
| `~/.wisp/config.json` | your settings, written by you, by `wisp config set` and chat's `/config set`, and by `wisp models enable`, `disable`, and `check` and chat's `/models` (`models.disabled`, and the capabilities a check passed), and by `wisp models pull` when you trust a publisher (`mlx.trustedPublishers`) | yours; user-only once wisp writes it |
| `~/.wisp/models/mlx/<name>` | links to the Hugging Face cache's snapshots, made by `wisp models pull` and by enabling a cached model | links |
| the Hugging Face cache (`HF_HUB_CACHE`, `$HF_HOME/hub`, or `~/.cache/huggingface/hub`) | the files `wisp models pull` fetched, in Hugging Face's own layout | readable by all (0644) |
| `~/.zsh/completions/_wisp`, bash-completion's or fish's per-user completions directory | the shell completion script, only when you run `wisp completions install`; it replaces only a file wisp wrote ([wisp.md](wisp.md), "`wisp completions`") | your default (umask) |
| `~/.wisp/logs/audit.jsonl` | the audit log, rotated | user-only |
| `~/.wisp/approvals.json` | remembered approvals | user-only |
| `~/.wisp/pending/` | commands waiting for your approval under `wisp mcp`, facts a caller asked you to keep, the model's questions to you, and your answers, until taken | user-only (directory 0700, files 0600) |
| `~/.wisp/transcripts/*.json`, `*.store` | chats saved before 0.27.0, and each one's links to the audit log; read by `wisp chat --resume`, never written now | user-only |
| `~/.wisp/threads/<id>/` | every thread, each chat and each MCP `respond` thread, saved after each turn so a later chat or server can resume it: its owner, start settings, and record, tool output included; deleted by `wisp threads delete`, by `close_thread`, or 30 days after its last use (`threads.keepDays`) | user-only (directory 0700, files 0600) |
| `~/.wisp/facts.json` | permanent facts: the ones you stated or kept, which every conversation is given | user-only |
| `~/.wisp/context/` | the exact context a model saw, saved by `/inspect context` and around each condensation | user-only |
| `~/.wisp/output/<session>/` | tool outputs too large for the model to see at once, kept whole so it can page or question them; removed 30 days after the session's last use (`context.outputDays`) | user-only |
| `~/.wisp/classifiers/risk/` | risk classifier versions: the release's default and those `wisp classifier train` makes | models read-only |
