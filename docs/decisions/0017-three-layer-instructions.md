# ADR 0017: What the model is told has three layers, and the first is wisp's own

Date: 2026-09-20. Status: accepted.

Amended by [ADR 0076](0076-the-sandbox-in-the-prompt.md): with `run_command`, layer 1 gains a sandbox note built from
the session's settings.

## Context

Until now "instructions" was one string: the MCP `instructions` argument or `--instructions` if given,
else `config.json`'s `instructions`, else a built-in sentence. An override replaced everything, so a
caller could, by accident or design, remove wisp's framing of who the model is and how to treat tool
results. There was also no place for the operator of a Mac to add standing guidance that applies to every
caller. The three things have different owners and lifetimes and were being spelled as one.

## Decision

`Prompting` carries three layers and renders them in order into the one `Instructions` the framework
takes, each optional layer under a short heading so the model and a log reader can tell whose words they
are:

| Layer | Owner | Set where | Lifetime |
| --- | --- | --- | --- |
| 1. wisp system prompt | wisp | `harness/Sources/WispCore/Resources/system-prompt.md` | fixed per release; cannot be removed or replaced |
| 2. system prompt extension | this Mac's operator | `config.json` `systemPromptExtension` | every session and thread on this install |
| 3. conversation instructions | the caller | `--instructions`, MCP `instructions` | one session or one thread |

- Layer 1 is a plain text file in the source tree, embedded at build time by the `EmbedSystemPrompt`
  SwiftPM build-tool plugin into a raw string constant, so the product stays one binary with nothing to
  ship beside it and the file is the prompt (a test checks the two are equal). It holds identity, tool
  discipline, faithful reporting of tool results, and brevity, and is kept well under 600 bytes because
  the on-device window is about 4k tokens.
- Layer 2 replaces what `config.json`'s `instructions` used to mean. The old key is still read when the
  new one is absent and is documented as the pre-0.2 spelling.
- Layer 3 is what `--instructions` and the MCP argument have always been, minus the power to remove
  layers 1 and 2. An MCP thread's `instructions` replaces the server's `--instructions` for that thread.
- `session.start` records `systemPromptExtension` and `instructions` as separate fields; layer 1 is not
  repeated per event because it is fixed per `version`, which every event carries.
- `Conversation` is the one place the layers meet, for every face.

## Consequences

- Callers can no longer switch off the tool-use and reporting rules; a caller that needs a different
  model persona must say so in layer 3 and lives within layer 1.
- The audit record for a session now says whose text was in force at each layer.
- Changing wisp's own prompt is a text edit plus a release; the plugin re-embeds it on the next build.
- The eval harness and the MCP prompting guidance in `wisp://tools.md` should stay consistent with
  layer 1; both describe "one tool per prompt, verbatim reporting".
