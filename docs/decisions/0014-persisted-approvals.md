# ADR 0014: Approvals have four scopes; project and always persist under ~/.wisp

Date: 2026-09-19. Status: accepted. Amends ADR 0011. Amended by
[ADR 0085](0085-an-approval-lasts-a-time-in-its-project.md): the choice is how long only; `project` lasts
`approval.persistDays` and `always` never expires, both in the command's project, its git repository with every
worktree, or its directory outside one; nothing applies in any directory.

## Context

Asking on every risky command makes routine delegation (a build-test loop, a git workflow) tedious and
multiplies exposure to the client's dialog problems. The MCP dialog had lost "approve for this session"
when it became fieldless. The owner decided that wisp may keep approvals after the process stops, in a
file under `~/.wisp`.

## Decision

- An approval carries a scope: `once` (amended 2026-09-19: the rest of the current turn, so one answer
  covers a prompt's whole tool loop), `session` (this process), `project` (this exact command in this
  exact directory), or `always` (this exact command anywhere). Chat answers `y`, `s`, `p`, `a`, or `n`; the
  MCP dialog offers the same four in a picker with Accept and Decline; `--yes` and `AutoApprover` mean once.
- `project` and `always` are written to `~/.wisp/approvals.json` (user-only, atomic writes) by
  `ApprovalStore`, with a random id, the level at grant, the source entry point, and an expiry
  (`approval.persistDays`, default 30). Expired entries are dropped on load.
- **Exact matching only.** No patterns or prefixes: a prefix rule such as "anything starting with git"
  is exactly the standing permission we do not want.
- **Dangerous commands are never persisted.** A `project` or `always` answer for a dangerous verdict is
  downgraded to `session` and audited as such; dangerous commands ask again in every process.
- A persisted approval decides only whether to ask. Deny patterns, the sandbox, and the classifier still
  run on every use, and every use is audited as `approval.decided` with decision `cached-project` or
  `cached-always` and the approval id.
- `wisp approvals` lists standing approvals; `revoke <id>` and `clear` remove them.

## Consequences

- Standing permissions are inspectable and bounded; the audit log links each use to its grant.
- Exact matching means slightly different commands still ask; that is the intended trade.
- The store is per user, not per project, so `project` entries carry their directory explicitly.
- The picker returns to the MCP dialog; if a client cannot render it, Accept still means once.
