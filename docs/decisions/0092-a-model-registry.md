# ADR 0092: A model registry: what is known, what is available, what is enabled

Date: 2026-11-28. Status: proposed 2026-11-28, at the operator's request; the operator answered its open questions
the same day (below). Stages 1 and 2 built 2026-11-28: the registry and its file, and the listing that keeps and reads it. Follows
[ADR 0056](0056-models-enabled-and-disabled.md) (enabling and checking models),
[ADR 0059](0059-one-set-of-model-actions.md) (`ModelActions`), and [ADR 0091](0091-wisp-app-window.md) (the window's Models
tab).

## Context

`wisp models list`, chat's `/models` and `/model`, the model's `models` tool, and `Wisp.app`'s Models tab all show one
listing, `ModelListing.entries`. Each time it is asked for, it is built from scratch:

- Apple's two models.
- Each backend's `installed` models.
- Each backend's cached models not linked yet (`unlinked`).
- Every model in `models.disabled` that no backend listed.

Whether a backend's models survive the backend being unreachable depends on where the backend keeps them. This was
read from the code on 2026-11-28:

| Backend | Where `installed` reads | When it cannot be reached |
| --- | --- | --- |
| `coreai`, `mlx` | Folders on this Mac | Always listed |
| `llamacpp` under `llamacpp.server wisp` | The links in wisp's llama.cpp models folder (ADR 0082) | Listed, whether or not the router runs |
| `ollama`, `lmstudio`, a `llamacpp` server the person runs | The server, over HTTP | Gone from the listing; one line says the server did not answer |

So when Ollama is not running, its models vanish from every face, and only a disabled one is kept. The person loses
the list of what they had and how to get it back, though wisp holds much of it:

- Per-model settings, `<runtime>.models.<name>`: `think`, `contextLength`, and the capabilities a check declared,
  with its date.
- The `model` setting.
- Each saved thread's model (`ThreadStore`, ADR 0066).
- The audit log's `model.pull`, `model.add`, `model.uninstall`, and `model.verified` events.

On 2026-11-28, seeing the window list only `system` from a scratch home with Ollama stopped, the operator asked for a
registry that keeps apart what is registered, what is available, and what is enabled, "so we can offer the user a view
of what is known even if it is not available or enabled, helping them remember what to do".

## Decision (proposed)

1. **Three states per model, kept apart.**
   - **Registered**: wisp has a record of the model.
   - **Available**: its runtime answers now and serves it, or its files are on this Mac.
   - **Enabled**: it is not in `models.disabled`, as now.

   A model can be registered and enabled but not available: Ollama's `granite4.2:8b` while Ollama is stopped. Such a
   model is listed, marked unavailable, with the reason and what to do.
2. **The registry is a file, `~/.wisp/models.json`, that wisp writes and the person can read, but need not edit**
   (the operator, 2026-11-28: hand editing is not needed for now). It holds one entry per
   model, in canonical form (`ollama:granite4.2:8b`), with:
   - `firstSeen` and `lastSeen`: the days a listing last had it from its runtime.
   - `origin`: `seen` (a runtime listed it), `pulled`, `added`, or `configured` (named in `config.json`).
   - The last facts its runtime reported (size, parameters, format), so an unavailable model still has a detail line.

   It is a cache of what was seen. Settings stay in `config.json`, and the runtimes stay the authority on what they
   serve. A missing or unreadable file is rebuilt from the next listing and loses nothing but the days.
3. **Kept current by the listing.**
   - Every listing that reaches a runtime records what it serves.
   - A pull, an add, or a check adds its model.
   - `wisp models uninstall` removes it.
   - A listing that cannot reach a runtime leaves that runtime's entries as they were, marked unavailable, rather than
     dropping them.
4. **Forgetting is the person's.** `wisp models forget NAME`, `/models forget`, and the window's **Forget** remove an
   entry that is not available. A model removed outside wisp (`ollama rm`) stays registered, unavailable with "not
   served by Ollama", until forgotten.
