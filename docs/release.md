# Releasing wisp

wisp ships as an arm64 binary, with MLX's Metal library beside it, through a Homebrew tap. This page is the procedure; the decision is
[ADR 0012](decisions/0012-homebrew-release.md).

## What a release is

- A git tag `vX.Y.Z` on `main` whose version equals `WispVersion.current` (semver, from 0.1.0).
- A GitHub release for that tag with `wisp-X.Y.Z-arm64.tar.gz` (the stripped `wisp` and `wisp-tui`,
  `mlx.metallib`, `Wisp Notifier.app`, and the LICENSE) and `wisp-X.Y.Z-arm64.tar.gz.sha256`, whose notes are the `## X.Y.Z` section of
  `CHANGELOG.md` followed by the install line; and, for a signed release, `Wisp-X.Y.Z.dmg` with
  `Wisp-X.Y.Z.dmg.sha256`, a disk image holding `Wisp.app`, a link to `/Applications`, and a read-me
  ([ADR 0072](decisions/0072-a-dmg-and-a-declared-layout.md)). `wisp update` finds the image and its checksum by
  these exact names on the latest release, and checks the app's `CFBundleShortVersionString` against the tag
  ([ADR 0074](decisions/0074-wisp-update.md)); renaming either breaks updates.
- A formula update in `pidster/homebrew-tap` (`Formula/wisp.rb`) pointing at that tarball with its
  checksum. Users run `brew install pidster/tap/wisp`, which installs `wisp`, `mlx.metallib`, and
  `Wisp Notifier.app` in the Cellar's `libexec` and links `/opt/homebrew/bin/wisp` to it, already on `PATH`; MLX finds its library
  beside the binary's real path ([ADR 0047](decisions/0047-mlx-in-the-release.md)). The formula also installs
  the shell completions for bash, zsh, and fish into Homebrew's completion directories, so a Homebrew user has
  them with no further step.

The release signs the binaries and the helper bundle with a Developer ID and notarises them, so a tarball downloaded
directly runs too; `--unsigned` leaves them with the linker's ad hoc signature, which Homebrew installs without
complaint, since it does not quarantine what it downloads (below, "Signing";
[ADR 0069](decisions/0069-signed-and-notarised-releases.md), [ADR 0071](decisions/0071-signed-releases-by-default.md)).

## Step 0: the docs sweep, before running the script

Do this first, by hand or by an agent, and commit it on its own before `scripts/release` (AGENTS.md,
"Docs sweep before every release"). Each change keeps its own page right; this catches what a change
made stale elsewhere. Read each against the code as it stands:

| Page | Check |
| --- | --- |
| `README.md` | What wisp can do, the quick start commands, the MCP tool list, the doc map, developer setup, the layout table |
| `AGENTS.md`, `CLAUDE.md` | The layout table, the architecture paragraph, the model's tool list, the MCP tool names, the smoke-test commands |
| `docs/README.md` | Every page, ADR, and proposal has a row with a current description (the preflight checks presence, not accuracy) |
| `docs/introduction.md`, `docs/guide/*.md` | The site's landing page and guides restate the reference: the commands, flags, defaults, messages, and `wisp doctor` output they quote, and the tool lists, against the binary's `--help` and the pages they link to |
| `docs/SUMMARY.md` and the site | Every new page in its part, the ADRs in number order; `scripts/check docs-site` builds the site with no warning ([ADR 0065](decisions/0065-documentation-site.md)) |
| `site/home/index.html` | The homepage restates the docs: the install line, the requirements, the gate's steps, the MCP tools, the runtimes, and `wisp-tui`'s text in its terminal picture, against the pages and source they come from |
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

