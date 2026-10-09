# Draft: common model controls

Date: 2026-09-20. Status: proposal, partly built since (brought up to date 2026-10-09; see "What is built").
The rest of the page is the proposal as written; the section below says which parts wisp now has.

Give callers a common way to request reasoning mode, reasoning effort and native speed mode.
Each model/backend combination declares what it can honour and translates supported requests to its
native controls. This extends the [routing and audit backlog](on-device-ai-todo.md); it does not select
a production model, introduce remote routing, or change runtime behaviour.

## What is built

Two backend settings and the thinking display implement part of this proposal, per runtime rather than through the
common vocabulary below ([ADR 0053](decisions/0053-the-models-thinking-shown.md), refined 2026-10-06;
[ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-06):

| Proposed here | What wisp has | Where |
| --- | --- | --- |
| `reasoning.mode` and `reasoning.effort`, for Ollama | `ollama.think`: `true`, `false`, or a level (`low`, `medium`, `high`, `max`, the values Ollama 0.35.1 accepts), sent as `/api/chat`'s `think` only to a model that reports `thinking`; unset sends nothing and leaves the model's default. One operator setting for every Ollama model, not per request or per model | [wisp.md](wisp.md), "`wisp config`"; ADR 0053 |
| `reasoning.mode`, for MLX | `mlx.think`: `true` or `false`, the chat template's `enable_thinking` for a model whose template takes it; unset asks a model declared `reasoning` to think and leaves any other to its template's default. No levels: the template's flag has none | [backends.md](backends.md), "Thinking"; ADR 0053 and ADR 0052, both refined 2026-10-06 |
| `reasoning.output: separate`, and "Reasoning channels" | The thinking is separated at the executor: Ollama's `message.thinking` chunks, and for MLX the block between the template's own thinking tags, split as it streams (a tag split across chunks held until whole, a prompt that opens the block seen from the rendered prompt's end, unclosed thinking kept as thinking, a tool call ending it). It is shown to the person (`thinking` while it lasts, `∴ thought for …` folded after), counted in usage's reasoning tokens, audited as `model.reasoning`, kept in the store, and never sent back to the model. Over MCP it is the thread's `reasoning` resource, not part of `respond`'s text | ADR 0053; [mcp.md](mcp.md) |
| Recording the turn's tokens | `respond`'s receipt carries `usage` (input, output, cached, reasoning) where the runtime reports it | [mcp.md](mcp.md) |

Still proposed, as the rest of this page describes: the common vocabulary and its descriptors per model and adapter,
per-request and per-conversation controls with the precedence below, strict rejection of an unsupported value
(`ollama.think` passes a level to Ollama and leaves its meaning to Ollama, which this page would refuse to do
silently), `speed.mode` and `performance.preference`, Foundation Models' `reasoningLevel`, Core AI's reasoning
controls, the controls in introspection, and the audit of requested against resolved controls. No ADR accepts the
contract yet; the checklist under "Audit and implementation work" is unchanged.

## Control vocabulary

The names below are proposed API vocabulary, not existing CLI flags or configuration fields.

| Control | Proposed values | Meaning |
| --- | --- | --- |
| `reasoning.mode` | `default`, `on`, `off` | Use the model's documented default, enable its explicit reasoning mode, or disable that mode. `off` does not mean that the model performs no computation or internal reasoning. |
| `reasoning.effort` | `default`, `low`, `medium`, `high` | Request a supported native effort level. Levels are relative to that model; equal labels do not imply equal compute, latency or quality. |
| `speed.mode` | `default`, `standard`, `fast` | Select the model/backend's native execution mode where supported. `standard` explicitly disables its fast mode; `default` uses its native default. This is an explicit control, not a latency target or model-selection request. |
| `performance.preference` | `default`, `low_latency`, `throughput` | Express the desired performance objective. This is a preference for routing or supported runtime scheduling/engine settings, not a promise of a particular speed. |
| `reasoning.output` | `final_only`, `separate` | Return only final-answer content, or also expose reasoning that the runtime makes available through a separate channel. This changes presentation, not generation effort. |

`default` preserves the underlying default for that field. Omitting a field inherits it from the next
configuration layer; explicitly supplying `default` resets it to the native default. If the underlying
default cannot be determined, report it as unknown rather than inventing an effective value.

Proposed request example:

```json
{
  "controls": {
    "reasoning": {
      "mode": "on",
      "effort": "low",
      "output": "final_only"
    },
    "speed": {
      "mode": "fast"
    }
  }
}
```

Do not equate effort with temperature, parameter count or maximum answer length. A reasoning-token
budget is a separate native control, where available; an output-token cap is not a substitute for it.
Native fast mode is also distinct from lowering effort or disabling reasoning. An adapter must declare
its actual meaning, supported combinations and any quality, cost or execution implications. Do not
synthesize fast mode by choosing a smaller model or reducing effort. The separate performance
preference expresses a routing objective and is not a replacement for this native control.
An optional deadline would also be separate from the performance preference: cancellation cannot
guarantee that an already-started tool operation was undone.

## Support belongs to a model and its adapter

A reasoning capability bit is insufficient. The control descriptor for an exact model revision,
runtime version and adapter version should report:

- Supported values and known defaults for each control, including whether reasoning is always on,
  switchable, unavailable or unknown.
- The native mapping and its scope: per turn, per session or requiring model reload.
- For speed mode, the native standard/fast settings, known tradeoffs and any coupling to reasoning
  mode or effort. Do not assume that fast implies low effort or that fast plus high effort is invalid.
- Declaration provenance: framework, runtime, model/template metadata or operator configuration.
  Keep any live verification evidence separate from the declaration.
- Whether reasoning content can be separated correctly, including a prompt that already opens the
  reasoning block. A model need not expose reasoning text to support an effort setting.
- Supported combinations with tools, schema output, streaming and conversation continuation.

Only advertise a control as supported when the adapter can apply it. A model card or tokenizer flag
alone does not establish support through Wisp. Introspection should distinguish native capability
from the subset currently available through the adapter.

## Resolution and failure behaviour

Use one resolution path for CLI, chat and MCP. Proposed precedence is per-request controls, conversation
defaults, operator defaults, then native defaults. Validate the complete request before generation or
tool execution. Persist the resolved controls for each turn; do not alter earlier transcript entries.

Explicit reasoning mode, effort and speed mode requests are requirements. Reject unsupported values or combinations with an
error naming the model, field and supported alternatives. Do not silently replace high with medium,
interpret off as low, or accept a setting that the backend will ignore. Off plus a non-default effort
is contradictory and should be rejected. A non-default effort with default mode can imply on when
the adapter declares that mapping; record that resolution explicitly.
Apply the same strict resolution to `speed.mode`: reject an unsupported fast request rather than
treating it as a best-effort latency preference. Reject conflicting explicit controls when native
fast mode cannot honour the requested reasoning mode or effort. Applying fast mode does not guarantee
a particular measured latency.

A performance preference is advisory. Report whether it was applied, left to routing, or unavailable.
If the caller pins a model, honour that selection. A preference alone must not switch the model, disable
explicitly requested reasoning, shrink required context, change the requested output contract, or move
work off-device. Future routing may select another model only within the caller's existing model,
quality and locality constraints. Any native speed/quality tradeoff must be described and permitted by
that policy rather than hidden behind the word fast.

Reject a per-turn change that the current session cannot safely support; do not silently discard
history to reopen it. Concurrent requests must not mutate shared model configuration. Capability and
mapping caches must be invalidated when their model/runtime/adapter identity changes.

## Reasoning channels

Separate reasoning at the adapter boundary before it reaches final-answer text, JSON parsing or the
tool-call parser. Use the model's actual protocol, not a global regular expression over arbitrary
answer text. Support delimiters split across streamed chunks and prompts that already contain an
opening delimiter. An incomplete reasoning block must not be promoted to a final answer or tool call.

`final_only` does not save the cost of reasoning tokens. `separate` exposes only content provided by
the runtime; it does not promise access to private model state. Transcript/audit retention of reasoning
is a separate policy from whether it is sent to the caller. Always record the requested settings and
their resolution without requiring a reasoning trace to explain a routing decision.

## Evidence and initial mappings

These observations identify mappings to implement and test, not completed Wisp control support.

| Model/runtime | Evidence | Consequence for the abstraction |
| --- | --- | --- |
| Granite 4.2 | The installed template and IBM's model card expose `enable_thinking`, `low_effort` and `reasoning_effort="low"`. Thinking is the template default. | Can represent an on/off switch and low effort. Do not invent a medium/high distinction that the native interface does not provide. |
| Liquid LFM2.5-8B-A1B | Liquid describes this checkpoint as reasoning-only. Its installed template has no thinking-off switch; `preserve_thinking` controls history rendering. | Report always-on reasoning unless a supported, verified alternative is established. Hiding its reasoning output is a separate capability. |
| Ollama | The API's `think` parameter accepts model-dependent booleans or effort levels; GPT-OSS requires levels and ignores booleans. | A generic `think=true/false` translation is insufficient. Declare and validate the exact per-model value set. |
| Foundation Models | The installed Xcode 27 SDK declares `ContextOptions.reasoningLevel` values `light`, `moderate`, `deep` and `custom(String)`. | Low/medium/high are candidate mappings, conditional on the selected model and executor honouring them. `light` is not evidence of an off switch. |
| MLX Swift bridge | The pinned bridge consumes a model-specific `reasoningConfig` in addition to the declared reasoning capability. | Resolve the reasoning protocol and template controls before advertising mode/effort support. |
| Core AI bridge | In the local integration check, requesting tools plus schema output skipped the tool call and invented a field value, while the ordinary tool call and a subsequent schema turn worked. | Independent tool and schema capability bits do not establish support for their combination. Reject unsupported combinations until implemented. |

Sources: [IBM's thinking modes](https://huggingface.co/ibm-granite/granite-4.2-3b#thinking-modes),
[Liquid's model description](https://www.liquid.ai/blog/lfm2-5-8b-a1b),
[Ollama thinking controls](https://docs.ollama.com/capabilities/thinking).
Local evidence is the 2026-09-20 run at
`~/.local/share/daimon-eval/daimon-tests-2026-09-20/REPORT.md`, its raw JSON results, and the pinned source
snapshot beside it. The Xcode SDK and installed model templates were inspected on the same date.

## Audit and implementation work

Extend the existing backend registry rather than putting provider-specific switches into the main
Agent. Keep the common request, descriptor and resolution result independent of MLX/Core AI SDK types.
Adapters own native translation and reasoning parsing; routing owns model selection and performance
preferences. The exact Swift types and wire/CLI spellings require an implementation decision.

- [ ] Define the common descriptors, requests, resolution rules and typed errors in the core layer.
- [ ] Add adapter mappings and combination checks for each supported model/runtime pair.
- [ ] Expose supported controls and their provenance through model introspection.
- [ ] Thread the same controls through CLI, chat, configuration and MCP, with documented scopes.
- [ ] Record requested controls, inherited values, resolved values, native parameters, mapping version,
  application scope, and any refusal or unfulfilled preference against the originating prompt/attempt.
  Distinguish parameters merely forwarded from settings acknowledged by a runtime or verified by a test.
- [ ] Keep the existing session/turn correlation while adding the stable prompt identity described in
  the routing backlog. Do not claim a prompt ID exists until it is implemented.
- [ ] Keep wall time, model-load time, first useful output, token counts where available, tool/approval
  time, and measured correctness separate from requested effort or speed labels.
- [ ] Add an ADR for the accepted contract before implementing behaviour, and update the command,
  MCP, backend and audit references alongside the implementation.

## Acceptance checks

Use model-independent tests for inheritance, unsupported controls, contradictory settings, native
parameter mapping, session scope and isolation between concurrent turns. Test native standard/fast
selection, rejection of unsupported speed modes and preservation of explicit reasoning settings.
Test combinations of speed mode, reasoning,
schema output and tools, including refusal before any tool runs. Exercise streamed delimiters, prompt-
supplied opening markers, incomplete reasoning and final-answer extraction as adapter protocol tests.

Keep live-model checks separate. Verify both the setting and task correctness: disabling Granite's
thinking should remove generated reasoning rather than merely hide it; an off request for the current
Liquid checkpoint should be refused; a low-effort request must not masquerade as a measured latency
guarantee. Recheck tool use, schema content and continuation for every supported combination. Compare
speed and accuracy on repeated, controlled workloads after the mappings work.
