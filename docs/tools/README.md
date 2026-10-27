# Tools

Tools the on-device model can call. Each page gives the model-facing contract (name, description, arguments,
result format) and the limits that protect the context window. `wisp tools` prints the live list.

| Tool | Purpose |
| --- | --- |
| [current_date](current_date.md) | The date and time; the model has no clock. |
| [run_command](run_command.md) | Run a shell command in the sandbox, with a timeout and bounded output; with `outsideSandbox`, one command the sandbox refuses, run without it once the person approves that run. |
| [read_file](read_file.md) | Read a text file one page at a time. |
| [edit_file](edit_file.md) | Write, append to, or replace text in a file, inside the sandbox's writable set. |
| [inspect](inspect.md) | wisp's own config, status, approvals, recent audit events (by turn too), and a turn's tool calls one line each; read-only. |
| [notify](notify.md) | Show the user a macOS notification; bounded, rate-limited, audited, no approval. |
| [custom tools](custom.md) | Your own tools: command templates with typed arguments, declared in `~/.wisp/config.json`. |
| [system_info](system_info.md) | Ports, free space, folder sizes, busy processes, memory, one process, battery, macOS, network; read-only. |
| [memory](memory.md) | The conversation's memory (not RAM): `recall` an earlier entry, turn, the task, the summary, a fact's history, or a stored output the model saw only in part (filtered by pattern, range, head, or tail), for one turn; `summarise` a stored output by exact readers; `condense` it with a question the model answers over all of it; `note` a fact, or propose the `task`, as the model. Off by default: `context.memory` turns it on. |
| [models](models.md) | The models wisp can run: `list` and `show` at once; `pull` (in the background), `enable`, `disable`, and `check` only once the person approves; `trust` and `switch` are the person's. Off by default: `tools.models` turns it on. |
| [plan](plan.md) | The conversation's plan: tasks with dependencies in trees rooted at turns, kept across turns and resumes; the model adds them, marks each running, done, failed, or skipped, and reads what is ready. Records only; nothing runs. Off by default: `tools.plan` turns it on. |
| [ask](ask.md) | One question to the person mid-turn: free text, or a choice of two to six options; never a permission, never a secret. Waits until answered in chat and `wisp-tui`; under `wisp mcp` the turn parks after 60 s and the answer reaches the next turn. Off by default: `tools.ask` turns it on. |

Select tools per session with `--tool <name>` on the CLI or the `tools` argument of MCP `respond`. Every
registered tool's schema is in the prompt on every turn, so enable only what a task needs. All the tools, the
default, are every registered tool but `memory`, `models`, `ask`, and `plan`, which join them when `context.memory`,
`tools.models`, `tools.ask`, and `tools.plan` are on; a named list has any of them only when it names it
([memory.md](memory.md), [models.md](models.md), [ask.md](ask.md), [plan.md](plan.md)), and `tools.disabled` can leave any out everywhere.

MCP clients discover these tools through the `wisp://tools` resource, generated from the registry; the
limits and example prompt for each come from the tool itself (`WispTool.limits`, rendered from its live
options, and `WispTool.examplePrompt`). See [../mcp.md](../mcp.md).

## Adding a tool

To give the model a command you use often, declare a custom tool in your config; no build is needed
([custom.md](custom.md)). To add a built-in tool to wisp itself:

1. Add a `struct` conforming to `WispTool` under `harness/Sources/WispCore/Tools/`, with an
   `@Generable` `Arguments` type, `@Guide` descriptions on each property, `limits` rendered from its
   options, and an `examplePrompt` that names the tool.
2. Keep the work in a pure helper (like `CurrentDateTool.format` or `FileReader`) and test that.
3. Bound the result to the tool-output budget: page it, or pass it through `ToolOutput.fitted` with the
   registry's `ToolBudget` and `OutputStore`, so what does not fit is kept and marked rather than dropped
   ([ADR 0050](../decisions/0050-tool-output-budget-and-overflow.md)). See
   [../context-management.md](../context-management.md).
4. Append it to `ToolRegistry.init`; it is wrapped by `AuditedTool` there.
5. Add a page here and a row above. The description is prompt text; write it for the model.
