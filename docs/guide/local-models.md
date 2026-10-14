# Local models

wisp needs nothing beyond Apple's on-device model, but that model has an 8,192-token window, and a long
conversation or a large tool output fills it fast. A model you run locally gives wisp a larger window and, on
the models measured, more reliable tool use, and it still runs on your Mac. This guide is when to add one and
which; [How to install local models](../install-local-models.md) has the steps for each runtime, and
[Model backends](../backends.md) the reference.

## When the on-device model is enough

For short questions, single commands, the condensing tools (several of which read their input exactly, with no model
turn at all), and the risk classifier, the on-device model does well and costs nothing to set up. Add a local
model when you see conversations condensed after a few turns, long tool outputs cut, or a multi-step task go
astray; or when you delegate repeated work from a coding agent and want a thread to last many turns.

## Which runtime

| Runtime | Choose it when | A model is named |
| --- | --- | --- |
| Ollama | You want the simplest start; every model measured with wisp is an Ollama model | `ollama:<name>` |
| MLX | You want the model in wisp's own process, with nothing else to run; `wisp models pull` fetches it | `mlx:<name>` |
| llama.cpp | You already serve GGUF files with `llama-server` | `llamacpp:<name>` |
| LM Studio | You already use LM Studio | `lmstudio:<name>` |
| Core AI | You want to try a model you exported yourself with Apple's Core AI tools | `coreai:<name>` |

wisp has been tested against fake llama.cpp and LM Studio servers, not yet a real one
([Model backends](../backends.md)).

## Which model, as measured

From the local-model comparison of 2026-10-04 on this project's Mac ([Measurements](../measurements.md)):

| Work | Model | Size | Why |
| --- | --- | --- | --- |
| Most things: single commands, short lookups, git | `granite4.1:8b` | 5.4 GB | About 2 s a request, close to the most accurate (`edit_file` 28/30, `system_info` 14/16) |
| Multi-step tasks, reasoning over several files | `gemma4:12b` | 8.0 GB | Perfect on tools (30/30, 16/16) at 12 to 18 s a request; it thinks before it answers |
| Large diffs and long drafts | `qwen3.8:27b` | 17.7 GB | As accurate, and the only one with both large-diff drafts right, but much slower |

Not for tool work: `llama3.2:3b`, which writes tool calls as text and misses edits, and `ministral-3:14b`, which
made no calls in that comparison.

A thinking model can be told not to think, which is often much faster: on 2026-10-10 `granite4.2:8b` without
thinking ran at `granite4.1:8b`'s speed, where thinking made it 4 to 15 times slower, and still got every draft
right.

```bash
wisp config set ollama.models.granite4.2:8b.think false
```

## The shortest path: Ollama

```bash
brew install ollama
brew services start ollama
ollama pull granite4.1:8b
wisp models                                    # lists ollama:granite4.1:8b
wisp --model ollama:granite4.1:8b "What is listening on port 8080?"
```

## Using a model

| Where | How |
| --- | --- |
| One command | `wisp --model ollama:granite4.1:8b "…"` |
| Every session from now on | `wisp config set model ollama:granite4.1:8b`; `wisp doctor` then checks it is available |
| In chat | `/model ollama:granite4.1:8b`, mid-conversation; `/models` lists what this Mac can run |
| An MCP thread | `"model": "ollama:granite4.1:8b"` on the `respond` call that starts it |

If chat's configured model is unavailable as it starts (Ollama not running, say), chat starts on `system` and
says so; a one-shot `wisp "…"` and an MCP `respond` fail with the reason instead, and never fall back.

## Windows and memory

wisp sizes each Ollama and MLX model's window when it is chosen, from the model's shape and the Mac's free memory
at that moment, capped at the model's maximum ([ADR 0043](../decisions/0043-context-window-from-memory.md)). The
same model may get a smaller window when memory is tight. `wisp models` shows each model's window (`CONTEXT`) and
how it was decided; to hold one model to a size:

```bash
wisp config set ollama.models.qwen3.8:27b.contextLength 16384
```

A llama.cpp or LM Studio model's window is the one its server holds it at.

## Turning models off

```bash
wisp models --all                          # every model, with the reason any cannot be used
wisp models disable ollama:llama3.2:3b     # hidden from /model and refused wherever a model is chosen
wisp models enable ollama:llama3.2:3b
```

The default model cannot be disabled until another is the default. Enabling an MLX or llama.cpp model whose
capabilities are not declared checks them on the model first, and records what passes
([ADR 0056](../decisions/0056-models-enabled-and-disabled.md)).
