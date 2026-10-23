# ADR 0075: `wisp models uninstall` removes a model where wisp knows its files

Date: 2026-10-23. Status: accepted by the operator on 2026-10-23, the cache's shared store (decision 2) settled the same
day once found; built 2026-10-23 for 0.31.1. Extends
[ADR 0059](0059-one-set-of-model-actions.md) (one set of model actions) with an action the person alone takes.

## Context

`wisp models pull` fetches an MLX model and `wisp models disable` hides one, but nothing removed a model: the person
ran `ollama rm`, deleted a link, or cleared the Hugging Face cache by hand, and `config.json` kept the model's
settings and its `models.disabled` entry. On 2026-10-23 the operator removed four disabled Ollama models that way
and asked for a command. They settled the shape the same day ([roadmap.md](../roadmap.md), 0.31.1): wisp removes a
model where it knows the files; an MLX model's link only, its cache on request; the person alone, with a typed
confirmation; and, asked again, a real folder to the Bin, the cache's whole repository on `--purge-cache`, and chat's
`/models uninstall` beside the command.

Probed on this Mac on 2026-10-23, declining at the prompt each time: the plan for `ollama:qwen3:1.7b` named Ollama's
delete and 1.36 GB; the plan for `mlx:Qwen3-1.7B-4bit` named the link and, first, 4.5 MB of cache. The cache's folder
for that repository held only small files: its weights blob was itself a link to a store at the cache's root,
`~/.cache/huggingface/hub/blobs/2d/…`, 26 GB in all, kept there by another Hugging Face tool, each blob with a `.refs`
list of the repository blobs that link to it and an empty `.lock`. wisp writes no such store; purging the repository's
folder alone would have left its 968 MB weights behind. No Hugging Face command-line tool (`hf`, `huggingface-cli`)
or `huggingface_hub` library was installed to hand the removal to, and no documentation of that store's format was at
hand; following it meant deleting another tool's files and rewriting its `.refs`. The operator chose that wisp leave
the store to the tool that keeps it.

## Decision

1. **`wisp models uninstall NAME`**, and `/models uninstall NAME` in chat and `wisp-tui`, through one action,
   `ModelActions.uninstall`. Each backend plans what goes (`ModelBackend.removal`), reading and changing nothing:
   - **Ollama**: its copy, through Ollama's `DELETE /api/delete`, sized from `/api/tags`. Every app using Ollama loses
     it.
   - **MLX and Core AI**: the entry in wisp's models folder. A link is removed and what it points to stays; a real
     folder is moved to the Bin. A model named by its path (`mlx:/…`, `coreai:~/…`) is outside the folder and refused.
   - **llama.cpp, LM Studio, and Apple's models** are refused, saying where they are removed.
2. **The cache on request, the repository's folder only.** An MLX model's files in the Hugging Face cache stay, and
   the plan says how much they hold. `--purge-cache` removes the repository's whole folder, `models--org--name`, every
   revision: the layout wisp itself writes when it pulls. Blobs its blobs link to in a store at the cache's root,
   which another tool keeps, are never touched: the plan names how much of the model is there and that wisp leaves
   it to that tool.
3. **The person types the name.** The plan comes first: what goes, the settings cleared, the bytes freed, what stays,
   and a warning when the model is the default (wisp then falls back to `system`). The model's name, as given or as
   the plan spells it, goes ahead; anything else leaves the model. `--yes` skips the question for a script; with no
   terminal and no `--yes`, nothing is removed.
4. **Its settings go with it**: `<scheme>.models.<name>` under any spelling (Ollama's with and without `:latest`), an
   MLX declaration, and its `models.disabled` entry, each a `config.change`. The default `model` is left, with the
   warning.
5. **The person's alone.** The model's `models` tool does not offer it, and the default policy refuses
   `wisp models uninstall` to the model.
6. **Audited**: `model.uninstall` with the steps, bytes, settings, whether it was the default, and the outcome
   (`removed`, `declined`, `failed`).

## Consequences

- Removing a model is one command that also tidies `config.json`; a removal stopped partway reports the steps done,
  and the audit records why it failed.
- A folder moved to the Bin still takes space until the Bin is emptied; a link, Ollama's copy, and a purged cache are
  gone at once.
- Where another tool keeps a model's weights in its own store, `--purge-cache` frees only the repository's folder,
  and the plan says so; handing that removal to Hugging Face's own tool, when one is installed and handles the store,
  is a later step.
