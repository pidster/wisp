# ADR 0082: A llama.cpp server wisp starts for the models it knows

Date: 2026-10-27. Status: accepted by the operator on 2026-10-29, after the probe below; to be built for 0.33.0.
Agreed by the operator on 2026-10-27: wisp should be able to start llama.cpp's `llama-server` for the models it knows
about, as a release of its own after 0.32.0. Builds on [ADR 0058](0058-a-shared-http-executor.md), which talks to a
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

The probe of 2026-10-29 ([measurements.md](../measurements.md), "A llama.cpp router for wisp's models"), with the
Homebrew `llama-server` 0.7.0 and the three Bonsai 2 models linked into a folder, found:

| Question | Result |
| --- | --- |
| Does a router serve linked models under their names? | Yes: links are followed, each model is named after its file, and `/v1/models` lists each `unloaded` until asked for |
| Does `--api-key-file` hold? | Yes: a request without the key gets 401 |
| Does a ternary model behave the same under the router? | Yes: wisp's five tool prompts on the 9B through the router and through `-m`, 5/5 each, the same answers, at 1.6 to 6.3 s and 1.5 to 5.0 s |
| How long is a load? | 8.5 s for the 9B's first load from disk, about 2 s again later, 1.4 to 2.4 s to switch models under `--models-max 1`; 0.2 to 0.5 s a request once loaded |
| How much memory? | 11.4 GB for the 9B at llama.cpp's defaults (a 262,144-token context, 4 slots); 3.8 GB at `--ctx-size 32768 --parallel 1`, which the router passes on to each model |
| What does idle sleep save? | After 20 s idle under `--sleep-idle-seconds 20` the 9B's process fell to 217 MB; the next request woke it in 0.74 s |
| Does stopping the router stop its models? | Yes |

The same day `Llama.app` (llama.app 0.46.1, team `V89L745MNN`) was found on this Mac already running a router of its
own, on port 9931, with one model at a time, idle sleep after 300 s, models from `~/.config/llama/models.user.ini`, no
key, and CORS open to every origin. wisp, at `llamacpp.baseURL`'s default port 8080, did not use it.

Starting a server is new for wisp in three ways. It runs a program wisp did not build, outside wisp's sandbox; it keeps
a process alive after the command that wanted it has ended; and it opens a port any process on the Mac can reach.

## Decision

Agreed by the operator on 2026-10-29:

1. **One router, not a server a model.** wisp's server is `llama-server --models-dir <folder>`, and a model is loaded
   by the router when a request names it, within `--models-max`.
2. **The models it knows.** The folder is `~/Library/Application Support/Wisp/llamacpp/models`, holding links to GGUF
   files the person adds with `wisp models` (a path, or a download through the models flow that already asks before
   pulling). wisp does not scan the disk for GGUF files. It is the first of wisp's state in Application Support, the
   place the operator prefers for what other agents should not reach, ahead of the protection track's decision for the
   rest.
3. **Whose server: `llamacpp.server`**, one of three:
   - `off`, the default: wisp connects to `llamacpp.baseURL` as today, and starts nothing;
   - `wisp`: wisp's own router (decisions 4 to 7);
   - `llama-app`: wisp uses `Llama.app`'s router, finding its port, and starts nothing; the person adds models in
     `Llama.app`. Its server has no key and answers any origin, which `wisp doctor` says.
4. **A LaunchAgent keeps wisp's router running**, with idle sleep: `Wisp.app` registers it with `SMAppService`, so it
   shows in Login Items and the person can turn it off there, and a Homebrew install writes the agent's file itself.
   launchd restarts and logs it. The agent's file inside a signed `Wisp.app` is fixed, so it cannot carry the person's
   settings: it runs a hidden subcommand, `wisp llamacpp serve`, left out of `--help`, which reads the configuration,
   checks the binary, and starts `llama-server` in its place. Idle sleep takes a loaded model to about 200 MB and wakes it in under a second, so a
   process that stays costs little.
5. **Which binary.** The server is a path the person names or approves once (`llamacpp.serverPath`), recorded with its
   digest and checked before each start, as ADR 0080 proposes for skills; not the first `llama-server` on `PATH`. The
   proposal of 2026-10-27 named this setting `llamacpp.server`; amended on 2026-10-29 to `llamacpp.serverPath`, since
   `llamacpp.server` is now the choice of whose server (decision 3). A
   changed digest, as every `brew upgrade llama.cpp` makes, is not started: wisp asks the person to approve the new one
   at the same path, and `wisp doctor` names the change. Starting it and approving it are audited.
6. **Access.** It listens on `127.0.0.1` only, with a key wisp generates, kept in a file only the person can read and
   passed by `--api-key-file`, and never logged or shown (as `llamacpp.apiKey` is today).
7. **Memory, set in configuration**, each setting explained by `wisp config` and `wisp doctor` with what it costs:
   a 65,536-token context, 1 slot, up to 2 models loaded at once, and sleep after 600 s idle by default (the 9B's
   memory at that context is to be measured with the build; it was 3.8 GB at 32,768). The operator chose these over 32,768 tokens and one model, and over llama.cpp's own defaults
   (11.4 GB for the 9B alone), as long as each is configurable and its effect is plain to the person. `wisp doctor`
   reports the server, its models, and what is loaded.
8. **Off by default**: `llamacpp.server` is `off`; without a change wisp behaves as today.

## Consequences

- `llamacpp:<name>` works without the person starting a server, and the error that tells them to start one is
  replaced by starting it, or by saying why wisp would not (no approved binary, the setting off).
- wisp gains a long-lived process of its own beyond `wisp mcp` and the notifier, with its start, stop, and logs to be
  documented in [backends.md](../backends.md) and [wisp.md](../wisp.md), and its events in [logging.md](../logging.md).
- The binary's digest and the key file sit in `~/.wisp`, under the same protection, or lack of it, as the rest; the
  protection track on the [roadmap](../roadmap.md) decides whether they move.
- Ollama and LM Studio are unchanged: they manage their own processes.
- The probe settled what the decisions waited on: load times of seconds, and a ternary model the same under the router
  as under `-m`.
- `Llama.app`'s router, open to any local process and web page, is the person's choice under `llama-app`; wisp says so
  rather than refusing it.
