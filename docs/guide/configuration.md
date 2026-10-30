# Configuration

wisp runs with no configuration at all. When you want it to behave differently, the settings live in one
optional file, `~/.wisp/config.json` (or `$WISP_HOME/config.json`), which you can change from the command line,
from chat, or by hand. This guide is a tour of what is worth changing and how; the
[reference](../wisp.md#home-directory-and-configuration) lists every field with its default.

## Look before you change

```bash
wisp config                     # every setting in effect, defaults applied, as JSON
wisp config list                # the settings `set` can change: each one's value or (default), and what it does
wisp config get approval.threshold
```

```
$ wisp config get approval.threshold
moderate	the default
```

The model's `inspect` tool and the MCP resource `wisp://config` show the same view, read-only.

## Change a setting

```bash
wisp config set model ollama:granite4.1:8b
wisp config set approval.timeoutSeconds 300
wisp config set routing.ladder system ollama:qwen3.8:27b     # a list: words, or a JSON array
wisp config unset approval.timeoutSeconds                    # back to the default
```

In chat, `/config set` and `/config unset` do the same, with Tab completing the settings and their values. Each
change is checked before it is written: an unknown setting, a value the setting does not take, or a file that
would no longer load is refused with the reason, and nothing changes. The rest of the file is kept as it is, and
the file is written readable by you alone. Changes apply from the next session: a running chat keeps the settings
it started with. A change that weakens the gate or the audit (the threshold at `never` or `dangerous`, the
classifier at `rules`, the audit off) prints a note. Every change is audited as `config.change`.

wisp's model cannot change its configuration: there is no tool for it, and its sandboxed commands cannot write
`~/.wisp` ([ADR 0040](../decisions/0040-config-from-chat.md)). A command you approve to run outside the sandbox
could, which is why you are asked about each one ([ADR 0064](../decisions/0064-an-approved-run-outside-the-sandbox.md)).

## The settings worth knowing

| You want to… | Setting | Default |
| --- | --- | --- |
| Run on a local model by default | `model` | `system` |
| Be asked less, or more | `approval.threshold`: `safe`, `moderate`, `dangerous`, or `never` | `moderate` |
| Choose what judges each command | `approval.classifier`: `coreml`, `system-model`, or `rules` | `coreml` |
| Wait longer, or forever, for your answer | `approval.timeoutSeconds` (0 waits forever) | 600 |
| Remember project and always approvals for longer | `approval.persistDays` | 30 |
| Give commands more time | `commandTimeoutSeconds` (0 is no limit), and the cap a call or thread may ask for, `commandMaxTimeoutSeconds` | 120, 1,800 |
| Stop the model asking to run a command outside the sandbox | `commandPolicy.sandbox.allowOutsideSandbox` | `true` |
| Give the model its `memory`, `models`, `ask`, or `plan` tool | `context.memory`, `tools.models`, `tools.ask`, `tools.plan` | `false` |
| Leave a built-in tool out everywhere | `tools.disabled` | none |
| Add house style to every conversation | `systemPromptExtension` | none |
| Turn notifications off | `notifications.enabled` | `true` |
| Check replies with a model too, or not at all | `verification.mode`: `off`, `readers`, or `model` | `readers` |
| Keep a thinking model from thinking, or set its level | `ollama.models.<name>.think false` (or `low` to `max`), or `ollama.think` for every model; the same under `llamacpp` and, `true` or `false` only, `mlx` | unset |
| Hold a model to a window | `ollama.models.<name>.contextLength` | sized from memory |
| Have wisp run a llama.cpp server for your GGUF files, or use Llama.app's | `llamacpp.server`: `off`, `llama-app`, or `wisp` (with `llamacpp.serverPath` approving the `llama-server` it runs, and `wisp models add`); set from a terminal, never by the model ([install guide](../install-local-models.md#llamacpp-and-lm-studio)) | `off` |

## Editing the file by hand

Some settings are edited only by hand: the rest of `commandPolicy` (the deny and allow patterns, the sandbox's
writable paths and network), custom tools, and fact kinds. Partial objects are fine; anything you leave out keeps
its default:

```json
{
    "systemPromptExtension": "Prefer British spelling.",
    "commandTimeoutSeconds": 300,
    "commandPolicy": {
        "sandbox": { "writablePaths": ["~/Library/Caches", "~/.cargo/registry", "~/.cargo/git", "~/.npm"] }
    }
}
```

`writablePaths` replaces the default list, so repeat the defaults you want to keep. A malformed file, or an
invalid `commandPolicy` pattern, is an error that names the problem (exit 64), and `wisp doctor`'s `config` line
says whether the file parses. Unknown fields are ignored. Where each section is described:

| Section | Reference |
| --- | --- |
| `commandPolicy` | [run_command](../tools/run_command.md#policy-and-sandbox) |
| `approval` | [Risk classification and approval](../approval.md#configuration) |
| `tools.custom` | [Custom tools](../tools/custom.md): your own command templates, run through the same gate |
| `ollama`, `mlx`, `llamacpp`, `lmstudio`, `coreai` | [Model backends](../backends.md) |
| `context`, `facts`, `assessment` | [Managing the context window](../context-management.md) |
| `routing` | [ADR 0037](../decisions/0037-routing-by-input-size.md) |

## Instructions, in three layers

What the model is told has three layers, in order ([ADR 0017](../decisions/0017-three-layer-instructions.md)):
wisp's own system prompt, which you cannot change; your `systemPromptExtension`, for every session on this Mac;
and a conversation's own instructions, from `--instructions` on the command line or `instructions` when an MCP
thread starts.

## Environment

| Variable | Effect |
| --- | --- |
| `WISP_HOME` | Moves wisp's home, `~/.wisp`, elsewhere: a scratch directory to try something without touching your state (its support folder, wisp's llama.cpp models and approval, goes under it as `support`, and no LaunchAgent is registered) |
| `WISP_LOG` | `debug`, `info`, or `error`: mirror wisp's diagnostics to stderr ([Logging](../logging.md#diagnostic-log)) |
| `WISP_LLAMACPP_API_KEY`, `WISP_LMSTUDIO_API_KEY` | The key of a llama.cpp server you start, or of LM Studio's, kept out of `config.json` |
| `WISP_LLAMACPP_AGENT` | `off`: `llamacpp.server wisp` registers no LaunchAgent; you run `wisp llamacpp serve` yourself |
