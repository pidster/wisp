# ADR 0085: An approval lasts a time, in its project

Date: 2026-11-05. Status: accepted. Amends ADR 0014.

## Context

The operator, evaluating the MCP approval dialog for 0.35.1, found that its choices do not say what they keep. They
were "This turn", "This session", "This project (30 days, this directory)", and "Always (30 days, any directory)":
one list mixing how long an approval lasts with where it applies, and an "Always" that ends after 30 days. Chat's
prompt (`[p]roject 30d`, `[a]lways 30d`), `wisp-tui` ("approved everywhere for 30 days"), and
`wisp approvals approve --scope` said the same.

The operator also saw 30-day approvals not sticking. Read from the audit log on 2026-11-05
([measurements.md](../measurements.md), "The git thread's slow turns and its approvals"): every `project` grant
(eight, and seven live in `approvals.json`) covered every later run of its pattern in the directory it was given in;
each time one was asked again, the command ran in another directory: a worktree of the same repository under
`.claude/worktrees/`, or the repository after a grant made in a worktree. `project` matched one exact directory, so
neither a subdirectory nor another worktree of the same repository was covered. No `always` grant was ever made.
`session`, the answer given most (48 times), ends with the server's process, so each release and each reconnect asks
again; the operator chose to keep that.

## Decision

1. **The choice is how long, and only that** (the operator, 2026-11-05): this turn (`once`), this session
   (`session`, until wisp's process exits), a number of days (`project`, `approval.persistDays`, 30 by default), or
   always (`always`). The values keep their names, so chat's `y`, `s`, `p`, `a`, `wisp-tui`'s keys, and
   `wisp approvals approve --scope` are unchanged; what `project` and `always` keep changes.
2. **A remembered approval applies only in its project.** There is no "any directory" any more: `always` is this
   project, never expiring, where it was any directory for 30 days. An `always` entry written before, which names no
   directory, is no longer used and is dropped from `approvals.json` at the next change.
3. **The project is the repository.** A command run inside a git repository is in that repository's project: its
   working tree, every subdirectory, and every worktree of it, which share one common git directory. wisp reads it
   from the `.git` entry nearest above the directory, without running git, and trusts only what git itself accepts: a
   real `.git` directory (not a link), or a worktree's `.git` file whose `gitdir:` is `<common>/worktrees/<name>`,
   whose `commondir` names that `<common>`, and whose `<name>/gitdir` points back at the same file. Any other `.git`
   entry, a link, a submodule's file, or one naming somewhere it does not belong, makes its folder a project of its
   own. So a `.git` file the model plants in a folder it may write, the temporary folders among them, cannot borrow a
   repository's approvals (raised in review on 2026-11-05): to join a repository it would have to write into that
   repository's own `.git`, as `git worktree add` does, which makes it a worktree of the repository in git's eyes too.
   Outside a repository the project is the directory itself, as before. An entry records the project it was granted
   in; one written before records only its directory, whose project is read when it is matched.
4. **`always` never expires.** It ends when the person revokes it (`wisp approvals revoke` or `clear`), or when its
   project is gone (`wisp approvals clear --gone`). The rest of ADR 0014 stands: the level at grant is the most an
   entry covers, a dangerous verdict is never remembered past the session, and deny patterns, the sandbox, and the
   classifier run on every use.
5. **Every face says only how long.** The labels are "This turn", "This session", "30 days" (the configured number),
   and "Always"; the dialog's text names the project the last two apply in.

## Consequences

- A grant in one worktree covers the repository and its other worktrees, so agents working in worktrees of one
  repository share their approvals; that is the intended trade for a project.
- `always` is a standing permission with no end but the person's; `wisp approvals` lists it as never expiring, and
  `wisp doctor` is unchanged.
- An `always` granted before 0.35.1, for any directory, is asked again once in each project. None was found in the
  operator's store.
