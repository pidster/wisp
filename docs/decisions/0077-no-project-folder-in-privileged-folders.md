# ADR 0077: The current directory is the project, unless it is a privileged folder

Date: 2026-10-23. Status: accepted by the operator on 2026-10-23. Amends the writable root of
[run_command.md](../tools/run_command.md) ("Writable root and working directory", since 2026-09-19).

## Context

The sandbox's writable set is rooted at the directory wisp was started in (`Options.writableRoot`, the current
directory), so that a command may change the project and nothing else; the launching app chooses that directory, as
Claude Code starts `wisp mcp` in the project. Nothing checked what the directory was. Probed on this Mac on 2026-10-23
with the note of [ADR 0076](0076-the-sandbox-in-the-prompt.md): started from `~`, the model was told it could
"write only under ~", which was true: every file in the home folder, `~/.ssh` and `~/.zshrc` among them, was writable
to its commands. Started from `/`, writes were limited by file permissions alone. With `Wisp.app` installed by
`wisp install` (0.31.0), `wisp chat` typed in a new terminal, which opens in the home folder, is the likely first run.

The operator chose on 2026-10-23 that the current directory stays the project wherever the launching app puts it,
unless it is a privileged folder, where commands write only to the temporary folders.

## Decision

1. **The current directory is the project** commands may write in (`CommandPolicy.projectRoot`), unless it is a
   privileged folder (`CommandPolicy.privilegedFolder`):
   - the home folder, or a folder above it (`/`, `/Users`), which would make the whole home writable;
   - the home's `Library`, which holds app data and keychains;
   - `/Volumes` itself, where every disk is mounted;
   - a system folder: `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/opt`, `/private` (but not
     its temporary folders, `/private/tmp` and `/private/var/folders`, writable anyway), `/dev`, `/cores`.
2. **Started in one, there is no project folder**: commands, and `edit_file`, write only to the temporary folders and
   `commandPolicy.sandbox.writablePaths`. A path added there makes such a folder writable for someone who wants it.
3. **It is said where it matters**: the model's sandbox note says wisp was started in that folder, so it gives no
   project folder, and to start it in a project; `wisp doctor`'s `sandbox` line says the same, or names the project
   folder when there is one.

## Consequences

- A chat started in a new terminal can read anywhere and write nowhere it should not; to work on a project, start
  wisp there, as before.
- Every place the writable set is read (the sandbox's profile, `edit_file`'s check, the refusal checks of
  [ADR 0054](0054-the-sandboxs-refusals-checked.md), the note) follows from one function, so they agree.
- A project kept under a system folder (`/opt/project`) gets no project folder; adding its path to `writablePaths`
  restores it.
