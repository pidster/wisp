# How to install local models

wisp works with nothing more installed: by default it runs on Apple's on-device model, the one behind Apple
Intelligence. That model has an 8,192-token window. A model you run locally gives wisp a larger window and, on the
models measured below, more reliable tool use. Everything here still runs on your Mac.

This page covers getting a model onto your Mac and choosing it. [backends.md](backends.md) is the reference for
each runtime: how the window is sized, what each declares, and every error.

## Which runtime

| Runtime | Choose it when | How wisp names a model |
| --- | --- | --- |
| [Ollama](#ollama) | You want the simplest start. The models measured with wisp are all Ollama models | `ollama:<name>` |
| [MLX](#mlx) | You want the model in wisp's own process, with nothing else to run. wisp fetches it for you | `mlx:<name>` |
| [llama.cpp](#llamacpp-and-lm-studio) | You already serve GGUF files with `llama-server` | `llamacpp:<name>` |
| [LM Studio](#llamacpp-and-lm-studio) | You already use LM Studio | `lmstudio:<name>` |
| [Core AI](#core-ai) | You want to try Apple's Core AI framework with a model you export yourself | `coreai:<name>` |

wisp has never been run against a real llama.cpp or LM Studio server; it was tested against fake ones
([backends.md](backends.md), "llama.cpp and LM Studio").

## Ollama

1. Install Ollama and start its server. Either install the app from [ollama.com](https://ollama.com), or:

   ```bash
   brew install ollama
   brew services start ollama      # or: ollama serve, in a terminal of its own
   ```

2. Fetch a model. `granite4.1:8b` is the one to start with (see [Which model](#which-model)):

   ```bash
   ollama pull granite4.1:8b
   ```

3. Check that wisp sees it, then use it once, or make it the default:

   ```bash
   wisp models                                    # the model is listed as ollama:granite4.1:8b
   wisp --model ollama:granite4.1:8b "What is listening on port 8080?"
   wisp config set model ollama:granite4.1:8b     # every wisp from now on; /model switches in chat
   wisp doctor                                    # "configured model: ollama:granite4.1:8b available"
   ```

wisp looks for Ollama at `http://127.0.0.1:11434`, Ollama's default. If it runs somewhere else, set
`ollama.baseURL`.

## MLX

MLX models run inside wisp itself, on the GPU. The Homebrew install includes everything they need, and
`wisp doctor`'s `MLX:` line confirms it. wisp fetches the model from Hugging Face:

```bash
wisp models pull mlx-community/Qwen3-1.7B-4bit     # lists the files, asks before downloading
wisp models enable mlx:Qwen3-1.7B-4bit             # checks it can reply, call a tool, and give a schema reply
wisp --model mlx:Qwen3-1.7B-4bit "What is the date in Tokyo?"
```

- **Where it goes.** The model is kept in the Hugging Face cache (`~/.cache/huggingface/hub` unless `HF_HOME` or
  `HF_HUB_CACHE` says otherwise). A model fetched there by Hugging Face's own tools is reused, not downloaded
  again. `~/.wisp/models/mlx/<name>` is a link to it.
- **Who published it.** Models from `mlx-community` are fetched without a question about the publisher. A
  model from any other publisher is put to you first, with its licence and download size. You can pull it once,
  or trust the publisher from now on.
- **An interrupted pull** resumes where it stopped the next time you run it.
- **In chat**, `/models pull <repository>` does the same.

When you enable it, wisp checks what the model can actually do. A model that replies but never calls a tool can
only be used with tools off.

## llama.cpp and LM Studio

Start the server, then name its model:

```bash
llama-server -m ~/models/Qwen3-8B-Q4_K_M.gguf -c 32768    # llama.cpp: named llamacpp:Qwen3-8B-Q4_K_M
wisp models enable llamacpp:Qwen3-8B-Q4_K_M               # checks whether it calls tools
```

For LM Studio, download a model in the app and start its server from the Developer tab (or `lms server start`).
The model is then `lmstudio:<key>`, such as `lmstudio:qwen/qwen3-8b`.

The window is the one the server holds the model at, so start `llama-server` with `-c`, or load the model in LM
Studio at the window you want. If the server needs a key, set `WISP_LLAMACPP_API_KEY` or `WISP_LMSTUDIO_API_KEY`.
wisp never logs or shows it. The details are in [backends.md](backends.md), "llama.cpp and LM Studio".

## Core AI

A Core AI model is a bundle you export once with Apple's
[coreai-models](https://github.com/apple/coreai-models) tools into `~/.wisp/models/coreai`. It is then
`coreai:<bundle directory name>`. wisp never exports or downloads one. The steps, and what tool calling on a small
export did when tried, are in [backends.md](backends.md), "Core AI".

## Which model

These are the Ollama models measured on this project's Mac, from the comparison of 2026-10-04 ([measurements.md](measurements.md),
"The local-model comparison"):

| Work | Model | Size | Why |
| --- | --- | --- | --- |
| Most things: single commands, short lookups, git | `granite4.1:8b` | 5.4 GB | About 2 s a request, and close to the most accurate (`edit_file` 28/30, `system_info` 14/16) |
| Multi-step tasks, reasoning over several files | `gemma4:12b` | 8.0 GB | Perfect on tools (30/30, 16/16) at 12 to 18 s a request; it thinks before it answers |
| Large diffs and long drafts | `qwen3.8:27b` | 17.7 GB | As accurate, and the only one with both large-diff drafts right, but much slower |

Avoid these for tool work:
- `llama3.2:3b` writes tool calls as text and misses edits.
- `ministral-3:14b` made no calls in that comparison. It writes calls in Mistral's own format, which wisp has read
  since 2026-10-06, but it has not been measured since.

**A thinking model can be told not to think.** That is often much faster. On 2026-10-10, `granite4.2:8b` without
thinking ran at `granite4.1:8b`'s speed, where thinking made it 4 to 15 times slower. It still got every draft
right, though it dropped two `system_info` cases (14/16):

```bash
wisp config set ollama.models.granite4.2:8b.think false
```

wisp's own internal calls, such as the classifier and summaries, never ask a model to think
([backends.md](backends.md), "Thinking, per model and per call").

## Memory and the context window

wisp sizes each Ollama and MLX model's window when it is chosen. The window is fitted to the Mac's free memory at
that moment and capped at the model's maximum, so the same model may get a smaller window when memory is tight.
`wisp models` shows the window (`CONTEXT`) and how it was decided (`FROM`). To hold one model to a size:

```bash
wisp config set ollama.models.qwen3.8:27b.contextLength 16384
```

[wisp.md](wisp.md#context-window) has the rule.

## Checking and turning models off

```bash
wisp models            # every model that can serve a conversation now, with what wisp knows of each
wisp models --all      # and the rest, each with the reason it cannot be used
wisp models disable ollama:llama3.2:3b     # hidden from /model and refused wherever a model is chosen
```

The default model cannot be disabled until another is made the default.

When a model will not start:

| Message | What to do |
| --- | --- |
| `no Ollama server at …` | Start Ollama (`brew services start ollama`, or open the app) |
| `Ollama has no model '<name>'; installed: …` | `ollama pull <name>`, or pick one of those listed |
| `model 'X' is disabled; enable it with …` | `wisp models enable X` |
| `no llama.cpp server at …` | Start `llama-server`, or set `llamacpp.baseURL` |

When chat's configured model is unavailable as it starts, chat starts on `system` and says so. A one-shot
`wisp "…"` and an MCP `respond` fail with the message instead.
