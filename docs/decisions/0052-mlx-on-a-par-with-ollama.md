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

**Refined 2026-10-04: into the Hugging Face cache, and linked.** The first pull on this Mac fetched
`mlx-community/Qwen3-1.7B-4bit` into `~/.wisp/models/mlx` while `~/.cache/huggingface/hub` already held
the same model, fetched earlier by Hugging Face's own tools: 984 MB stored twice, and the cache also held four
other `mlx-community` models. The operator decided that wisp reuses the cache and pulls into it, so a model is
stored once whichever tool fetched it. This replaces the hidden `.<name>.partial` directory above; the rest of
the pull (terminal only, `mlx-community` only, the file allow-list, the size and SHA-256 checks, the 1 GiB margin,
the model refused the command) stands.

- **The cache** is `huggingface_hub`'s: `HF_HUB_CACHE`, else the older `HUGGINGFACE_HUB_CACHE`, else
  `$HF_HOME/hub`, else `$XDG_CACHE_HOME/huggingface/hub`, else `~/.cache/huggingface/hub`. `huggingface_hub`
  derives `HF_HOME`'s default from `XDG_CACHE_HOME`, so wisp does too. A leading `~` is expanded; `$VAR` inside a
  value, which `huggingface_hub` also expands, is not, and an empty variable counts as unset.
- **Its layout**, as `huggingface_hub` writes it: `models--mlx-community--<name>/blobs/<id>`, where the id is an
  LFS file's SHA-256 (the listing's `lfs.oid`) and another file's git blob id (the listing's `oid`);
  `snapshots/<revision>/<file>` as relative links `../../blobs/<id>`; and `refs/main` holding the revision.
  The revision is the commit `sha` of `/api/models/<repo>/revision/main`, the call `snapshot_download` makes
  first; the tree is then listed at that commit and each file fetched from `resolve/<revision>/<file>`, so the
  files are the commit's even if `main` moves meanwhile. A blob downloads into `blobs/<id>.incomplete` and takes
  its name once checked, under `huggingface_hub`'s lock file `.locks/models--…/<id>.lock` taken as an exclusive
  `flock`, which is what its `filelock` takes on macOS; a held lock refuses the pull rather than waiting. An
  `.incomplete` blob, wisp's or another tool's, is started again, not resumed.
- **Reuse.** The plan checks each wanted file's blob before the question: present, the listed size, and for
  weights the listed SHA-256, read in 4 MiB pieces (the blob may be gigabytes; the command says which file it is
  checking). A blob of any revision counts, since its name is its content. Only the missing or wrong files are
  fetched, the room needed is theirs plus the margin, and the question names how many and how many bytes. When
  every file is in the cache there is no download question: the pull says each file is already in the Hugging
  Face cache and links.
- **The link.** `<models>/<name>` becomes an absolute link to the snapshot, so `mlx:<name>` resolves as before.
  A link to another snapshot of the same model (an older revision, or one the operator made by hand) is pointed at
  this one. A real directory there, such as the first pull's copy, is left as it is unless the person answers yes
  to a second question, asked after the snapshot is complete and checked again file by file; on yes it goes to the
  Trash, not deleted, and the link takes its place; on no the model is in the cache and the directory still serves
  `mlx:<name>`. Anything else at that path (a file, a link elsewhere) refuses the pull before any request, since
  replacing it would change what `mlx:<name>` runs.
- **Resolution follows the link to its real directory.** Foundation's URL listing does not follow a link at the end
  of the path, so a linked model's weights counted as 0 bytes when its window was sized (`ENOTDIR`, probed on this
  Mac); the backend now resolves the model directory first, for the window, the engine, and the loader.
- **`wisp models`** adds one line naming the complete `mlx-community` snapshots in the cache that nothing in the
  models directory names, and that `wisp models pull mlx-community/<name>` links one without downloading. Complete
  is judged without the network: `config.json` and a `*.safetensors`, no dangling entry, and every shard
  `model.safetensors.index.json` names.
- **Audit.** `model.pull` adds `cache` (the snapshot), `reused` (files the cache already held), `fetchedFiles`,
  and `link` (`created`, `unchanged`, `replaced link`, `replaced directory`, `kept directory`), and the outcome
  `linked` when nothing was downloaded.
