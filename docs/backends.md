# Model backends

Which models wisp can run a conversation on, how to get their assets onto this Mac, how to name
them, what each declares it can do, and what goes wrong. The decisions are
[ADR 0013](decisions/0013-model-selection.md), [ADR 0016](decisions/0016-local-runtimes-through-an-executor.md),
and [ADR 0019](decisions/0019-model-backends.md).

## How selection works

`--model`, `config.json`'s `model`, and the MCP `respond` argument `model` all take the same spelling:

| Spelling | Backend | Where the model runs |
| --- | --- | --- |
| `system` (default) | Apple's Foundation Models | on device |
| `private-cloud` (alias `pcc`) | Apple's Private Cloud Compute | Apple's servers, with a note on stderr |
| `ollama:<name>` | a local Ollama server | on device, in Ollama's process |
| `coreai:<name-or-path>` | Apple's Core AI framework, in wisp's process | on device |
| `mlx:<name-or-path>` | MLX Swift, in wisp's process | on device; in the release and in builds made with the `MLX` trait |

`wisp models` lists the models that can serve a conversation right now, and `--all` adds the rest with
the reason each is excluded ([wisp.md](wisp.md)); `wisp doctor` checks the configured
model resolves. A backend this build lacks is refused with the registered ones named.

Every backend is the same above the model: the tool loop, the approval gate, the sandbox, transcripts,
and the audit log are unchanged. When a conversation opens, wisp records `model.resolved` with the
backend, the model, the asset behind it, and its declared capabilities (`docs/logging.md`).

## Private Cloud Compute

`private-cloud` needs the managed entitlement `com.apple.developer.private-cloud-compute`, which Apple
assigns to an App ID on request (App Store Small Business Program, under two million first-time
downloads) and which only a provisioning profile can authorise. An ad-hoc signed command-line tool such
as the Homebrew or `swift build` binary cannot carry it. The framework does not say so: on this Mac on
2026-09-20 `PrivateCloudComputeLanguageModel.availability` was `available` and `quotaUsage` below the
limit, and the first request failed with `LanguageModelError` code -1 wrapping
`ModelManagerServices.ModelManagerError` code 1046. wisp therefore checks its own code signature
before asking the framework and refuses with a sentence:

```
model 'private-cloud' is unavailable: this binary lacks the com.apple.developer.private-cloud-compute entitlement, …
```

`wisp models --all` shows the same line. Once the entitlement is present, resolving the model reads its
window from `PrivateCloudComputeLanguageModel.contextSize` (an async, throwing property; 32,768 tokens on
this Mac on 2026-09-29, read without the entitlement in a probe), so `Agent` condenses ahead of it; if
the read throws or takes over five seconds, the window stays unknown until an overflow reports it. Until wisp ships as a signed app with the entitlement, the
spelling is accepted for that future and every run of it is refused before any data leaves the Mac.

## Capabilities are declared, never assumed

A model may run a conversation, call tools, produce schema-shaped output, or reason. wisp opens a
conversation only when the model declares what the request needs, and refuses before generation with a
hint otherwise. Who declares them:

| Backend | Source of the declaration |
| --- | --- |
| `system`, `private-cloud` | the framework |
| `ollama` | the server's `/api/show` `capabilities` for that model (`tools`, `completion`, `thinking`, `vision`); a model without `completion`, such as an embedding model, is refused at resolution because it cannot hold a conversation |
| `coreai` | the bundle: tool-call markers in the tokenizer, a thinking format, the engine's guided-generation support |
| `mlx` | the operator, in `config.json`; an undeclared model is text only |

A text-only model can always run a conversation with no tools: `--no-tools` on the CLI, `tools: []`
over MCP. Declared support is eligibility, not quality: a model that declares tool calling may still
call tools badly, and only an evaluation says how well.

## Ollama

