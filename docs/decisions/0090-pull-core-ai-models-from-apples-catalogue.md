# ADR 0090: Core AI models are pulled from Apple's catalogue by preset

Date: 2026-11-22. Status: proposed; the direction (pull by preset) chosen by the operator on 2026-11-22, the rest not
yet agreed; probes first (below). Would amend [ADR 0059](0059-one-set-of-model-actions.md) (a pull is MLX's only) and
extend [ADR 0088](0088-core-ai-through-wisps-executor.md).

## Context

wisp runs Core AI models from `.aimodel` bundles in `coreai.modelsDirectory` (`<home>/models/coreai` by default), with
the engine, tokenizer, and constrained decoding from [apple/coreai-models](https://github.com/apple/coreai-models),
pinned by commit in `harness/Package.swift` (`3f109ef` on 2026-11-22). Getting a bundle is the person's job: clone that
repository, install `uv`, and run its export (`docs/backends.md`, "Core AI"). Nothing in wisp lists what can be
exported, and a missing bundle's error only names the export command.

The repository is also Apple's curated catalogue. Its model registry
([`model_registry.py`](https://github.com/apple/coreai-models/blob/main/python/src/coreai_models/model_registry.py)),
read on 2026-11-22, lists 38 language-model presets for macOS, each a short name with a Hugging Face id, a compression
preset, a compute precision, and a context length, which the export takes from the preset:

| Family | Presets (macOS) |
| --- | --- |
| Qwen2.5, Qwen3 | `qwen2.5-1.5b-instruct` (and `-8bit-kv`), `qwen3-0.6b`, `-1.7b`, `-4b` (and `-8bit-kv`), `-8b`, `qwen3-coder-30b-a3b-instruct` |
| Qwen3.5 to 3.8 | `qwen3.5-0.8b`, `-2b`, `-4b`, `-9b`, `-27b`, `-35b-a3b`, `-122b-a10b`, `qwen3.6-27b`, `qwen3.6-35b-a3b`, `qwen3.8-27b` (all at full precision, 262,144 tokens) |
| Gemma | `gemma3-4b-it`, `gemma3-12b-it`, `gemma-3n-e2b(-it)`, `gemma-3n-e4b(-it)` |
| Others | `gpt-oss-20b`, `muse-glimmer-30b` (and its drafter), `mistral-7b-instruct-v0.3`, `mixtral-8x7b-instruct-v0.1`, `phi-3-mini-instruct`, `phi-3.5-mini-instruct`, `phi-4-mini-instruct`, `olmo2-1b-instruct`, `smollm2-135m/360m/1.7b-instruct`, `smollm3-3b` (and `-base`) |

`uv run coreai.model.registry --list-models --type llm --platform macOS` prints the same list from a checkout.

How the export is built matters for running it from wisp:

- It is a Python package in a `uv` workspace (`python/`, entry point `coreai.llm.export`), depending on `torch` 2.9.0,
  `transformers` 5.12.1, and Apple's `coreai-core`, `coreai-torch`, and `coreai-opt` at exact beta versions; the
  versions it is tested with are in the workspace's `uv.lock`.
- Some presets name a compression file by its path in the source tree (`compression_config`), so the export needs a
  checkout, not only the package.
- It downloads the source weights from the Hugging Face Hub (or ModelScope) and converts them on this Mac.
- Two compression presets need macOS 27.2 (`fp4_…` and `fp8_…`); none of the 38 macOS presets uses them by default.

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
   `wisp models` lists the presets not yet exported as available, beside the exported bundles it lists today.
2. **The export runs from a checkout at the commit wisp pins.** wisp keeps a checkout of apple/coreai-models at the
   `Package.swift` revision in `<home>/cache/coreai-models/<commit>` and runs
   `uv run --frozen coreai.llm.export <preset> --output-dir <dir>` in it (the export takes a registry short name as
   well as a Hugging Face id), so the Python export and the Swift runtime
   that runs its bundle come from one commit and the tested dependency versions (`uv.lock`) are used. Moving the pin
   moves both. wisp does not install `uv`; without it a pull is refused with how to get it, and `wisp doctor`
   reports it.
3. **The approval says what will run, as well as what will be fetched.** A Core AI pull is asked as an MLX pull is
   (always, per pull, never remembered, the publisher question for the Hub organisation), and its plan adds the
   preset's compression and context, that Apple's export code at the pinned commit runs on this Mac, and the
   first-time cost of the Python environment.
4. **The export runs under wisp's sandbox**, with the network allowed and writes limited to the checkout, the uv and
   Hugging Face caches, and the bundle's directory, if probe 3 shows the conversion can run there; otherwise this
   decision is revisited, not dropped quietly.
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
3. **The export inside wisp's sandbox**, with the profile of decision 4.
4. **A gated model** (`gemma3-4b-it`): what the export says without a Hugging Face token or the licence accepted, so
   the plan can say it first.

## Consequences

- Every Apple-curated language model becomes one command away, chosen and checked by Apple, with the context and
  compression Apple tested.
- A first pull costs the Python environment (`torch` and the rest: a 964 MiB `.venv` over 2.5 GiB of uv's cache on
  this Mac, probe 1, though the download into an empty cache is unmeasured) as well as
  the weights, and every pull keeps the source weights in the Hub cache as well as the bundle; the plan has to say so.
- wisp runs third-party code for the first time as part of an action: Apple's export, fixed to the pinned commit and
  its lockfile, approved each time.
- A bump of the coreai-models pin needs a check that the export still works at the new commit, as well as the
  runtime.
- Diffusion, vision, audio, and embedding models in the catalogue stay out of scope: wisp runs language models only.
