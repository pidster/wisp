# Engineering standards

wisp is held to the highest standard of coding and software-engineering practice. This page lists what that
means in practice and how it is enforced. Everything here is mechanical where it can be; judgement calls are
recorded as [decisions](https://github.com/pidster/wisp/tree/main/docs/decisions).

## The gate

`scripts/check` is the single entry point used by the pre-commit hook, CI, and humans:

| Command | What it does |
| --- | --- |
| `scripts/check lint` | `swift format lint --strict` over the harness and the evaluations package; `cargo fmt --check` and `cargo clippy -D warnings` over the tools workspace |
| `scripts/check build` | `swift build --build-tests -Xswiftc -warnings-as-errors`, so a warning in `Tests/` fails as one in `Sources/` does, then the completions check: the shell completion scripts committed in `harness/Sources/WispCore/Resources/completions/` must equal what the built binary generates from its command tree (`wisp --generate-completion-script zsh\|bash\|fish`, swift-argument-parser's, with wisp's marker line added), and a change to the commands that leaves them stale fails with the command to refresh them; `cargo build` with `RUSTFLAGS=-D warnings` |
| `scripts/check evals-build` | Compiles the model evaluations (`harness/Evals`, its own package) with their tests, warnings as errors, without running them, so a change to an API they call fails in the gate rather than at release time. About 22 s cold, 2 to 4 s after a change to the harness (2026-10-09) |
| `scripts/check test` | `swift test` with the build's flags (among the tests, `EvalSetsTests` checks the eval case sets of `harness/Evals` without a model: well formed, ids unique, counts as declared, every `edit_file` case solved by the calls its prompt asks for), so it reuses the build's products (a flag that differed recompiled everything, about 15 to 20 s a run); then the `CommandRunner` suites again inside an outer Seatbelt sandbox to exercise the nested-sandbox fallback, which fails if its filter ran no tests; `cargo test --workspace` |
| `scripts/check format` | Auto-fix formatting with swift-format and rustfmt |
| `scripts/check eval [context\|compare\|checkpoint] [record]` | Runs the model evaluation (the separate `harness/Evals` package; `WISP_MODEL_TESTS=1` is set for you): every suite but the context eval, or with `context` only the context eval, which is a measurement for design decisions (ADR 0045) and takes hours, or with `compare` the suites that decide delegation on each model `WISP_EVAL_MODELS` names, one model at a time ([measurements.md](measurements.md#comparing-models)), or with `checkpoint` context checkpoint 2, the parts `WISP_CHECKPOINT` names (all by default), ending with its own table and a TSV of its rows. `record` also writes each task's measurement into `harness/Sources/WispCore/Resources/measurements.json`, to commit. `edit_file`, `system_info`, and `draft_change` run a fixed seeded subset of their case sets, what the release runs; `WISP_EVAL_FULL=1` runs the whole sets, about 128 minutes of those suites one after another against 52 (they run in parallel: the whole run took 41 minutes on 2026-10-12) ([measurements.md](measurements.md#the-case-sets)). It reports classifier accuracy and every miss, asserts the floors on the configured model, and ends with a summary table, model by suite, saved with the whole output under `harness/Evals/.build/evals`. It exits non-zero when `swift test` failed (a floor missed, a strict case errored, the build failed), after the summary; `compare` goes on past a model that fails and names the failed models after its summary instead. Every line reaches the log and the terminal as it is printed: the test process runs with `NSUnbufferedIO=YES`, since its `print` goes through C stdio, which buffers a pipe in blocks, so until 0.22.0 a run's results arrived only when it ended (six hours for `granite4.2:8b` on 2026-10-09). Needs a model; not in the gate |
| `scripts/check eval-stream-probe` | Proves the eval's output streams and keeps `swift test`'s status, with no model: a small Swift program stands in for `swift` on `PATH`, prints an eval line through `print`, sleeps two seconds, prints another, and exits with a status of its choosing; it runs once passing and once exiting 3. Each line's arrival is stamped in seconds from the start: the first must arrive at 0 or 1, before the second is printed, the second at 2 or later, and the step's status must be the program's own. Without `NSUnbufferedIO` both lines arrive together at 2 and the probe fails. About five seconds; not in the gate, since it compiles a program with `swiftc` |
| `scripts/check mlx-build` | Builds the harness and its tests with the MLX trait, warnings as errors, in `harness/.build/mlx`: the code only that trait compiles, which the release ships. About 80 s cold, 1 s warm (2026-10-09). Needs the Metal toolchain; the release preflight runs it, the gate does not |
| `scripts/check mlx-live <model directory>` | The MLX live test (`MLXLiveTests`) on real weights: builds with `--traits MLX` in `harness/.build/mlx`, so the gate's build is untouched, copies MLX's Metal library beside each test bundle's binary as `mlx.metallib`, and runs it with `WISP_MLX_TESTS=1` (needs the Metal toolchain and a model directory; not in the gate; ADR 0047) |
| `scripts/check launcher` | Part of the gate: runs a copy of `scripts/wisp-mcp` with a stand-in binary and checks the name it starts the server under (`wisp mcp`, `wisp mcp (claude-code)` from `WISP_MCP_CLIENT`, a name stripped to safe characters; [ADR 0061](decisions/0061-process-names-set-at-spawn.md)); skipped, with a note, where `ps` cannot run, as inside wisp's own sandbox when the hook runs through `run_command` |
| `scripts/check mcp-build` | The release build `.mcp.json` runs as the `wisp` MCP server (`scripts/wisp-mcp` execs `harness/.build/release/wisp`): with the MLX trait, as Homebrew ships it, when the Metal toolchain is there, otherwise without it. Either way the lockfiles are left as they were (a bare `swift build -c release` drops their MLX pins). Rerun it after code changes; the server runs the last build |
| `scripts/check coverage` | `swift test --enable-code-coverage`, run once, plus an `llvm-cov` per-file line report for the harness sources (not in the gate). When the tests fail it prints the failures and no report |
| `scripts/check coverage-gate` | Measures the total line coverage and fails when it is more than 0.1 below `harness/coverage-baseline`, or more than 0.1 above it (record the rise first); fails, with no figure, when the tests fail or the report has no numeric total. The release preflight runs it ([release.md](release.md#coverage-gate)) |
| `scripts/check coverage-baseline` | Writes the measured total into `harness/coverage-baseline`, to commit; refuses, leaving the file alone, when the tests fail or the total is not a number |
| `scripts/check classifier-default` | Copies `training/risk/train.tsv` into `Resources/risk-examples.tsv` and trains the risk classifier the version ships into `Resources/risk-default.json`; run after the version bump ([release.md](release.md#bumping-the-version)) |
| `scripts/check completions` | Rewrites the three completion scripts (`_wisp`, `wisp.bash`, `wisp.fish`) from a fresh debug build; commit them with the change to the commands. The next build embeds them (the `EmbedSystemPrompt` plugin), and `ShellCompletionsTests` checks the embedded text is the files. Not part of `all` |
| `scripts/check hygiene` | Checks on what is staged, read from the index (`git show :path`), not the working copy: conflict markers (`<<<<<<<` and `>>>>>>>`; `=======` alone is a Markdown setext underline), trailing whitespace, files over 1 MiB (one named exception, ADR 0042), a path git has to quote (a newline, tab, quote, or backslash in it); commit author uses a GitHub noreply address; the lockfiles keep their MLX pins (below). Paths with spaces are read whole |
| `scripts/check palette` | `Style.Palette` (Swift) and `tools/wisp-tui/src/palette.rs` define the colours twice; fails, naming the colour and both values, when a Swift colour is missing from Rust or differs. Names map by upper-casing at word breaks (`tokensIn` is `TOKENS_IN`); aliases (`tokensOut = glow`) are resolved; Rust may have colours of its own (`DEEP`, `SENT`, `WHITE`) |
| `scripts/check docs-links` | Part of the gate: `scripts/docs-links` checks the documentation site's sources without mdBook ([ADR 0065](decisions/0065-documentation-site.md)): every page under `docs/` is in `docs/SUMMARY.md` (bar a list of deliberate exclusions in the script, empty today), the summary names each page once and only pages that exist, and every link in the book's pages, and in what they include, is absolute or resolves inside `docs/` to a page in the book or a file the site copies; a link outside `docs/`, to a directory, or from the root is refused with the GitHub URL to use. About 0.15 s (2026-10-14) |
| `scripts/check docs-site` | `docs-links`, then the site itself: `mdbook build` into `book/` (git ignores it), failing when mdBook is missing (with how to install 0.5.4), when the build fails, or when it warns; a version other than 0.5.4 is noted. Not in the gate; `.github/workflows/docs.yml` runs it on Linux before deploying |
| `scripts/check all` | The gate, and what `scripts/check` with no argument runs: `hygiene`, `palette`, `launcher`, `docs-links`, `lint`, `build`, `evals-build`, `test`, in that order. Not `format`, `eval`, `mlx-build`, `mlx-live`, `mcp-build`, the coverage commands, `classifier-default`, `completions`, or `docs-site` |
| `scripts/check install-hooks` | Points `core.hooksPath` at `.githooks/` |

Run `scripts/check install-hooks` once after cloning. The pre-commit hook runs `scripts/check all`; on a warm build
cache with a small change the whole gate takes 40 to 50 s on this Mac, most of it the tests (2026-10-09). Bypass
with `git commit --no-verify` only for work-in-progress commits on a branch that will be squashed.

`scripts/check format` fixes most lint findings automatically. Rust checks are skipped until the workspace has
its first crate. When the gate itself runs inside a Seatbelt sandbox (wisp running its own hook through
`run_command`), the script detects it, passes `--disable-sandbox` to SwiftPM, and skips the nested-sandbox
test step.

### The lockfiles' MLX pins

The release builds with `--traits MLX` (ADR 0047), so `harness/Package.resolved` must pin the packages only that
trait resolves: `mlx-swift`, `mlx-swift-lm`, `swift-numerics`, and `swift-syntax`. Any build without the trait,
the gate's own included, rewrites the lockfile without them; on 2026-10-05 a commit carried that loss. The gate
guards both lockfiles, `harness/Package.resolved` and `harness/Evals/Package.resolved`, in two ways:

- **Hygiene fails** when a lockfile lacks one of the pins, naming them and the fix. In a commit (the hook sets
  `WISP_CHECK_COMMIT=1`) it checks the staged version; run by hand, the working copy.
- **Every subcommand puts the lockfiles back on exit** when a build during the run left one without a pin: the
  script copies them when it starts and restores the copy byte for byte, so `scripts/check` leaves the working
  tree's lockfiles as it found them. A lockfile that changed in another way is left alone.

The fix for a failure is the committed lockfile (`git checkout HEAD -- harness/Package.resolved`); when the
dependencies really changed, resolve with the trait (`swift build --package-path harness --traits MLX
--scratch-path harness/.build/mlx`, which `scripts/check mlx-build` runs) so the new lockfile carries the pins.
Neither check uses the network. The MCP server's release build has the same trap; `scripts/check mcp-build` avoids
it.

## Definition of done

A change is done only when all of the following are true. "Works on my machine" is the start, not the end.

1. **Tested.** New or changed behaviour has tests that run without the on-device model, and the whole gate
   passes (`scripts/check`). Model-dependent paths are exercised by running the binary, and the command used
   is in the commit message or PR.
2. **Documented in code.** Every declaration that a reader could reasonably need to understand has a `///`
   comment: public API (enforced by lint), and internal or private members whose purpose is not obvious from
   the name. Say what and why, not how.
3. **Documented for users.** `docs/` reflects the change: a new or changed tool updates its page under
   `docs/tools/` and the index; a CLI flag or subcommand updates `docs/wisp.md`; an MCP change updates
   `docs/mcp.md`; an architectural change updates `docs/design.md`; a non-obvious or hard-to-reverse choice
   gets an ADR. If nothing in `docs/` needs to change, say so in the commit message.
4. **Recorded.** `AGENTS.md` (and `CLAUDE.md` for Claude Code-only points) is updated when the change alters how an agent should work in this repository
   (new command, new rule, moved code).

Documentation is part of the development cycle, not a follow-up task. The pre-commit hook reminds you when a
commit touches `harness/Sources` or `tools/` without touching `docs/`; it is a reminder, not a block,
because refactors legitimately need none.

## Rules

- **Formatting** is defined by `harness/.swift-format` (4-space indent, 120 columns, ordered imports) and
  `tools/rustfmt.toml` (100 columns). Rust crates inherit the workspace lints: `unsafe_code` forbidden,
  clippy `pedantic`, `unwrap_used` and `expect_used` warned, and warnings are errors in the gate.
- **Documentation**: every `public` declaration has a `///` comment; `Throws:` and `Parameters:` sections are
  validated by the linter.
- **Safety**: no force unwrap, force try, or implicitly unwrapped optionals. No `fatalError` in library code.
- **Concurrency**: Swift 6 strict concurrency stays on. Never silence a diagnostic with `@unchecked Sendable`
  or `nonisolated(unsafe)`; restructure instead.
- **Errors** are typed enums with `CustomStringConvertible` descriptions.
- **Tests** accompany every behaviour change and never require the on-device model. Keep logic in pure
  functions and test those; the live model is exercised by running the binary. Tests use swift-testing
  (`@Suite`, `@Test`, `#expect`). Check `scripts/check coverage` when adding a module; `Agent` and the tool
  `call` wrappers are the accepted gaps because they need the model.
- **Layering**: logic in `WispCore`; the executable target holds only argument parsing and I/O. Rust tool
  binaries know nothing about agents; the harness owns the model-facing schema.
- **Commits** are small and single-purpose. The subject says what, the body says why.
- **Decisions** that are non-obvious or hard to reverse get an ADR in `docs/decisions/`.

## CI

`.github/workflows/ci.yml` runs `scripts/check lint`, `build`, and `test`, but is currently
`workflow_dispatch` only: it needs a macOS 27 / Xcode 27 runner that has not been provisioned yet. Until
then the pre-commit hook is the only automated gate, so do not bypass it. Restore the `push` and
`pull_request` triggers when a runner exists.

`.github/workflows/docs.yml` is the one workflow that runs on its own: on a push to `main` that touches the docs,
it installs mdBook 0.5.4 on `ubuntu-latest` from its release tarball, checked against the SHA-256 written in the
workflow, runs `scripts/check docs-site`, and deploys the site to GitHub Pages
([ADR 0065](decisions/0065-documentation-site.md)). It needs no macOS.