Install and run [Ollama](https://ollama.com); `ollama pull <name>` fetches a model. `config.json`:

```json
{ "model": "ollama:qwen3-coder", "ollama": { "baseURL": "http://127.0.0.1:11434", "timeoutSeconds": 120 } }
```

**The window is sized per model** ([ADR 0043](decisions/0043-context-window-from-memory.md)). When a model
is selected, wisp works out its window from the model's shape and the Mac's memory:
- the model's maximum and shape come from `/api/show`, and its weights' size from `/api/tags`;
- the key-value cache costs 2 × layers × key-value heads × head size × 2 bytes per token;
- the window is the largest multiple of 4,096 at which the weights, the cache, and 512 MiB of buffers fit
  half the memory available now, and no more than three quarters of installed memory, capped at the
  model's maximum;
- it is never below 8,192 tokens.

On 2026-09-29, with 19.6 GB available, `granite4.1:8b` (131,072 at most) got 24,576 tokens, estimated at
9.2 GiB; Ollama loaded it in 8.95 GiB. The `model.resolved` audit event records the window and why.
Setting `contextLength` fixes one window for every model instead.

Errors: `no Ollama server at <url>` when nothing listens; `Ollama has no model '<name>'; installed: …`
when the name is unknown (the `:latest` tag may be omitted). Ollama does not signal context overflow; it silently drops the front of the prompt once it passes the
server's window. wisp therefore asks for an explicit window on every request (the sized or configured
window, sent as `num_ctx`; larger windows cost memory) and reads the token usage every reply reports, and `Agent`
condenses the transcript ahead of the window when the last request plus the new prompt would pass 85%
of it (`docs/context-management.md`). `/tokens` in `wisp chat` shows that reported usage for these
models.

Ollama is sent each tool's JSON Schema, but its models are not held to it when they write a call's
arguments. The framework refuses a call that lacks a required property, and a refused call ends the whole
turn. On 2026-09-29 `granite4.1:8b` called `system_info` with `{"topic": "processes"}`. `process` is
required so that the on-device model always names one, and its description says "otherwise empty", so
the turn ended. The executor therefore fills a missing required string with `""`, a missing array with
`[]`, and a missing boolean with `false` before the framework sees the call. A missing number or
choice has no neutral value, so it is left out, and the call still fails.

Models tried on 2026-09-23 on an M4 Max with 48 GB, Ollama 0.33.3, wisp 0.8.1, through `wisp respond`
with the default `contextLength`. Each ran five prompts three times: the git-thread instruction from
`AGENTS.md` with `git log --oneline -3`; the same with a quoted, piped command
(`git log --format='%h %s' -2 | tail -1`), to check that the command is not rewritten; a task in which the
model chooses the command (count the `.swift` files under a directory); the `current_date` loop; and a
text-only question. Every model passed all fifteen, and the audit log showed the quoted command run as
given every time. Times are warm, per turn, and include wisp's classifier and sandbox; the first turn
after a model loads is slower (the cold column).

| Model | Size | Declares | git | verbatim | task | date | text | cold |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `qwen3-coder` | 30.5B, 18.6 GB | tools | 3 s | 4 s | 3.4 s | 0.4 s | 0.2 s | 13 s |
| `granite4.1:8b` | 8.8B, 5.4 GB | tools | 3.4 s | 4.1 s | 3.8 s | 0.6 s | 0.2 s | 8 s |
| `ornith:9b` | 9.0B, 5.6 GB | tools, reasoning | 5.8 s | 7.4 s | 6 s | 1.7 s | 3 s | 24 s |
| `qwen3.8:27b` | 27.3B, 17.7 GB | tools, reasoning, vision | 12 s | 14 s | 13.5 s | 6 s | 2 s | 17 s |

The reasoning models are slower because wisp does not send Ollama's `think` option, so they think in full
on every turn. `granite4.1:8b` matched `qwen3-coder` at under a third of the memory. `ornith:9b` once
named the wrong weekday for the date; `current_date` returns an ISO timestamp without one. Five prompts
are a smoke test, not an evaluation: they show that these models drive wisp's tools, not how well they
handle longer tasks.

