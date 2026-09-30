# harbour sync: design overview

`harbour sync <source> <destination>` makes the destination directory match the
source directory. It is the core command of harbour, a small open-source file
synchronisation tool written in Swift. This page describes how the command is
put together and why. The flags are listed on their own reference page.

## Goals

- Safe by default: nothing at the destination is removed unless the user asks.
- Restartable: an interrupted sync can be run again and will finish the job.
- Predictable: the same inputs always produce the same plan, in the same order.
- Quiet on success, precise on failure.

## The three phases

A sync runs as three phases in strict order. No phase starts before the
previous one has finished, which keeps each one easy to reason about and test.

### 1. Scan

The scanner walks the source tree depth first and yields one record per entry:
relative path, kind (file, directory, symlink), size in bytes, modification
time with nanosecond precision, and the POSIX permission bits. Paths that match
an `--exclude` glob are dropped here, before any later work is spent on them.
Symlinks are recorded as links and never followed. When `--checksum` is set the
scanner also computes a SHA-256 digest for every regular file, streaming it in
64 KiB chunks so memory use stays flat for very large files.

### 2. Plan

The planner loads the manifest kept at the destination, by default
`.harbour/manifest.json`. The manifest maps each relative path to the size,
mtime and optional SHA-256 recorded the last time that path was synced. The
planner compares the scan with the manifest and emits an ordered list of
actions:

- copy: the path is new at the source
- update: the path exists in both places and differs
- delete: the path is in the manifest but gone from the source (only with
  `--delete`)
- skip: the path is unchanged

Two files are "different" when size or mtime differ, or, with `--checksum`,
when the digests differ. Directories are created before their contents and
removed after them, so the plan is always valid to apply top to bottom.

### 3. Apply

The applier executes the plan with a pool of workers sized by `--jobs`. Each
copy writes to a temporary file in the destination directory, named
`.harbour-tmp-<random>`, flushes it, sets the permissions and mtime, and then
renames it into place. Because rename is atomic on the same volume, readers
never see a half-written file. When every action has finished, the manifest is
rewritten the same way, so it never describes work that did not happen.

## Conflict detection

A conflict is a path whose destination copy changed since the last sync: its
size or mtime no longer matches the manifest entry. Overwriting it would lose
edits made at the destination. The planner marks such paths as conflicts,
leaves them untouched, and reports each one by name. The rest of the plan is
still applied.

## Errors and exit statuses

- `0`: everything in the plan was applied and there were no conflicts.
- `1`: the command line was invalid or the source could not be read.
- `2`: the sync finished but one or more conflicts were left alone.
- `3`: one or more actions failed, for example a permission error or a full
  disk. Failed paths are printed to standard error, one per line.
- `130`: interrupted by the user. Temporary files are removed on the way out.

## Operational notes

The manifest is written with the same temporary file and rename step as any copied file, so a crash between actions
leaves the previous manifest intact and the next run repeats only the unfinished work.
