# ADR 0045: Layered context, composed for each request

Date: 2026-10-01. Status: accepted. Records the
[layered-context proposal](../proposals/2026-09-29-layered-context.md), which stays the detailed record: decisions
D1 to D12 with what was considered and when to reopen each, and every evaluation. Amends
[ADR 0025](0025-context-estimation.md) (when and how far the context is condensed) and
[ADR 0043](0043-context-window-from-memory.md) (what the window sets). Reverses design rule 4 of
[context-management.md](../context-management.md) as it stood before the proposal ("the transcript stays a faithful
record"): the store is the faithful record, and the model's context is composed from it. Leaves
[ADR 0017](0017-three-layer-instructions.md) unchanged. Amended by [ADR 0048](0048-permanent-facts-over-mcp.md): the
person admits a permanent fact an MCP caller asks for from a terminal (`wisp facts keep`) or `wisp-tui`, as well as
from chat.

## Context

Until phase 2 of the proposal, wisp kept one transcript per conversation, and it was at once the record, the
model's view, and what the person saw. The only way to keep it inside the window was to cut the oldest turns off.
On the on-device model's 8,192 tokens a scripted chat, now `ContextEvalTests`, showed what that costs: facts
planted early went with the turns that held them; the model, not told what it had lost, named the oldest file
still in view as the first it read; nothing could bring dropped turns back; once full, it condensed before almost
every turn; and most of the window was tool output that nobody needed twice.

The baseline, 2026-09-29, under heavy load from other work (times indicative only):

| Model, window | Score | Condensations | Tokens after a turn, median (max) |
| --- | --- | --- | --- |
| On-device, 8,192 | 0/6 | 9 | 5,896 (7,123) |
| granite4.1:8b, 8,192 | 1/6 | 4 | 6,124 (7,411) |
| granite4.1:8b, 32,768 (nothing dropped) | 6/6 | 0 | 11,201 (16,252) |

Granite answered everything when nothing was dropped, so the loss at 8,192 was the dropping's, not the model's.
These are not tuning problems: while the transcript is both the record and the model's view, keeping it small
means forgetting.

### What each phase measured

Each phase was evaluated on the same eval (scenarios `showing`, `recalling`, and `noting` add to the baseline; the
proposal's "Evaluation" has every table):

| Phase | Finding | Figures |
| --- | --- | --- |
| 3, cutting retyped output | Saves what the retype cost and no more | About 200 tokens for an 866-byte file; no condensation moved |
| 3b, tool output as a reference after its turn | The scenario fits the window, and recall follows | A reading turn added about 490 tokens on-device and 450 on granite, against 1,300 whole; 6/6 on both models with no condensation, against dropping's 0/6 and 1/6 |
| 4a, facts | Facts survive a condensation that drops every early turn | At a 50% budget: 1/6 with references alone, 5/6 with facts, on both models |
| 4b, the running summary | One call for facts and the summary holds its schema and costs less | 5/6 on-device and 6/6 on granite in one call, 3/6 and 5/6 in two |
| 4c, `memory` | Granite recalls the right entry when a detail is gone, and quotes it | The detail question answered after `recall entry 6`; without the tool, a name made up |

### The checkpoint, 2026-10-01

Phase 6 ran twenty tests, one at a time, on the `recalling` scenario (22 turns, 7 questions) at a window of 8,192:
on-device, then granite at a configured 8,192. The load average was 1 to 5 (7 to 10 in the last run), so times
are comparable. One run each; none was broken, and none was rerun. "The stack" is the design as built, with
condensing to the default target. The proposal's "Checkpoint, 2026-10-01" has every table.

**The whole design against dropping:**

| Budget | Strategy | On-device: score, condensations, time per turn median (p95) | granite: score, condensations, time per turn median (p95) |
| --- | --- | --- | --- |
| 85% | dropping | 0/7, 8, 13.7 s (20.3 s) | 1/7, 4, 5.1 s (15.2 s) |
| 85% | the stack | 6/7, 0, 10.4 s (13.4 s) | 7/7, 0, 9.2 s (11.3 s) |
| 50% | dropping | 0/7, 13, 10.6 s (18.7 s) | 0/7, 13, 10.4 s (18.4 s) |
| 50% | the stack | 3/7, 7, 6.9 s (33.6 s) | 4/7, 7, 8.8 s (42.7 s) |
| 50% | the stack, phase 2's fixed four turns | 4/7, 2, 9.3 s (22.9 s) | 7/7, 1, 6.1 s (9.5 s) |
| 50% | the stack without `memory` | 5/7, 5, 8.2 s (33.8 s) | 5/7, 5, 6.0 s (42.6 s) |

At the default budget the stack never condensed in 22 turns (6,239 and 6,511 tokens at most) and missed only the
on-device model's detail, which it had recalled and then misread. At half the window every strategy of the design
beat dropping.

**Condensing to a target at a budget equal to the target.** The 50% runs set the budget to 0.5, which is also the
target's share. The goal of a condensation is the share or, when less, the budget less the prompt and the
headroom; with the share at the budget, the second always won (goals of 2,922 to 3,954 tokens, all below the
4,096 the share gives). A condensation then ends one headroom below the trigger, and the first turn that adds
anything lasting triggers the next: 70 of the 84 gaps between condensations under the target were a single turn,
against four turns or more under the fixed policy, whose trigger has no headroom. Each condensation distils, so
the target runs made 7 to 12 distillation calls (86 to 116 s in all on-device, 133 to 192 s on granite) against 1
or 2 (19 to 42 s), and each call was another chance to garble a fact: the on-device distiller once recorded the
release codename as `4127`. That is why the target scored lower than the fixed policy at 50%. Phase 5's
guarantees held throughout: in 96 condensations the fill after was at or below the goal every time, the floor was
never reached, and nothing overflowed.

**The assessment** (every built-in tool offered, 50%):

| Tool sets | On-device: score, time per turn median | granite: score, time per turn median | Assessment call, mean |
| --- | --- | --- | --- |
| None (the stack) | 4/7, 7.5 s | 5/7, 6.7 s | |
| Per request (D4) | 3/7, 11.2 s | 3/7, 12.8 s | 2.3 s on-device, 4.3 s on granite |
| Grown per task (D11's alternative) | 2/7, 10.1 s | 4/7, 13.5 s | 2.2 s, 3.3 s |
| Every tool, no saving | 4/7, 9.5 s | 4/7, 12.9 s | 2.1 s, 3.8 s |

The rules settled 9 or 10 of 22 requests; the rest, every question but the first, took a model call. Registering
fewer tools saved 412 to 662 tokens at the first turn and 60 to 305 by the sixth, as the now block grew, and did
not change how often the context condensed. The inferred task was rewritten on 8 to 11 of 22 requests, and the
return to the task failed in all three granite runs (the task had become the latest question) and in one of three
on-device runs; without the assessment both models returned to it. No turn needed the retry for an unregistered
tool, and `inspect`, registered on most requests, was called once in four runs.

## Decision

The design of the proposal, as built in phases 2 to 5, is wisp's context management. In outline, with the
decisions that set each part:

- **Four records of one conversation** (D8, D12). The audit log is the truth, verbatim and append-only; the store
  (`ThreadRecord`) refers to it by event id and adds what composition needs (kinds, states, facts, summaries,
  links); the model's context is composed for each request (`ContextComposer`); the transcript the person sees
  carries every tool's output, the same in chat and over MCP (D9: inline up to 1 KiB, a resource above).
- **Layers ordered by stability**, most stable first (D4, D11, D12): the instructions (wisp's prompt, the
  operator's extension, the caller's instructions as ADR 0017 has them, and the tool definitions); the earlier
  block (permanent facts, the conversation's facts the literal turns no longer show, and the running summary);
  the literal turns; the now block (ephemeral facts, the task, and, with the assessment, the relevant facts and
  the tools line); the request. **Authority by position:** everything derived from the conversation is on the
  prompt side, labelled as a record with its source, never in the instructions.
- **Tool output** (D5, D12) is whole in the turn that produced it and a structured reference after it (the tool,
  the entry, the time, the status, the size, the first and last lines, the arguments; at most 640 bytes), with
  `memory "recall entry N"` to see it again. Exact copies of an output in a reply are cut from what the model
  carries. D5's slice of tool output sized to the window was not built: references after the turn answered the
  same need.
- **Facts** (D1, D2, D3, D6) are versioned assertions under `{scope, subject, name}`, with a source (the person, a
  caller, a tool, the model) that sets precedence, and a temporal class that sets where they live: the
  conversation (dynamic), the process (ephemeral), or `~/.wisp/facts.json` (permanent, admitted only by the
  person). Facts from tool output are extracted every turn without a model; facts from prose and the running
  summary are distilled by the conversation's model, in one call, when turns are dropped. Subject kinds are data.
  The person sees, states, deletes, and scopes them; the agent supersedes and never deletes.
- **`memory`** (D12, phase 4c) recalls stored entries, turns, the task, the summary, and a fact's history, for the
  turn only, from the audit log; it also lets the model note a fact (source `model`, method `noted`). It comes with
  every tool, and with a named list only when the list names it.
- **Condensing to a target** (phase 5; amends ADR 0025). Due when the context, the prompt, and a headroom of the
  latest eight turns' average size reach the budget (85%); it takes references first, then distils and drops the
  fewest oldest turns, measuring after each step, down to the goal (`context.target`, 0.5 of the window, or less
  when the prompt and the headroom need it); never below one literal turn, where the earlier block is squeezed and
  the person is told. The overflow retry condenses the same way and retries once.
- **The assessment per request** (D12, amending D4, D6, D7) is built and **off by default**
  (`assessment.enabled`).
- **A model switch** carries the store to the new model's agent, which composes from it for its own window (D10).

**Defaults, and what the checkpoint says about them:**

| Setting | Default | The checkpoint |
| --- | --- | --- |
| Budget (`contextBudget`) | 0.85 of the window | Nothing condensed in 22 turns at 8,192 with the stack; unchanged |
| `context.target` | 0.5 | Unchanged. Not measured at 85%, where it leaves 2,867 tokens below the budget, four to seven reading turns at 8,192 once the prompt and headroom are taken (arithmetic). At 50%, where it equals the budget, it condensed on nearly every turn: the guard below |
| `context.headroomTurns` | 8 | Unchanged; the variants over one turn or none were not run |
| `facts.share`, `facts.summaryShare` | 0.1 and 0.05 of the window | Unchanged (phase 4b) |
| `assessment.enabled` | false | Stays off: lower scores on both models, 2 to 4 s a call on more than half the requests, a task that drifts with each question, and a token saving that did not reduce condensing |
| `memory` | registered with every tool | Stays: the one way back to a dropped detail other than running a tool again, used correctly by granite each time it recalled the right entry for the detail question; about 150 tokens of definition and rule |

**The guard, a follow-up to phase 5.** A target at or near the budget must not be possible. Proposed: the goal
leaves at least a few average turns between condensations, by clamping the share to at most the budget less 0.2
(no change at the default 0.85; 0.3 at a budget of 0.5), or by deriving the goal from the budget, the budget less
the prompt, the headroom, and a few turns' lasting growth. Either goes with a gate test that no configuration
condenses on consecutive turns while turns of average size arrive, and the 50% eval variants re-run under it. At
0.5 on an 8,192 window either form may reach the floor, which says that a 50% budget is too tight for that window
rather than that the guard is wrong.

Built 2026-10-01. The first form: the share is capped at the budget less 0.2
(`ContextComposer.targetMargin`, `effectiveShare(of:)`), applied where the goal is computed so a `ContextTarget`
built in code is capped as well as `context.target`; the derived-goal form was not needed. The default 0.5 is
unchanged. `wisp doctor` reports a capped setting (ok, with a note), and the `context.condensation` event's
`target` is the goal in tokens, so it already records the capped share. A gate test runs generated conversations
at every target from 0 to 1 in steps of 0.05 and asserts that no two condensations fall on consecutive turns
while turns of average size arrive (it fails with the margin at 0). The 50% eval variants have not been re-run
under the guard.

## Consequences

- **The store, not the transcript, is the record**, and `/inspect context`, `wisp-tui`'s panel, and
  `wisp://threads/{thread_id}/context` show the model's context for any turn at no cost to the model. Design rule 4
  of [context-management.md](../context-management.md) now names what the active view may differ by: dropping
  whole turns, cutting exact copies, and references, each marked in the store and audited.
- **Measured gains**: at the default budget the design kept everything in view for 22 turns where dropping lost
  every early fact; at half the window it beat dropping on every strategy. The cost on the on-device model was
  none in time (turns were faster); on granite a turn took longer (9.2 s against 5.1 s median), because each turn
  after a tool-using one starts a new session and the context no longer shrinks.
- **ADR 0025 amended**: condensing is due on the estimate plus a headroom and condenses to a token goal verified
  after each step, rather than to the policy's turns; phase 2's `.fixed` stays for the equivalence suite and the
  earlier eval strategies.
- **ADR 0043 amended**: the window also sets the condensing target and the earlier block's caps, and its open
  question 9 (tool output sized to the window) is answered by references after the turn, not by sizing; tool
  results keep their 4 KiB bound within their own turn.
- **New audit events** (`context.cut`, `context.reference`, `context.distillation`, `context.summary`,
  `context.memory`, `context.assessment`, and the `fact.*` kinds) and new fields on `context.condensation`;
  [logging.md](../logging.md) lists them.
- **One run each.** Every checkpoint figure is one run, and earlier phases showed on-device scores varying by two
  or three of seven between builds that differ in small ways. The design's gain over dropping is large enough to
  rely on (0 or 1 of 7 against 6 or 7 at the default budget); the differences between variants at 50% are not,
  except where a mechanism explains them, as the guard's does.

**Open:**

- **The guard** above, then the 50% variants again, and the target at 0.4 and 0.6 and the headroom over one turn
  or none, which the checkpoint did not run; and the default budget exercised by a scenario long enough to
  condense at 85%.
- **The assessment**, if it is reconsidered: a task that changes only when the request restates it, not on each
  question; D7's repeated facts, which did not help the on-device model (D7's own condition for dropping them) but
  could not be separated from the task inference here; and a tools line that does not invite tool calls when the
  answer is in the context. A fast specialised classifier could choose tools instead of the model's call (D4,
  [ADR 0038](0038-fast-specialised-classifiers.md)), trained on the audit's pairs of a request and the tools it
  used.
- **A specialised distiller** (D1), once reviewed pairs of turns and distilled facts exist and the distiller's
  cost matters; at the checkpoint a distillation took 1.7 to 29 s.
- **MCP host effects and permanent facts over MCP** in later releases: `set_fact_scope` offers `thread` and
  `session` only until the operator decides how permanent facts are managed there
  ([ADR 0044](0044-host-effects.md)). Settled: host effects by [ADR 0046](0046-approval-and-notifications-over-mcp.md),
  permanent facts by [ADR 0048](0048-permanent-facts-over-mcp.md).
- **The summary's visibility** (`/inspect facts`, the facts resource) is judged in use.
- **D10's model switch** is not yet evaluated, and Core AI and MLX report no window until their bundles' metadata is
  read ([ADR 0043](0043-context-window-from-memory.md)).
