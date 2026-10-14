# wisp

wisp is a small AI agent that runs on your Mac and stays there. It drives Apple's on-device Foundation Model,
the one behind Apple Intelligence, or a model you run locally in Ollama, MLX, llama.cpp, or LM Studio, and gives
it tools: it can run a command, read and edit a file, report on the machine, and send you a notification. No
prompt, file, or command output leaves the Mac, and there is no key, account, or bill.

It is for two kinds of user at once: a person at a terminal who wants a local assistant that cannot do anything
behind their back, and a coding agent (Claude Code, Codex, any MCP client) that wants to hand the local chores to
something cheaper than itself: run the tests and return the failures, condense a log, summarise a diff, scan a
commit for secrets.

## Two faces

| Face | You reach it with | What it is for |
| --- | --- | --- |
| The command line | `wisp "…"`, `wisp chat` (with `wisp-tui`, its terminal front end), and one-job subcommands: `wisp scan`, `wisp redact`, `wisp watch`, `wisp draft`, `wisp notify` | Asking a question, handing over a task, a conversation, everyday jobs that need no prompt |
| The MCP server | `wisp mcp`, registered in your agent's MCP configuration | `respond`, which runs a task on the local model on a named thread, and ten condensing tools that read something large on the Mac and return something small |

Both open the same kind of session, with one configuration, one set of approvals, and one audit log.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/overview-dark.svg">
  <img alt="You at the terminal (wisp, wisp chat, wisp-tui) and your coding agent over MCP (respond, ten condensing tools, set_fact_scope, and close_thread) both open one wisp session. The session holds the config, approvals, threads, and facts, and runs the model, on device, through Ollama, or in process with MLX or Core AI, with its seven tools, and three more, memory, models, and ask, that are off by default. A command the model asks for passes the gate in order: the policy deny list, the risk classifier, you when it matters, and the Seatbelt sandbox, and only then reaches your Mac. The session, the model, and the gate all write to one audit log." src="images/overview-light.svg" width="960">
</picture>

## The safety model, in five lines

1. **A policy** refuses what should never run (`sudo`, `rm -rf /`, piping into a shell, disk tools, a wisp agent of its own).
2. **A Seatbelt sandbox** confines every command's writes to the directory wisp was started in, the temporary directories, and the build caches you configure; it can never write `~/.wisp`.
3. **A risk classifier** rates each simple command `safe`, `moderate`, or `dangerous`, rules first and a fast Core ML model beside them.
4. **You** are asked at `moderate` and above, and your answer has a scope you choose; silence is a refusal, and the agent that called wisp can never answer for you.
5. **The audit log** records every prompt, tool call, verdict, approval, and command outcome, verbatim, and every reply says what the turn actually ran.

## Where to go next

| If you want to… | Read |
| --- | --- |
| Install wisp and ask it something | [Install and first run](guide/install.md) |
| Let Claude Code or Codex delegate to it | [Delegating from Claude Code and Codex](guide/delegating.md) |
| Know what you will be asked, and why a command was refused | [Approvals and the sandbox](guide/approvals-and-sandbox.md) |
| Give it a larger model | [Local models](guide/local-models.md) |
| Change how it behaves | [Configuration](guide/configuration.md) |
| Fix something that does not work | [Troubleshooting](guide/troubleshooting.md) |
| Look up a flag, a tool, or an MCP argument | [Command reference](wisp.md), [Tools](tools/README.md), [The MCP server](mcp.md) |
| Know exactly what it can do to your Mac | [What wisp can do to your Mac](trust.md) |
| Understand how it is built, and why | [Design](design.md) and the [decision records](decisions/0001-swift-and-foundationmodels.md) |

wisp is open source, at [github.com/pidster/wisp](https://github.com/pidster/wisp); every page here has an edit
link to its source in the repository's `docs/` folder. The [Changelog](changelog.md) says what each release
changed.
