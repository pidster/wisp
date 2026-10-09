# Model backends

Which models wisp can run a conversation on, how to get their assets onto this Mac, how to name
them, what each declares it can do, and what goes wrong. The decisions are
[ADR 0013](decisions/0013-model-selection.md), [ADR 0016](decisions/0016-local-runtimes-through-an-executor.md),
[ADR 0019](decisions/0019-model-backends.md), for MLX and Core AI's windows,
[ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), and, for llama.cpp and LM Studio,
[ADR 0058](decisions/0058-a-shared-http-executor.md).

## How selection works

`--model`, `config.json`'s `model`, and the MCP `respond` argument `model` all take the same spelling:

| Spelling | Backend | Where the model runs |
| --- | --- | --- |
| `system` (default) | Apple's Foundation Models | on device |
| `private-cloud` (alias `pcc`) | Apple's Private Cloud Compute | Apple's servers, with a note on stderr |
| `ollama:<name>` | a local Ollama server | on device, in Ollama's process |
| `llamacpp:<name>` | llama.cpp's `llama-server` | on device, in the server's process |
| `lmstudio:<name>` | LM Studio's server | on device, in LM Studio's process |
| `coreai:<name-or-path>` | Apple's Core AI framework, in wisp's process | on device |
| `mlx:<name-or-path>` | MLX Swift, in wisp's process | on device; in the release and in builds made with the `MLX` trait |

