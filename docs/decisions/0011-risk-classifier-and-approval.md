# ADR 0011: Classify command risk with rules plus the on-device model, and ask above a threshold

Date: 2026-09-17. Status: accepted. Amended by [ADR 0044](0044-host-effects.md): approval is the first
request-and-answer host effect; approvers are what a face carries for it.

## Context

Patterns and the sandbox (ADR 0009) are hard limits. Between "forbidden" and "fine" lies most of what an
agent wants to run: file modifications, commits, installs, network calls. Modern harnesses route those
through a risk classifier that decides whether a human must approve. A probe showed the on-device model
catches every dangerous command in a labelled set but under-rates some moderate ones as safe.

## Decision

- A `RiskClassifier` protocol with three levels. `RuleRiskClassifier` (regexes with reasons) and
  `ModelRiskClassifier` (fresh session, `@Generable` verdict) are composed by taking the higher level, so
  the model can only raise a verdict, never lower one, and the rules cover its weak spot.
- `ApprovalGate`, one per session, asks an `Approver` at or above a configurable threshold (default
  `moderate`) and caches "approve for this session" by exact command line. Denials return to the model as
  tool output.
- Approvers per entry point: denying (non-interactive `respond`, unless `--yes`), terminal (`chat`), MCP
  elicitation (`mcp`, unless `--yes`), with a clear denial when the client lacks elicitation.
- Every verdict and decision is audited (`classifier.verdict`, `approval.*`).
- Amended 2026-09-19: an unanswered approval is a denial. Approvers report `unanswered` after
  `approval.timeoutSeconds` (default 600; `0` disables the timeout at the owner's request, after two
  minutes proved too short for real dialogs) and the gate refuses, auditing `timed-out`. The MCP dialog is
  fieldless (Accept once or Decline) because a form picker made Claude Code's dialog unresponsive; session
  approval over MCP and approval for clients without elicitation are open questions.
- A model evaluation suite runs only with `WISP_MODEL_TESTS=1` (`scripts/check eval`); it asserts that
  no dangerous command is rated below moderate and reports accuracy.

## Consequences

- One extra model call (about a second) per `run_command`. Acceptable; `useModel: false` removes it.
- The classifier never loosens the policy or the sandbox; it only adds a human in the loop.
- Session approvals are keyed by exact command text, so a build-test loop is asked once per distinct
  command. Normalisation is future work.
- MCP clients without elicitation cannot approve, by design; the calling harness keeps its own approval UX
  and runs risky commands itself.
