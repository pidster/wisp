# Changelog

All notable changes to harbour. Versions follow semantic versioning.

## 2.3.0 (unreleased)

Nothing yet.

## 2.2.0

Added:

- `--bandwidth RATE` limits the bytes per second across all workers, with
  suffixes K, M, and G. Requested in issue 198; the limit is shared by every
  worker rather than applied to each, so raising `--jobs` no longer multiplies
  the load on a slow link.
- A summary line at the end of every run that is not `--quiet`: counts of
  copied, updated, deleted, and skipped paths, and of conflicts.

Changed:

- The default for `--jobs` is the active processor count, capped at 8. It was
  4 on every machine, which left large servers idle.
- Conflicts are reported on standard error, one per line, before the summary.

Fixed:

- An interrupted copy no longer leaves a partial file at its final path: each
  copy is written to a temporary name and renamed into place when complete.
- Symbolic links whose targets are outside the source tree are copied as links
  instead of failing the scan.

## 2.1.1

Fixed:

- `--exclude` patterns ending in a slash matched files as well as directories.
- The manifest was rewritten even when nothing changed, which touched its
  modification time and woke up tools that watch it. It is now written only
  when the plan had changes that were applied.

## 2.1.0

Added:

- `--checksum` compares SHA-256 digests instead of size and modification time.
  Slower on the first run; the digests are kept in the manifest afterwards.
- `--manifest PATH` keeps the manifest outside the destination, for read-only
  or shared destinations.

Changed:

- Exit status 2 now means the run finished but some paths were in conflict;
  status 3 means some copies failed. Both used to be 1, which made it hard for
  scripts to tell a usage error from a partial run.

## 2.0.0

Changed:

- harbour is now a single binary written in Swift; the Python version is
  retired. Command names and flags are the same, except `--threads`, renamed
  `--jobs`.
- The manifest moved from a dotfile in the destination root to
  `.harbour/manifest.json`, so related state can live beside it. The first run of
  2.0.0 migrates an old manifest in place.

Removed:

- `--follow-links`. Following links made a sync's result depend on what the
  links pointed at when it ran; links are now always copied as links.

## 1.4.2

Fixed:

- Copies to network volumes that do not support extended attributes no longer
  fail; the attributes are skipped with a warning.

## 1.4.0

Added:

- `--verbose` prints each change as it is applied.
- `--quiet` prints nothing but errors.
