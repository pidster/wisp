# Local model selection and installation

> To install a local model for wisp today, read [How to install local models](install-local-models.md). This page
> is the dated record of the first installations.

Date: 2026-09-19. Status: dated record of the initial three MLX installations and Python smoke checks.
Integration follow-up added 2026-09-22; see the final section. Historical binary and evidence names below
are intentional: the project was called Daimon at the time of these checks.

This follows the [evaluation design](local-model-evaluation.md). The first comparison retains Apple's
system model as the current daimon baseline and adds three existing, quantized models. These candidates
provide a size comparison within Qwen3 and a generation comparison at approximately four billion
parameters. They are evaluation candidates; no production model or runtime winner has been selected.

## Selected models

| Candidate and asset source | Evaluation role | Installed snapshot size |
| --- | --- | --- |
| Apple's system model | Existing Foundation Models / daimon baseline | Managed by macOS; not separately downloaded here |
| [Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | Small, lower-resource candidate | 984,015,687 bytes |
| [Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit) | Within-family capacity comparison; later MLX/Core AI comparison | 2,278,972,183 bytes |
| [Qwen3.5-4B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit) | Newer model at a similar parameter count | 3,061,132,920 bytes |

Snapshot sizes include weights and supporting files, totalling about 6.32 GB before cache deduplication.
They exclude the Python runtime and dependencies and do not predict inference memory. Qwen3.5 was tested
with text input only; its snapshot also contains vision-related resources. All three configurations specify
four-bit quantization with a group size of 64.

Keep the initial set small enough to run the same workload cases consistently. A different family or a
larger model can follow if results identify a question this set cannot answer. The installation checks
below provide no basis for rejecting the smaller candidate or ranking overall capability.

## Pinned assets and environment

| Hugging Face repository | Exact revision |
| --- | --- |
| `mlx-community/Qwen3-1.7B-4bit` | `3b1b1768f8f8cf8351c712464f906e86c2b8269e` |
| `mlx-community/Qwen3-4B-4bit` | `4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25` |
| `mlx-community/Qwen3.5-4B-MLX-4bit` | `32f3e8ecf65426fc3306969496342d504bfa13f3` |

The installation ran on an Apple M4 Max with 48 GiB unified memory, macOS 27.0 build 26A428.
An isolated environment lives at `~/.local/share/daimon-eval/.venv`:

| Component | Version |
| --- | --- |
| Python | 3.12.12 |
| mlx | 0.32.2 |
| mlx-metal | 0.32.2 |
| mlx-lm | 0.31.3 |
| transformers | 5.17.0 |
| huggingface-hub | 1.32.0 |

Assets are in the standard `~/.cache/huggingface/hub` cache. Each snapshot was downloaded at its pinned
revision. Every file's size was checked and SHA-256 recorded; published LFS hashes, including every weight
file, matched. No model repository's remote Python code was enabled.

The local installation directory retains the following evidence and repeatable scripts:

| Path under `~/.local/share/daimon-eval/` | Contents |
| --- | --- |
| `installation.json` | Hardware, runtime versions, exact snapshot paths, revisions, per-file sizes and hashes |
| `requirements.lock.txt` | Resolved Python package versions |
| `install-models.py` | Installer with the three model revisions pinned |
| `smoke-models.py` | Bounded inference checks and network-denial probe |
| `smoke-results.json` | Prompts, rendered chat templates, outputs, settings, timings and memory observations |

These are machine-local artifacts, outside the repository. `requirements.lock.txt` records package
versions; it is not a hash-locked dependency supply-chain manifest.

## Observed smoke results

Each model ran in its own process with a Seatbelt profile denying network access. A socket probe returned
`EPERM` in every process. Hugging Face and Transformers offline flags were also enabled. Loading used
the exact local snapshot path. This verifies offline inference from the installed snapshots on this
machine; it does not verify a fresh install of a packaged Swift application.

Each check used a fresh prompt, the snapshot's chat template, non-thinking mode, greedy decoding,
seed zero and a maximum of 128 generated tokens. These are installation-check settings, not tuned
evaluation defaults. No output grammar was applied.

| Check | Qwen3-1.7B | Qwen3-4B | Qwen3.5-4B |
| --- | --- | --- | --- |
| Load and return only `READY` | Passed | Passed | Passed |
| Extract the failed test as strict JSON | Failed format: correct data inside a Markdown fence | Passed | Passed |
| Emit a request for `current_date`, `timeZone: Europe/London` | Expected name and argument observed | Expected name and argument observed | Expected name and argument observed |

The extraction input was `alpha PASS; beta FAIL; gamma PASS`; the required decoded JSON was
`{"failed_tests":["beta"]}`. The 1.7B result preserves the expected information, but its complete response
is not JSON. Both facts matter when evaluating a delegation contract.

The tool check supplied a single function schema and explicitly requested that function. The Qwen3 models
emitted JSON inside `<tool_call>` tags. Qwen3.5 emitted `<function=current_date>` and
`<parameter=timeZone>` blocks inside `<tool_call>`. These outputs were inspected directly. No tool was
executed, and no Swift provider parser, Foundation Models tool loop, daimon policy or audit path was tested.
This is preliminary evidence of call formatting, not autonomous tool selection or completed tool use.

Timing and memory observations remain in the raw results. Three short prompts, fixed execution order,
and no repetitions do not establish comparable cold/warm performance or realistic context capacity.

To repeat these checks on this installation, run the following command. It overwrites
`smoke-results.json`, so preserve that file first when retaining multiple runs.

```sh
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  "$HOME/.local/share/daimon-eval/.venv/bin/python" \
  "$HOME/.local/share/daimon-eval/smoke-models.py"
```

## State at the initial installation date (2026-09-19)

`fm available` reported that the system model is available. The installed daimon binary reports version
0.1.2. The repository Agent still constructs a SystemLanguageModel, and its Swift package has no MLX
or Core AI dependency. The three downloads are therefore ready for Python MLX experiments, but cannot
yet be selected by daimon. No main-Agent or classifier configuration was changed.

The next evaluation prerequisites are the workload fixtures and scoring rubrics, plus an integration
that runs these assets through the intended Swift provider. Verify native tool parsing, tool execution,
transcripts, structured-output behaviour and packaged offline loading there before the direct/MCP
comparison. Main-Agent selection remains an implementation detail; classifier configurability remains
a later concern. Core AI exports, fine-tuning and the 60-case workload evaluation have not been run.

## Subsequent integration checks (2026-09-20)

Wisp now implements the [backend registry](backends.md), including Core AI and optional MLX Swift.
After the initial installation, additional assets were prepared and Qwen3-4B was exported for Core AI.
The local integration suite ran 45 CLI requests and seven MCP turns across nine backend/model
combinations. All 18 ordinary CLI file/date tool cases executed the requested tool; exact-answer
formatting and some structured-output content failed. A combined Core AI tool/schema request skipped
the tool and invented a field value. These are dated integration observations, not a comparative
speed/accuracy benchmark or proof that every capability combination works.

Machine-local handoffs retain the original project name in their paths:

- `~/.local/share/daimon-eval/preparation-2026-09-20/READY.md`: prepared assets and pinned revisions.
- `~/.local/share/daimon-eval/coreai-export-2026-09-20/READY.md`: Core AI export, manifest and smoke checks.
- `~/.local/share/daimon-eval/daimon-tests-2026-09-20/REPORT.md`: CLI/MCP results, limitations and source evidence.

The [common-controls proposal](model-controls.md) uses those findings to require model-specific
reasoning parsing and validation of capability combinations. The broader evaluation design remains
proposed work.