`wisp models` lists the models that can serve a conversation right now, with what wisp knows of each (runtime,
parameters, size, format, the window and how it was decided, where an MLX model lives, whether it is enabled, and
its capabilities), and `--all` adds the rest with the reason each is excluded ([wisp.md](wisp.md)); `wisp doctor`
checks the configured model resolves. A backend this build lacks is refused with the registered ones named. A model
can be turned off with `wisp models disable <name>`: it is then not offered and is refused wherever a model is
chosen; the default cannot be ([ADR 0056](decisions/0056-models-enabled-and-disabled.md)). When chat's configured
model is unavailable as it starts, chat starts on `system` and says so; `respond` and MCP fail instead.

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
| `llamacpp` | schema replies always (the server holds the reply to the schema with a grammar); tool calling when `/props` says the chat template supports tool calls, else `config.json` (`llamacpp.models.<name>`), declared by the operator or recorded by wisp's check (`wisp models enable` or `check`) |
| `lmstudio` | schema replies always; tool calling from `/api/v1/models` `trained_for_tool_use`, thinking from its `reasoning`; an `embedding` model is refused at resolution |
| `coreai` | the bundle: tool-call markers in the tokenizer, a thinking format, the engine's guided-generation support |
| `mlx` | `config.json`: the operator's declaration, or what wisp's check of the model recorded when it was enabled or checked (`wisp models check`); an undeclared model is text only |

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
- a model that reports its layers individually (gemma4: `attention.head_count_kv` and
  `attention.sliding_window_pattern` as arrays, one entry per layer) is counted layer by layer. Only the layers
  that attend to the whole window grow with it, at their own key-value heads × (key length + value length) × 2
  bytes per token each. The sliding-window layers keep `sliding_window` tokens plus a batch of 2,048, at
  `key_length_swa` and `value_length_swa` (the model's key and value lengths when those are missing), a fixed
  cost taken off the budget first. A model whose Modelfile names a `DRAFT` (gemma4's speculative decoder) adds
  one more whole-window layer as wide as its widest, and its working buffers are counted twice. The reason says
  how the layers were counted, for example `40 of 48 layers sliding-window (1,024 tokens), with a draft model`;
- a hybrid model, which interleaves attention with recurrent (state-space) layers (`qwen35`: qwen3.8, ornith), counts
  only its attention layers per token: every `full_attention_interval`th layer, or, for a model reporting heads
  per layer, those with heads. The recurrent layers' state does not grow with the window; it is sized from the
  `ssm.*` fields as llama.cpp allocates it (32-bit, once plus once per drafted token for a model that drafts) and
  taken off the budget first. The model's own draft layers (`nextn_predict_layers`) count as a draft model's do.
  The reason names the class, for example `16 of 64 layers attention, with 1 draft layer of its own; 748 MiB
  recurrent state`;
- the window is the largest multiple of 4,096 at which the weights, the cache, and 512 MiB of buffers fit
  half the memory available now, and no more than three quarters of installed memory, capped at the
  model's maximum;
- it is never below 8,192 tokens.

On 2026-09-29, with 19.6 GB available, `granite4.1:8b` (131,072 at most) got 24,576 tokens, estimated at
9.2 GiB; Ollama loaded it in 8.95 GiB. On 2026-10-04, `gemma4:12b` was measured at exactly the 18 KiB per token
the per-layer rule estimates (16 KiB for its 8 global layers, 2 KiB for its draft model); with 30 GB available
it gets its full 262,144 tokens. On 2026-10-05, `qwen3.8:27b` was measured at the 68 KiB per token and 748 MiB of
recurrent state the hybrid rule estimates (it had been counted at 260 KiB), at 8,192 and 32,768 tokens, and
`ornith:9b` at 32 KiB and 50 MiB; with 30 GB available ornith now gets 262,144 tokens instead of 65,536. The
`model.resolved` audit event records the window and why.
Setting `contextLength` fixes one window for every model instead, and `ollama.models.<name>.contextLength` one
model's, ahead of it, so one model can be held to a size while the rest are sized from memory:

```
wisp config set ollama.models.qwen3.8:27b.contextLength 16384
```

`wisp models` (`FROM` is `model config`) and `wisp doctor` ("configured for this model") say which setting gave
the window.

Errors: `no Ollama server at <url>` when nothing listens; `Ollama has no model '<name>'; installed: …`
when the name is unknown (the `:latest` tag may be omitted). Once the server has the request: `Ollama at <url>
stopped before the reply was done (…); nothing of it was kept` when the connection is lost, or the stream ends
without the chunk that says `done`; `Ollama at <url> sent nothing for N s (ollama.timeoutSeconds); the request was
abandoned` when it goes silent. Either ends the turn with that error, recorded as the turn's `error` event: what
had streamed is not kept as a reply, and a tool call that had arrived is not run, so the conversation's next turn
goes to Ollama without it. Tested with a fake server that drops the connection, closes it early, or holds it open
(`OllamaInterruptionTests`). Ollama does not signal context overflow; it silently drops the front of the prompt once it passes the
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

A Mistral model can write its calls as text in its own format, `name[ARGS]{…}`, which its Ollama template leaves
in `content` instead of `tool_calls`. `ministral-3:14b` did so throughout the 2026-10-04 comparison, so wisp saw
no calls ([measurements.md](measurements.md), "The local-model comparison, 2026-10-04"). Probed on 2026-10-06 with
two files to read, it wrote the first call as text (`read_file[ARGS]{"path": "/tmp/notes.txt"}`, one token a
chunk) and Ollama parsed the second. The executor therefore holds back a reply's text while it may still be such
calls, which in practice means its first few characters, and at the reply's end reads it as calls if it is exactly
that: one or several, each an offered tool's name followed directly by `[ARGS]` and one JSON object, with nothing
else around them but whitespace and the `[TOOL_CALLS]` marker. Those calls are made before any Ollama parsed
while the text was held, in the order the model wrote them. Anything else, such as text that mentions
`read_file[ARGS]{…}` or a tool the request does not offer, is the reply as the model wrote it. The rules are the
ones wisp's MLX executor applies to calls a template states and mlx-swift-lm misses (`TextToolCalls`). Only a
request that offers tools and wants no schema reply holds anything back.

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

## llama.cpp and LM Studio

Both serve OpenAI's chat-completions API, and wisp speaks it to them through one executor with a small dialect
for what differs ([ADR 0058](decisions/0058-a-shared-http-executor.md)). What they share:

- **Requests.** Each request carries the whole conversation to `/v1/chat/completions` with `stream: true` and
  `stream_options.include_usage`, the tools with their JSON Schemas, and for a schema reply `response_format` of
  type `json_schema`. Calls carry positional ids (`call00001`, nine letters and digits, as Mistral's templates
  require) and each tool output names the call it answers. The model's thinking is never sent back.
- **The stream.** Reply text, thinking (`delta.reasoning_content` or `delta.reasoning`, shown and audited as
  Ollama's is, [ADR 0053](decisions/0053-the-models-thinking-shown.md)), and tool-call fragments gathered by
  `index` until the choice finishes; missing required strings, arrays, and booleans are filled as for Ollama,
  and calls written as text in Mistral's format are read back the same way. Usage comes from the last chunk;
  without a reasoning count from the server, each chunk of thinking counts one token.
- **The window is the server's.** The server holds the model at a window it chose, so wisp reads it instead of
  sizing one from memory; the listing's `FROM` says `server`. A request the server refuses as larger than its
  window is condensed and retried.
- **Errors.** `no llama.cpp server at <url>: …; start one with llama-server -m <model.gguf>, or set
  llamacpp.baseURL` (or the LM Studio equivalent) when nothing answers; `llama.cpp serves no model '<name>'; it
  serves: …`; `… refused the request (HTTP 401): … set WISP_LLAMACPP_API_KEY, or llamacpp.apiKey in config.json`;
  `llama.cpp at <url> stopped before the reply was done (…); nothing of it was kept` when the stream ends before a
  choice finishes or `[DONE]` comes, or the connection is lost; `… sent nothing for N s (llamacpp.timeoutSeconds)`
  when it goes silent. Chat falls back to `system` when its configured model is unavailable, as for Ollama.
- **The key.** When the server was started with one, set `WISP_LLAMACPP_API_KEY` or `WISP_LMSTUDIO_API_KEY` (it
  wins), or `apiKey` in the section. It is sent as `Authorization: Bearer …` and never logged; `wisp config` and
  `inspect` show only `set (…)` or `unset`. The environment keeps it out of `config.json`, which a tool that reads
  files could otherwise read.

None of this has been run against a real `llama-server` or LM Studio: neither was installed on this Mac when it was
built (2026-10-09). The executor was checked live against Ollama 0.35.1's own OpenAI-compatible endpoint (a tool
call through the loop, and thinking streamed as `delta.reasoning`), and every behaviour above is tested against a
fake server for each dialect (`OpenAICompatibleExecutorTests`, `OpenAICompatibleBackendTests`).

### llama.cpp

Install llama.cpp (`brew install llama.cpp`, or a release from its repository) and serve one model:

```
llama-server -m ~/models/Qwen3-8B-Q4_K_M.gguf -c 32768
```

```json
{ "model": "llamacpp:Qwen3-8B-Q4_K_M", "llamacpp": { "baseURL": "http://127.0.0.1:8080", "timeoutSeconds": 120 } }
```

- **Names.** `/v1/models` lists the model by the `-m` path or the `--alias` given; a path is named by its file's
  name without `.gguf` (`llamacpp:Qwen3-8B-Q4_K_M`), and the path itself is accepted too. A router serving several
  models (`--models-dir`) lists each, and wisp asks `/props` about the one it uses.
- **Window.** `/props` `default_generation_settings.n_ctx`, the window of a slot, which one request gets: `-c`
  divided among the slots (`--parallel`). Without it, 8,192, and the note says why.
- **Tools.** llama.cpp gives any model tools (`--jinja`, its default) and does not say which models call them, so
  a model is usable with tools once `config.json` declares it, or once `wisp models check llamacpp:<name>` (or
  `enable`) has asked it the three short questions of [ADR 0056](decisions/0056-models-enabled-and-disabled.md)
  and recorded what passed under `llamacpp.models.<name>`. When `/props` reports the chat template supports tool
  calls (`chat_template_caps`), that declares it. Schema replies need nothing.
- **Thinking.** `llamacpp.think` `true` or `false` is sent as the chat template's `enable_thinking`
  (`chat_template_kwargs`) for every model; unset sends nothing. The server separates thinking from the reply with
  `--reasoning-format` (`auto` by default); with `none`, thinking stays in the reply's text.

### LM Studio

Install [LM Studio](https://lmstudio.ai), download a model, and start the server from the Developer tab (or
`lms server start`):

```json
{ "model": "lmstudio:qwen/qwen3-8b", "lmstudio": { "baseURL": "http://127.0.0.1:1234", "timeoutSeconds": 120 } }
```

- **Names.** A model's `key` as `/api/v1/models` lists it (`lmstudio:qwen/qwen3-8b`). That listing (LM Studio
  0.4.0 and later) gives every downloaded model's parameter count, size, architecture and quantisation, and what
  it can do; an older server's `/v1/models` gives the names only, and wisp then knows nothing more.
- **Window.** A loaded model's window is the one LM Studio loaded it at. A model not loaded is loaded by LM Studio
  at its own default when the first request comes, which wisp cannot see, so it uses 8,192 (or the model's maximum
  when smaller) and says so; load it at the window you want and choose it again.
- **Tools and thinking.** As LM Studio reports them: `trained_for_tool_use` and `reasoning`. A model it does not
  report as trained for tools is usable with tools off only. Thinking is set per model in LM Studio, so the section
  has no `think`. An embedding model is refused.

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

`modelsDirectory` defaults to `<home>/models/coreai`. wisp never exports or downloads. A models directory
that is a link, and a bundle linked into it by name, are listed and resolved through their real directories, as
MLX's are.

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

The context window is the one the bundle was exported for, read from `metadata.json`:
`language.max_context_length` (metadata 0.2), or `max_context_length` at the top level of a 0.1 bundle
([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)). wisp condenses against it as it does against any
known window, `model.resolved` records it with the note `declared by the bundle (metadata.json …)`, `wisp doctor`
says the same, and `wisp models` shows it in `CONTEXT`, with `bundle` in `FROM`. It is not sized from
memory: the export fixes the window and Core AI allocates its own cache within it. A bundle whose metadata
states none leaves the window unknown, as before (wisp assumes 8,192 tokens until an overflow tells it).
Whether Core AI refuses or truncates a prompt past the window has not been probed.

Errors: `no Core AI bundle at <path> (no metadata.json); bundles under <dir>: …; export one with …`
when the name points nowhere; the bridge's own message (missing asset, malformed metadata, wrong bundle
kind) when the bundle is incomplete. Loading reads the tokenizer synchronously at resolve time and the
engine on first use, so the first reply after `wisp` starts is slow.

