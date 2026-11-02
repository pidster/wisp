# ADR 0083: An empty response is asked once more, from the turn's record

Date: 2026-11-02. Status: accepted by the operator on 2026-11-02; built for 0.34.0.

## Context

The FoundationModels framework ends a turn with "Session ended without producing a response" when a model's response
holds neither text nor a tool call. Local models do this now and then after tool calls: the evals of 2026-10-17 had
six (four of Bonsai 2 9B's `edit_file` cases, one of its `system_info` cases, two of `granite4.1:8b`'s), the eval of
2026-10-30 three, all Bonsai's, and the plan probe of 2026-11-02 six, all Bonsai's, a sixth of its conversations
([measurements.md](../measurements.md), "A nudge to plan"). The audit log of the operator's own use held five, four
of `granite4.1:8b`'s with no thinking in the turn. llama.cpp's log showed each of the probe's requests ending normally
with tokens generated, so the server had not failed; the model's turn came back empty, and wisp failed the turn with
the framework's message.

Asking again by sending the turn's prompt once more would run the model's commands again, which wisp never does
([ADR 0050](0050-tool-output-budget-and-overflow.md)). A probe with `ScriptedModel` on 2026-11-02 found that the
framework keeps nothing of a turn it ends this way: the session holds the context composed before the turn, without
the prompt, the calls, or their outputs, so the turn cannot simply be continued in the same session.

## Decision

The operator's answers on 2026-11-02:

1. **Ask once more, then say so.** When a response comes back empty, wisp asks the model once more, with a note of its
   own:

   ```
   [wisp: your last response had no reply and no tool call. Reply to the person now, from what you have done this turn.]
   ```

   When that is empty too, the turn ends with wisp's line, `(the model ended its turn without a reply)`, and the
   turn's `ran:` line, instead of failing.
2. **The turn is rebuilt from its record, so nothing runs again.** wisp rebuilds the turn as it rebuilds a turn the
   person stopped: the prompt, and each call with its output as the tool events recorded them, a call without an
   output dropped. It opens a session on the context composed before the turn with the rebuilt turn after it, and
   sends the note there; the model reads its calls' outputs from the record. The operator chose this over ending the
   turn at once with wisp's line, after the probe showed a same-session follow-up was not possible.
3. **The note is wisp's, not the person's.** The store keeps it as a notice, as a parked question's answer is kept, so
   it is never taken for something the person wrote; the rebuilt prompt and calls are recorded as the turn's, joined
   to their audit events by the calls' ids.
4. **Audited** as `turn.empty`, with `outcome`: `replied`, `empty again`, or `nothing to rebuild` (an agent with no
   tool event trail, which a face's thread always gives; only a bare agent in a test lacks one).

## Consequences

- A turn that ended empty after a model's tool calls now usually ends with a reply, and otherwise with wisp's line
  rather than an error a caller must handle; whether the note brings a reply from Bonsai 2 9B is to be measured, by
  rerunning the plan probe and the `edit_file` suite on it.
- The second request carries the turn's outputs as the record holds them, as a stopped turn's are: whole when they
  fit the tool-output budget, the held-back part kept in the output store ([ADR 0050](0050-tool-output-budget-and-overflow.md)).
- A schema reply is asked again the same way, its note sent with the schema, so the reply is still shaped.