## Core AI

Apple's Core AI framework runs models exported to `.aimodel` bundles, through the `CoreAILanguageModel`
bridge from [apple/coreai-models](https://github.com/apple/coreai-models), which wisp pins by commit
(`harness/Package.swift`). Requires macOS 27 and Xcode 27 to build; nothing extra to run.

Preparing an asset (once, on any Mac with `uv`; downloads the source weights from Hugging Face):

```
git clone https://github.com/apple/coreai-models.git && cd coreai-models
uv run coreai.llm.export Qwen/Qwen3-0.6B --output-dir ~/.wisp/models/coreai
```

That writes a bundle directory (`metadata.json`, the `.aimodel`, a `tokenizer/` folder) under the
models directory. `uv run coreai.model.registry --list-models` lists the supported source models; the
recipes under `models/` give per-family options such as 4-bit weights. Measured on 2026-09-20: Qwen3
0.6B exported in two minutes to 331 MB.

Naming: `coreai:<bundle-directory-name>` under the models directory, or `coreai:/absolute/path` and
`coreai:~/path`. `config.json`:

```json
{ "model": "coreai:qwen3_0_6b_4bit_dynamic", "coreai": { "modelsDirectory": "~/.wisp/models/coreai" } }
```

`modelsDirectory` defaults to `<home>/models/coreai`. wisp never exports or downloads.

Capabilities come from the bundle: the bridge detects tool-call markers in the tokenizer vocabulary,
a thinking format, and whether the loaded engine supports guided generation. What wisp has verified,
and with which model, is in the changelog for the release that shipped it; treat any other model as
unverified until you run it.

Verified on 2026-09-20 with Qwen3 0.6B (4-bit, exported as above) on an M4 Max: the bridge declared
tool calling, guided generation, and reasoning from the bundle; a text-only reply took 6 s cold and 1 s
warm and was right every time; the `current_date` tool loop ran through the framework, with the model's
thinking recorded as `reasoning` transcript entries, in 3 of 6 attempts. The other 3 ended with
"Session ended without producing a response" from the same prompt, so at this model size and bridge
revision tool calling is declared and demonstrated but not reliable. The live test
(`WISP_COREAI_TESTS=1 WISP_COREAI_MODEL=<bundle> swift test --filter CoreAILiveTests`) asserts the
declaration and the text reply and reports the tool-loop outcomes. Two things to know about thinking models: the bridge lets the model
think before it answers and budgets 2048 tokens for reasoning models, so a small model that never
closes its thinking ends the turn with the framework error "Session ended without producing a
response" (wisp reports it as a turn error and audits it); and Qwen3's `/no_think` switch made the
bridge fail every tool call in that probe, so do not put it in the instructions of a tool-using thread.

Errors: `no Core AI bundle at <path> (no metadata.json); bundles under <dir>: …; export one with …`
when the name points nowhere; the bridge's own message (missing asset, malformed metadata, wrong bundle
kind) when the bundle is incomplete. Loading reads the tokenizer synchronously at resolve time and the
engine on first use, so the first reply after `wisp` starts is slow.

Limitations: text and tool calling only; no images or audio (the bridge supports vision models, wisp
does not pass images). Structured output is used by wisp only where a model declares guided
generation, and wisp has no structured-output feature yet. Memory is the model's: a 4B model wants
several GB.

## MLX Swift

[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)'s `MLXLanguageModel` bridge runs models in
MLX or Hugging Face safetensors layout in wisp's own process on the GPU. MLX compiles its Metal kernels at
build time, so the bridge is behind the `MLX` package trait: the ordinary build and the sandboxed
pre-commit hook never need the Metal toolchain, and a build without the trait refuses every `mlx:` model
with a message saying so. The release is built with the trait ([ADR 0047](decisions/0047-mlx-in-the-release.md)),
so `brew install pidster/tap/wisp` runs MLX models.