Limitations: text and tool calling only; no images or audio (the bridge supports vision models, wisp
does not pass images). Structured output is used by wisp only where a model declares guided
generation, and wisp has no structured-output feature yet. Memory is the model's: a 4B model wants
several GB.

## MLX Swift

MLX Swift ([mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)) runs models in MLX or Hugging Face
safetensors layout in wisp's own process on the GPU. MLX compiles its Metal kernels at build time, so it is
behind the `MLX` package trait: the ordinary build and the sandboxed pre-commit hook never need the Metal
toolchain, and a build without the trait refuses every `mlx:` model with a message saying so. The release is built with the trait ([ADR 0047](decisions/0047-mlx-in-the-release.md)),
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
`mlx-community` quantised repositories are the usual choice. Put the directory, or a link to it, under
`<home>/models/mlx` (`config.json` `mlx.modelsDirectory`), or name it by path, or have wisp fetch an
`mlx-community` one:

```
wisp models pull mlx-community/Qwen3-1.7B-4bit
```

The pull keeps the model in the Hugging Face cache, in `huggingface_hub`'s own layout, so a model Hugging
Face's tools fetched is reused and one wisp fetches is theirs too; `<home>/models/mlx/<name>` becomes a link
to the cache's snapshot. The cache is where `huggingface_hub` puts it: `HF_HUB_CACHE`, else
`HUGGINGFACE_HUB_CACHE`, else `$HF_HOME/hub`, else `$XDG_CACHE_HOME/huggingface/hub`, else
`~/.cache/huggingface/hub`.

