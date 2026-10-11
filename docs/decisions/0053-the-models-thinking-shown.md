# ADR 0053: The model's thinking shown

Date: 2026-10-04. Status: accepted. Amended on 2026-10-11: thinking chosen per model and per call (below).

## Context

A reasoning model thinks before it answers. Ollama streams that thinking as `message.thinking` chunks whether or
not the request sets `think`: probed on 2026-10-04 with `ornith:9b` against `/api/chat` with streaming on, "Is 91
prime? One word." gave 42 thinking chunks and then 2 chunks of reply, and the same pattern with `think: true`. On
this Mac the models that report `thinking` among their capabilities are `qwen3.8:27b`, `gemma4:12b`, `gemma4:26b`,
and `ornith:9b`.

wisp's Ollama executor decoded only `content` and `tool_calls`. The thinking was dropped, the turn looked idle for as
long as the model thought, and usage reported `reasoningTokenCount: 0`, hard-coded. `ThreadRecord` already had a
`.reasoning` entry kind, unused.

Two facts about the framework, probed on 2026-10-04 with a scripted executor:

- The executor channel has a reasoning event (`.reasoning(action: .appendText(_:tokenCount:))`). The session keeps
  what it carries as a `Transcript.Reasoning` entry before the reply, and usage's `reasoningTokenCount` counts it.
- `streamResponse` yields a snapshot only when the reply's text changes, so a model that thinks yields nothing
  until it answers. A face cannot learn that the model is thinking from the stream. A task-local value bound around
  `streamResponse` and `respond` is visible inside the executor.

What `/api/chat`'s `think` accepts was read from the installed Ollama 0.35.1 binary on 2026-10-04, from its own
refusal message: `invalid think value: %q (must be "high", "medium", "low", "max", true, or false)`.

## Decision

- **The executor decodes the thinking** and sends each chunk to the framework as a reasoning event, so the session
  keeps it as a reasoning entry. Ollama reports no count of its own for thinking and streams a token a chunk, so the
  chunks are its reasoning tokens in the request's usage.
- **The turn is told as it happens, through wisp's own channel.** `Agent` binds a `ReasoningObserver` as a task
  local around each turn's requests; the executor's `ThinkingStretch` tells it when thinking begins (the first
  thinking chunk) and ends (the first reply or tool-call chunk, or the end of the stream). The observer records
  `model.reasoning` at both edges: `phase` `start`, and `phase` `end` with the text verbatim, its bytes, tokens, and
  seconds. Calls outside a turn (distillation, the summary, an assessment) have no observer and record nothing.
- **Every face shows it from those events.** `ChatActivity` says `thinking` while it lasts; the plain chat's working
  line reads `… 9 s · thinking (6 s)`, one line redrawn each second as before rather than an animation, which its
  line-based output does not suit. `wisp chat --json`'s `activity` line gains `thinking: true`. `wisp-tui`'s busy box
  draws the operator's thought bubble (2026-10-04): `.`, `.o`, `.oO`, `.oO( thinking )`, `.oO( thinking. )`,
  `.oO( thinking.. )`, `.oO( thinking... )`, then the last four looping, a frame every 280 ms, the loop waking for each
  frame. When thinking ends, chat shows `∴ thought for 4.2 s, 42 tokens` with the thinking folded under it as a tool's
  output is, and the JSON `event` line carries it as `output`, which `wisp-tui` folds the same way.
- **Kept for the person, never for the model.** The store keeps the thinking as the turn's `.reasoning` entry, linked
  to its `model.reasoning` `end` event. `ContextComposer` leaves every reasoning entry out of every request, the
  turn's own included; condensing leaves it where it is; `memory` recalls it only as "(the model's thinking, kept for
  the person and not recalled)"; and the Ollama executor never sends one back. `/show` takes its entry number or
  event id, `/inspect thinking [N]` shows every stretch or a turn's, and over MCP
  `wisp://threads/{thread_id}/reasoning` lists them and `…/reasoning/{id}` reads one.
- **`ollama.think`**, a setting: `true`, `false`, `low`, `medium`, `high`, or `max`, sent as `think` only to a model
  that reports `thinking`; unset sends nothing and leaves the model's default. It is Ollama's setting, under
  `ollama`, since `model` is a model name and the other backends have no such switch yet.

