# ADR 0088: Core AI through wisp's executor

Date: 2026-11-09. Status: proposed; the operator's to accept. Would amend
[ADR 0019](0019-model-backends.md) (Core AI models run through wisp's own executor; coreai-models' bridge stays as
an option) and extend [ADR 0052](0052-mlx-on-a-par-with-ollama.md)'s approach, a runtime driven by wisp's executor,
to Core AI. Drafted on 2026-10-08 against the code of that day and not landed then; rewritten for the code of
2026-11-09.

## Context

`coreai:` models run through the `CoreAILanguageModel` bridge from `apple/coreai-models` (ADR 0019), at the
pinned commit `3f109ef`, which is unchanged since. On 2026-10-05 three community Core AI bundles were tried in wisp
on an M4 Max (48 GB, macOS 27): Agents-A1-4B (a Qwen3.5 text tower, int8), Nemotron-3-Nano-4B (int8), and Muse
Glimmer 30B (int4). None of them is on this Mac any more, so nothing below was measured again for this record. All
three loaded and answered a text prompt. Four things went wrong:

| What | Seen | Cause |
| --- | --- | --- |
| Tool calls vanished | Agents-A1-4B and Nemotron thought "Let's call the tool", then the turn ended with no call and no error | Their templates ask for the XML form, `<tool_call><function=NAME><parameter=KEY>…`. The bridge's `ToolCallParser` reads only JSON inside `<tool_call>` and drops a body it cannot parse |
| Thinking in the reply | The whole reasoning, then a bare `</think>`, then the answer | The templates open `<think>` in the generation prompt, so the model writes only the closing tag; the bridge's `ThinkTagParser` always starts outside a block |
| An abort as wisp exited | Muse Glimmer printed its reply, then SIGABRT (exit 134), once in four runs | The crash report: the main thread in `exit()` running C++ static destructors while a background task released the engine, whose `MPSGraphExecutable` teardown touched a static registry being destroyed (`std::terminate`). The pipelined engine winds each generation down in an unstructured `Task` that holds the engine strongly, and that task held the last reference |
| A silent exit on a bad bundle | A half-downloaded Muse Glimmer bundle: no reply, no wisp error | Fixed apart from this record: the weights are checked against `main.hash` before Core AI reads them (`BundleIntegrity`, [backends.md](../backends.md), "Core AI") |

The bridge's parsers are private to its executor, and the framework's `LanguageModelExecutorGenerationChannel`
events are opaque (its `Event` and `Action` types expose no accessors in the macOS 27 SDK), so wisp cannot rewrite
the bridge's output after the fact. Nor can wisp reach the bridge's engine to wait for it: the bridge keeps it in
`ModelResources`, which is internal, and its public `unload()` drops the reference without waiting for the
generation task still winding down, so the race in the third row stays. coreai-models does not accept pull requests
("If you open a pull request, it will be closed", its README); it takes bug reports as issues.

What coreai-models makes public at `3f109ef` is enough to drive the engine directly (read in its checkout on
2026-11-09): `LanguageBundle` and its `loadTokenizer()`, `CoreAIRunner(bundle:).makeInferenceEngine()`, the
`InferenceEngine` protocol (`generate`, `warmup`, `lastPrefixHitCount`, `cancel()`, `supportsLogits`,
`supportsGuidedGeneration`), `LanguageConfig.additionalStopTokenIds`, `StopSequences`, and both constrained decoding
strategies. Only `ConstrainedGenerationCapable`, which the bridge uses to pick a strategy, is `package`.

Since the draft, wisp gained most of what the executor needs: `ThinkingSplitter` and `ThinkingFormat` in `WispCore`,
shared by MLX's executor and `ReplyRelay`; `TextToolCalls`, the strict all-or-nothing rules every reading of calls
from text follows; `RequestThinking`, the thinking a request's scope asks for (ADR 0053, amended 2026-10-11); and
`TurnStop`, the person's stop, which MLX's executor honours.

## Decision

### wisp's own executor for Core AI

`coreai:` models run through `CoreAIModel`, a `LanguageModel` whose executor maps each request onto the bundle's
chat template (through the transcript mapping the Ollama and MLX executors share, `ChatMessage`, and
`ChatTemplateValues`, moved from `WispMLX` to `WispCore`) and hands it to a `CoreAIEngine`:

- **One engine per bundle**, made on first resolution and kept for the process, so every thread on a bundle shares
  one copy of the weights. It loads the tokenizer alone when it first counts, and the weights on the first request,
  as the bridge does (`CoreAIRunner`, then a warm-up). Requests run one at a time: the pipelined engine cancels a
  generation still in flight when another starts.
- **No prefix pool.** Core AI keeps one cache per engine and reuses its prefix itself; the executor reports the
  tokens it reused (`lastPrefixHitCount`) as cached.
- **The window is enforced**, as for MLX: the window the bundle was exported for, a prompt of it or more refused
  with `LanguageModelError.contextSizeExceeded`, and generation stopping at it.
