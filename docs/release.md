# Releasing wisp

wisp ships as one arm64 binary through a Homebrew tap. This page is the procedure; the decision is
[ADR 0012](decisions/0012-homebrew-release.md).

## What a release is

- A git tag `vX.Y.Z` on `main` whose version equals `WispVersion.current` (semver, from 0.1.0).
- A GitHub release for that tag with `wisp-X.Y.Z-arm64.tar.gz` (the stripped release binary and the
  LICENSE) and `wisp-X.Y.Z-arm64.tar.gz.sha256`, whose notes are the `## X.Y.Z` section of
  `CHANGELOG.md` followed by the install line.
- A formula update in `pidster/homebrew-tap` (`Formula/wisp.rb`) pointing at that tarball with its
  checksum. Users run `brew install pidster/tap/wisp`, which installs to Homebrew's prefix
  (`/opt/homebrew/bin/wisp`), already on `PATH`.

The binary is unsigned for now; Homebrew does not quarantine what it downloads, so Gatekeeper does not
intervene. A signed and notarised `.pkg` is a possible later channel.

## Step 0: the docs sweep, before running the script

Do this first, by hand or by an agent, and commit it on its own before `scripts/release` (AGENTS.md,
"Docs sweep before every release"). Each change keeps its own page right; this catches what a change
made stale elsewhere. Read each against the code as it stands:

| Page | Check |
| --- | --- |
| `README.md` | What wisp can do, the quick start commands, the MCP tool list, the doc map, developer setup, the layout table |
| `AGENTS.md`, `CLAUDE.md` | The layout table, the architecture paragraph, the model's tool list, the MCP tool names, the smoke-test commands |
| `docs/README.md` | Every page, ADR, and proposal has a row with a current description (the preflight checks presence, not accuracy) |
| `docs/wisp.md` | Every subcommand, flag, chat command, and config field the binary has; `wisp --help` and `/help` are the source |
| `docs/mcp.md` | Every MCP tool, argument, result field, and resource `ToolCatalog` declares |
| `docs/tools/README.md`, `docs/trust.md` | The model's tools, and what each can change on the Mac |
| `docs/design.md` | Components added or moved since the last release |
| `docs/backlog.md` | Shipped items marked done with the date; nothing listed as next that has shipped |
| `CHANGELOG.md` | The `## Unreleased` section names every user-visible change since the last tag (`git log vPREV..`) |

Commit it as "Bring the docs up to date for X.Y.Z", or "Docs sweep for X.Y.Z: nothing stale".

## Procedure

`scripts/release X.Y.Z` does all of it and refuses to continue at the first problem. `--dry-run` performs
every local step and prints the remote ones instead of executing them.

1. Preflight: every `docs/*.md`, decision, and proposal is linked from `docs/README.md`; clean tree on `main`, `WispVersion.current` equals `X.Y.Z`, no existing tag, `gh` is
   authenticated, `CHANGELOG.md` has a non-empty `## X.Y.Z` section, `scripts/check` passes (the full
   test run), `scripts/check coverage-gate` passes, and `scripts/check eval` passes. The release's eval only asserts the
   floors; it does not rewrite `harness/Sources/WispCore/Resources/measurements.json`, because the sets
   are small and every run re-rolls the numbers. Record deliberately with `scripts/check eval record`
   and commit the file; the binary embeds it, so a release carries the numbers that were committed.
   If the eval nonetheless dirtied the tree the release stops. The eval is the slow step: about eight
   minutes on the on-device model on this Mac (2026-09-22), longer since the risk dev set grew to 392
   commands, and much longer when the Mac is busy. **Change nothing in the checkout while a release
   runs.** The binary is built from the working tree, so before building and again before publishing
   the script checks that `HEAD` and the tree are as preflight found them, and stops if not. 0.13.0
   shipped an edit made while its evals ran; 0.13.1 is the build that matches its source.
2. Build: `swift build -c release` and `cargo build --release -p wisp-tui`, `strip` both, verify
   `wisp --version` and `wisp-tui --version` print `X.Y.Z` (the crate version in `tools/wisp-tui/Cargo.toml`
   is bumped with `WispVersion.current`) and `wisp doctor` passes on the build machine. The release is built without the `MLX` trait: MLX needs a Metal library
   bundle beside the binary at run time, which the one-file tarball and formula do not carry
   (`docs/backends.md`); MLX is a self-build option until that packaging is decided.
3. Package: tarball with `wisp` and `LICENSE`; SHA-256 file.
4. Publish: `git tag -a vX.Y.Z`, push the tag, `gh release create` with both assets and generated notes.
5. Tap: clone or update `pidster/homebrew-tap`, write `Formula/wisp.rb` from the template with the new
   URL and checksum, commit, push.
6. Verify from a clean shell: `brew update && brew install pidster/tap/wisp && wisp doctor`.

Until a macOS 27 CI runner exists this runs on a developer's Mac with Xcode 27.

## Coverage gate

`harness/coverage-baseline` records the total line coverage of the last release. `scripts/check
coverage-gate` measures the current figure and refuses a release when it is lower. When it is higher,
the gate also refuses until `scripts/check coverage-baseline` has recorded the new figure and it is
committed, so the baseline only ever moves up through a commit that says so. Lowering it is possible
by editing the file, and the commit must say why. A tenth of a point either way counts as unchanged:
timing-dependent branches (sandbox nesting, timeouts) move the measured figure by a few hundredths
between identical runs, observed on 2026-09-20 (93.05% against a 93.08% baseline).

## Release notes

`CHANGELOG.md` is written for people who run wisp, not from commit subjects: what they can now do,
what changed under them, what was broken and is fixed. Add a line under `## Unreleased` in the commit
that makes a user-visible change; the version-bump commit renames that section to the version. Anything
a user can notice as a removal or an incompatible change (a URI that moved, old data that no longer
loads) goes first, in a `Breaking:` list ahead of `Added:` and `Changed:`. The release script publishes
the whole section as it stands, so the list needs no other handling.

## Bumping the version

`WispVersion.current` in `harness/Sources/WispCore/Audit/AuditEvent.swift` is the single source. Bump
it in its own commit ("Bump version to X.Y.Z") that also renames `## Unreleased` in `CHANGELOG.md`, the
crate version in `tools/wisp-tui/Cargo.toml` and `tools/Cargo.lock`, and retrains the risk classifier the
release ships with `scripts/check classifier-default`, which writes `risk@X.Y.Z-default` into
`harness/Sources/WispCore/Resources/risk-default.json`; then run the release. The committed file is the shipped model, and the eval measures it. The tag check and
the shipped classifier's version in preflight make a mismatch impossible to ship.

## First-run support

`wisp doctor` checks what a new install needs: the on-device model is available and enabled, macOS
is 27 or later, `sandbox-exec` exists, `~/.wisp/config.json` parses, and the home directory is writable.
It is the first thing to ask for when someone reports a problem.
