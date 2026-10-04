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
