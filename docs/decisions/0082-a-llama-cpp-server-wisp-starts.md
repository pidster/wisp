# ADR 0082: A llama.cpp server wisp starts for the models it knows

Date: 2026-10-27. Status: proposed. Agreed by the operator on 2026-10-27: wisp should be able to start llama.cpp's
`llama-server` for the models it knows about, as a release of its own after 0.32.0. Everything under "Decision" is
**pending**: proposed here, not yet agreed. Builds on [ADR 0058](0058-a-shared-http-executor.md), which talks to a
server someone else started.

## Context

Of wisp's local runtimes, llama.cpp is the one the person has to keep running by hand. Ollama loads and unloads its
own models behind one daemon; MLX and Core AI run inside `wisp` (ADR 0052); LM Studio has its own app. For
`llamacpp:<name>` wisp only connects to `llamacpp.baseURL` and, when nothing answers, says `no llama.cpp server at …;
start one with llama-server -m <model.gguf>, or set llamacpp.baseURL` (ADR 0058, [backends.md](../backends.md)).

That matters because llama.cpp is where the fastest accurate model for tool work runs: `Ternary-Bonsai-2-9B-Q2_0` was
as accurate as `granite4.1:8b` on the tools on 2026-10-17 and two to four times faster at diff summaries and as a
classifier ([measurements.md](../measurements.md)), and its `Q2_0` ternary format is llama.cpp's.

What `llama-server` offers, from `llama-server --help` of the Homebrew build on this Mac on 2026-10-27 (version
0.7.0, build 11669):

| Option | What it does |
| --- | --- |
| `--models-dir PATH` | Router mode: one server for every model in a folder, each loaded when first asked for |
| `--models-max N` | At most N models loaded at once (default 4; 0 for no limit) |
| `--models-autoload`, `--no-models-autoload` | Whether a request loads a model (default on) |
| `--models-preset PATH` | An INI file of per-model settings for the router |
| `--sleep-idle-seconds N` | Sleep after N seconds idle (default off) |
| `--host`, `--port` | Default `127.0.0.1` and `9931`; wisp's `llamacpp.baseURL` defaults to port `8080` |
| `--api-key-file FNAME` | Keys read from a file rather than the command line |

A router already reports a `status` per model in `/v1/models`, which wisp reads (ADR 0058). So one server can serve
every model wisp knows about, without wisp handing out ports or choosing which model to keep in memory.

Starting a server is new for wisp in three ways. It runs a program wisp did not build, outside wisp's sandbox; it keeps
a process alive after the command that wanted it has ended; and it opens a port any process on the Mac can reach.

## Decision

Proposed, every part **pending** the operator's agreement:

1. **One router, not a server a model.** wisp starts `llama-server --models-dir <folder>` and points
   `llamacpp.baseURL` at it. A model is loaded by the router when a request names it, within `--models-max`.
2. **The models it knows.** The folder is wisp's own (for instance `~/.wisp/models/llamacpp`, beside `mlx` and
   `coreai`), holding links to GGUF files the person adds with `wisp models` (a path, or a download through the models
   flow that already asks before pulling). wisp does not scan the disk for GGUF files.
3. **Who keeps it running.** Options, to be chosen:
   - a LaunchAgent, which `Wisp.app` could register with `SMAppService` so it shows in Login Items and the person can
     turn it off there; a Homebrew install would write the agent's file itself;
   - a process wisp starts on demand, detached, with a pid file under `~/.wisp`, stopped after an idle time;
   - a process that lives only while `wisp mcp` or chat runs.
   The LaunchAgent is the leaning: launchd restarts it, logs it, and stops it, and the person can see it.
4. **Which binary.** The server is a path the person names or approves once (`llamacpp.server`), recorded with its
   digest and checked before each start, as ADR 0080 proposes for skills. Not the first `llama-server` on `PATH`.
   Starting it is audited, and a changed digest asks again.
5. **Access.** It listens on `127.0.0.1` only, with a key wisp generates, kept in a file only the person can read and
   passed by `--api-key-file`, and never logged or shown (as `llamacpp.apiKey` is today).
6. **Memory.** `--models-max` and `--sleep-idle-seconds` set from configuration, with defaults chosen against this
   Mac's 48 GB and the models wisp measured; `wisp doctor` reports the server, its models, and what is loaded.
7. **Off by default.** `llamacpp.manage` (name to be agreed) turns it on; without it, wisp behaves as today.

## Consequences

- `llamacpp:<name>` works without the person starting a server, and the error that tells them to start one is
  replaced by starting it, or by saying why wisp would not (no approved binary, the setting off).
- wisp gains a long-lived process of its own beyond `wisp mcp` and the notifier, with its start, stop, and logs to be
  documented in [backends.md](../backends.md) and [wisp.md](../wisp.md), and its events in [logging.md](../logging.md).
- The binary's digest and the key file sit in `~/.wisp`, under the same protection, or lack of it, as the rest; the
  protection track on the [roadmap](../roadmap.md) decides whether they move.
- Ollama and LM Studio are unchanged: they manage their own processes.
- Not measured yet: how long the router takes to load a model on first use, and whether a ternary model behaves the
  same under the router as under `-m`. A probe settles both before the decisions are taken.
