# ADR 0019: Model backends are a registry, and a model's capabilities are declared, never assumed

Date: 2026-09-20. Status: accepted. Extends [ADR 0016](0016-local-runtimes-through-an-executor.md).
Amended by [ADR 0047](0047-mlx-in-the-release.md): MLX ships in the release. Amended by
[ADR 0052](0052-mlx-on-a-par-with-ollama.md): MLX models run through wisp's own executor by default, the bridge
stays as `mlx.executor: "bridge"`, and `wisp models pull` fetches `mlx-community` models on the person's command.
Amended by [ADR 0056](0056-models-enabled-and-disabled.md) (refined 2026-10-04): an MLX model's capabilities are
still declared in `config.json` only once verified, and wisp can now do the verifying, on the model itself, when it is
enabled or checked (`wisp models check`), recording the ones that pass with the day of the check.

## Context

ADR 0016 added Ollama as a third model through a wisp-supplied executor, with the selection spelled
`ollama:<name>` and the runtime's settings read from `config.json`. Two more local runtimes are wanted
(MLX Swift and Core AI), each with its own dependencies, asset formats, and idea of what a model can do,
and more are candidates (see the backlog). Hard-wiring each into `ModelSelection` would put every
runtime's SDK into `WispCore`, which the tests and the sandboxed pre-commit hook build, and would
leave capability claims implicit: the Ollama executor declared tool calling for every model, including
an embedding model that cannot chat.

## Decision

- `ModelBackend` is a protocol: a scheme, `resolve(name, config)` into a `ResolvedModel`, `installed`
  for `wisp models`, and `settings` for `wisp config`. `ModelBackends` is the registry, keyed by
  scheme. Ollama is built into `WispCore`; the executable registers the others at launch, so
  `WispCore` never links a runtime it does not need and a build can omit one.
- `ModelSelection.local(backend:name:)` is spelled `<backend>:<name>`. Parsing accepts any scheme;
  resolving a scheme this binary lacks fails with `unknownBackend` naming the registered ones, so a
  config file can name a backend an older or slimmer build does not have and get a clear error.
- A `ResolvedModel` carries the capabilities the model declares and who declared them
  (`CapabilitySource`: the framework for Apple's models, the runtime for Ollama's `/api/show` and a Core
  AI bundle, the operator's configuration, or undeclared). Before a session is opened, a request that
  needs tool calling is refused with `unsupportedCapability` and a hint naming the fix. A model that
  declares nothing runs a text-only conversation. Nothing is inferred from a model's name or from the
  runtime having a tool-capable API.
- `ToolSelection.none` is the spelling for "no tools": `--no-tools` on the CLI, `tools: []` over MCP
  (an omitted `tools` still means all).
- A new audit event, `model.resolved`, records at conversation open which model actually served,
  its backend, its asset, its declared capabilities and their source, and the tools it was opened with.
- A backend never downloads. Acquisition is the operator's job; a missing asset is an `unavailable`
  failure that says where wisp looked.

## Consequences

- Ollama now reports per-model capabilities from `/api/show`, so `ollama:nomic-embed-text` is refused
  for tool use rather than failing mid-generation.
- Adding a runtime is one target with one `ModelBackend` and one `register` call; it does not touch
  `ModelSelection`, `Session`, the MCP server, or the audit.
- The eligibility check is exactly that: a model that declares tool calling may still call tools badly.
  Quality is measured by evaluation, not declared.
