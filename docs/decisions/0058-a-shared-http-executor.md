# ADR 0058: A shared HTTP executor for llama.cpp and LM Studio

Date: 2026-10-09. Status: accepted. Extends [ADR 0016](0016-local-runtimes-through-an-executor.md) and
[ADR 0019](0019-model-backends.md); applies [ADR 0053](0053-the-models-thinking-shown.md) (thinking) and
[ADR 0056](0056-models-enabled-and-disabled.md) (enabling and checking) to two more runtimes; departs from
[ADR 0043](0043-context-window-from-memory.md) for them (the window is the server's, not sized from memory).

## Context

The backlog recorded on 2026-09-20 that several local runtimes serve an OpenAI-compatible HTTP API, and that the
Ollama executor's mapping from a transcript to a chat request is most of what they need. The roadmap put two of them
in 0.21.0: llama.cpp's `llama-server` and LM Studio. Neither was installed on this Mac when this was built (no
`llama-server` or `lms` on `PATH`, no LM Studio app, nothing listening on 8080 or 1234), so what follows rests on
their documentation, read on 2026-10-09, and on tests against a fake server; the one live check was against Ollama's
own OpenAI-compatible endpoint (Consequences).

What the two servers share, from llama.cpp's `tools/server/README.md` and LM Studio's developer documentation and
API changelog:

- `POST /v1/chat/completions` with `stream: true`, answered as server-sent events (`data: {…}` lines, then
  `data: [DONE]`); `tools` and streamed `delta.tool_calls` fragments, gathered by `index`; `response_format` of type
  `json_schema`, which both enforce with a grammar whatever the model; `stream_options.include_usage` for a last
  chunk with `usage` (LM Studio since 0.3.18); a bearer token in `Authorization` when the server is started with a
  key (llama.cpp's `--api-key`, LM Studio 0.4.0's API tokens).
- `GET /v1/models`, which names the models.

Where they differ:

| | llama.cpp | LM Studio |
| --- | --- | --- |
| Default address | `http://127.0.0.1:8080` | `http://127.0.0.1:1234` |
| Thinking in the stream | `delta.reasoning_content` (`--reasoning-format`, default `auto`) | `delta.reasoning` since 0.3.23; `reasoning_content` with its DeepSeek setting |
| Asking a model not to think | per request: `chat_template_kwargs: {"enable_thinking": false}` | per model, in the app |
| What it says about a model | `/v1/models`: the id (the `-m` path or `--alias`), `meta.n_params`, `meta.size`; in router mode a `status` per model. `/props`: the slot's window (`default_generation_settings.n_ctx`) and what the chat template supports (`chat_template_caps`) | `/api/v1/models` (0.4.0): every downloaded model's `type` (`llm`, `embedding`), `key`, `architecture`, `quantization.name`, `size_bytes`, `params_string`, `loaded_instances[].config.context_length`, `max_context_length`, `capabilities.trained_for_tool_use`, `capabilities.reasoning` |
| Whether a model calls tools | not reported per model: with `--jinja` (the default) any template can be given tools, and only `chat_template_caps` says what the template supports | reported: `trained_for_tool_use` |
| A request too large for the window | not in the README; the server's error type for it is taken to be `exceed_context_size_error`, with `n_prompt_tokens` and `n_ctx`, which is not confirmed here, so wisp matches the wording too | a per-model overflow policy in the app; the error, if any, not documented |

## Decision

