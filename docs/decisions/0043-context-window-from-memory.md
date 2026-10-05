# ADR 0043: Size a local model's context window from its shape and the Mac's memory

Date: 2026-09-29. Status: accepted. Amends [ADR 0016](0016-local-runtimes-through-an-executor.md) (Ollama's
settings) and [ADR 0025](0025-context-estimation.md) (the window the agent condenses against). Amended by
[ADR 0045](0045-layered-context.md): the window also sets the target condensing brings the context down to and the
caps of the earlier block (facts and the summary, as shares of it); open question 9, cited under Consequences, is
answered by tool output sent as a reference after its turn rather than sized to the window, so tool results keep
their 4 KiB bound within their own turn. Amended by [ADR 0052](0052-mlx-on-a-par-with-ollama.md): an MLX model's
window is sized by the same rule from its `config.json`, and a Core AI model's is its bundle's declared window.

## Context

wisp asks Ollama for a context window on every request (`num_ctx`), so that it knows the limit it
condenses against ([ADR 0025](0025-context-estimation.md)). That window was `ollama.contextLength` from
`config.json`, 8,192 by default, the same for every model. On 2026-09-29, `/api/show` reported that
`granite4.1:8b` supports 131,072 tokens. wisp ran it in an 8,192-token window, so it condensed as often
as the on-device model, for no reason but the setting.

A model's maximum is not the right request either. Ollama keeps a key-value cache for the whole window,
and on Apple Silicon that memory is shared with everything else on the Mac. The cache grows linearly with
the window, at a rate fixed by the model's shape:

```
bytes per token = 2 (key and value) × layers × key-value heads × head size × 2 (16-bit entries)
```

For `granite4.1:8b` (`/api/show`: 40 layers, 8 key-value heads, head size 4,096 ÷ 32 = 128), that is 160
KiB per token. Measured on 2026-09-29 on this Mac (M4 Max, 51.5 GB), loading it at two windows:

| `num_ctx` | Weights + cache, estimated | Ollama's `/api/ps`, measured |
| --- | --- | --- |
| 8,192 | 4.98 + 1.25 = 6.23 GiB | 6.42 GiB |
| 32,768 | 4.98 + 5.00 = 9.98 GiB | 10.23 GiB |

The measured cost per token between the two is 162.6 KiB, against 160 KiB estimated. The rest is about
0.2 GiB of working buffers that do not grow with the window. At its maximum of 131,072 tokens the model
needs about 27 GB. That fits this Mac, where about 22 GB was available at the time, only barely, and it
would not fit a 16 GB Mac at all.

## Decision

- **Size the window when the model is selected.** When `ollama.contextLength` is not set, wisp sizes
  the window from what it can read without loading the model:
  - from `/api/show`: the model's maximum (`<architecture>.context_length`) and shape (`block_count`,
    `attention.head_count_kv`, `attention.head_count`, `embedding_length`, and `attention.key_length` and
    `attention.value_length` when present);
  - from `/api/tags`: the size of the weights;
  - from `/api/ps`: what Ollama already holds for this model;
  - from the Mac: installed memory, and what is available now (free, inactive, purgeable, and speculative
    pages).
- **The rule.** The window is the largest multiple of 4,096 at which the weights, the cache, and 512 MiB
  of working buffers fit a budget, capped at the model's maximum.
  - **The budget** is the smaller of half the memory available now (counting what Ollama already holds
    for this model as available) and three quarters of installed memory, which is about what macOS lets
    the GPU use.
  - **A floor of 8,192 tokens,** or the model's maximum if that is smaller. If even the floor does not
    fit, wisp uses it anyway and says so: Ollama may then run partly on the CPU, slower but working.
  - **16-bit cache entries are assumed.** A quantised cache (`OLLAMA_KV_CACHE_TYPE`) is not visible from
    outside the server. Assuming 16-bit errs towards a smaller window, which is the safe direction.
- **A configured window wins.** `ollama.contextLength` in `config.json` is used as it is, for every model.
- **Without the shape, fall back.** When `/api/show` gives no shape, the window is 8,192, as before, and
  the reason says why.
- **Fixed for the life of the agent.** The window is chosen when the model is selected: at the start of
  a session, when an MCP thread opens, and at `/model`. It does not change mid-conversation, because
  Ollama reloads a model whenever the requested window changes.
- **Visible.** The `model.resolved` audit event records the window and why, for example "32,768 of
  131,072: 10.2 GiB of an 11.1 GiB budget". The model's backend settings (`wisp models`, `inspect`) report
  it as sized or configured.

The on-device model and Private Cloud Compute are unchanged: Apple fixes their windows and the framework
reports them. Core AI and MLX keep an unknown window until their bundles' metadata is read, which is
left for later.

## Consequences

- On this Mac, `granite4.1:8b` gets a window of tens of thousands of tokens instead of 8,192, depending on
  memory at selection. Conversations condense far less often. Everything that already scales with the
  window follows: the 85% ahead-of-window budget, and the saved context.
