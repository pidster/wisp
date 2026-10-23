# ADR 0076: The model is told its sandbox

Date: 2026-10-23. Status: accepted by the operator on 2026-10-23. Amends [ADR 0017](0017-three-layer-instructions.md)
(layer 1, wisp's own words, gains a sentence built from the session's settings).

## Context

Every command the model runs goes through Seatbelt ([run_command.md](../tools/run_command.md), "Policy and sandbox"):
it may read any file, write only under the writable root, the temporary folders, and `commandPolicy.sandbox.writablePaths`,
and reach the network unless `allowNetwork` is false. The model was told none of this. Its only hint was
`run_command`'s `outsideSandbox` argument ("for a command the sandbox refuses, such as brew upgrade"), so it learnt
the limits by failing, an `Operation not permitted`, and the system prompt (130 words) never mentioned a sandbox.

On 2026-10-23 the operator asked for the constraints in the model's context, concisely, and chose where and how much:
in the system prompt, built per session from the real settings, and only where a command fails: where it may write,
whether the network is on, and whether it may ask to run outside; not the policy's refusals (`sudo`, answering wisp's
own approvals, a nested wisp), which come back as clear errors of their own.

## Decision

1. **A sandbox note follows wisp's system prompt** in a conversation that has `run_command`, and only there. It is
   layer 1, wisp's own words, built when the conversation's agent is opened from its runner's settings
   (`CommandRunner.sandboxNote`), so it says what is true for that session and face: the project directory (with `~`
   for the home), "the temporary folder", and the configured writable paths; the network on or off; that a write
   elsewhere fails with `Operation not permitted`; and, where `allowOutsideSandbox` permits it, that the model may ask
   with `outsideSandbox`, which the person approves.
2. **The other cases say what holds**: under `--unsafe`, that commands run without a sandbox; when wisp itself runs
   inside another sandbox, which decides what commands may write, that this is so.
3. **It is short**: one sentence of limits and one of what to do, under 300 bytes, tested, for the on-device model's
   8k-token window.

## Consequences

- The model knows before its first command where it can write; a refusal reads as the expected limit, not a mystery.
- A conversation resumed from a saved thread keeps the instructions it began with; a changed setting reaches a new
  conversation.
- Layer 1 is no longer the same text for every session; the fixed file, `Resources/system-prompt.md`, is unchanged, and
  the note is the one part built at run time.
