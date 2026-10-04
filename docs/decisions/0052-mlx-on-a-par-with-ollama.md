# ADR 0052: MLX on a par with Ollama, and Core AI's window

Date: 2026-10-04. Status: accepted. Amends [ADR 0019](0019-model-backends.md) (MLX models run through wisp's
own executor; mlx-swift-lm's bridge stays as an option; a model can be fetched on the person's command),
[ADR 0043](0043-context-window-from-memory.md) (the MLX and Core AI windows it left for later), and extends
[ADR 0016](0016-local-runtimes-through-an-executor.md)'s executor to an in-process runtime.

## Context

`mlx:` models ran through mlx-swift-lm's `MLXLanguageModel` bridge (ADR 0019), in wisp's process, since
0.17.0 in the release too ([ADR 0047](0047-mlx-in-the-release.md)). Against an Ollama model they lacked four
things the rest of wisp relies on:

| What | Ollama (ADR 0016, 0043) | MLX through the bridge |
| --- | --- | --- |
| The window | Sized from `/api/show`'s shape, the weights, and memory; reported as `contextSize` and `contextNote` to the agent, `model.resolved`, and `wisp doctor` | Unknown: wisp assumed 8,192 tokens until an overflow told it |
| Token counts | The runtime's `prompt_eval_count` after each request | None before or after a request |
| Usage | `UsageReporting.lastInputTokens`, and `updateUsage` on the channel | Sent to the framework's channel, which wisp cannot read back; nothing reached `UsageReporting` |
| The processed prompt | Ollama keeps its own cache between requests | Every request processed from the first token |

The last matters more since [ADR 0045](0045-layered-context.md): D11 composes every request afresh from the
thread's store, the instructions and the earlier block first, so consecutive requests share a long prefix
and differ only at the end, or, after a condensation or a reference, somewhere in the middle. A runtime in
wisp's own process can keep the key-value cache of the last prompt and process only what follows the part
the new one shares with it. The bridge cannot: its executor makes a fresh cache for every request and takes
no cache from its caller (mlx-swift-lm at the pinned commit `c6446cf`, `MLXLanguageModel.swift`), and
`ChatSession`, which does reuse a cache, only appends messages to a conversation it holds itself, where wisp
replaces the whole conversation each request.

What mlx-swift-lm does offer, as public API: `generate(input:cache:parameters:context:)` and `generateTask`
over a caller's `[KVCache]`; `canTrimPromptCache` and `trimPromptCache`; the tokenizer's
`applyChatTemplate(messages:tools:additionalContext:)`; tool calls parsed in the model's own format by the
generation loop; and, in `MLXGuidedGeneration`, `GuidedGenerationLoop`, `GrammarConstraint`, and the biases
the bridge uses for schema replies. Its `ModelContainer` and `SerialAccessContainer` cannot carry a cache
across calls under strict concurrency without `@unchecked Sendable`, which wisp does not use.