- **Thinking and calls read by wisp**, from the text as it streams, by the template's reply format
  (`ReplyFormat`, read from the chat template's text):
  - *Tagged*: thinking between the template's tags (`ThinkingSplitter`), primed when the rendered prompt ends inside
    an open block; calls in `<tool_call>` frames (`ToolCallFrames`, in `WispCore`), in any of the three forms
    templates ask for: a JSON object, a JSON array, or the XML form, with each XML parameter read as its schema's
    type. A reply that ends on the model's own stop token still inside the block the prompt opened, having said
    nothing else, has its block's text taken as the reply too: Nemotron answered after a tool result without closing
    the block (probed 2026-10-08). Cut off by its budget, it stays thinking.
  - *Channels*: messages routed by header, `to=self` for thinking, `to=user` for the reply, `to=TOOL` for a call
    written in ATEM (`ToolCallFrames.atem`), each ended by `<|eom|>`, the turn by `<|eot|>`: Muse Glimmer's
    template, which the bridge handled and the tagged reading does not. Generation stops once a tool message ends,
    so nothing the model would write in the tool's place is read.
  - A frame or tool message that holds no call to an offered tool stays in the reply as the model wrote it, rather
    than being dropped, by `TextToolCalls`' rules.
- **Stop tokens**: the tokenizer's end of sequence, the extra ones its configuration lists (as the bridge reads
  them), and the template's own end of turn (`<|im_end|>`, `<|eot|>`) when it writes one.
- **Schema replies** are generated by the engine's constrained decoding, as the bridge does: the pipelined strategy
  for an engine without logits, the per-step one otherwise. No thinking phase before the constraint, as MLX's
  executor has.
- **Capabilities** come from the chat template: tool calling when it renders tools, reasoning when it marks
  thinking or routes to `self`, and guided generation, which the engine is asked for when a request needs it.
- **Exact counts.** `ResolvedModel.tokenCount(for:)` renders the transcript, with the tools its instructions
  declare, through the template, without loading the weights.
- **Thinking is the template's default** unless a request's scope asks otherwise: a template that takes
  `enable_thinking` is sent what `RequestThinking` asks (off for wisp's own calls, such as a classifier's verdict,
  or a thread's `think`), as MLX's is (`ThinkingControl`); with nothing asked, nothing is sent. A `coreai.think`
  setting, like `mlx.think`, is left until a model needs it. This is the one choice the draft did not make, since
  `RequestThinking` came after it; it follows ADR 0053's amendment rather than deciding anything new.
- **The person's stop** (`TurnStop`) cancels the request, which the engine checks at every token, as MLX's
  executor does.
- **The bridge stays**, as `coreai.executor: "bridge"`, the escape hatch while wisp's executor is young.

### Shutting the engines down before exit

The executable runs its command through `ModelBackends.shuttingDown(after:)`, which awaits every backend's
`shutdown()` after the command, whether it returned or threw, before the process exits. Core AI's backend shuts down
each engine its executor made: it waits for the engine's turn, calls the engine's `cancel()`, which awaits the
generation task still winding down, and drops the engine on that task. The engine's last reference then goes before
`exit()` runs its static destructors. Other backends do nothing. The bridge's engines are not reachable from wisp and
are not shut down, so the bridge keeps the race.

### Upstream

The tool-call and thinking bugs, and the profiling span that a failed load leaves open (the "ProfileSpan[ModelLoad]
was not explicitly ended" message), are for coreai-models' issues; the teardown race in MPSGraph for Apple through
Feedback Assistant. wisp does not wait for them.

## Consequences

- Measured on 2026-10-08, M4 Max, macOS 27, with `WISP_HOME` a scratch directory, on the three bundles above, which
  are no longer on this Mac, through the draft of this executor: all three answered "Paris" to a one-word question
  with no thinking in the reply, and ran the `current_date` tool loop to a one-sentence answer. Agents-A1-4B: text in
  19 s, tools in 22 s. Nemotron-3-Nano-4B: 7 s and 15 s. Muse Glimmer 30B: 19 s and 34 s, with Core AI's compiled
  copy already cached; through the bridge on 2026-10-05 the same prompts took 45 to 83 s, the first runs compiling
  it. The executor as written for the code of 2026-11-09 has not run on a real bundle; its tests drive it over a
  scripted engine.
- Exit: on 2026-10-08 six consecutive Muse Glimmer runs through the draft executor exited 0. So did six through the
  bridge in the same build, so the race did not recur in that sample either way; the fix rests on the crash report's
  mechanism, which shutting down before exit removes, not on a measured rate. One abort in four runs was seen before.
- `WispCoreAI` depends on swift-transformers' `Tokenizers` directly, the same package coreai-models uses; the
  lockfile's pins do not change.
- `ChatTemplateValues` moved from `WispMLX` to `WispCore`, shared by both executors. MLX's own tool-call parsing is
  unchanged; its readings of the XML and ATEM forms are left to mlx-swift-lm.
- A bundle whose template uses a reply format wisp does not know is read as tagged without thinking: its text is
  the reply and only `<tool_call>` frames are calls. `coreai.executor: "bridge"` is the fallback.
- A retried turn (ADR 0083, ADR 0086) and condensing on overflow (ADR 0045) work for Core AI models as for any
  other, now that an overflow is reported as one. `model.request` stays Ollama's.
- Not measured: guided generation through wisp's executor on a real bundle, the static-shape (Neural Engine)
  engine, a request's thinking switch on a real template, and long multi-turn threads.