```
~/.cache/huggingface/hub/models--mlx-community--Qwen3-1.7B-4bit/
  blobs/<sha256 of each weights file, git blob id of each other file>
  snapshots/<commit>/config.json -> ../../blobs/<id>      (one relative link per file)
  refs/main                                               (the commit)
~/.wisp/models/mlx/Qwen3-1.7B-4bit -> <cache>/models--mlx-community--Qwen3-1.7B-4bit/snapshots/<commit>
```

The pull lists the repository at the commit `main` is at, checks each file against the cache (there, the
listed size, and each weights file's SHA-256, which reads it), and says per file whether it is already in the
Hugging Face cache or to fetch. It asks before it downloads anything; when every file is already in the cache it
asks nothing and only links. It runs only from a terminal, and the default command policy refuses it to the
model. It fetches only `mlx-community` repositories and only the top-level files a model directory needs
(`json`, `safetensors`, `jinja`, `txt`, `model`, `tiktoken`), checks each fetched file's size and each weights
file's SHA-256 against the listing, and refuses before any download when the disk lacks what it will download
plus 1 GiB. A file downloads into `blobs/<id>.incomplete` under `huggingface_hub`'s lock for it; another
program holding the lock refuses the pull. An interrupted pull keeps the files it finished and the part of the
one it was fetching; the next run fetches the rest, resuming that part with an HTTP range request (`Range:
bytes=<offset>-`) and checking the whole file, so a part that does not continue into the listed SHA-256 is refused
and fetched whole next time. A server that ignores the range answers with the whole file, which is fetched from the
start, and the pull says so. A real directory at `<home>/models/mlx/<name>` seeds the cache: each of its files whose
size, and for weights SHA-256, match the listing is copied into `blobs/` (with `copyfile`'s clone, so on APFS it
takes no space until one copy changes) instead of being fetched.

At `<home>/models/mlx/<name>`: nothing, or a link to an older snapshot of the model, becomes the link. A real
directory, such as a copy fetched before the pull used the cache, stays unless you answer yes to a second
question, asked once the snapshot is complete and checked; yes moves it to the Trash and links in its place.
Anything else there refuses the pull. The model is then `mlx:<name>`; `wisp models enable` checks its
capabilities and records them, or you declare them. Each pull is audited as `model.pull` ([logging.md](logging.md)). `wisp models` lists the complete
`mlx-community` snapshots in the cache that nothing links yet, `WHERE` `HF cache, not linked` and `ENABLED` `no`;
`wisp models enable mlx:<name>` (or the pull) links one without downloading
([ADR 0056](decisions/0056-models-enabled-and-disabled.md)).

wisp follows a linked model to its real directory when it resolves it, for the window, the weights' size, and
loading. The pull uses Hugging Face's model information (`/api/models/<repo>/revision/main`), its tree
listing at that commit, and `resolve/<commit>/<file>` downloads, tested against a repository served from memory
and a temporary cache; it has not yet been run against the Hub ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)
lists what is unverified; the range request and the seeding were built the same way, refined 2026-10-09).