MLX loads its compiled kernels, one Metal library, when the GPU is first used. It looks for
`mlx.metallib` in the directory of the binary holding its code (the real path, after links), then
`Resources/mlx.metallib` there, then `default.metallib` in a `mlx-swift_Cmlx.bundle` beside the binary
(what `swift build` leaves), then `Resources/default.metallib`. The release ships the build's library as
`mlx.metallib` beside `wisp` (3.8 MB); the Homebrew formula installs both in the Cellar's `libexec` and
links `bin/wisp` to it. `wisp doctor` repeats the search and loads what it finds; in that layout,
reproduced under a scratch prefix on 2026-10-03, it reads:

```
ok   MLX: Metal library <prefix>/Cellar/wisp/0.17.0/libexec/mlx.metallib loads
```

A self-build with the trait finds the bundle beside the built binary and needs nothing more; a copy of the
binary elsewhere needs the library copied beside it as `mlx.metallib`, which the doctor's failure says. A
build without the trait reports `not in this build` and passes. To build with it:

```
xcodebuild -downloadComponent MetalToolchain     # once, if xcrun -f metal fails; 868 MB installed
swift build --package-path harness -c release --traits MLX
```

Preparing an asset: a model directory holding `config.json`, the `*.safetensors`, and the tokenizer files
(`tokenizer.json`, `tokenizer_config.json`). A Hugging Face snapshot works as it is, and the
`mlx-community` quantised repositories are the usual choice; wisp does not download. Put the directory
under `<home>/models/mlx` (`config.json` `mlx.modelsDirectory`), or name it by path.

Capabilities come from the operator, because the bridge never infers them: declare per model in
`config.json`, only what you have verified, and an undeclared model runs text-only conversations.

```json
{
  "model": "mlx:Qwen3-1.7B-4bit",
  "mlx": {
    "modelsDirectory": "~/.wisp/models/mlx",
    "models": { "Qwen3-1.7B-4bit": { "capabilities": ["toolCalling", "reasoning"] } }
  }
}
```

Accepted capability names: `toolCalling`, `guidedGeneration`, `reasoning`, `vision`; another spelling is
refused at resolve. `wisp models` lists the directories that resolve, with architecture, quantisation,
and the declaration; `--all` shows the others with the reason, including every MLX model in a build
without the trait.

Verified on 2026-09-20 with `mlx-community/Qwen3-1.7B-4bit` (a Hugging Face cache snapshot, 938 MB)
on an M4 Max, through the CLI built with `--traits MLX`: undeclared, a text-only reply in 2.5 s
including the weight load; declared `toolCalling`, the `current_date` loop ran 3 of 3 attempts, about
4 s each, with the right arguments; undeclared with tools requested, refused before generation with the
hint. The live test runs with `scripts/check mlx-live <model directory>`, which builds with the trait in its
own scratch path and copies the library beside the test bundle's binary, where MLX looks under `swift
test`; on 2026-10-03 it passed with the same model, a text reply in 1.7 s and the tool loop 3 of 3.

Errors: `this build has no MLX support` when the trait is off; `no MLX model at <path> (no config.json);
models under <dir>: …` when the name points nowhere; `unknown capability '<x>'` for a bad declaration; the
bridge's own message when weights fail to load. Weights load on first use, so the first reply is slow.

## Deferred candidates

Recorded, not implemented: llama.cpp; LM Studio (`llmster`); ONNX Runtime; PyTorch and Hugging Face
Transformers; vLLM. Several of these serve an OpenAI-compatible HTTP API, and the Ollama executor's
transcript-to-chat mapping is most of a shared HTTP executor for them. Embeddings, reranking, and other
non-conversational models need task-specific interfaces rather than a `LanguageModel`, and are a
separate design.
