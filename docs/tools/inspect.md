# inspect

Shows wisp's own state to the model: the effective configuration, this conversation's status, the
standing command approvals, or recent audit events. Read-only. The same views back the MCP `wisp://`
resources and `wisp config`; see [ADR 0018](../decisions/0018-introspection.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `what` | string | yes | `config`, `status`, `approvals`, `audit`, or `calls`. |
| `last` | integer | no | For `audit`: how many of the most recent events. Default 20, maximum 100. Ignored with `turn`. |
| `kind` | string | no | For `audit`: only events of this kind, such as `command.outcome` or `approval.decided`. |
| `session` | string | no | For `audit` and `calls`: only events of this session or thread id. Default for `calls`, and for `audit` with `turn`: this conversation. |
| `turn` | integer | no | For `audit`: every event of this turn of the conversation rather than the last N. For `calls`: which turn. Default for `calls`: this turn. |

## Result

- `config`: pretty JSON, every setting with its default applied, the model, the `run_command` policy, and
  the paths under `~/.wisp` (the same as `wisp config`); compact JSON on one line when the pretty layout would
  pass the 4 KiB cap, as it does with every backend's settings, so no setting is cut.
- `status`: pretty JSON with `session`, `entryPoint`, `turn`, `model`, `tools`, `sessionApprovals` (how
  many patterns are approved for this session), `auditFile`, `version`.
- `approvals`: pretty JSON array of standing approvals: `id`, `pattern`, `workingDirectory` (null for
  `always`), `scope`, `level`, `grantedAt`, `expiresAt`, `source`.
- `audit`: one summary line per event, oldest first, the same lines `wisp logs` prints. `no matching
  audit events` when nothing matches.
- `calls`: one line per tool call of a turn, numbered, with the tool, its arguments (shortened), and its outcome:
  a command's exit status (and whether it timed out), `denied by policy; did not run`, `not approved; did not
  run`, `threw: …`, an `error: …` result's first line, or `ok, N bytes`. Built from the turn's audit events
  (`TurnCalls`, as `respond`'s `calls`), so a turn's calls fit where its raw events did not
  ([ADR 0050](../decisions/0050-tool-output-budget-and-overflow.md)). `no tool calls in turn N` when there are none.

```
turn 3: 3 tool calls
1. run_command {"command":"swift build"} → exit status 1
2. read_file {"path":"/a"} → ok, 3612 bytes
3. inspect {"what":"audit"} → error: unknown kind 'nope'
```

An unknown `what` or `kind` is returned as `error: …` text naming the accepted values.

## Limits

Output is bounded to the tool-output budget (an eighth of the model's window, 4 to 64 KiB;
[context-management.md](../context-management.md)); a view past it is kept whole in the conversation's output
store and shown as its first and last lines with a marker and a `held back:` note naming how to page it. `audit`
reads the audit file (and its rotated predecessors), so a session whose audit log is disabled sees nothing. Every
call is itself audited as `tool.call` and `tool.result` like any other tool, so reading the audit log leaves a
trace in it; the same call made again in a turn, with the same arguments, is answered with a `[repeated call: …]`
line above its result (six `inspect(audit)` calls in one turn of session `ce87576a`, 2026-10-04).

## Example

```
wisp "Use inspect with what: audit, last: 5, kind: command.outcome and tell me which commands ran and their exit status."
wisp "Use inspect with what: calls to list this turn's tool calls, then check each claim you made against them."
```

## Implementation

`InspectTool` in `harness/Sources/WispCore/Tools/InspectTool.swift` renders `Introspection`
(`Session/Introspection.swift`), which a `WispThread` builds with the session's home, config, store,
and a status closure. Tested in `IntrospectionTests` and, through the MCP server with a scripted model,
in `WispServerWireTests`.