- More memory is used while a large window is loaded. The budget keeps that to half of what was free
  when the model was selected, and never more than three quarters of the Mac's memory.
- The window depends on the moment of selection. A session started while memory is tight keeps a small
  window until the model is selected again, even if memory is freed later.
- Tool results and model-pass chunks still use fixed 4 KiB bounds. Scaling them to the window is open
  question 9 of the layered-context proposal
  ([2026-09-29-layered-context.md](../proposals/2026-09-29-layered-context.md)).
- Tests without the model:
  - the sizing rule, with its cap, floor, budget, and rounding;
  - reading the shape from `/api/show`, with and without key and value lengths;
  - reading memory;
  - the fallback without a shape, and a configured window winning;
  - the window reaching the `num_ctx` of each request and the agent's `contextSize`, over a fake
    Ollama.

## Refined 2026-10-04: models reported per layer

`wisp models` showed `gemma4:12b` and `gemma4:26b` at 8,192 tokens from `default`. Ollama's `/api/show` reports
gemma4's `attention.head_count_kv` as an array, one entry per layer (12b: 48 entries, 8 on sliding layers and 1
on global ones; 26b: 30 entries, 8 and 2), with `attention.sliding_window` (1,024) and a 48- or 30-entry
`attention.sliding_window_pattern` (five sliding layers to each global one), `key_length` and `value_length`
512 for global layers and `key_length_swa` and `value_length_swa` 256 for sliding ones. The sizing read a number,
found none, and fell back. No other installed model (`granite`, `llama`, `mistral3`, `qwen35`, `qwen3moe`,
`deepseek2`) reports an array or a sliding window.

The rule now counts such a model layer by layer:

```
bytes per token = Σ over global layers of key-value heads × (key length + value length) × 2
fixed bytes     = Σ over sliding layers of key-value heads × (key_length_swa + value_length_swa) × 2
                  × min(window, sliding_window + 2,048)
```

The fixed bytes come off the budget before the window is counted; the swa lengths fall back to the model's
when missing; a model reported as one number is sized exactly as before. The 2,048 is a batch: llama.cpp sizes a
sliding cache at the window plus one batch of cells, and Ollama chose batches of 512, 1,024, and 2,048 in the
probes below, so the largest is assumed.

gemma4's Modelfile also names a `DRAFT`, a four-layer `gemma4-assistant` model that Ollama runs beside it for
speculative decoding and that `/api/show` does not describe. Its GGUF header gives one global layer as wide as
the model's widest (1 head for 12b, 2 for 26b) and three sliding layers. A drafted model is therefore counted
with one more global layer of that width, and with its 512 MiB of working buffers twice. The draft sets
`shared_kv_layers` to 4, every layer, yet Ollama allocated each of its caches, so `shared_kv_layers` is not read:
it is 0 on both gemma4 models, and the one place it is not 0 showed no saving.

Measured on 2026-10-04 on this Mac (Ollama 0.35.1, which runs gemma4 through llama-server), loading
`gemma4:12b` with a one-token prompt at three windows and reading the cache llama.cpp allocated from Ollama's
server log:

| `num_ctx` | Batch | Global layers (model + draft) | Sliding layers (model + draft) |
| --- | --- | --- | --- |
| 8,192 | 1,024 | 128 + 16 MiB | 640 + 48 MiB (2,048 cells) |
| 65,536 | 2,048 | 1,024 + 128 MiB | 960 + 72 MiB (3,072 cells) |
| 131,072 | 512 | 2,048 + 256 MiB | 480 + 36 MiB (1,536 cells) |

