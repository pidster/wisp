# ADR 0056: Models enabled and disabled, the listing as a table, and chat's fallback

Date: 2026-10-04. Status: accepted. Amends [ADR 0013](0013-model-selection.md) (where a model is chosen, a disabled
one is now refused), [ADR 0040](0040-config-from-chat.md) (a setting that holds in the running chat at once), and
[ADR 0052](0052-mlx-on-a-par-with-ollama.md) (`wisp models` lists cached MLX models as rows, and enabling one links it).

## Context

`wisp models` listed every model that could serve a conversation, as tab-separated lines on a pipe and, on a
terminal, four columns (model, parameter count, size, capabilities), the capabilities in the framework's names
(`toolCalling, guidedGeneration`). Most of what wisp knows about a model was not in it: which runtime serves it, the
context window wisp would use and how that was decided ([ADR 0043](0043-context-window-from-memory.md), ADR 0052),
the architecture and quantisation, and, for MLX, whether it is in the models folder or the Hugging Face cache. The
cached MLX models nothing linked were one line in parentheses after the table.

On this Mac the listing held models the operator does not want offered: Ollama models pulled for a comparison, an
embedding model, `private-cloud`, which an unsigned build cannot use. `/model`, Tab, and `/config set model` offered
all of them, and there was no way to say "not this one" short of removing the model from its runtime. The
operator's decisions (2026-10-04):

- A **disabled model is hidden and refused**: `/model` and Tab do not offer it, and it cannot be chosen by `/model`,
  `--model`, `config.json`'s `model`, or an MCP caller's `respond` `model`; the error names it as disabled and says
  how to enable it. The default cannot be disabled until the default changes, so wisp never starts on a model it
  refuses.
- The listing is a designed table: a column for every fact wisp knows, each under a plain heading, the same columns
  in every face, readable in a narrow terminal ("Don't take my table suggestion as a literal requirement").
- In `wisp-tui`, `/models` is a picker: arrows move, Space turns a model on or off, Enter saves, Esc leaves it.
  Elsewhere `/models enable|disable <name>` and `wisp models enable|disable <name>`.
- A complete cached MLX model that `wisp models` names as not linked is enabled the same way, and enabling it links
  it, with no download and so no question.

A probe on 2026-10-04 with `ollama.baseURL` pointed at a port nothing listened on found every entry point failing
fast and clearly (`wisp models`, `wisp doctor`, `wisp "…"`, `/model ollama:…` in a running chat, and MCP `respond`
starting an Ollama thread), except one: `wisp chat` with an unavailable configured model printed one error line and
exited, so the person could not reach `/model` to choose another.

## Decision

### Disabled models

- **Stored** in `config.json` as `models.disabled`, a list of models as `--model` spells them, beside the top-level
  `model`; absent or empty, every model is enabled. It is a setting in `ConfigSettings` (kind `models`), so
  `/config set models.disabled` and `wisp config set` reach it too, and every change is a `config.change` event, as
  ADR 0040 records any setting.
