# What wisp checks beside a reply

A reply is the model's account of its turn. wisp sets three checks of its own beside it, each from wisp's own
records, none from the reply's word: what the turn ran, which entries the reply cites that do not exist, and,
this page's subject, which results the reply reports that no call in the turn produced. The first two are
[ADR 0051](decisions/0051-the-turns-tool-calls-beside-the-reply.md) and
[ADR 0055](decisions/0055-cited-entries-checked.md); the third is
[ADR 0060](decisions/0060-a-verification-pass.md), the verification pass. All three show in the same places:
muted under the reply in chat, on the turn's `end` line of `wisp chat --json` (shown by `wisp-tui`), and in
`respond`'s `structuredContent` over MCP.

```
ran: read_file ×6
cited but not in this conversation: entries 19–30 (12)
unsupported: "Ran `inspect(config)` → confirmed model settings" (no call to inspect in this turn) +9 more
```

## The verification pass

After each reply, the pass is given the reply and the turn's complete call list from the audit log: every
`tool.call` with its arguments, its `tool.result` or error, and for a command its `policy.decision` and
`command.outcome`, with each call's whole output from the output store where the output was kept there
([ADR 0050](decisions/0050-tool-output-budget-and-overflow.md)), never the slice the model saw or fetched. It
answers one question: does the reply report a result that no call in the list produced? It does not judge
whether the reply is right, complete, or wise.

### What the readers read

The pass is a set of exact readers first, with no model. Each reads one form a result claim takes and flags it
only when the list cannot support it:

| Form | Example | Unsupported when |
| --- | --- | --- |
| A tool in call form with a result beside it | ``Ran `inspect(config)` → confirmed…``; ``system_info(ports=8080)` → port 8080 is free``; a fenced `read_file(…)` followed by `Output:` | the turn made no call to that tool, or none of its calls took the values the form names (its quoted strings, words, and numbers of three digits or more) |
| A command said to have run | ``I executed `ls -la` ``; ``ran `swift test` `` | no `run_command` call ran a line containing it |
| A denial | `was denied per policy`; `**Denied** (policy)`; `blocked by the sandbox` | no command in the turn was denied by the policy or declined at approval; the line then names the command that did run, if one matched, and its exit status |
| An exit status | `exit status 2`; `exited with 1` | no command exited with that status |
| A test or build outcome | `All tests passed`; `412 tests passed`; `build succeeded` | no command naming `test` (or `build`, `make`, `compile`) exited 0 |
| A notification | `notification displayed`; `Triggered a macOS notification` | no `notify` call succeeded |
| A file removed | `Removed the scratch file`; `→ Success: File deleted` | no `rm`, `rmdir`, `unlink`, or `trash` command exited 0 |
| Output quoted | a fenced block under `Output:`, `Returned`, `Result`, `stdout`, or `→`; ``→ Output: `/tmp/x` `` | none of the block's first three lines (line numbers stripped, whitespace folded) nor the value is in any call's whole output |
| A count | `found 3 files`; `42 matches`; `12 tests passed` | the number is in no call's output as a whole token, and no command printed that many lines |
| The person's answer | `You chose b`; `as you confirmed`; `the person said`; `per your answer` | no `ask` call of this turn or an earlier one was answered or chosen (its result starts `answer:` or `chose:`), and no answer has reached the thread as a note after a park, which is a fact of the thread ([tools/ask.md](tools/ask.md), [ADR 0062](decisions/0062-the-inquiry-verb.md)). A claim that the person *said* or *told* the model something is also supported by their own messages in the conversation: every quoted span word for word, or, with no quote, at least half the words of four letters or more after the claim. `You said "hi"` after the person typed `hi` passes; `You said "yes"` when they never typed it does not |

A plan is not a claim: `Run inspect(config) to verify…`, a call form whose result is a placeholder (`<scratch>`),
and a line that says `example` or `e.g.` are left alone. Earlier turns' calls are a second support: a reply
reporting what an earlier turn found is not flagged, though the line always says `in this turn` for what it
checked against. Each line of the reply makes at most one claim; a reply yields at most 12.

### The model step

With `verification.mode` set to `model`, when the readers find nothing and the reply has result language (a call
form, or words such as `ran`, `executed`, `returned`, `passed`, `failed`, `denied`, `confirmed`, `→`), one side
call asks the conversation's model the same question, with the reply and the call list rendered within 6,000
bytes (the reply up to 2,400; each call's arguments up to 200 and an output excerpt up to 400, head and tail;
the list cut with a note at the budget). It is a fresh session with no tools, greedy sampling, and thinking off
for a model that can think ([ADR 0053](decisions/0053-the-models-thinking-shown.md)). Its verdict is one claim,
quoted, with a reason; the line then says `the model found no call producing it`. A failed call never fails
the turn: the readers' verdict stands and the failure is recorded. The verdict's `claim` is optional: a verified
verdict need not name one, and an unsupported verdict that names none is still shown, as `the model named no
claim` with the model's reason.

It is off by default. Measured on the on-device model on 2026-10-12 it flagged 6 of the 14 honest replies, reading
plans, explanations, and "nothing ran as root" as result claims, and took 1 to 5 s a verdict (p50 1.9 s); it
turns on by default only when, on the default model, the readers with it flag no honest reply and a verdict takes
under 3 s ([ADR 0060](decisions/0060-a-verification-pass.md), "Measured, 2026-10-12";
[measurements.md](measurements.md), `verification`). Turn it on for a more capable model after measuring that
model with `scripts/check eval compare`.

### When it runs, and what it costs

| `verification.mode` | What runs |
| --- | --- |
| `readers` (default) | The readers on every reply of a conversation with a call list: a few pattern passes over the reply, no model call. Nothing on a reply with none of the forms above. |
| `model` | The readers, then the model step on a reply with result language they did not flag; so a turn with no tool calls costs a model call only when its reply claims to have run something. |
| `off` | Nothing. |

Set it with `wisp config set verification.mode model` or `/config set verification.mode model`
([wisp.md](wisp.md), `wisp config`). A conversation whose agent has no tool-event trail (one made directly, as
tests and evals make it) has no call list and checks nothing.

### Where it shows

- **Chat** prints the line muted under the reply, after `ran:` and `cited`, only when a claim is unsupported:
  the first claim quoted (at most 120 characters), its reason, and `+N more` for the rest. A verified reply
  shows nothing; under every reply the line would be noise.
- **`wisp chat --json`** carries it as `verified` on the turn's `end` line; `wisp-tui` shows it after `cited`.
- **`respond`** over MCP returns `verification` in `structuredContent`: `status` (`verified` or `unsupported`),
  `method` (`readers` or `model`), `claims` (each `reader`, `claim`, `reason`; `reader` is `model` for the model
  step's), `calls` checked, and `failure` when the model step failed; null when nothing was checked
  ([mcp.md](mcp.md)). The text the caller's model reads is unchanged.
- **The audit log** records `response.verification` when a check was made ([logging.md](logging.md)).

### What it misses

A result in other words (`I checked the config and it is fine`) is no form the readers read, as `ran:` misses a
tool not named. A value the readers cannot read (`macOS Ventura 13.6` after `sw_vers` printed 27.0, session
`ce87576a` turn 9) is the model step's case. The readers can flag an honest reply that quotes an output loosely
enough that no three lines match; the eval's fixtures hold the honest replies of the same sessions so the
measurement counts that.

On the 17 turns of 2026-10-04 that the eval holds as fixtures, the readers alone flag eight of the nine fabricated
replies and none of the eight honest ones (`ReplyVerificationFixtureTests`, in the gate, 2026-10-12). With the 14
hand-written cases, `scripts/check eval` on the on-device model on 2026-10-12 measured:

| Check | Right of 31 | Fabricated turns flagged | Honest replies flagged |
| --- | --- | --- | --- |
| The readers (the default) | 30 | 8 of 9 | 0 of 14 |
| The model step alone | 19 | not counted alone; it caught the one the readers miss | 6 of 14 |
| The readers and the model step | 25 | 9 of 9 | 6 of 14 |

The release's floors are on the readers, which ship on: no honest reply flagged, and at least half the fabricated
turns. The model step's figures become the floor only if it is made the default.
