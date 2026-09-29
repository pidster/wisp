# ADR 0025: Condense ahead of a known window from the usage the runtime reports

Date: 2026-09-20. Status: accepted.

## Context

`Agent` recovers from context overflow reactively: Apple's models throw `contextSizeExceeded`, the
transcript is condensed, the prompt retried (ADR 0003 and `docs/context-management.md`). Ollama and the
other local runtimes never throw. Past the window they drop the front of the prompt, which is the
system message, and answer as if there had been no instructions. This happened repeatedly to the git
thread in this repository: after a few commits with hook output the model stopped following its fixed
instruction and started explaining the output instead.

What is available: every executor already reports the tokens a request used (`updateUsage`); the
framework exposes `LanguageModelSession.usage`, but it accumulates across requests (probed: two
one-request turns of 40 tokens read 80), so the last request's figure has to be kept by the executor
itself. `SystemLanguageModel` states its `contextSize`,
and Ollama accepts `num_ctx` per request, so the window can be chosen rather than discovered. What is
not: a token count for a prompt that has not been sent, without a model call.

## Decision

- `ResolvedModel.contextSize` states the window when the model or its settings do (the system model's
  property; Ollama's configured `contextLength`, default 8192, sent as `num_ctx` on every request so the
  server's default cannot differ from the limit wisp condenses against). Otherwise it is nil until an
  overflow error reports it, which `Agent` records.
- Executors that report usage keep the last request's input tokens on the model (`UsageReporting`:
  Ollama from `prompt_eval_count`; the scripted test model). Before each prompt, `Agent` adds a rough
  cost for the new prompt (four bytes per token) to that figure. If the sum reaches `contextBudget` (85%) of a known window, the
  transcript is condensed to the policy's turns first, audited as `context.condensation` with reason
  `budget`; an overflow recovery is audited with reason `overflow`. A window nobody knows changes
  nothing, and a `.failFast` policy never condenses.
- `Agent.contextTokens()` falls back to the reported usage for models that cannot count, so `/tokens`
  works for Ollama.

## Consequences

- The instructions survive long threads on Ollama; the trade is a few hundred tokens of headroom and
  a rough prompt estimate. The estimate errs high for ASCII prose and low for CJK text; the budget
  absorbs that.
- `ollama.contextLength` is a memory choice the operator makes; the doctor and `wisp config` show it.
- Tests without the model: the scripted model reports 40 input tokens per request, so an agent on a
  50-token window condenses on the second prompt and audits it (`AgentTests`); the Ollama request body
  carries `num_ctx` and the settings round-trip (`OllamaModelTests`).
- Not done: counting the prompt exactly for models that can count (a model call per prompt), and
  summarising instead of dropping. Both remain in `docs/context-management.md`.

## Amendment, 2026-09-29: counting when the runtime reports nothing, and overflow as a message

On macOS 27 the on-device model reports no token usage, so `lastInputTokens` was always 0 and the ahead
check never ran for it. It also reports an overflow as `inferenceFailed` with the message "Provided N
tokens, but the maximum allowed is M", not as `contextSizeExceeded`, so the reactive retry never ran
either. A scripted chat reached 7,460 of 8,192 tokens (91%) and then failed a turn outright.

**Decision.**
- **Count when nothing is reported.** When the model reports no usage but can count its transcript
  (`ResolvedModel.tokenCount`), the ahead check counts before each prompt. That is the cost this ADR
  avoided for runtimes that report; a model that reports none leaves no other way to see the window
  filling. Across the six file-reading turns of the same chat, turn times with and without the count
  differed by at most about 0.3 s, within run-to-run noise.
- **Read the overflow message.** `Agent.overflow(in:)` recognises the message form as well as the
  framework's error, taking the window and the request's size from the text.