5. **The reason and the next step, per runtime.** An unavailable model's line names why and what to do:

   | Why | What to do |
   | --- | --- |
   | Ollama is not running | Open Ollama, or run `ollama serve` |
   | Ollama runs but does not serve it | `ollama pull <name>` |
   | wisp's llama.cpp router is stopped | `wisp llamacpp agent repair` |
   | A GGUF file's link is broken | Already said today |
   | LM Studio's server is off | Start it from LM Studio's Developer tab, or run `lms server start` |
   | An MLX folder is gone | `wisp models pull <repository>` |

   The texts the listing already gives for an unreachable runtime are reused.
6. **Every face shows the same three states.**
   - `wisp models list` gains an `AVAILABLE` column and lists unavailable registered models after the available ones.
     `--json` gains `available`, `registered`, and `reason` per model.
   - The window's Models tab shows them greyed, with the reason and the step.
   - Chat's `/model` and Tab offer only available and enabled models, as now.
7. **What the model sees.** The model's `models` tool lists registered models that are unavailable too, each with its
   reason and next step, so it can tell the person "start Ollama to use granite4.2:8b" (the operator, 2026-11-28). It
   cannot switch to or enable such a model, which a request refuses with the same reason.
8. **Saved threads say when their model is unavailable.** `wisp threads` and `wisp://threads` mark a thread whose
   model is registered but unavailable, with the reason. What a resumed thread does about it is decided after this is
   built (the operator, 2026-11-28).
9. **Audited.** Forgetting records `model.forget`. Registering a model a listing saw records nothing, since the
   listing already ran and the registry is a cache of it.

## Plan

Each stage is a commit, with tests that need no model and docs in the same commit.

1. **The registry** (built 2026-11-28). `ModelRegistry` in `WispCore/Session`:
   - Reads and writes `models.json` atomically, holding the file lock wisp's other state files use.
   - Merges a listing into the registry, and marks a runtime's entries unavailable when it did not answer.
   - Pure functions over values, tested against fixtures.
2. **The listing uses it** (built 2026-11-28). An unavailable model's reason is its `problem` until stage 3 gives
   it a column of its own, so every face already shows it as `not usable:`. An uninstall forgets the model, so an
   uninstalled model is not listed as unavailable.
   - `ModelListing.entries` merges the registry into its result.
   - `Entry` gains `available` and `reason`.
   - The per-runtime reasons (decision 5) come from each backend, through a new `ModelBackend.unavailable(...)` with a
     default.
   - The existing listing tests are extended for a runtime that does not answer.
3. **The terminal.**
   - `wisp models list`, its `--json`, and chat's `/models` show the three states.
   - `wisp models forget` is added, with `/models forget`.
   - The `models` tool lists unavailable models with their reasons (decision 7).
   - `wisp threads` and `wisp://threads` mark a thread whose model is unavailable (decision 8).
   - Pulls, adds, checks, and uninstalls keep the registry current.
4. **The window.** Unavailable models are greyed in the Models tab, with the reason, the step, and **Forget**. ADR 0091's
   footnote stays for a runtime with nothing registered.
5. **Docs and acceptance.**
   - `wisp.md` (`models list`, `forget`), `logging.md` (`model.forget`), `trust.md` (the new file in the table of what
     wisp keeps), and `design.md`.
   - A probe with Ollama stopped and started again, recorded here before the operator accepts.

## Answers from the operator, 2026-11-28

1. **Where registration lives:** a cache file is right; hand editing is not needed for now (decision 2).
2. **The model's `models` tool:** it sees unavailable models, with their reasons (decision 7).
3. **How long an unseen model stays:** for ever, until the person says to forget it (decision 4).
4. **Threads:** a saved thread says when its model is unavailable (decision 8). What to do about it is decided after
   this is built.

## Consequences

- A stopped runtime no longer empties its part of the list. The person sees what they had, why it cannot run, and the
  one step that brings it back.
- wisp keeps one more file under `~/.wisp`, written by listings. It names models, not conversations, and is listed on
  the trust page.
- The listing does a small file write when it changes something. Listings that change nothing write nothing.
