# ADR 0008: Recover from context overflow by condensing to recent turns

Date: 2026-09-17. Status: accepted. Amended by [ADR 0025](0025-context-estimation.md) (condensing
ahead of the window) and [ADR 0045](0045-layered-context.md): condensing now brings the composed context
to a token target, distilling facts and a summary from the turns it drops, rather than keeping the last
four turns.

## Context

The on-device model's window is about 4k tokens and the framework offers no automatic management. Chat
sessions and MCP threads outlive that budget quickly once tools return output. Options: fail and make the
caller start over (ADR 0007's initial stance), drop old turns, or summarise old turns with the model.

## Decision

`Agent` gets a `ContextPolicy`, defaulting to `.condense(keepTurns: 4)`. On `contextSizeExceeded` the agent
rebuilds its session from the pre-call transcript condensed to the instructions plus the last four turns and
retries the prompt once. Callers learn it happened through `Agent.condensations`. Dropping is preferred over
summarising for now because it is deterministic, free, testable without the model, and keeps the transcript a
faithful record.

`Transcript.condensed(keepTurns:)` is the single pure function that implements the policy, so alternatives
(summarisation, token-budget trimming) can replace it without touching `Agent`.

## Consequences

- MCP `respond` no longer fails on overflow by default; it reports `condensed: true` in the structured
  result. ADR 0007's "close it and start a new one" error remains only when recovery itself fails.
- A retried prompt costs a second model call; acceptable because overflow is rare relative to turns.
- The model loses everything before the kept turns. Tasks that need earlier facts must restate them or save
  them via a tool result. `docs/context-management.md` lists summarisation as the next experiment.