Between 8,192 and 131,072 the global caches grew by exactly 18 KiB a token (16 for the model, 2 for the draft),
the estimate; counting every layer for the whole window, at its own heads and lengths, would give 336 KiB. `/api/ps` could not be
used as it was for granite: for gemma4 it reported 1.39, 2.23, and 1.52 GB at the three windows, less than the
weights and not growing with the window, so a gemma4 model that is already loaded is under-counted as held,
which errs towards a smaller window. Working buffers grew with the batch (about 0.5 GiB at 1,024, 2 GiB at
2,048, the draft and the vision and audio projectors included), which the 512 MiB overhead, doubled for a
drafted model, covers only at the smaller batches; the budget's half of available memory is the margin. Ollama's
own scheduler predicted 12.5 GiB for 12b at 131,072 tokens, against 11.7 GiB by this rule.
`gemma4:26b` (18.7 GB of weights) was not loaded: with about 19 GB available and another model in use it would
not have fitted. Its estimate is 24 KiB a token (5 global layers of 2 heads, and its draft's) and 600 MiB fixed.

## Refined 2026-10-05: hybrid attention and recurrent models

`qwen3.8:27b` (architecture `qwen35`, 17.7 GB) sized at 8,192 tokens wherever it ran. Its `/api/show` reports
`block_count` 65, 4 key-value heads of 256, `full_attention_interval` 4, `nextn_predict_layers` 1, and `ssm.*` fields
(`conv_kernel` 4, `state_size` 128, `group_count` 16, `inner_size` 6,144). It is a hybrid: 64 layers of which every
fourth attends and the rest are gated-delta recurrent layers, which keep a state of fixed size instead of a cache,
and one multi-token-prediction layer after them that Ollama runs as a draft (`--spec-type draft-mtp
--spec-draft-n-max 4`, from the Modelfile's `PARAMETER draft_num_predict 4`). The rule counted all 65 layers at
260 KiB a token, 3.8 times the real cost. `ornith:9b` is the same architecture (32 layers, no draft layer), counted
at 128 KiB against 32.

The rule now counts only the layers that keep a cache:

```
attention layers = layers i < block_count − nextn_predict_layers with (i + 1) % full_attention_interval == 0,
                   or, for a model reporting heads per layer, those with heads > 0
bytes per token  = Σ over attention layers of heads × (key length + value length) × 2
                   + the nextn_predict_layers' own, counted as draft layers (the working buffers twice)
fixed bytes      = recurrent layers × 4 × ((conv_kernel − 1) × (inner_size + 2 × group_count × state_size)
                                           + state_size × inner_size)
                   × (1 + draft_num_predict, for a model that drafts)
```

`(i + 1) % interval == 0` is mlx-swift-lm's convention (`Qwen35.swift`); llama.cpp's source was not available
here, but the layer counts it logged agree (16 of 64, 8 of 32). The state formula is llama.cpp's `n_embd_r` (the
convolution's last inputs) plus `n_embd_s` (the state matrix) at 32 bits, reconstructed from the log rather than
read in source, and it matches the log to the byte. llama.cpp keeps one copy of the state per drafted token to roll
back to (`4 rs_seq`), so a drafting model's state is multiplied. A model that sets none of these fields is sized
exactly as before; without the `ssm.*` fields the layers are still counted but no state is guessed at.

Measured on this Mac (Ollama 0.35.1), reading what llama.cpp allocated from Ollama's server log:

| Model | `num_ctx` | Attention cache | Draft layer's cache | Recurrent state |
| --- | --- | --- | --- | --- |
| `qwen3.8:27b` | 8,192 | 512 MiB (16 layers) | 32 MiB (1 layer) | 748.12 MiB (64 layers, `1 seqs 4 rs_seq`) |
| `qwen3.8:27b` | 32,768 (2026-10-05) | 2,048 MiB | 128 MiB | 748.12 MiB |
| `ornith:9b` | 8,192 (2026-09-23) | 256 MiB (8 layers) | none | 50.25 MiB (`0 rs_seq`) |
| `ornith:9b` | 32,768 (2026-10-04) | 1,024 MiB | none | 50.25 MiB |

The estimate is 68 KiB a token for qwen3.8 (64 for its attention layers, 4 for the draft layer) and 748.125 MiB
fixed (48 layers × 3.12 MiB × 5 copies); 32 KiB a token for ornith and 50.25 MiB fixed (24 × 2.09 MiB): every
figure in the table, exactly. With 30 GB available ornith now gets its full 262,144 tokens (65,536 before);
with its 17.7 GB of weights qwen3.8 needs about 41 GB available to leave the floor (43 GB before), and at 50 GB
available it gets 73,728 tokens, against 24,576 before.

No other installed model changed: `llama`, `granite`, `mistral3`, `qwen3moe`, and `gemma4` set none of these fields.
`deepseek2` (`deepseek-coder-v2`) reports `kv_lora_rank` 512, the compressed cache of multi-head latent attention,
but llama.cpp did not use it for this GGUF: loaded at 8,192 tokens on 2026-10-05 it allocated 2,160 MiB, 270 KiB a
token, the full 27 layers × 16 heads × (192 + 128) × 2 the rule already estimated. A newer deepseek2 GGUF that
llama.cpp runs compressed would be over-estimated, the safe direction.

Not verified, because no such model is installed and llama.cpp's source was not at hand: the GGUF fields of
`granitehybrid`, `jamba`, `nemotron_h`, `lfm2`, `falcon-h1`, `mamba`/`mamba2`, and `qwen3next`. The rule covers them
where they use the same names: a layer reported with no key-value heads is counted as recurrent, and the `ssm.*`
state formula takes a missing `group_count` as 0 (Mamba-1's shape). A pure state-space model reports no
key-value heads and falls back to 8,192 as before; `lfm2`'s short-convolution state is not sized (it is small);
`falcon-h1`, which runs attention and Mamba-2 side by side in every layer, gets every layer counted per token but no
state, which the 512 MiB of working buffers covers for the sizes published. MLX's side is in
[ADR 0052](0052-mlx-on-a-par-with-ollama.md).