Capabilities come from `config.json`, because MLX never infers them, and are recorded there only once verified;
an undeclared model runs text-only conversations. wisp verifies them itself when you enable a model that declares
none, and again with `wisp models check mlx:<name>`: it loads the model and asks three short questions, each once,
greedily, within a time limit (a plain reply, a call of one trivial tool with a given word, a two-field schema
reply), and records the capabilities that pass, `toolCalling` and `guidedGeneration`, with the day, under
`verified` ([wisp.md](wisp.md#wisp-models-check-name),
[ADR 0056](decisions/0056-models-enabled-and-disabled.md), refined 2026-10-04). A model that cannot give the plain
reply has nothing recorded and enabling it is refused; one that replies but calls no tool is enabled for use with
tools off only. `reasoning` and `vision` are not checked; declare them yourself, only what you have
verified. A capability you declared by hand is kept when a check fails it, with a note. On this Mac on 2026-10-04,
enabling `mlx:Qwen3-1.7B-4bit` passed all three in 4.1 s, 2.3 s of it the first question with the weights loading.

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
refused at resolve. `wisp models` lists the directories that resolve, with architecture and quantisation
(`FORMAT`), the weights' size, the window, where the model lives, and the declared capabilities; `--all` shows the
others with the reason, including every MLX model in a build without the trait.

### What runs the model

Since 0.19.0 wisp's own executor runs `mlx:` models ([ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md)),
which brings them level with Ollama's:

| | wisp's executor (`mlx.executor: "wisp"`, the default) | The bridge (`mlx.executor: "bridge"`) |
| --- | --- | --- |
| The window | Sized from `config.json` and memory, or `mlx.contextLength`; a prompt that does not fit is refused as an overflow, which wisp condenses and retries | The same window, for condensing; not enforced |
| Token counts | Exact, from the model's chat template and tokenizer, without loading the weights | The same |
| Usage | Input (with the reused prefix as cached tokens) and output tokens per request, as Ollama's executor reports them | Not reported to wisp |
| The processed prompt | A thread's last prompt kept and reused (below) | Every request processed from the first token |
| Text, tool calls, schema replies | Yes: tool calls parsed in the model's own format, schema replies through the same xgrammar loop the bridge uses | Yes |
| Thinking | As `mlx.think` says; unset, asked for when `reasoning` is declared and otherwise the template's default (Qwen3 thinks), as Ollama does; a schema reply thinks before its constraint starts; split from the reply by the chat template's tags, shown, counted, and never sent back (below) | Asked for only when `reasoning` is declared, plus a think-then-call phase for reasoning models with tools |
| Images | No: `vision` is not offered | When `vision` is declared |

The bridge is mlx-swift-lm's `MLXLanguageModel`, which ran every MLX model before 0.19.0. It stays for vision
models and as the fallback until 0.20.0 has measured wisp's executor against it.

**Thinking.** A reasoning model's thinking is shown as Ollama's is ([ADR 0053](decisions/0053-the-models-thinking-shown.md),
refined 2026-10-06): wisp reads the thinking block's tags from the model's chat template (the first tag with
`think` in its name whose closing tag the template also holds, `<think>` and `</think>` for Qwen3), splits each
reply's text by them as it streams, a tag split across chunks held until it is whole and the template's newlines
around it dropped, and sends the thinking to the framework as reasoning. Chat says `thinking` while it lasts and
shows `∴ thought for 2.0 s, 181 tokens`, `/inspect thinking` lists it, usage counts it (one token a streamed
chunk, within the tokens generated), it is audited as `model.reasoning`, and no later request carries it. A
template that opens the block itself in the generation prompt is seen from the rendered prompt's end, so the
reply is thinking from its first token; thinking that is never closed stays thinking; a tool call ends it. A
model whose template has no such tags has its text left as it is.

Whether the model thinks is the template's `enable_thinking`: `mlx.think` (`true` or `false`) sets it for every
MLX model whose template takes the flag (Qwen3's does; a template without it ignores it); unset, it is `true` when
`reasoning` is declared and otherwise not set at all, so the template's own default holds, as an unset
`ollama.think` leaves a model to Ollama. Qwen3's template thinks by default. Until 2026-10-06 an undeclared model
was told not to think, which cost Qwen3 its multi-step tool calls and its drafts against the same model on
Ollama (below, "Against Ollama"). A schema reply on a model that thinks thinks first, as Ollama lets a model think
before it applies a `format`: it generates freely until the thinking block closes (half the reply's budget at
most; a block cut off is closed with the template's tag), streamed as thinking, and the schema's constraint then
starts from the prompt and what it thought; a model that begins its reply without thinking is constrained from the
prompt. This applies to wisp's executor; the bridge decides for itself (it turns thinking off unless `reasoning`
is declared).
Measured on this Mac on 2026-10-06 with `mlx:Qwen3-1.7B-4bit`, undeclared, and `mlx.think: true`: "Is 51 prime? One
word." thought for 2.0 s and 181 tokens, then replied `No.`, the thinking folded under the `∴` line and none of it
in the reply; with `mlx.think: false` it replied `51 is not prime.` in 1.0 s with 6 tokens and no thinking.

**Against Ollama.** On 2026-10-06 the same Qwen3-1.7B weights scored far lower through wisp's executor than through
Ollama on the tool loop and on drafts (`edit_file` 2/30 against 20/30) because an undeclared model was told not to
think; leaving it to the template, MLX scored 13/30 against Ollama's 15/30 in one run, about 14 s a case. Without
thinking, the MLX 4-bit conversion of this model does not make its second call even on Ollama's exact prompt, where
Ollama's own quantisation does; `mlx-community/Qwen3-4B-4bit` does. The numbers are in
[measurements.md](measurements.md) and the probes in [ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), refined
2026-10-06.

**The window.** An MLX directory's `config.json` gives the shape ADR 0043's rule needs: `max_position_embeddings`,
`num_hidden_layers`, `num_key_value_heads` (else `num_attention_heads`), and `head_dim` (else `hidden_size` ÷
`num_attention_heads`), read from `text_config` first in a multimodal model. A hybrid model's recurrent layers
are counted as for Ollama, from the fields mlx-swift-lm reads: with `full_attention_interval` (Qwen3.5,
Qwen3-Next) only every interval's last layer has a cache and the rest a state sized from the `linear_*` fields;
with the `mamba_*` fields (Falcon-H1) every layer has both, so the cache is counted as before and the Mamba-2
state (134 MiB for the 7B models) is a fixed cost. With the weights' size (the
`*.safetensors` files) and the Mac's memory now, wisp chooses the largest multiple of 4,096 that fits half the
available memory and three quarters of the installed, capped at the model's maximum and never below 8,192;
weights this process already holds count as available. `mlx.contextLength` sets the window for every MLX model
instead, and `mlx.models.<name>.contextLength` one model's, ahead of it. `model.resolved` and `wisp doctor` give the window and why, in the form `<window> of <maximum>: <needed> of a
<budget> budget`, as for Ollama; a directory whose `config.json` has no shape gets 8,192 with a reason saying so.

**The processed prompt.** wisp composes every request afresh ([ADR 0045](decisions/0045-layered-context.md)), so
consecutive requests of a thread share a long prefix: the instructions, the earlier block, and the turns before
the newest. wisp keeps the key-value cache of each thread's last prompt and, for the next request, processes only
what follows the longest prefix the two renderings share, trimming the cache back when a condensation or a
reference changed something earlier. One copy of the weights serves every thread on a model, one request at a
time; the threads' caches together hold at most one window, and the least recently used goes first. A schema
reply runs on a cache of its own. How much this saves has not been measured yet; 0.20.0 measures it.

**Tool calls.** mlx-swift-lm parses calls in the format the model's architecture or chat template names, the
`<tool_call>{"name": …, "arguments": {…}}</tool_call>` JSON form when neither names one, and only for the tools the
request offers. wisp's executor adds two things for formats a template states and mlx-swift-lm does not handle
(ADR 0052, refined 2026-10-05):

- **A JSON array in one frame.** When a reply has no call mlx-swift-lm recognised, a `<tool_call>` frame it
  rejected as malformed is read as `[{"name": …, "arguments": {…}}, …]`, the form Falcon-H1-Tiny-Tool-Calling's
  template asks for. Strictly: exactly one frame, a non-empty array, each element exactly `name`, a tool the
  request offers, and `arguments`, an object; anything else stays text.
- **ChatML's end of turn.** When the chat template uses `<|im_end|>` and the tokenizer has it as one token,
  generation stops there, as mlx-swift-lm does for the ChatML models in its own registry. A checkpoint whose
  `generation_config.json` lists only `<|end_of_text|>` (Falcon-H1-Tiny-Tool-Calling) otherwise ran on to the
  token limit, writing tool results and further turns, and a call in a turn it wrote for the user was parsed as
  its own.

What the Falcon-H1 models wrote for the capability check's tool question on 2026-10-05, through the executor,
greedy:

| Model | Reply | Check |
| --- | --- | --- |
| `Falcon-H1R-7B-4bit` | A call mlx-swift-lm parses: its template asks for the JSON form and names `tool_call.name`, from which mlx-swift-lm infers it (the reply itself was not captured) | passes, in 8.2 s |
| `Falcon-H1-7B-Instruct-4bit` | A sentence, then `</tool_call>` where `<tool_call>` belongs, a Python literal (`{'arguments': {'word': 'heron'}, 'name': 'run_function'}`, the quoting its template's example uses), and a tool name the request does not offer (`run`, `run_action`, `run_function` across variants of the prompt) | fails: no call to parse. Its template also leaves the system turn without `<|im_end|>`; closing it did not change the reply |
| `Falcon-H1-Tiny-Tool-Calling-90M-bf16` | `<tool_call>\n[{"name": "record_word", "arguments": {}}\n</tool_call>`: an array that never closes, with no argument | fails: malformed. With the tool's schema less the framework's `x-order` and `title` keys it wrote a well-formed array with `heron`, which the array reading above takes; a 90M model's reply turns on such details |

Verified on 2026-09-20 with `mlx-community/Qwen3-1.7B-4bit` (a Hugging Face cache snapshot, 938 MB)
on an M4 Max, through the CLI built with `--traits MLX`: undeclared, a text-only reply in 2.5 s
including the weight load; declared `toolCalling`, the `current_date` loop ran 3 of 3 attempts, about
4 s each, with the right arguments; undeclared with tools requested, refused before generation with the
hint. The live test runs with `scripts/check mlx-live <model directory>`, which builds with the trait in its
own scratch path and copies the library beside the test bundle's binary, where MLX looks under `swift
test`, removing the copies before it builds and when it ends, since an unsigned copy stops the next build
signing the bundle; on 2026-10-03 it passed with the same model, a text reply in 1.7 s and the tool loop 3 of 3. Those runs
were through the bridge. On 2026-10-04 the live test passed on wisp's executor with
`mlx-community/Qwen3-1.7B-4bit`, fetched with `wisp models pull`, all five tests: the window 40,960 tokens
(the model's maximum, 5.8 GiB of a 13.2 GiB budget), 18 tokens counted with the model's tokenizer before the
first request, the first request 27 input tokens in 0.98 s and the second 43 with 23 of them reused in
0.087 s, and a text conversation then the tool loop. One run on one Mac: 0.20.0 measures it properly.

Errors: `this build has no MLX support` when the trait is off; `no MLX model at <path> (no config.json);
models under <dir>: …` when the name points nowhere; `unknown capability '<x>'` for a bad declaration; MLX's
own message when weights fail to load; an overflow (`the prompt is N tokens; the window is M`) that wisp
condenses and retries. The tokenizer loads when wisp first counts and the weights on the first request, so the
first reply is slow.

## Deferred candidates

Recorded, not implemented: ONNX Runtime; PyTorch and Hugging Face Transformers; vLLM. vLLM serves an
OpenAI-compatible HTTP API, so the shared executor that serves llama.cpp and LM Studio
([ADR 0058](decisions/0058-a-shared-http-executor.md)) is most of what it needs: a dialect value. Embeddings, reranking, and other
non-conversational models need task-specific interfaces rather than a `LanguageModel`, and are a
separate design.