- **Refused at every entry**: `Session.begin` refuses a `--model` that is disabled; `WispThread.openAgent` refuses
  a disabled model whichever way it was named, which covers `/model`, an MCP thread's `model`, `respond`, and the
  routing that opens a ladder's or a task's model (a disabled one is skipped by `ChangeDraft.route`, which tries the
  next, and refused for a task's model pass). The error is `ModelSelection.Failure.disabled`: "model 'X' is disabled;
  enable it with wisp models enable X, or /models enable X in chat".
- **The default is never disabled.** A file whose `model` (or `system`, when it names none) is also in
  `models.disabled` does not load; `ConfigEdit` refuses a change that would make one, with "X is the default model,
  so it cannot be disabled; make another model the default first", or, for `config set model X` with X disabled,
  the disabled error above.
- **Hidden where models are offered**: `/model`'s Tab, `/config set model`'s and `routing`'s choices, and the
  listing's `offered` flag leave them out. The listing itself shows them, with `ENABLED` `no`, so they can be
  turned back on.
- **At once in the chat that changes them.** ADR 0040 applies a setting from the next session, because the gate's
  rules must not change under a conversation the person has approved commands in. Which models are offered is not
  such a rule, and a picker whose choice did not hold until a restart would read as broken. So a session keeps its
  disabled models in a `DisabledModels` set, read from the file when it begins and replaced when this session's
  chat enables or disables one; `/model` and Tab follow it at once. The conversation already running on a model the
  person disables keeps it until `/model` switches. Another running process (a `wisp mcp` server) sees the change
  from its next session, as with any setting.
- **Enabling a cached MLX model links it.** A backend may list models it could serve once linked
  (`ModelBackend.unlinked`) and link one (`ModelBackend.link`); MLX lists the complete `mlx-community` snapshots in
  the Hugging Face cache that the models folder does not name, and links one by `ModelPull.cachedPlan`, a plan made
  from the snapshot alone with every file reused, through the pull's own `link`. No request is made, so no question
  is asked; the person is told what was linked to what, and it is recorded as `model.pull` with outcome `linked`, as
  a pull that found every file in the cache is.

### The listing

One `ModelListing.Entry` per model carries every fact: the selection, the runtime, the parameter count, the bytes
on disk, the format (family or architecture and quantisation: Ollama's `details.family` and
`quantization_level`, MLX's `model_type` and `quantization.bits`, a Core AI bundle's `kind` and `compression`), the
window and its note, the declared capabilities, where an MLX model lives, whether it is enabled, and why it cannot
be used. `ModelTable` lays it out the same way for every face:

| Column | Shows | Dropped on a narrow terminal |
| --- | --- | --- |
| `MODEL` | The name, `*` before the default (in chat, the model in use) | never |
| `RUNTIME` | `on-device`, `Private Cloud`, `Ollama`, `MLX`, `Core AI` | second (the name's prefix says it) |
| `PARAMS` | The parameter count the runtime reports | fifth |
| `SIZE` | The weights on disk | sixth |
| `FORMAT` | Family and quantisation, such as `granite Q4_K_M` | first |
| `CONTEXT` | The window wisp would use | seventh |
| `FROM` | How it is known: `memory` (sized), `config`, `bundle` (declared), `default` (no shape), `model` (its own) | third |
| `WHERE` | MLX only: `models folder`, `HF cache`, `HF cache, not linked` | fourth |
| `ENABLED` | `yes` or `no` | never |
| `CAPABILITIES` | `tools`, `structured replies`, `thinking`, `vision`, or `text only`; last, so it wraps | never |

A column no listed model has a value for is left out; an empty cell stays empty, never a placeholder. On a terminal
the columns are dropped in that order until the last has 20 cells, as `TerminalTable.fitting` decides; the last
wraps under itself as before. The window's `FROM` is read from the note each backend writes, in the forms ADR 0043
and ADR 0052 give it, and a test holds each backend's wording to its word.

The listing shows what can serve the conversation and what the operator can turn on: disabled models, cached MLX
models not linked, and a disabled model no backend lists (Ollama down), with its reason; `--all` adds the rest.
Piped, every column is a tab-separated field in this order whether or not it has a value, so a script finds a field
at the same place on every line, and `--json` (new) has a named field per column (`context` as a number, `bytes`
beside `size`, `contextNote`, `location` as `modelsFolder`, `hubCache`, or `hubCacheNotLinked`) with `default`,
`usable`, and `problem`. Chat's `/models` prints the same table, fitted to the terminal when its width is known.

### The picker

`/models` in a face with choices sends a `choice` with toggles: the existing `choice` line, with `toggles: true`,
`columns` (each `heading` and `drop`, the rank in which a narrow face drops it), and on each option `cells` and `on`.
The answer is `choose` with `values`, the options left on; a `choose` with a single `value` or none is no change, so a
front end that does not know toggles changes nothing by answering it as a plain choice. Chat turns the difference
into enables and disables and applies them as `/models enable|disable` would. Extending `choice`, rather than a
message of its own, keeps the id, the timeout, and the answer's path the ones every choice already has. `wisp-tui`
draws it as a table under the column headings, `[x]` and `[ ]` for on and off, and drops columns by the same ranks
when the dialog is narrow.

### Chat falls back when its model is unavailable

When chat's configured model is unavailable as chat starts (`ModelSelection.Failure.unavailable`, or a backend this
build lacks), chat starts on `system` instead and says so before the first prompt, in the ember colour:

```
ollama:granite4.1:8b is unavailable (no Ollama server at http://127.0.0.1:9: Could not connect to the server);
using system. /model ollama:granite4.1:8b once Ollama is running
```

It is recorded as `model.fallback` (`model`, `reason`, `fallback`), before the `model.resolved` of `system`. The
plain chat and `wisp chat --json` (so `wisp-tui`) share it through `Session.openChatAgent`.

- Only the configured default falls back. A model named with `--model` fails as before: the person asked for that
  model.
- Only unavailability. A model that resolves but lacks a capability the conversation needs is the configuration's to
  fix, and fails as before.
- When `system` is unavailable too, or disabled, chat fails as before, with the configured model's error.
- `wisp respond` and MCP `respond` never fall back. A script or a calling agent chooses its own fallback; a silent
  change of model would make its results depend on what happened to be running.

## Consequences

- `/model` and Tab offer only what the operator wants offered; the listing still shows the rest, marked.
- A file disabling its own default no longer loads, with the reason; one written before this cannot exist, since
  `models.disabled` is new.
- The piped `wisp models` lines changed shape: every column a field, instead of the name and a `detail; capabilities`
  field. Nothing in this repository read the old shape; `--json` is the form for scripts.
- `ChatLoop.Context.models` returns the listing rather than lines, and a face lays it out.
- `wisp chat` reaches its prompt with Ollama down; the note says how to return to the configured model.
- Tests without a model: the refusals at each entry (`--model`, a thread's model, `/model`, MCP `respond` over the
  wire); the file refusing a disabled default; `ConfigEdit` refusing either way round; enabling and disabling writing
  the file, keeping the rest, auditing, and holding in the session at once; enabling a cached model linking it
  through a fake backend and, in `WispMLXTests`, through `MLXBackend` over a temporary cache with a hub that answers
  nothing; the table at 160, 120, 80, and 60 columns, the dropped columns, the piped fields, `--json`, the picker's
  choice; every backend's window note read as its word; the fallback, and each case that must not fall back; the
  picker in `ChatLoop`, the protocol's toggles both ways, and `wisp-tui`'s picker and keys.

## Refined 2026-10-04: enabling checks what an MLX model can do

The operator's direction the same day: "The enable function should take care of the config setting." Linked from
the Hugging Face cache and enabled, `mlx:Qwen3-1.7B-4bit` showed `ENABLED` `yes`, and `wisp models --all` said it
was not usable, because it "does not support tool calling (capabilities undeclared); declare its capabilities in
config.json". Enabling must leave a model usable, and [ADR 0019](0019-model-backends.md)'s rule stands: a capability
is recorded only once verified. So wisp verifies it, on the model itself, and records what passes.

- **When.** Enabling a model (`wisp models enable`, `/models enable`, the `wisp-tui` picker's save) whose backend
  leaves its capabilities to `config.json` (`ModelBackend.declarationKeys`; MLX's is `mlx.models.<name>`) and whose
  entry there declares none, whether the model was disabled, not linked, or already enabled. Ollama's and Core AI's
  runtimes report capabilities (`/api/show`; the bundle's tokenizer markers, thinking format, and the engine's
  guided generation), so nothing of theirs is checked; Apple's come from the framework. Over MCP nothing changes:
  callers cannot enable models.
- **The questions.** Three, in order, each one attempt, greedy (`temperature` 0, which the MLX executor honours), with
  a small reply budget (64 tokens for the reply, 128 for the others): a plain reply ("Say hello.", passing when it
  is not empty), the floor; a call of one trivial tool, `record_word`, asked to record `heron`, passing when the
  call arrives with that word (whatever the model replies after it); and a schema reply of two fields (a colour and
  a number from 1 to 10), passing when it decodes. One attempt, because greedy decoding gives the same answer again,
  so a retry would add time and no information. Each question resolves the model with only the capability it tries
  declared, as the file would declare it.
- **Time limits.** 3 minutes for the first question, which also loads the weights, and 1 minute for each other,
  through `Timeout.run`, which cancels the question and stops waiting at the limit. A question that fails or runs
  out fails only its capability.
- **The floor.** When the plain reply fails, the other two are not asked, nothing is recorded, and the person is
  told the model cannot hold a conversation.
- **`reasoning` and `vision`** are not checked: a short question cannot tell reliably whether a model thinks or
  reads images, and wisp's MLX executor maps text only. The output says so; the person may declare them by hand.
- **Recorded** under `mlx.models.<name>` through `ConfigEdit` (a change by keys, since a model's name holds dots),
  `capabilities` and `verified` (`date`, `passed`, `failed`), audited as `model.verified` and `config.change`, and
  held by the session that checked (`DeclaredModels`), so `/model` can switch to the model in that chat at once.
- **Before it starts**, it says what will run: "checking mlx:Qwen3-1.7B-4bit: loads the model (968.1 MB) and asks
  three short questions …", then each result as it arrives. It asks nothing: enabling was the person's request.
- **Checking again** is `wisp models check <name>` (and `/models check`), a command of its own rather than a flag on
  enable, since checking a model already enabled is not enabling it. It replaces what an earlier check recorded: a
  capability the last check passed and this one fails is taken out, and said so. A capability the person declared by
  hand (in `capabilities` and not in `verified.passed`) is **kept** when its check fails, and the failure reported:
  wisp tells the person, and does not overrule their declaration.
- **The listing** shows a check: `CAPABILITIES` ends `(verified)`, and `--json`'s new `capabilitiesFrom` says how
  the capabilities are known (`verified 2026-10-04`, `config`, `runtime`, `framework`), as `contextFrom` does for the
  window. No column is added.

Measured on this Mac on 2026-10-04, in a scratch home, with the build that has MLX: `wisp models enable
mlx:Qwen3-1.7B-4bit` passed all three in 4.1 s (reply 2.3 s, loading the weights; tool call 0.4 s; schema reply
1.4 s) and recorded `toolCalling` and `guidedGeneration`. Tests without a model cover each check passing and
failing, only passing capabilities recorded, the floor recording nothing, a hand declaration kept, an earlier
check's capability taken out, the time limit with a model that never answers, the audit, the keys with dots, an
enabled model checked on enable, Ollama skipped, and the check over the MLX executor with its fake runtime.

**Three outcomes of enabling (operator's question, 2026-10-04: can enable reject a model for chat agents when it has no
tool or chat support?).** The check run by enable decides the enabling; `setModels` links such a model but leaves it
as it was, and `Session.checkModels` turns it on or keeps it off, recorded as `model.verified` with `outcome` and a
`config.change` of `models.disabled` when that changes.

1. **The reply fails: enable refuses.** The model stays disabled, or becomes so when it was enabled but unusable
   (it was unusable anyway): "mlx:X cannot hold a conversation (…); it stays disabled". Nothing is recorded as a
   capability. `outcome` `refused`. The default model cannot be disabled, so for it the line says so instead.
2. **The reply passes and tool calling fails: enabled for use with tools off only.** "mlx:X holds a conversation but
   did not call a tool; it is usable only with tools off: --no-tools, tools: [] over MCP, the condensers; chat and
   agents with tools refuse it." Only what passed is recorded. Chat and agents with tools refuse it as they refuse
   any model without tool calling, so `/model` and Tab do not offer it; the listing and the picker show it, as
   enabled, with `CAPABILITIES` leading `text only` (`text only, structured replies (verified)` when the schema
   reply passed) and the reason "wisp's check on <day> found it holds a conversation but calls no tools". `outcome`
   `text only`.
3. **Both pass: enabled and usable.** `outcome` `usable`.

`wisp models check` and `/models check` report and record only; they do not turn a model on or off. A check of a
model already enabled is a question about it, not a request to change what is offered, and the person who wants it
off has `disable`. Tests with the fake backend cover each outcome through chat's `/models enable` and the picker's
save, and `check` leaving a refused model's state as it was.

**Refined on 2026-10-09 (0.21.1), after a code review.** Two places where the decision above did not hold:

- **Refused at every entry, under every spelling.** `DisabledModels` compared selections as spelled, so a model
  disabled as `ollama:x` was opened as `ollama:x:latest`, a llama.cpp model disabled by its file's name was opened
  by its `.gguf` path id, and an MLX model disabled as `mlx:<org>/<name>` was opened by its directory's absolute or
  `~` path. Every place the list is consulted (`Session.begin`'s `--model`, `WispThread.openAgent`, the listing's
  `ENABLED`, `setModels` and `setDisabled`, the default-disabled check when the file loads) now compares canonical
  forms, which each backend gives (`ModelBackend.canonicalName`): Ollama adds `:latest` to a name without a tag;
  llama.cpp and LM Studio take a `.gguf` path id's file name, the rule their listing uses; MLX and Core AI take the
  real path of the directory a name points to. The file keeps the spellings the person wrote.
- **A check's result takes precedence over what a server reports.** For llama.cpp, a failed tool check said
  "usable only with tools off" and audited `text only`, yet the model resolved with tool calling when `/props`
  reported the chat template supports tool calls, so a conversation with tools took it. The recorded check now
  outranks the server's report: a capability in the check's `failed` is taken out unless the operator declared it
  by hand. The three outcomes then mean what they say on every backend.
