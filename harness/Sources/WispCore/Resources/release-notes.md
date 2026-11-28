## 0.35.3

Added:

- `wisp://status` has `update`: whether `updates.check` is on, the running version, and what the last check found,
  with a newer version when one is out, so an MCP client can tell an update is waiting.

Changed:

- The default policy allows the model `wisp update --check`, which only says whether a release is out (ADR 0074,
  amended). `wisp update` itself stays the person's.
- `coreai:` models run through wisp's own executor, as Ollama and MLX models do, which reads the model's thinking
  and tool calls itself (ADR 0088, proposed). Tool calls in the XML form Qwen3.5-based models and Nemotron 3 Nano
  write are made, where the bridge dropped them, and thinking a template opens in the prompt no longer appears in
  the reply with a bare `</think>`. Muse Glimmer's routed messages and ATEM calls are read as before. The window the
  bundle was exported for is enforced, token counts are exact, usage is reported, a request's thinking switch and
  Ctrl-C are honoured as for MLX. `coreai.executor: "bridge"` goes back to coreai-models' bridge.

Fixed:

- A llama.cpp model asked not to think could still think before a structured reply: Nemotron 3.5 Bolt wrote a plan
  before each classifier verdict, about 400 tokens and 10 s a verdict. Thinking off now also sends a thinking budget
  of 0.
- wisp could abort as it exited after a `coreai:` reply (seen once in four runs with Muse Glimmer 30B): Core AI's
  engine was torn down by its own background task while the process was exiting. wisp now shuts its engines down
  before it exits; the bridge's engines (`coreai.executor: "bridge"`) are out of its reach.
- A `coreai:` bundle whose weights are truncated or corrupt, such as an unfinished download, is refused with the
  file and its expected and actual SHA-256, instead of aborting wisp inside Core AI's compiler with no reply and no
  error. The weights are checked against the `main.hash` exported beside them the first time a bundle is used,
  about 2 s a gigabyte, and remembered in `~/.wisp/cache/coreai-verified.json` until they change.
