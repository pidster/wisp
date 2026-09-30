# harbour sync: flag reference

Usage: `harbour sync [options] <source> <destination>`

Every flag below is optional and has a safe default. Flags may appear before or after the two
positional arguments.

## --delete
Remove destination paths that are recorded in the manifest but no longer exist
at the source. Paths that harbour never synced are never removed, even with this
flag, because they are not in the manifest.

- Default: off.
- Example: `harbour sync --delete ~/Photos /Volumes/Backup/Photos`

## --exclude <glob>
Skip source paths matching the glob. Repeat the flag for several patterns. Globs
are matched against the path relative to the source root; `*` does not cross a
slash, and `**` does.

- Default: none.
- Example: `harbour sync --exclude '*.tmp' --exclude 'node_modules/**' src dst`

## --checksum
Compare files by SHA-256 digest instead of size and mtime. This finds files that
changed without their mtime changing, at the cost of reading every source file.

- Default: off, the size and mtime comparison is used.
- Example: `harbour sync --checksum ~/Documents /mnt/nas/Documents`

## --jobs <n>
Number of files copied at the same time. Accepts 1 to 64.

- Default: the number of performance cores, capped at 8.
- Example: `harbour sync --jobs 2 ~/Movies /Volumes/Spinning/Movies`

## --bandwidth <rate>
Limit the total copy rate across all workers. The rate is a number with an
optional suffix `k`, `m` or `g` for KiB, MiB or GiB per second.

- Default: unlimited.
- Example: `harbour sync --bandwidth 5m ~/Archive user@host:/srv/archive`

## --verbose
Print one line per action as it is applied, in the form `copy path/to/file`,
`update path/to/file` or `delete path/to/file`. Repeat as `-vv` to add sizes and
timings.

- Default: off, only the summary line is printed.
- Example: `harbour sync --verbose src dst`

## --quiet
Print nothing on success. Errors and conflicts are still reported on standard
error, and the exit status is unchanged.

- Default: off.
- Example: `harbour sync --quiet src dst && echo synced`

## --manifest <path>
Read and write the manifest at this path instead of `.harbour/manifest.json`
inside the destination. The parent directory must exist.

- Default: `<destination>/.harbour/manifest.json`.
- Example: `harbour sync --manifest ~/.cache/harbour/photos.json src dst`

## Flag interactions

- `--verbose` and `--quiet` conflict; giving both is an error and exits with 1.
- `--checksum` with a high `--jobs` value can make the scan phase disk bound;
  lower `--jobs` does not speed the scan, because the scan is single threaded.
- `--bandwidth` is shared between workers, so raising `--jobs` does not raise
  the total rate above the limit.
- `--delete` combined with a fresh `--manifest` path removes nothing, because
  an empty manifest records no synced files.
- `--exclude` applies to the source only. An excluded path already present at
  the destination is left alone, and it is not deleted by `--delete`.
- Every flag can also be set in `~/.config/harbour/defaults`, one `name=value` per line; a flag on the command line always
  overrides the file, and `--exclude` patterns from both places are added together.
- `--jobs 1` gives the same result as any other value, only slower and easier to follow in logs, because the plan order is fixed and workers never share a path.
- Precedence when a value is given twice: the last `--manifest`, `--jobs` or `--bandwidth` on the command line wins, while `--exclude` accumulates every occurrence in order given.
