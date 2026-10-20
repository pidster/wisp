# ADR 0067: A call's time limit may only lengthen the one it would otherwise get

Date: 2026-10-20. Status: accepted. Chosen by the operator on 2026-10-20. Amends
[ADR 0063](0063-command-time-limits.md), point 5.

## Context

ADR 0063 let a model's `run_command` call ask for its own limit with `timeoutSeconds`, and put that request above
the thread's `commandTimeoutSeconds` and the operator's default, "shorter or longer". The argument's guide read
"Seconds this command may run, for a long build or test. Omit for the default." and did not say what the default
was.

On 2026-10-19 the git thread `git5` (model `ollama:granite4.1:8b`, `commandTimeoutSeconds` 600, the instructions in
`AGENTS.md`) filled in every optional argument on its first call, unprompted: `timeoutSeconds: 30` and
`outsideSandbox: false`. The call was a `git commit` whose pre-commit hook runs the gate, and it was killed at 30 s
(`exitStatus` -15), the failure the thread's 600 s was set to prevent. The next two calls copied 30 from the
first. In the audit log of 2026-10-14 to 2026-10-19, granite asked for its own limit on 10 of 142 `run_command`
calls without being told to: seven of 300 s on 2026-10-15, which did no harm, and these three. The caller worked
around it by naming `timeoutSeconds 1800` in every git prompt.

A model has little reason to want less time than its caller or the operator gave it: a command that hangs is
still killed at the longer limit, and a typed command the person stops themselves.

## Decision

1. **A call's request only lengthens.** The limit a call would have without a request is the thread's
   `commandTimeoutSeconds`, else the operator's `commandTimeoutSeconds`. A `timeoutSeconds` shorter than that,
   after the cap, gets that limit instead; one as long or longer wins as before, clamped to
   `commandMaxTimeoutSeconds`. Under an operator default of 0, no limit, every request gets no limit.
2. **The audit records what was asked.** `command.outcome` for such a call has `timeoutSource` and
   `timeoutSeconds` of the limit it kept (`thread` or `default`), and `timeoutAsked`, the seconds the call asked
   for. It is absent when the call asked for none, or for as long or longer.
3. **The guide says so.** `timeoutSeconds` is guided as "Only for a build or test that needs longer than the
   default, in seconds. Omit otherwise.", and the `limits` text says it "asks for longer, up to N s".
4. A request below 1 is still refused as text, and nothing runs.

## Consequences

- The git thread's 600 s holds whatever the model fills in, and prompts need not name a timeout.
- A model can no longer shorten a command's limit. Nothing in wisp relied on that; a caller who wants a short limit
  starts the thread with a short `commandTimeoutSeconds`.
- `CommandRunner.TimeLimit.Request` carries the thread's limit beside a call's request, and `TimeLimit` the
  shorter seconds asked for (`shorter`).
- Tests: `CommandTimeLimitTests` checks the rule in `limit(for:requested:)` and drives it through the real sandbox
  with a thread limit of 5 s and a call asking for 1 s.
