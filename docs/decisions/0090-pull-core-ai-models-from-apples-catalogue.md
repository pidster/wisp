# ADR 0090: Core AI models are pulled from Apple's catalogue by preset

Date: 2026-11-22. Status: proposed; the direction (pull by preset) chosen by the operator on 2026-11-22, the rest not
yet agreed; probes 1 to 4 run on 2026-11-22 and probe 5 on 2026-11-23 (below). Would amend [ADR 0059](0059-one-set-of-model-actions.md) (a pull is MLX's only) and
extend [ADR 0088](0088-core-ai-through-wisps-executor.md).

## Context

wisp runs Core AI models from `.aimodel` bundles in `coreai.modelsDirectory` (`<home>/models/coreai` by default), with
the engine, tokenizer, and constrained decoding from [apple/coreai-models](https://github.com/apple/coreai-models),
pinned by commit in `harness/Package.swift` (`3f109ef` on 2026-11-22). Getting a bundle is the person's job: clone that
repository, install `uv`, and run its export (`docs/backends.md`, "Core AI"). Nothing in wisp lists what can be
exported, and a missing bundle's error only names the export command.

The repository is also Apple's curated catalogue. Its model registry (`python/src/coreai_models/model_registry.py`)
at wisp's pinned commit lists 26 language-model presets for macOS, each a short name with a Hugging Face id, a
compression preset, a compute precision, and a context length, which the export takes from the preset:

| Family | Presets (macOS, at `3f109ef`) |
| --- | --- |
| Qwen2.5, Qwen3 | `qwen2.5-1.5b-instruct` (and `-8bit-kv`), `qwen3-0.6b`, `-1.7b`, `-4b` (and `-8bit-kv`), `-8b`, `qwen3-coder-30b-a3b-instruct` |
| Gemma | `gemma3-4b-it`, `gemma3-12b-it`, `gemma-3n-e2b(-it)`, `gemma-3n-e4b(-it)` |
| Others | `gpt-oss-20b`, `muse-glimmer-30b` (and its drafter), `mistral-7b-instruct-v0.3`, `mixtral-8x7b-instruct-v0.1`, `phi-3-mini-instruct`, `phi-3.5-mini-instruct`, `phi-4-mini-instruct`, `olmo2-1b-instruct`, `smollm2-135m/360m/1.7b-instruct` |

`uv run --frozen coreai.model.registry --list-models --type llm --platform macOS` prints the same list from a
checkout. Apple's `main` has moved well past the pin: on 2026-11-23 (`ca2aecf`) its registry also has the Qwen3.5 to
3.8 line (full precision, 262,144 tokens), SmolLM3, and Gemma 4, and compression presets that need macOS 27.2. None
of those can be pulled at the pin; getting them is a bump of the pin, which moves the Swift runtime too, and is a
decision of its own (Consequences).

How the export is built matters for running it from wisp:

- It is a Python package in a `uv` workspace (`python/`, entry point `coreai.llm.export`), depending on `torch` 2.9.0,
  `transformers` 5.12.1, and Apple's `coreai-core`, `coreai-torch`, and `coreai-opt` at exact beta versions; the
  versions it is tested with are in the workspace's `uv.lock`.
- Some presets name a compression file by its path in the source tree (`compression_config`), so the export needs a
  checkout, not only the package.
- It downloads the source weights from the Hugging Face Hub (or ModelScope) and converts them on this Mac.

wisp's pull (ADR 0052, ADR 0059) is MLX's: `ModelPullers` holds one puller, `PullSummary.selection` is `mlx:<name>`,
and a pull fetches a Hub snapshot and links it, approved per pull with the publisher, licence, and download size,
never remembered. A Core AI pull is a different kind of work: a download and then a conversion, which runs Apple's
Python code on this Mac.

On this Mac on 2026-11-22: `uv` 0.9.17 is installed (the workspace needs 0.9.0 or later); there is no checkout of
coreai-models and no bundle in the models directory, so nothing below has been measured here yet.

## Decision

1. **`coreai:<preset>` pulls a registry preset.** `wisp models pull coreai:qwen3-4b`, `/models pull`, and the `models`
   tool take a preset's short name from the registry at wisp's pinned commit. A name not in it is refused, with
   the way to list them. The bundle is written to `<coreai.modelsDirectory>/<preset>`, so `coreai:qwen3-4b` then
   selects it; the export names its directory after the model and compression (`qwen3_0_6b_4bit_dynamic` for
   `qwen3-0.6b`, probe 1), so wisp exports into a staging directory and moves the bundle to the preset's name.
   `wisp models` lists the presets not yet exported as available, beside the exported bundles it lists today, with
   what each preset's family was verified to do at the pinned commit (tools, no tools, or not yet usable in wisp,
   probe 5). A drafter preset is not offered as a model.
2. **The export runs from a checkout at the commit wisp pins.** wisp keeps a checkout of apple/coreai-models at the
   `Package.swift` revision in `<home>/cache/coreai-models/<commit>` and runs
   `uv run --frozen coreai.llm.export <preset> --output-dir <dir>` in it (the export takes a registry short name as
   well as a Hugging Face id), so the Python export and the Swift runtime
   that runs its bundle come from one commit and the tested dependency versions (`uv.lock`) are used. Moving the pin
   moves both. wisp does not install `uv`; without it a pull is refused with how to get it, and `wisp doctor`
   reports it.
3. **The approval says what will run, as well as what will be fetched.** A Core AI pull is asked as an MLX pull is
   (always, per pull, never remembered, the publisher question for the Hub organisation), and its plan adds the
   preset's compression and context, that Apple's export code at the pinned commit runs on this Mac, the
   first-time cost of the Python environment, the size of the files the export will fetch (the whole repository's
   weights, and a drafter's target, probe 5) and the memory the conversion is known to need (probes 2 and 5), and,
   for a gated preset, that it needs the licence accepted and a Hugging Face token (probe 4).
4. **The export runs under wisp's sandbox**, with the network allowed and writes limited to the checkout, the uv and
   Hugging Face caches, the bundle's directory, `$TMPDIR`, and the per-user cache directory. Probe 3 ran the
   conversion under such a profile; building the environment there into an empty cache is still to be shown.
5. **A pull has two phases, shown and cancelled as one.** The status line says which phase it is in (fetching the
   source weights, converting); cancelling stops the export's process group and removes the half-written bundle,
   keeping the downloaded weights in the Hub cache for the next pull.
6. **Pulls are keyed by scheme.** `ModelPullers` holds one puller per backend scheme, and a pull's summary names its
   own selection (`coreai:<preset>`, `mlx:<name>`), so a third backend's pull needs no change in `WispCore`.

## Probes, before any code

1. **One export by hand** at the pinned commit, `qwen3-0.6b` (the smallest): whether `uv run --frozen` builds the
   environment, how long the environment and the export take, the disk used by each (environment, Hub cache, bundle),
   and peak memory; then `coreai:qwen3-0.6b` answers in wisp.

   **Run on 2026-11-22**, on this Mac (macOS 27, Xcode 27.2), from a checkout at `3f109ef`, outside any sandbox:

   | Step | Result |
   | --- | --- |
   | `uv sync --frozen` | Exit 0 in 0.7 s; the `.venv` is 964 MiB. Not a first-time cost: uv's cache already held the packages (2.5 GiB, unchanged by the sync), so the cost of an empty cache is still unmeasured |
   | `uv run --frozen coreai.llm.export qwen3-0.6b --output-dir …` | Exit 0 in 99 s (94 s of CPU), peak resident memory 5.8 GiB. The Hub cache already held `Qwen/Qwen3-0.6B`, so nothing was downloaded; the download's time and size are still unmeasured |
   | The bundle | 331 MiB, `qwen3_0_6b_4bit_dynamic/`: the `.aimodel` (with `main.hash`), the tokenizer and chat template, and `metadata.json` (metadata 0.2, `max_context_length` 8192, compression `4bit`) |
   | `wisp` 0.35.3 (release build, scratch home), `--no-tools` | "Paris", in 7 s including the load |
   | The same, `--tool current_date` | Called the tool and gave the date, in 3 s |

   The export warned that coremltools has not been tested with `torch` 2.9.0, and that it sent unauthenticated Hub
   requests (set `HF_TOKEN` for higher rate limits); neither stopped it.
2. **A larger preset** (`qwen3-4b` or `qwen3.5-4b`), for how time and memory grow, and so whether the plan must warn
   that the biggest presets (`qwen3.5-122b-a10b` at full precision) cannot be converted on a given Mac.

   **Run on 2026-11-22**, `qwen3-4b`, with nothing of it in the Hub cache, on the same 48 GiB Mac:

   | Step | Result |
   | --- | --- |
   | The export, download included | Exit 0 in 215 s (154 s of CPU); the download of five files took about 80 s of it |
   | Peak resident memory | 19.7 GiB, against 5.8 GiB for `qwen3-0.6b` |
   | The Hub cache | Grew by 7.5 GiB, the source weights (`models--Qwen--Qwen3-4B`), kept after the export |
   | The bundle | 2.1 GiB, `qwen3_4b_4bit_dynamic/` |
   | `wisp` 0.35.3, `--tool current_date` | Called the tool and gave the date and time, in 13 s including the load |

   Peak memory grew from 5.8 to 19.7 GiB as the source weights grew from about 1.2 GB to 7.5 GiB. Two points
   suggested the conversion holds a few times the source weights in memory; probe 5 does not bear that out (a 13 GiB
   source peaked at 22 GiB, a 2.8 GiB one at 12 GiB), so memory cannot yet be predicted from the source size. The
   plan should state the source size and warn about memory from measured figures where there are some.
3. **The export inside wisp's sandbox**, with the profile of decision 4.

   **Run on 2026-11-22**, `qwen3-0.6b` again, under `sandbox-exec` with a profile written as
   `CommandPolicy.seatbeltProfile` writes one: everything allowed but writes, which are limited to the checkout, uv's
   and the Hub's caches, the output directory, `$TMPDIR`, and the per-user cache directory, with `~/.wisp` denied and
   the network open. Exit 0 in 92 s, peak 5.7 GiB, no denial in the output, a 331 MiB bundle that answered "Paris" in
   wisp. Two limits: the profile was written by hand from wisp's code rather than made by wisp, and the environment
   was already built, so building it into an empty uv cache inside the sandbox is untested. The export is not
   byte-for-byte repeatable: this bundle's `main.hash` differs from probe 1's, from the same command and weights.
4. **A gated model** (`gemma3-4b-it`): what the export says without a Hugging Face token or the licence accepted, so
   the plan can say it first.

   **Run on 2026-11-22**, with no Hugging Face token on this Mac (`HF_HUB_DISABLE_IMPLICIT_TOKEN=1` as well): exit 1
   in 4 s, a Python traceback ending in `OSError: You are trying to access a gated repo`, with Hugging Face's 401 and
   the model's page. Nothing was downloaded. The plan should find out first that a preset is gated (Google's Gemma
   presets are), say that it needs the licence accepted on the model's page and a token, and refuse before running
   the export without one, instead of passing the traceback on.
5. **The smallest preset of each family not yet exported**, to see whether every family converts and runs in wisp.

   **Run on 2026-11-23**, on the same Mac, outside the sandbox, at `3f109ef`, one after another under a watchdog
   that would have stopped an export past 40 GiB resident (none reached it). Each bundle was then asked a plain
   question (`--no-tools`) and to use `current_date`, with wisp 0.35.3 in a scratch home. Whether a tool was called
   is read from that home's audit log, not from the reply. `mixtral-8x7b-instruct-v0.1` (87 GiB of source weights)
   was not tried, nor `gemma-3n-e2b-it`, which is gated like probe 4's Gemma.

   | Preset | Source weights downloaded | Export | Peak | Bundle | Plain question | `current_date` |
   | --- | --- | --- | --- | --- | --- | --- |
   | `smollm2-135m-instruct` | 0.3 GiB | 92 s | 1.8 GiB | 260 MiB | "The capital of France is Paris." | Refused by wisp: the runtime reports the model cannot call tools |
   | `olmo2-1b-instruct` | 2.8 GiB | 115 s | 12.4 GiB | 804 MiB | "Paris" | Refused, as above |
   | `qwen2.5-1.5b-instruct` | 2.9 GiB | 135 s | 9.2 GiB | 840 MiB | "Paris." | Called; the right date |
   | `muse-glimmer-30b-drafter` | 4.8 GiB, and 55 GiB of `Muse-Glimmer-30B`, its target | 1,100 s | 19.1 GiB | 9.4 GiB | Fails to load: "Expected at least 2 growing KV cache states, found 0" | The same |
   | `phi-3-mini-instruct` | 7.1 GiB | 234 s | 17.2 GiB | 2.1 GiB | "Paris" followed by a literal `<\|end\|>` | Refused, as above |
   | `mistral-7b-instruct-v0.3` | 27 GiB: the repository holds the weights twice (`consolidated.safetensors` and the shards), and both were fetched | 584 s | 19.0 GiB | 3.8 GiB | "Paris", with an aside | Not called: wrote `[current_date timeZone: …]` as text |
   | `gpt-oss-20b` | 13 GiB | 368 s | 21.7 GiB | 13 GiB (no compression) | "Paris", after its harmony-format analysis channel, shown raw | Not called: wrote the call and an invented result in harmony format as text, then a date |

   What changes:

   - **Every family converts; not every bundle is usable.** Of seven exports, one model (`qwen2.5`, as `qwen3` in
     probes 1 and 2) runs in wisp with tools; three run without tools because their chat templates have no tool syntax
     at all, which wisp reads and honours; two have tool syntax in their templates that wisp's executor does not
     read (`gpt-oss`'s harmony channels, Mistral's `[TOOL_CALLS]`): `gpt-oss` wrote a well-formed call that wisp
     missed and did not stop at, so it went on to invent the result; Mistral's text was not a well-formed call,
     but wisp could not have read one, and wisp keeps no raw output to tell more; and Phi's reply keeps its
     `<|end|>` turn marker;
     the drafter does not run alone at all. A pull must not promise more than its family is known to do: wisp keeps
     a table of what each family was verified to do at the pinned commit, shows it in the plan, and does not offer
     a drafter as a model.
   - **The download is the repository, not the model's size.** Mistral fetched both copies of its weights, and the
     drafter fetched its 55 GiB target. The plan's size comes from the files the export will fetch, not from the
     parameter count.
   - **Exports take minutes to tens of minutes**, mostly downloading (the drafter's 18 minutes), so decision 5's
     status line and cancel matter.

## Consequences

- Every Apple-curated language model becomes one command away, chosen and checked by Apple, with the context and
  compression Apple tested.
- A first pull costs the Python environment (`torch` and the rest: a 964 MiB `.venv` over 2.5 GiB of uv's cache on
  this Mac, probe 1, though the download into an empty cache is unmeasured) as well as
  the weights, and every pull keeps the source weights in the Hub cache as well as the bundle; the plan has to say so.
- wisp runs third-party code for the first time as part of an action: Apple's export, fixed to the pinned commit and
  its lockfile, approved each time.
- A bump of the coreai-models pin needs a check that the export still works at the new commit, as well as the
  runtime, and a fresh probe 5 for the family table. The newer families on Apple's `main` (Context) arrive only
  with such a bump, which changes the Swift runtime every Core AI model runs on; it is its own decision, not this
  one's.
- Making `gpt-oss`'s harmony output and Phi's end token readable, and letting Mistral and `gpt-oss` call tools,
  is work in wisp's Core AI executor, separate from pulling; it was done on 2026-11-23 (ADR 0088's amendment of that
  date), after which `gpt-oss-20b` and `mistral-7b-instruct-v0.3` made calls through the tool loop.
- Diffusion, vision, audio, and embedding models in the catalogue stay out of scope: wisp runs language models only.