1. Preflight: the version is exactly three numbers, `X.Y.Z`; every `docs/*.md`, decision, and proposal is linked from `docs/README.md` (but `docs/SUMMARY.md`, the site's table of contents, which `scripts/check docs-links` checks instead); clean tree on `main`, the Metal toolchain present (a one-line kernel compiles with `xcrun metal`; `xcrun -f metal` finds a stub even when the toolchain, a separate download that an Xcode update can drop, is missing), `WispVersion.current` equals `X.Y.Z`, no existing tag here or on `origin`
   (`git ls-remote`), `origin/main` is `HEAD` (pushed, and nothing on origin left out), `gh` is
   authenticated, `CHANGELOG.md` has a non-empty `## X.Y.Z` section, `scripts/check` passes (the full
   test run, and the evaluations compiled), `scripts/check mlx-build` passes (the harness and its tests with the MLX
   trait, warnings as errors, before the release build is the first to compile that code), `scripts/check coverage-gate` passes, and `scripts/check eval` passes, judged by `swift test`'s own exit status (until 0.21.1 it was `grep`'s, so a missed floor passed): every suite but the context eval, which is a measurement for design decisions
   (ADR 0045) and runs on purpose with `scripts/check eval context`. `--skip-eval` leaves the eval out, for a release whose eval already
   passed on the same code (a dry run just before, with only docs changed since); 0.15.0 was the first. The release's eval only asserts the
   floors; it does not rewrite `harness/Sources/WispCore/Resources/measurements.json`, because it runs
   only the subsets and every run re-rolls the numbers. Record deliberately with `scripts/check eval record`
   and commit the file; the binary embeds it, so a release carries the numbers that were committed.
   If the eval nonetheless dirtied the tree the release stops. The eval is the slow step: since 0.23.0 it
   runs a fixed subset of each large case set, about 52 minutes for `edit_file`, `system_info`, and
   `draft_change` at the configured model's 2026-10-12 times ([measurements.md](measurements.md), "Run time, and
   the release's subsets"), plus the other suites, and much longer when the Mac is busy. **Change nothing in the checkout while a release
   runs.** The binary is built from the working tree, so before building and again before publishing
   the script checks that `HEAD` and the tree are as preflight found them, and stops if not. 0.13.0
   shipped an edit made while its evals ran; 0.13.1 is the build that matches its source.
2. Build: `swift build -c release --traits MLX` and `cargo build --release -p wisp-tui`, each run with
   `WISP_RELEASE=1` (only the release script sets it; without it a build prints `X.Y.Z-dev+<commit>`); copy the build's
   `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` into the stage as `mlx.metallib`, `strip`
   both binaries, verify `wisp --version` and `wisp-tui --version` print `X.Y.Z` (the crate version in
   `tools/wisp-tui/Cargo.toml` is bumped with `WispVersion.current`) and `wisp doctor` passes on the build
   machine, with its `MLX` finding loading the staged `mlx.metallib`, away from the build's bundle, and that the
   staged `wisp completions zsh|bash|fish` prints the committed scripts in
   `harness/Sources/WispCore/Resources/completions/`, which the formula installs. Unless `--unsigned` is given, both
   binaries are signed after `strip` and before those checks, and then notarised; the release stops unless Apple
   accepts them (`--dry-run` signs and prints the submission instead). The release build's `WispNotifier` is
   stripped and wrapped by `scripts/notifier-app` in `Wisp Notifier.app`, with its icon built from
   `harness/Notifier/AppIcon-1024.png`, its version `X.Y.Z`, and signed with the same identity or ad hoc
   ([ADR 0070](decisions/0070-a-notification-helper.md)); the staged `wisp doctor`'s `notifier` finding must name the
   staged bundle, and a signed release notarises the bundle with the binaries. A signed release then assembles
   `Wisp.app` with `scripts/wisp-app` from the same staged parts (`wisp` and `wisp-tui` in `Contents/MacOS`, the
   helper in `Contents/Helpers`, the library in `Contents/Resources/mlx-swift_Cmlx.bundle`, the `Info.plist`
   declaring each), signs it inside out, and checks that its `wisp doctor`'s `package` finding has every declared
   part and that `wisp`, started through a link outside the app, loads the app's library; the app goes in the same
   notarisation as the binaries and is stapled, then `scripts/wisp-dmg` packs it into the DMG, which is signed,
   notarised, stapled, and checked with `spctl` (`--dry-run` builds both and prints the submissions). MLX
   adds about 18 MB to the stripped binary and 3.8 MB of library (about 6 MB to the download; ADR 0047).
   A dry run, often made before the bump is pushed, reports the two remote checks and goes on.
3. Package: tarball with `wisp`, `wisp-tui`, `mlx.metallib`, and `LICENSE`; SHA-256 file; and the formula,
   `wisp.rb`, written from the template with the new URL and checksum before anything is published.