Models had to be put under the models directory by hand. Core AI bundles declare the window they were exported
for in `metadata.json` (`language.max_context_length` in metadata 0.2, `max_context_length` at the top level
of 0.1, as coreai-models' own `LanguageBundleTests` read them), and wisp did not read it.

No model was run and nothing was downloaded for this decision: no weights may be fetched while it is built,
and the measurements are 0.20.0's (below).

## Decision

### wisp's own executor for MLX

`mlx:` models run through `MLXModel`, a `LanguageModel` whose executor maps each request onto the model's chat
template (through the transcript mapping Ollama's executor now shares, `ChatMessage`) and hands it to a
`PrefixEngine`:

- **One engine per model directory**, made on first resolution and kept for the process, so every thread on a
  model shares one copy of the weights. It loads the tokenizer alone when it first counts, and the weights on
  the first request. It is an actor that owns the weights and the caches, so neither needs to be `Sendable`;
  its requests run one at a time, under a lock that holds across generation's suspension points, as the GPU
  serves one.
- **One slot per resolved model.** Each thread resolves its model, so each thread has a slot: the tokens its
  last prompt rendered to and the cache that processed them. When the resolved model goes, its slot is
  released. The slots together hold at most one window of tokens, since the window was sized for one cache
  of that length; the least recently used is dropped first, and a slot longer than the window is not kept.
- **The reuse rule** (`PrefixPlan`). Render the new prompt; keep the longest common prefix of it and the slot's
  tokens, less the prompt's last token, which must be processed to give the next one's probabilities; trim the
  cache back to that prefix; process the rest. A cache that cannot drop tokens (a rotating cache that has
  wrapped) is kept only when the new prompt extends it, and otherwise rebuilt, as is any cache whose length
  does not match its tokens after trimming.
- **After generation the cache is trimmed back to the prompt**, so the slot holds exactly what was rendered.
  The reply's own tokens are processed again in the next request, because a template need not render a past
  reply exactly as the model generated it (a template may, for instance, render the generation prompt with
  a thinking block that it leaves out of past replies); comparing renderings with renderings keeps the rule
  exact, and the reuse stops where two renderings part. A failed or cancelled request leaves the slot empty.
- **The window is enforced.** A prompt of the window or more is refused with
  `LanguageModelError.contextSizeExceeded`, which the agent's overflow path condenses and retries, and
  generation stops at the window. MLX would otherwise run on past it.
- **Usage in Ollama's shape.** The executor records the rendered prompt's length for `UsageReporting` and sends
  `updateUsage` with input as the prompt, cached as the tokens reused, and output as the tokens generated.
- **Exact counts.** `ResolvedModel.tokenCount(for:)` renders the transcript, with the tools its instructions
  declare, through the model's chat template and tokenizer, without loading the weights.
- **Schema replies** are generated with mlx-swift-lm's guided loop, as the bridge does: the schema compiled by
  xgrammar over the model's vocabulary, with the bridge's closing and whitespace biases, on a cache of their
  own; the slot is left as it was, since a schema reply is a one-off condenser or distillation call.
- **Tool calls** are parsed by mlx-swift-lm's generation loop in the model's own format, for the tools the
  request offers; missing required arguments are completed as Ollama's executor completes them.
- **Thinking** is asked for (`enable_thinking`) only when the operator declared `reasoning`, as the bridge did.
  The thinking text itself is 0.19.0's other item.
- **No images.** The mapping is text only, so `vision` is not offered under this executor.
- **The bridge stays**, as `mlx.executor: "bridge"`: the escape hatch while wisp's executor is unmeasured, and
  the way to run a vision model. It gets the sized window and exact counts; it does not report usage or reuse
  a prefix.

Everything but the runtime itself is generic and compiled without the `MLX` trait: the engine over a
`PromptRuntime` protocol, the plan, the pool, the executor. Tests drive the framework's real session and tool
loop through `MLXModel` over a fake runtime that processes tokens onto a list. The MLX runtime
(`MLXPromptRuntime`, `MLXPromptTokenizer`) is the one file under `#if MLX`.

### The window from the model's configuration

An MLX model directory carries its Hugging Face `config.json`. Its shape is read as ADR 0043 reads Ollama's:
`max_position_embeddings` (or `max_sequence_length`, `n_positions`), `num_hidden_layers`, `num_key_value_heads`
(else `num_attention_heads`), and `head_dim` (else `hidden_size` ÷ `num_attention_heads`), from `text_config`
first when a multimodal model nests its language model there. The weights are the `*.safetensors` files'
size, and weights this process already holds count as available, as Ollama's loaded models do. ADR 0043's rule
then applies unchanged: the largest multiple of 4,096 that fits half the available memory and three quarters
of the installed, capped at the model's maximum, with the 8,192 floor; the floor's reason says the Mac may
swap, where Ollama's says it may run partly on the CPU. `mlx.contextLength` sets it for every MLX model, as
`ollama.contextLength` does; without a shape the window is the floor and the reason says so. The window and
its reason reach the agent, `model.resolved`, and `wisp doctor` as Ollama's do.

### Fetching mlx-community models

`wisp models pull mlx-community/<name>` fetches a model into the MLX models directory, where it is then
`mlx:<name>`. A backend still never downloads when a model is resolved; the pull is the person's command:

- **Only from a terminal, and only after asking.** It lists the repository, prints how many files and bytes it
  would fetch and where, and asks `[y/N]`; anything but yes fetches nothing. Without a terminal it refuses, as
  `wisp approvals approve` does, and the default command policy refuses `wisp models pull` to the model.
- **Bounded.** Only `mlx-community`, the organisation that publishes MLX conversions; only top-level files with
  the extensions a model directory needs (`json`, `safetensors`, `jinja`, `txt`, `model`, `tiktoken`); sizes
  known before the question and checked after each file; LFS files (the weights) checked against the listing's
  SHA-256; refused before any request when the volume lacks the files plus 1 GiB; a minute's limit on silence.
- **Resumable by file.** Files go into a hidden `.<name>.partial` directory beside the destination and the
  directory takes the model's name only when every file is in; a later pull finds the finished files and
  fetches the rest. A file interrupted part-way starts again.
- **Audited** as `model.pull` with the repository, destination, file and byte counts, bytes fetched, and the
  outcome (`fetched`, `declined`, `failed`), under a session of entry point `models`.

The listing is Hugging Face's tree API (`/api/models/<repo>/tree/main`) and the files its `resolve/main/<file>`
URLs. Tests serve a repository from memory through the `Transport` protocol; the real Hub was not contacted
while this was built.

### Core AI's window

`coreai:` models report the window their bundle was exported for, from `metadata.json`
(`language.max_context_length`, or a 0.1 bundle's `max_context_length`), as `contextSize`, with the note
"declared by the bundle". It is not sized from memory: the export fixes the window and Core AI allocates its own
cache within it, and the metadata carries no shape. `wisp models` shows it in the bundle's line. Token counts
and usage for Core AI are unchanged.

## Consequences

- An MLX conversation condenses ahead of a window wisp knows, against counts from the model's own tokenizer
  and the usage of the last request, as an Ollama one does, and `wisp doctor`'s `context window` says how the
  window was chosen.
- A thread's requests after the first process only what changed: the new turn, or from the first difference
  after a condensation. That is the point of the design; how much it saves is not yet measured.
- wisp now owns MLX generation, which the bridge did before: sampling, stop tokens, and tool-call parsing come
  from mlx-swift-lm's public generation API, but the composition is wisp's. A behaviour the bridge had and wisp's
  executor lacks (vision, the bridge's think-then-call phase for reasoning models with tools) needs
  `mlx.executor: "bridge"` until it is added. Before 0.19.0 is released, `scripts/check mlx-live <model>` must
  pass on wisp's executor; its new test checks the window, a count, usage, and reuse on a second request.
  2026-10-04: it passed with `mlx-community/Qwen3-1.7B-4bit`, fetched by `wisp models pull` (984 MB, 9 files),
  all five tests; the second request reused 23 of its 43 input tokens and took 0.087 s against the first's
  0.98 s ([backends.md](../backends.md)).
- Memory: the caches of all threads on one model together hold at most one window, so a second thread on the
  same model evicts the first's slot when both are long; the first then processes its prompt in full again.
- Tests without a model: the reuse rule and the pool; the engine with a fake runtime (reuse across requests,
  trimming on divergence, rebuilding an untrimmable cache, slots per thread and their release, schema replies
  on their own cache, overflow); the framework's session and tool loop and the agent through `MLXModel`
  (streaming, usage, cached tokens, counts with tools); the window from `config.json` with weights held or not,
  configured, and without a shape; the shape reader; the pull (naming, the file filter, the plan, refusals,
  a checked fetch interrupted and resumed, a size or digest mismatch, no room); Core AI's window from both
  metadata versions; the doctor's wording; the policy refusing the model a pull.
- **What 0.20.0 must measure**, on this Mac and, for the window, on a 16 GB one:
  - the live test on wisp's executor and on the bridge with the same model (`mlx-community/Qwen3-1.7B-4bit`, as
    ADR 0047 used): text, the tool loop, and schema replies, so the default executor is confirmed or reverted;
  - prefix reuse over the context evaluation's long scenario: tokens reused per request, time to the first
    token and total time per request with reuse and with `mlx.executor: "bridge"`, and how often a condensation
    or a reference forces a deep trim;
  - the key-value cache's real cost per token against the estimate from `config.json`, as ADR 0043 measured
    Ollama's (162.6 KiB measured against 160 estimated), and the process's memory with two threads on one model;
  - the windows sized for two or three common `mlx-community` models, and whether they hold under load;
  - MLX against Ollama for the same model: speed, tool-call reliability, and schema replies (the roadmap's
    0.20.0 item);
  - `wisp models pull` against the real Hub: the listing's format (the LFS `oid` as SHA-256), throughput, and
    resuming after an interruption;
  - whether Core AI refuses or truncates a prompt past the bundle's window.
