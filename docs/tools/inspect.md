# inspect

Shows wisp's own state to the model: the effective configuration, this conversation's status, the
standing command approvals, or recent audit events. Read-only. The same views back the MCP `wisp://`
resources and `wisp config`; see [ADR 0018](../decisions/0018-introspection.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `what` | string | yes | `config`, `status`, `approvals`, or `audit`. |
| `last` | integer | no | For `audit`: how many of the most recent events. Default 20, maximum 100. |
| `kind` | string | no | For `audit`: only events of this kind, such as `command.outcome` or `approval.decided`. |
| `session` | string | no | For `audit`: only events of this session or thread id. |

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

An unknown `what` or `kind` is returned as `error: …` text naming the accepted values.

## Limits

Output is capped at 4 KiB; a cut is marked `[truncated: N bytes, showing 4096]`. `audit` reads the audit
file (and its rotated predecessors), so a session whose audit log is disabled sees nothing. Every call
is itself audited as `tool.call` and `tool.result` like any other tool, so reading the audit log leaves a
trace in it.

## Example

```
wisp "Use inspect with what: audit, last: 5, kind: command.outcome and tell me which commands ran and their exit status."
```

## Implementation

`InspectTool` in `harness/Sources/WispCore/Tools/InspectTool.swift` renders `Introspection`
(`Session/Introspection.swift`), which a `WispThread` builds with the session's home, config, store,
and a status closure. Tested in `IntrospectionTests` and, through the MCP server with a scripted model,
in `WispServerWireTests`.