- **One executor, a small dialect.** `OpenAICompatibleModel` and its executor speak `/v1/chat/completions` for both;
  `OpenAICompatibleDialect` holds every difference as a value (scheme, runtime name, default port, how to start it,
  where it describes its models, whether it takes `think`, whether its models' capabilities are declared), each read
  in one place. Thinking is decoded from either field for both, since LM Studio uses both by setting and version.
- **What is shared with Ollama is extracted, not copied.** `ReplyRelay` is what both executors feed: thinking through
  `ThinkingStretch` as reasoning events, reply text, tool calls completed against their schema
  (`ChatMessage.completed`), and the hold on text that may be calls written as text (`TextToolCalls.mistral`).
  `ConnectionFailure` names a connection's failure by when it came; `LastInputTokens` keeps the usage `Agent`
  condenses by. The transcript goes through `ChatMessage.messages(from:)`, as for Ollama and MLX.
- **Schemes per runtime: `llamacpp:<model>` and `lmstudio:<model>`.** One generic `openai-compat:<name>@<base>` was
  rejected: a base URL in a model's name would put configuration into every place a model is named
  (`models.disabled`, `routing`, an MCP caller's `model`), and the runtime matters to the operator, since what it
  reports, where to start it, and what its errors say all differ. Each has its own `config.json` section: `baseURL`,
  `timeoutSeconds`, `apiKey`, and for llama.cpp `think` and `models`. A llama.cpp model listed by its file's path
  is named by the file's name without `.gguf` (the path itself is accepted too); an LM Studio model by its `key`.
- **The key is a secret.** `WISP_LLAMACPP_API_KEY` or `WISP_LMSTUDIO_API_KEY` wins over the file's `apiKey`, so the
  key need not be in a file the model's tools could read. It is sent as `Authorization: Bearer …` on every request
  and nowhere else: the settings `wisp config` and `inspect` show say `set (…)` or `unset`, the settings' and the
  executor configuration's descriptions leave it out, `/config set` has no `apiKey` setting (a `config.change` event
  would record its value), and a refusal (HTTP 401 or 403) says which variable or key to set.
- **The window is the server's.** The server holds the model loaded at a window it chose, so wisp reads that window
  rather than sizing one from the Mac's memory (ADR 0043), which would be a guess about memory another process holds.
  llama.cpp: `/props` `default_generation_settings.n_ctx`, a slot's window, which is what one request gets.
  LM Studio: the loaded instance's `context_length`; a model not loaded is loaded by LM Studio at its own default when
  the first request comes, so wisp uses the 8,192 floor (or the model's maximum when smaller) and says why. The note
  begins `reported by` and the listing's `FROM` says `server`. A request the server refuses as too large (an error of type
  `exceed_context_size_error`, or one whose message says the context size, length, or window was exceeded) is the
  framework's `contextSizeExceeded`, so `Agent` condenses and retries as it does for MLX and the on-device model.
- **Capabilities.** Schema replies are declared for every model of both, since the server holds the reply to the
  schema with a grammar. LM Studio's `trained_for_tool_use` declares tool calling and `capabilities.reasoning`
  thinking, by the runtime, as Ollama's `/api/show` does; an `embedding` model is refused as unable to hold a
  conversation. llama.cpp reports neither per model, so tool calling is declared by the runtime only when
  `chat_template_caps` says the template supports tool calls; otherwise it is the configuration's
  (`llamacpp.models.<name>`), and `wisp models enable` or `check` asks ADR 0056's three questions of the model and
  records what passes there, as for MLX. `vision` is never declared: the executor maps text only.
- **`think`** is llama.cpp's only (`llamacpp.think`, `true` or `false`, sent as `chat_template_kwargs.enable_thinking`;
  unset sends nothing). LM Studio's section has no `think`; a value there is ignored.
- **The rest is Ollama's behaviour.** An unavailable server fails fast and names the runtime and how to start it
  (`no llama.cpp server at …; start one with llama-server -m <model.gguf>, or set llamacpp.baseURL`); a stream that
  ends before a choice finishes or `[DONE]` comes, or a lost connection, is an interruption, nothing of it kept and no
  call it began made; a server silent for `timeoutSeconds` is a timeout naming the setting; chat falls back to
  `system` when its configured model is unavailable, saying to choose it again once the server is running; the
  doctor's configured-model and window checks resolve through the same path. Both backends are built into
  `WispCore`, as Ollama's is: they need no library.

## Consequences

- Two more runtimes run wisp's conversations, with the tool loop, approval, sandbox, and audit unchanged. Adding a
  third OpenAI-compatible server is a dialect value and a registry line, unless it differs in a way the dialect does
  not yet hold.
- No new audit event: `model.resolved` records the backend (`llamacpp`, `lmstudio`), the asset (base URL and the
  server's id), the window and its note, and the capabilities and their source.
- The Ollama executor now relays through `ReplyRelay`; its tests pass unchanged.
- A llama.cpp model is usable with tools only once declared or checked, as an MLX model is. That is one command
  (`wisp models check llamacpp:<name>`), and it is honest: llama.cpp would accept tools for any model, and only the
  model can say whether it calls them.
- Tests without a server (`OpenAICompatibleExecutorTests`, `OpenAICompatibleBackendTests`), against a fake for each
  dialect: text in deltas, a tool call through the framework's loop with its output answering its id, several calls
  split across chunks and interleaved, fragments without an index, a schema reply, thinking in each dialect's field
  (decoded, counted, audited, not sent back), the server's reasoning count, usage and cached tokens, `think` sent
  only for llama.cpp and only when set, a stream cut short, a tool call cut short, a lost connection, a silent server,
  an error in place of a chunk, an overflow typed for condensing, the key sent and never logged or shown, a refused
  key, the environment's key over the file's, listings and windows for each dialect (a path id, a router, a loaded
  and an unloaded model, an embedding model, an LM Studio before 0.4.0), an unavailable server, the session's
  `model.resolved`, the doctor's finding, and the check recording a llama.cpp model's capabilities.
- Checked live on 2026-10-09 against Ollama 0.35.1's own OpenAI-compatible endpoint, the only such server on this Mac,
  with `llamacpp.baseURL` and `lmstudio.baseURL` pointed at it in a scratch home: `llamacpp:granite4.1:8b`, declared
  `toolCalling`, ran `run_command` (`uname -m`, `arm64`) through the tool loop in 5.7 s, its window the floor because
  Ollama has no `/props`; `lmstudio:qwen3:1.7b` thought for 96 chunks, streamed as `delta.reasoning`, audited as
  `model.reasoning`, and answered `No`, its listing read from `/v1/models` after `/api/v1/models` answered 404. A
  real `llama-server` and LM Studio remain to be tried.