## Consequences

- Time a reasoning model spends thinking reads as thinking, and its tokens are counted.
- A turn after one that thought starts a new session, because the session holds a reasoning entry the composition
  leaves out. That costs nothing with Ollama, whose executor sends every message each request; an in-process runtime
  that keeps its processed prefix (MLX) should compare without reasoning entries when that matters.
- Within a turn the framework's session still holds the turn's reasoning entries between requests of its tool loop;
  whether a runtime sees them is its executor's choice, and Ollama's sends none.
- Core AI and MLX report thinking the same way when their executors send reasoning events through a
  `ThinkingStretch`; that is left to their own work.
- Tests without a model: the Ollama stream with thinking chunks (decoded, counted, audited, linked, not sent back,
  `think` in the body only when configured and offered), the stretch's edges, the activity and the protocol flag,
  the rendered line and fold, `/show` and `/inspect thinking`, recall, condensing, the MCP resources, and in
  `wisp-tui` the frames, their order and loop, the wake, the box, and the panel.

**Refined 2026-10-06: MLX's thinking shown.** wisp's MLX executor now does what the Ollama executor does, through
the same `ThinkingStretch`. MLX streams one text, so the thinking is split from it by the chat template's own tags,
read from the template rather than assumed: the first tag with `think` in its name whose closing tag the template
also holds (`<think>` and `</think>` in Qwen3's). `PrefixEngine` splits each streamed chunk
(`ThinkingSplitter`: a tag split across chunks held until whole, the template's newlines around a tag dropped,
unclosed thinking kept as thinking, a tool call ending it) and starts inside the block when the rendered prompt's
end has an unclosed opening tag, as a template that writes it into the generation prompt leaves it. The executor
sends the thinking as reasoning events, counts a token a chunk within the tokens generated, and tells the turn's
observer at both edges; the composition leaves the reasoning entry out as for Ollama, so no request carries it.
`mlx.think` (`true` or `false`) sets the template's `enable_thinking` for a model whose template takes it, overriding
the declared `reasoning` that set it before; it has no levels, since the template's flag has none. The prefix cache
is unaffected: the slot keeps the rendered prompt, which never holds the thinking. Probed on this Mac on
2026-10-06 with `mlx:Qwen3-1.7B-4bit` and `mlx.think: true`: 181 tokens of thinking in 2.0 s, shown and folded, and the
reply `No.` without a tag; `mlx.think: false` gave a 6-token reply with no thinking.

What `mlx.think` unset means changed the same day ([ADR 0052](0052-mlx-on-a-par-with-ollama.md), refined 2026-10-06,
"the MLX gap"): a model declared `reasoning` is still asked to think, and any other is left to its template's default
instead of being told not to, as an unset `ollama.think` leaves a model to Ollama; a schema reply thinks first.

**Amendment, 2026-10-11: thinking chosen per model and per call.** `ollama.think`, `mlx.think`, and `llamacpp.think`
applied to every request to every model of their runtime. The granite comparison of 2026-10-09 and 2026-10-10
([measurements.md](../measurements.md), "granite4.1 against granite4.2, with and without thinking") showed what that
cost: `granite4.2:8b` thinking matched `granite4.1:8b` on every delegation suite at 4 to 15 times the time (a median of
34.7 s against 9.0 s a case of `edit_file`, 5.3 s against 0.3 s a schema reply, 14.4 s against 3.0 s a classifier
verdict, its classifier half alone about six hours), and with `ollama.think` `false` it matched 4.1's speed on the
tools and got every draft right. Turning `ollama.think` off would have taken thinking from `gemma4:12b` and
`qwen3.8:27b` too. The operator asked on 2026-10-10 for thinking to be chosen per model and per call.

- **Per model first.** `<runtime>.models.<name>.think` beside the model's `contextLength`: `ollama.models.<name>.think`
  takes what `ollama.think` takes (`true`, `false`, `low`, `medium`, `high`, `max`); `mlx.models.<name>.think` and
  `llamacpp.models.<name>.think` take `true` or `false`; each is validated as the runtime's setting is, and
  `lmstudio.models.<name>.think` is refused at load, since LM Studio sets thinking per model in its app. A model's own
  setting comes ahead of the runtime's; an Ollama name is found with or without its `:latest` tag; an MLX entry that
  sets only `think` declares nothing, as one that sets only a window does. `wisp config set`, `/config set`, and
  `wisp config` take them; `wisp models` shows the default a model is sent beside its `thinking` capability, as
  `thinking (false)`.
- **Per call: wisp's own calls ask for no thinking.** A request-scoped choice, `RequestThinking.current`, a task local
  as the turn's `ReasoningObserver` is, which each executor reads as it builds a request: Ollama's `think`,
  llama.cpp's `chat_template_kwargs.enable_thinking`, MLX's template flag. Nothing in the configuration changes. The
  calls that ask for none, through `RequestThinking.sideCall`, which also unbinds the observer as before: the model
  classifier's verdict (`ModelRiskClassifier`), the fact distiller and the running summary (both from `handOn`), and
  the assessment. A schema reply (`Agent.respond(to:schema:)`, and so `respond` with a `schema`, `triage`,
  `summarise_diff`, `scan_secrets` and `redact` with `thorough`, and every condenser's model pass) asks for none
  unless the conversation chose its thinking. Each answers a narrow question of a fixed shape; on `granite4.2:8b`
  thinking bought none of them anything measurable.
- **Drafts keep the model's default.** The writing step of `draft_change` and `wisp draft` keeps the model's
  configured thinking (`keepsThinking`); its summary step, a schema reply, does not. This is a choice, not a
  measurement: on `granite4.2:8b` not thinking got every draft right (10/10, 2/2, 2/2) where thinking got 9/10, 2/2,
  and 0/2, so thinking did not help drafts there; but a draft is the one writing task among them, and a model whose
  thinking helps its writing should keep it. The per-model setting decides, as it does for a conversation's turns.
- **Open-ended turns keep the default.** A conversation's turns, in chat, `wisp respond`, and over MCP, ask nothing
  unless the conversation chose: the model's own setting, else the runtime's, else nothing sent.
- **The caller over MCP chooses.** `respond` takes `think` (`true`, `false`, or one of Ollama's levels) when a thread
  starts, and refuses it on an existing thread, as it refuses `model`, `tools`, and `instructions`. It is kept on the
  thread's agent (`Agent.thinking`), asked of every turn, and shown as `think` in `wisp://threads` and
  `wisp://threads/{thread_id}`. A level is refused as the thread opens on a runtime whose switch is only on or off
  (`ResolvedModel.checkThink`).
- **A model that cannot think is sent nothing**, whatever is asked: an Ollama model that does not report `thinking`;
  a llama.cpp model neither declared nor reported `reasoning` and with no `think` configured; an MLX model whose
  template does not take `enable_thinking`, which keeps its default; Apple's models and Core AI's, which have no
  switch. A level asked of llama.cpp or MLX is sent as on.
- **Audited where requests are audited.** `prompt` carries `think`, what the turn's requests send (absent when they
  send nothing); `context.distillation`, `context.summary`, and `context.assessment` carry the `think` their call
  sent, and a model classifier's `classifier.verdict` has it in its `metadata` ([logging.md](../logging.md)).

Consequences: `granite4.2:8b` can be the delegation model with thinking off (`ollama.models.granite4.2:8b.think false`)
while `gemma4:12b` and `qwen3.8:27b` keep theirs; the classifier and the condensers stop paying for thinking on a
thinking model; an MCP caller can turn thinking off for a thread of fixed commands and leave it on for a complex
task. A schema reply that asks for no thinking no longer thinks before its constraint starts on MLX (the refinement of
2026-10-06, above); that phase now runs only where thinking is kept. MLX's bridge executor (`mlx.executor bridge`)
decides for itself and takes no per-call choice. Tests without a model: the resolution order and the validation, the
request bodies (FakeOllama, FakeChatServer, the MLX engine's rendered prompt) for a turn, a side call, a draft, and a
model that cannot think, the scripted model's record of what each request asked, `respond`'s `think` on a new thread
and refused on an existing one, the listing's note, and the audit fields.
