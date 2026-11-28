## 0.36.0

Added:

- Opening `Wisp.app` from the Finder opens a window in place of the install dialog (ADR 0091). It has three tabs:
  **Install**, as before; **Updates**, which lists the recent releases with their notes and installs the newest; and
  **Models**, which can enable, disable, check, uninstall, pull, and add models, as `wisp models` does, and names a
  runtime it could not ask, such as Ollama when it is not running.
- The Updates tab shows this version's release notes in a few lines, with links to its release page and to all
  releases on GitHub. The notes are built into the app, so nothing is asked of GitHub to show them.
  `wisp update --notes` prints the same in a terminal.
- `wisp models forget NAME`, and `/models forget NAME` in chat, stop wisp listing a model it remembers that no
  runtime serves now; nothing on disk changes, and a served model is refused (ADR 0092). The default policy refuses it to the model.
- `wisp update --releases` lists the recent releases in a terminal, with their days, a few lines of notes, and the
  one running marked. The model may run it, and `--notes`, as it may run `wisp update --check`.

Changed:

- A model whose runtime is not running is still listed, with what to do: `wisp models list`, chat's `/models`, and
  `Wisp.app`'s Models tab show a model wisp has seen before, such as an Ollama model while Ollama is stopped, with
  its last known size and `not usable: Ollama is not running at …; open Ollama, or run ollama serve`. wisp keeps
  what it has seen in `~/.wisp/models.json`; uninstalling a model removes it (ADR 0092). Such a model has `no` in a
  new `AVAILABLE` column and `not available:` before its reason; `--json` gains `available`. Piped, every line has the
  `AVAILABLE` field after `ENABLED`, so `CAPABILITIES` moves from the tenth field to the eleventh. The model's
  `models` tool lists such a model too, with why, so it can tell you what to do; asked to enable or check one, it is
  told the model is not available rather than asking you. `wisp threads` and `wisp://threads` mark a saved thread
  whose model was not available at the last listing, with why. `Wisp.app`'s Models tab greys such a model, with why,
  and offers **Forget…**.

Fixed:

- `coreai:` models whose templates write tool calls in a format other than `<tool_call>` frames now make them
  (ADR 0088, amended). gpt-oss's harmony format is read: its thinking is thinking, its answer is the reply without
  the channel markers, and its calls are made and stop generation, where it went on to invent the tool's result.
  Mistral-7B-Instruct-v0.3's `[TOOL_CALLS]` array is read and ends the reply, and its template no longer fails on a
  conversation with a tool result for want of call ids, through Core AI or MLX. Phi-3's replies no longer end with a literal `<|end|>`.
