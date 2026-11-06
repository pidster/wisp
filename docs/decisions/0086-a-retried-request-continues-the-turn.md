# ADR 0086: A retried request continues the turn, so no call runs again

Date: 2026-11-06. Status: accepted. Amends [ADR 0008](0008-context-condensation.md) and
[ADR 0045](0045-layered-context.md) (the overflow retry, and the retry with every tool after a call to a tool the
request had not registered, which "retries once"). Follows [ADR 0083](0083-an-empty-response-is-asked-once-more.md),
whose rebuild it reuses. Leaves [ADR 0050](0050-tool-output-budget-and-overflow.md)'s rule unchanged: a command run
again is a new command, and is not stopped.

## Context

The model runs its tool loop inside one framework request (`session.respond(to:)` or `session.streamResponse(to:)`).
Two failures inside that request made wisp send the turn's prompt again on a fresh session:

- **An overflow.** Under `.condense(keepTurns:)` the agent dropped earlier turns and sent the prompt again; under
  `.target` it condensed to the target (`retryToTarget`) and did the same.
- **A call to a tool the request had not registered**, which the framework refuses (`withToolRecovery`): the agent
  registered every tool and sent the prompt again.

The framework keeps nothing of a request that threw, and the thread's store holds nothing of the current turn until
the turn ends, so the fresh session lacked the turn's calls. The model, given its prompt again, called its tools
again: a command run before the failure, perhaps approved, perhaps `git commit`, ran a second time.
[context-management.md](../context-management.md) said so: the tool retry's "cost is the overflow retry's: tool calls
made earlier in the same request run again."

ADR 0083 had met the same problem after an empty response, and solved it by rebuilding the turn from its audit events
(the prompt, then each call with the output it returned, as a stopped turn is recorded), opening a session on the
context with the rebuilt turn after it, and sending a note of wisp's in place of the prompt.

The options considered:

1. **Rebuild and continue**, as ADR 0083 does: the retry is sent on the condensed context with the rebuilt turn, and
   the note asks the model to go on from what it has done.
2. **Answer repeats from the store**: let the retry send the prompt, and have `AuditedTool` return the earlier output
   for a call the turn had already made, instead of running it. Rejected: it reverses ADR 0050's rule that a command
   run again is a new command, so a command run again on purpose after an edit would return stale output, and one
   approval would cover two runs.
3. **No retry after a tool call**: fail the turn once it has run anything. Kept only as the fallback, below; on its
   own it would turn every overflow late in a long tool loop into an error the caller must handle.

The operator chose the first on 2026-11-06.

## Decision

1. **A retry after a tool call continues the turn.** Under both condensing policies after an overflow, and after a
   call to an unregistered tool, when the turn's tool events hold at least one call that returned, wisp rebuilds the
   turn from them (`Agent.rebuiltTurn`, using ADR 0083's `stoppedEntries` and `answered`), opens the fresh session
   on the condensed context followed by the rebuilt turn, and sends, in place of the prompt:

   ```
   [wisp: this turn's request was sent again on a fresh context. Your tool calls so far this turn are above, with their results; go on from them to finish the person's request.]
   ```

   A turn that has made no call is retried with its prompt, as before.
2. **The note is wisp's.** The store keeps it as a notice, as it keeps the empty reply's note; the rebuilt prompt
   and calls are recorded as the turn's, joined to their audit events by the calls' ids. A session continued once
   that is continued again (a second overflow under the tool retry, or an empty response after a continuation) drops
   the calls it already holds before the newer rebuild is appended, so no call appears twice.
3. **The rebuilt turn counts toward the target.** Under `.target` the goal leaves room for the rebuilt turn and the
   note, estimated at four bytes a token, where it left room for the prompt alone.
4. **When it cannot fit, the turn ends.** When the rebuilt turn and the note alone take the whole window by that
   estimate, the request is not sent; when the continued request overflows again, it is not retried. Either ends the
   turn with `ContextFailure.doesNotFit`, as the target's second overflow already did, and under `.condense` too,
   where a second overflow had surfaced the framework's error. The session is left holding the rebuilt turn, so the
   failed turn's record keeps what ran and the next turn knows it. A note naming what ran in place of the error was
   considered and not chosen: the failure is the existing one a caller already handles, and the `ran:` line and the
   audit already name the calls.
5. **Audited.** `context.condensation` (reason `overflow`) and `context.assessment` (method `retry`) record
   `continued`, the number of calls the retry went on from; absent when there were none.

## Consequences

- A call made before an overflow or a refused tool call is not made again unless the model chooses to call it again,
  which is a new call, classified, approved, and audited as one. Tested with `ScriptedModel`, which gained an
  `.overflow` step that overflows mid-turn, after a call (`ContinuedTurnTests`): the call runs once under both
  policies and under the tool retry, the retried request carries its output and the note, and a turn that cannot
  fit fails without running it again.
- Streaming is unchanged: the continued request's text continues what was shown, or is separated by a newline, as a
  retry's always was.
- The estimate in point 4 is rough, so a turn just over the window is still sent once, and the retry is the exact
  check, as it was for the target's plain retry.
- The equivalence fixtures, whose overflows come before any call, are unchanged.

## Probed on a real model, 2026-11-06

On the on-device model, a turn of five `seq` commands overflowed after its first call. The retry continued from
that call, so it did not run again. The next request overflowed again, and the turn ended as decision 4 says,
with no call run twice. The probe and its audit events are in [measurements.md](../measurements.md), "A retried
request continuing its turn". Ollama does not reach this path: it truncates an overlong prompt and reports no
overflow.
