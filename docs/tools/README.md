# Tools

Tools the on-device model can call. Each page gives the model-facing contract (name, description, arguments,
result format) and the limits that protect the context window. `wisp tools` prints the live list.

| Tool | Purpose |
| --- | --- |
| [current_date](current_date.md) | The date and time; the model has no clock. |
| [run_command](run_command.md) | Run a shell command with a timeout and bounded output. |
| [read_file](read_file.md) | Read a text file one page at a time. |
| [edit_file](edit_file.md) | Write, append to, or replace text in a file, inside the sandbox's writable set. |
| [inspect](inspect.md) | wisp's own config, status, approvals, and recent audit events; read-only. |
| [notify](notify.md) | Show the user a macOS notification; bounded, rate-limited, audited, no approval. |
| [custom tools](custom.md) | Your own tools: command templates with typed arguments, declared in `~/.wisp/config.json`. |
| [system_info](system_info.md) | Ports, free space, folder sizes, busy processes, memory, one process, battery, macOS, network; read-only. |
| [memory](memory.md) | The conversation's memory (not RAM): `recall` an earlier entry, turn, the task, the summary, or a fact's history that the context holds only as a reference, for one turn; `note` a fact, or propose the `task`, as the model. Off by default: `context.memory` turns it on. |

Select tools per session with `--tool <name>` on the CLI or the `tools` argument of MCP `respond`. Every
registered tool's schema is in the prompt on every turn, so enable only what a task needs. All the tools, the
default, are every registered tool but `memory`, which joins them when `context.memory` is on; a named list has it
only when it names it ([memory.md](memory.md)), and `tools.disabled` can leave it out everywhere.

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
3. Bound the result: 4 KiB or page it. See [../context-management.md](../context-management.md).
4. Append it to `ToolRegistry.init`; it is wrapped by `AuditedTool` there.
5. Add a page here and a row above. The description is prompt text; write it for the model.