- **Tests** use a temporary cache and the fake Hub: a fresh pull's layout, links, `refs/main`, and the link; a
  complete snapshot fetching nothing; a partial or interrupted one fetching only what is missing; a corrupt blob
  (wrong size, wrong digest) fetched again; an `.incomplete` blob started again; a held lock; a real directory kept
  or, with yes, replaced, and never while the snapshot lacks a file; a link repointed; the variables' precedence;
  and the listing of unlinked models.
- **Not verified against the live Hub** (no request was made while this was built): that the revision endpoint
  returns `sha`; that the tree's `oid` for a file kept in git is the id `huggingface_hub` names its blob by (its
  `ETag`); how Xet-backed files are named in the cache (taken to be their SHA-256, as LFS files are); that a tree
  of a model's top level arrives in one page; and that `filelock` and wisp exclude each other in practice. A blob
  named differently from what `huggingface_hub` would name it would be fetched again, not misused, since every
  reuse is checked by size and weights by digest. The pull against the real Hub, listed below for 0.20.0, now
  includes linking a model Hugging Face's tools fetched.

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

**Refined 2026-10-05: hybrid models' windows.** ADR 0043's hybrid rule (refined 2026-10-05) applies to
`config.json` as mlx-swift-lm builds the caches. With `full_attention_interval` (Qwen3.5, Qwen3-Next) only every
interval's last layer keeps a key-value cache and the others a gated-delta state, sized from `linear_conv_kernel_dim`,
`linear_num_value_heads` × `linear_value_head_dim`, and `linear_num_key_heads` × `linear_key_head_dim`. With
`mamba_d_conv`, `mamba_d_ssm`, and `mamba_d_state` (Falcon-H1, whose `FalconH1.swift` gives every layer a
`CacheList` of a Mamba cache and an attention cache) every layer keeps both: the cache is counted as before and the
Mamba-2 state, with `mamba_n_groups` (else 1), is added as a fixed cost. The state is counted at 32 bits, as
llama.cpp keeps it; MLX keeps the convolution window in the activations' type, so this errs towards a smaller
window. For `Falcon-H1-7B-Instruct-4bit` and `Falcon-H1R-7B-4bit` (44 layers): 44 KiB a token as before and
134 MiB of state, so 221,184 tokens with 30 GB available instead of 225,280; `Falcon-H1-Tiny-Tool-Calling-90M-bf16`
(24 layers) 12 KiB a token and 5 MiB. `Qwen3-1.7B-4bit` sets none of these fields and sizes exactly as before. Not
measured on MLX: no hybrid was run live for this.

