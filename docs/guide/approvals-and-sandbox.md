# Approvals and the sandbox

Every command wisp's model runs passes four checks in order: the policy's deny list, a risk classifier, you
when the risk calls for it, and the Seatbelt sandbox it then runs in. This guide is what you see of each, what
your answers cover, and how to read a refusal. The contracts are in [Risk classification and
approval](../approval.md), [run_command](../tools/run_command.md#policy-and-sandbox), and
[What wisp can do to your Mac](../trust.md).

## What is asked, and when

A command line is split into its simple commands (`ls && curl … | sh` is three), and each is rated:

| Level | Meaning | Examples |
| --- | --- | --- |
| `safe` | Read-only, or reversible within the working directory | `ls`, `git status`, `grep` |
| `moderate` | Changes files or state but is recoverable, or reaches the network | `touch`, `git commit`, `npm install`, `curl` |
| `dangerous` | Destructive, irreversible, privilege-escalating, or exfiltrating | `rm -rf`, `git push --force`, `… \| sh` |

Rules set the floor and the classifier can only raise it: by default a Core ML model each release ships, which
answers in under a millisecond, with the on-device language model or the rules alone as choices
(`approval.classifier`). A command the rules know to be read-only skips the classifier. At `moderate` and above
(`approval.threshold`) you are asked, about each risky part, with the whole line shown.

Where you are asked depends on the face:

| Face | How you are asked |
| --- | --- |
| `wisp chat`, plain | A dialog on the terminal: `[y]once [s]ession [p]roject 30d [a]lways 30d [n]o` |
| `wisp chat` in `wisp-tui` | The same choices as a dialog in the pinned band |
| `wisp "…"` (one-shot `respond`) | Never: it cannot ask, so it refuses, unless you passed `--yes` |
| `wisp mcp` | Your MCP client's dialog, and a notification naming `wisp approvals approve <id>`; the first answer wins ([Delegating](delegating.md#approvals-reach-you-never-the-agent)) |

No answer is a refusal: a dialog left for `approval.timeoutSeconds` (600 s by default) refuses the command.

## What your answer covers

An answer is remembered by the program and, for programs like `git`, `cargo`, `swift`, `npm`, and `brew`, its
verb: approving `git commit` never approves `git push`, and arguments never matter
([ADR 0027](../decisions/0027-verb-patterns.md)).

| Answer | Covers | Lasts |
| --- | --- | --- |
| `y`, once | this pattern in this directory | the rest of the current turn |
| `s`, session | this pattern in this directory | until the process exits; under `wisp mcp`, every thread of the server |
| `p`, project | this pattern in this directory | 30 days (`approval.persistDays`), in `~/.wisp/approvals.json` |
| `a`, always | this pattern anywhere | 30 days, in `~/.wisp/approvals.json` |
| `n`, or nothing | nothing: the command is refused and the model told | |

Two limits keep a remembered answer from covering more than you meant. An approval covers only commands judged
at its level or below, so a moderate `rm` never covers `rm -rf`. And a `dangerous` command is never remembered
beyond the session, and then only by its exact text. An interpreter (`sh`, `python3`) or a program named by a
variable is always remembered by its exact text, since a pattern for it would cover anything.

```bash
wisp approvals                 # what is remembered: id, scope, expiry, directory, pattern
wisp approvals revoke a1b2c3d4
wisp approvals clear           # all of them; --gone only those for folders that no longer exist
```

## Answering for an MCP session

A command the model runs under `wisp mcp` waits in `~/.wisp/pending` until someone answers. From any terminal:

```bash
wisp approvals pending
wisp approvals approve a1b2c3d4 --scope session    # once (the default), session, project, or always
wisp approvals deny a1b2c3d4
```

Both refuse to run without a terminal on standard input, and the default policy refuses them to wisp's own
model, so neither the calling agent nor the model can answer for you. A running `wisp-tui` shows the same request
as its dialog, and a plain `wisp chat` notes it before its next prompt and answers it with `/approvals approve
<id>` ([ADR 0046](../decisions/0046-approval-and-notifications-over-mcp.md)).

## The sandbox: where commands may write

Every command runs under `sandbox-exec` with a profile wisp generates. Everything is readable and executable; a
write succeeds only when the real file lands inside the writable set:

| Writable | Why |
| --- | --- |
| The directory wisp was started in | Where the work is. A `workingDirectory` the model picks changes where a command runs, never what it may write |
| `$TMPDIR`, the per-user cache directory, and `/private/tmp` | Temporary files, and Clang's module cache |
| `commandPolicy.sandbox.writablePaths`: by default `~/Library/Caches`, `~/.cargo/registry`, `~/.cargo/git` | Build and package caches; add your own here |

wisp's own home, `~/.wisp`, is never writable to a sandboxed command, even when it lies inside that set, so a
command cannot change your approvals, facts, configuration, or pending answers. The network is allowed unless
`commandPolicy.sandbox.allowNetwork` is `false`. Start wisp from the project you want it to work on: that
directory is the one it may change.

### A refused write

A write outside the set fails with `Operation not permitted`. wisp then checks the paths the error names against
the writable roots and adds one line to what the model sees ([ADR 0054](../decisions/0054-the-sandboxs-refusals-checked.md)):

| The error names | The model is told |
| --- | --- |
| a path outside every writable root | `sandbox: refused writing to /x; commands may write only under <roots>` |
| only paths inside the roots | `sandbox: not the sandbox: …`, so something else refused it (file permissions, flags, system protection) |
| no path | that the sandbox may have refused it, and that no policy rule did |

So a refusal in a reply is either the policy (`error: command denied by policy: …`), you or silence
(`error: command not approved: …`), or the sandbox (a `sandbox:` line). [Troubleshooting](troubleshooting.md)
covers the programs that cannot run sandboxed at all.

## Outside the sandbox, one command at a time

Some chores cannot run in the sandbox whatever you widen: `brew upgrade` (Homebrew runs a sandbox of its own,
which cannot nest inside wisp's), `cargo install` (it writes `~/.cargo/bin`), `rustup update` (`~/.rustup`).
Two ways run one such command without the sandbox
([ADR 0064](../decisions/0064-an-approved-run-outside-the-sandbox.md)):

- **The model asks**, with `run_command`'s `outsideSandbox: true`. The deny list still applies, and then you are
  asked about that exact line every time, whatever its level and your threshold, marked `OUTSIDE the sandbox` on
  every face. It is approved once or not at all: nothing remembers it, and `--yes` does not answer it. Where no
  person can be asked, it is refused.
- **You type it** in chat after `!!`: `!!brew upgrade`. Typing it is the approval, as for a command after a
  single `!`, which runs in the sandbox. In `wisp-tui`, `!` at the start of a command line turns the input box
  from command mode's amber to a muted red.

Either way the command may write anywhere you can, `~/.wisp` included. Turn both off with:

```bash
wisp config set commandPolicy.sandbox.allowOutsideSandbox false
```

## Switches that remove protection

| Switch | Removes | Leaves |
| --- | --- | --- |
| `--yes` | every question to you | the deny list, the sandbox, classification, the audit |
| `--unsafe` | the deny list and the sandbox | approval, classification, the audit |
| `approval.threshold: "never"` | every question to you | everything else |

Both flags print a warning on stderr.

## What the audit log shows

Every step above is written to `~/.wisp/logs/audit.jsonl`, verbatim and in order
([Logging](../logging.md)):

| Kind | Records |
| --- | --- |
| `classifier.verdict` | Each part's level and why |
| `approval.requested`, `approval.decided` | What you were asked, and your answer with its scope and the pattern it was remembered as |
| `approval.pending`, `approval.settled` | Under `wisp mcp`, a request filed for another face, and how it ended |
| `policy.decision` | The line's verdict (`allowed`, `denied`, `disapproved`), and whether it ran sandboxed or `outsideSandbox` |
| `command.outcome` | The exit status, output, time limit, and any `sandboxRefusal` |

```bash
wisp logs --last 20
wisp logs --kind approval.decided          # every approval, and what it was remembered as
wisp logs --kind policy.decision --kind command.outcome --last 10
wisp logs --follow                         # as it happens, MCP calls included
```