4. Publish: `git tag -a vX.Y.Z`, push the tag, `gh release create` with the assets (the tarball and, signed, the DMG,
   each with its checksum) and generated notes.
   A release that fails from here cannot simply be rerun, since preflight refuses an existing tag, so the
   script prints, on its way out, the exact commands for the steps still to do (the tag push, the release
   create or an upload with `--clobber` if it exists, the tap push), with the artifacts and the formula left in
   `harness/.build/release-artifacts`.
5. Tap: clone `pidster/homebrew-tap`, copy in `Formula/wisp.rb`, commit, push. The formula has no `version`
   line: Homebrew scans the version from the URL's `releases/download/vX.Y.Z/`, and `brew audit` reports a
   `version` equal to the scanned one as redundant (`resource_auditor.rb`, `audit_version`, read on
   2026-10-09). The formula puts `wisp`, `mlx.metallib`, and `Wisp Notifier.app` in `libexec` with a link
   in `bin`, writes `wisp-layout.json` beside them, saying where each part is
   ([ADR 0072](decisions/0072-a-dmg-and-a-declared-layout.md)), and runs `generate_completions_from_executable(bin/"wisp", "completions")`, which writes the output of
   `wisp completions bash`, `zsh`, and `fish` (the scripts embedded in the binary) to `bash_completion/"wisp"`,
   `zsh_completion/"_wisp"`, and `fish_completion/"wisp.fish"`. Its test checks both versions, that the library,
   the layout, the helper's executable, and the three scripts are installed, and that `wisp completions zsh` prints a zsh script.
6. Verify from a clean shell: `brew update && brew install pidster/tap/wisp && wisp doctor`. Its `signature` line names
   the Developer ID for a signed release, and `signed ad hoc` for an unsigned one.
7. Docs site: check that the site at https://wisp.pidster.com carries the release. The `Docs` workflow
   (`.github/workflows/docs.yml`, [ADR 0065](decisions/0065-documentation-site.md)) deploys it on every push to `main`
   that touches `docs/`, `site/`, `book.toml`, or `CHANGELOG.md`, so the version bump's push, which renames the
   changelog's section, starts it. `gh run list --workflow docs.yml --limit 3` shows that run; wait for it to succeed,
   then open https://wisp.pidster.com/docs/changelog.html and see the `## X.Y.Z` section, and the homepage's "Latest
   release" line, which the build fills from that section and the bump commit's date. If no run started, or it
   failed, start one with `gh workflow run docs.yml` and check again. The script does not do this step.

Until a macOS 27 CI runner exists this runs on a developer's Mac with Xcode 27.

## Signing

On by default since 0.30.1: a release signs and notarises unless it is run with `--unsigned`
([ADR 0069](decisions/0069-signed-and-notarised-releases.md), [ADR 0071](decisions/0071-signed-releases-by-default.md)).
The certificate's name, for an individual developer account the person's legal name, is written into every signed
binary, where `codesign -dv` shows it to anyone.

Once, on the Mac that releases:

1. An Apple Developer Program membership. As its Account Holder, in Xcode › Settings › Accounts › the team › Manage
   Certificates, add a **Developer ID Application** certificate; `security find-identity -v -p codesigning` then lists
   it. Export it with its key as a `.p12` from Keychain Access, kept somewhere safe: a Mac without the key cannot sign
   as the team.
2. A team API key in App Store Connect (Users and Access › Integrations › Team Keys, the Developer role): note its Key
   ID and the Issuer ID above the list, and download `AuthKey_<KeyID>.p8`, which Apple offers once. Then, in a
   terminal, `xcrun notarytool store-credentials wisp-notary --key <path>/AuthKey_<KeyID>.p8 --key-id <KeyID>
   --issuer <IssuerID>`, which checks them with Apple and keeps them in the keychain. `xcrun notarytool history
   --keychain-profile wisp-notary` signs in with them and changes nothing.

Each release then signs with the identity `WISP_SIGN_IDENTITY` names, `Developer ID Application` when it is unset or
empty (the full name, or any part that matches one identity; `WISP_NOTARY_PROFILE` names another profile than
`wisp-notary`). Preflight refuses an identity that is not a Developer ID Application one or matches none or several,
and a profile that cannot sign in; on a Mac without the certificate, `scripts/release X.Y.Z --unsigned` releases
unsigned.

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
is 27 or later, `sandbox-exec` exists, MLX's Metal library loads, `~/.wisp/config.json` parses, and the home
directory is writable. It also says who signed the running `wisp`.
It is the first thing to ask for when someone reports a problem.