**Refined 2026-10-05: tool calls a template states and mlx-swift-lm misses.** Enabling the three Falcon-H1 models,
`Falcon-H1-7B-Instruct-4bit` and `Falcon-H1-Tiny-Tool-Calling-90M-bf16` made no call in the capability check
(ADR 0056), `Falcon-H1R-7B-4bit` did. Probed through the executor with the check's request, greedy: Instruct wrote
a sentence, `</tool_call>` in the opening tag's place, a Python literal, and a tool it was not offered (`run`,
`run_action`, `run_function` as the prompt varied), which no parser should turn into a call; Tiny wrote
`<tool_call>` and a JSON array that never closed, without the argument. With the tool's schema less the
framework's `x-order` and `title`, Tiny wrote the array its template asks for (`<tool_call>[{"name", "arguments"}]
</tool_call>`), which mlx-swift-lm's JSON parser rejects as malformed, since it reads one object per frame; and it
did not stop at `<|im_end|>`, which its `generation_config.json` leaves out, so it ran to the token limit writing
tool results and user turns, and a call in a user turn it invented was parsed as its own. Two additions to the
executor, generic and tested without MLX (`ToolCallRecovery`):

- When a reply has no call mlx-swift-lm recognised, each frame it rejected as malformed is read as a JSON array of
  calls, strictly: one frame, a non-empty array, each element exactly `name`, an offered tool, and `arguments`, an
  object; all or nothing.
- `<|im_end|>` is a stop token when the chat template uses it and the tokenizer holds it as one token, as
  mlx-swift-lm's registry makes it for its ChatML models, which a model loaded from a directory does not reach.

Neither makes Instruct or Tiny pass the check: Instruct's reply is not a call, and Tiny's, with the schema wisp
sends, is malformed. Leaving the framework's schema keys out was not done: it would change every model's prompt,
Ollama's too, on the evidence of one 90M model, and stays an open question. In a scratch home the check then gave H1R tool calling passed in
8.2 s, Instruct and Tiny failed (0.5 s for Tiny, which now stops at its turn's end).


**Refined 2026-10-06: the MLX gap, thinking left to the template.** `scripts/check eval compare` on the same weights
through both runtimes (`mlx:Qwen3-1.7B-4bit` under wisp's executor, `ollama:qwen3:1.7b`, Q4_K_M) found wisp's MLX
path far behind on multi-step tool work and drafting: `edit_file` 2/30 against 20/30, drafts 4/10, 0/2, 0/2 against
9/10, 1/2, 2/2, schema 4/6 against 6/6, and MLX's `edit_file` cases ending in 1.3 s against Ollama's 12 s. Every MLX
`edit_file` failure made no `edit_file` call: the model called `read_file`, then replied with the file's lines
verbatim and stopped.

*The cause* was the thinking toggle, not the executor's mechanics. This decision asked for thinking only when
`reasoning` was declared, so an undeclared Qwen3 was rendered with `enable_thinking: false` (the empty
`<think>\n\n</think>` block). Ollama sends no `think` unless `ollama.think` is set, and Qwen3 then thinks; its
`edit_file` runs showed `model.reasoning` events before each call. Probed on this Mac, each hypothesis with the
smallest experiment:

- *Thinking.* The case's second request (after `read_file`), sampled ten times at the executor's defaults: no
  `edit_file` call in 10 with `enable_thinking: false`, a call in 8 of 10 with it on. Through the CLI in a scratch
  home, `mlx.think: true` made the case pass (18 s, thinking before both calls).
- *Ollama without thinking.* The same suites on `ollama:qwen3:1.7b` with `ollama.think: false`: `edit_file` 19/30,
  drafts 8/10, 2/2, 2/2, schema 5/6. So turning thinking off does not cost Ollama's weights what it cost MLX's.
  Ollama's exact rendering of wisp's second request (Ollama 0.35.1's own template code run over the captured
  `/api/chat` body; 829 tokens, the count its server logged) fed to the MLX weights: 0 calls in 12; the same text
  through Ollama's raw endpoint: 8 in 8. The same text on `mlx-community/Qwen3-4B-4bit` and on `Qwen/Qwen3-4B`
  (bf16) through the same MLX runtime: 12 in 12 each. Without thinking, the gap is in the 1.7B 4-bit MLX conversion's
  weights, not in the prompt wisp renders or the runtime.
- *The prompt.* Leaving the framework's `title`, `x-order`, and `additionalProperties` out of the tool schemas, and
  adding Qwen3's `/no_think` as Ollama's template does with `think: false`: 0 calls in 12 for each variant.
- *Prefix reuse.* Greedy, the second request with the slot warmed by the first (707 of 765 tokens reused) and on a
  fresh slot: identical without thinking; with thinking they part after some sixty tokens (chunked prefill's
  rounding) and both end in the same `edit_file` call. No corruption.
- *The split and the parsing.* With thinking on, the call after the thinking was recognised every time; nothing was
  dropped.
- *Sampling.* MLX samples at mlx-swift-lm's defaults, temperature 0.6, top-p 1, no top-k, as the bridge does; the
  mlx-community snapshot has no `generation_config.json`; Ollama's Modelfile adds top-p 0.95 and top-k 20. Without
  thinking all twelve MLX samples were the same echo, so truncating the tail would not change it. Left as it is.

Ollama with thinking also lets a model think before a `format` applies (a schema request with `think` unset returned
`thinking` and then the JSON); this executor constrained a schema reply from its first token.

*Changes*, tested without MLX over the fake runtime:

- `mlx.think` unset no longer turns thinking off: a model declared `reasoning` is asked to think, and any other is
  rendered without `enable_thinking`, so its template's default holds, as an unset `ollama.think` leaves a model to
  Ollama. `mlx.think` still decides when set. Counting renders the same way. The bridge is unchanged: it turns
  thinking off unless `reasoning` is declared.
- A schema reply on a model whose template marks thinking, unless `enable_thinking` is false, thinks first: free
  generation on a cache of its own until the block closes (`ThinkingPhase`), streamed and counted as reasoning, at
  most half the reply's budget; the xgrammar loop then starts from the prompt and the thinking's own tokens through
  the closing tag, as the bridge's think-then-call phase prefills them. A block cut off is closed with the template's
  tag; a model that begins its reply without thinking is constrained from the prompt.
- A null in a past tool call's arguments rendered as `NSNull`, which the template engine cannot convert ("Cannot
  convert value of type NSNull to Jinja Value"), so every later request of that thread failed to render. Found by the
  probe, not by the evals: the framework records MLX's calls without the nulls Ollama's carry. A null is now the
  engine's `none`, written `null` as Ollama writes it. The conversion (`ChatTemplateValues`) moved out of the
  MLX-only file so the gate tests it.

*After*, the same suites, same day, both runtimes in one `eval compare` run (not recorded):

| Suite | MLX before | MLX after | Ollama (thinking, the default) | Ollama, `think: false` |
| --- | --- | --- | --- | --- |
| `edit_file` | 2/30, 1.3 s | 13/30, 14.3 s | 20/30, 12 s, then 15/30, 12.6 s | 19/30, 1.5 s |
| Drafts, small / medium / large | 4/10, 0/2, 0/2 | 7/10, 1/2, 1/2 | 9/10, 1/2, 2/2 both runs | 8/10, 2/2, 2/2 |
| Schema | 4/6 | 5/6, 6.4 s | 6/6, then 5/6 | 5/6 |
| `edit_file` on the bridge (`mlx.executor: "bridge"`) | 6/30, 2.2 s; 24 of 30 made no `edit_file` call | unchanged code | | |

The gap on `edit_file` closes to within Ollama's own run-to-run spread (20 and 15 of 30 on the same code); MLX's
failures are now Ollama's kind, a wrong line or lost indentation, and three cases of 30 ended without a reply. Drafts
come close; MLX is two to three times slower on them, its thinking longer, and on the large band 114 s a case against
38 s. *The executor decision*: wisp's executor stays the default for 0.20.0. The bridge scored 6/30 on `edit_file`, failing as wisp's
executor did (24 of 30 made no `edit_file` call), since it also turns thinking off for an undeclared model, and it lacks the window's enforcement, usage,
and prefix reuse. What 0.20.0 still measures is listed above; this answers its "MLX against Ollama" item for
Qwen3-1.7B on these suites.

**Refined 2026-10-09: a half-fetched file resumed, the cache seeded from a copy, and Core AI's links followed.**
The 0.21.0 follow-ups of the cache refinement above.

- **Resuming.** The transport now writes each download into `blobs/<id>.incomplete` as it arrives, so an
  interrupted fetch leaves its part (before, it downloaded to a temporary file and moved it in whole, so a part
  never survived). The next run asks for the rest with `Range: bytes=<offset>-`. A 206 is appended to the part; a
  200, a server that ignored the range, rewrites the file from the start and the pull tells the person it started
  again. The whole file is then checked as a fresh one is (size, and the SHA-256 of weights, read in one pass over
  the part and the rest), so a part that does not continue into the listed digest is refused and removed, and the
  next run fetches it whole. A part as long as the file is checked as it is and kept if it passes; a longer one is
  started again. This replaces "an `.incomplete` blob is started again, not resumed".
- **Seeding.** When `<models>/<name>` is a real directory, such as a copy fetched before the pull used the cache,
  the plan checks its files as it checks the cache's blobs, and each that passes is copied into `blobs/` instead of
  fetched, with `copyfile`'s `COPYFILE_CLONE` (an APFS clone, a copy where the volume cannot clone), under the
  blob's lock, and checked again, since the directory may change between the question and the copy. The directory
  is left as it is; the second question still decides whether the link replaces it. `model.pull` adds `seeded`.
- **Core AI** lists a models directory that is a link, and resolves a linked bundle through its real directory,
  as MLX's resolution was made to above.
- **Tests**, with the fake Hub and temporary directories: an interrupted fetch leaving its part and the next run
  resuming it; a part resumed and checked whole; a server that ignores the range; a part that does not continue into
  the digest refused and fetched whole next time; a real directory's intact files seeding the cache while a changed
  one is fetched; and Core AI's linked directory and bundle. Not verified against the live Hub: that its download
  redirects keep the `Range` header and answer 206.
