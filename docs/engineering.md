# Engineering standards

wisp is held to the highest standard of coding and software-engineering practice. This page lists what that
means in practice and how it is enforced. Everything here is mechanical where it can be; judgement calls are
recorded as [decisions](decisions/).

## The gate

`scripts/check` is the single entry point used by the pre-commit hook, CI, and humans:

| Command | What it does |
| --- | --- |
| `scripts/check lint` | `swift format lint --strict` over the harness; `cargo fmt --check` and `cargo clippy -D warnings` over the tools workspace |
| `scripts/check build` | `swift build -Xswiftc -warnings-as-errors`, then the completions check: the shell completion scripts committed in `harness/Sources/WispCore/Resources/completions/` must equal what the built binary generates from its command tree (`wisp --generate-completion-script zsh\|bash\|fish`, swift-argument-parser's, with wisp's marker line added), and a change to the commands that leaves them stale fails with the command to refresh them; `cargo build` with `RUSTFLAGS=-D warnings` |
| `scripts/check completions` | Rewrites those three scripts (`_wisp`, `wisp.bash`, `wisp.fish`) from a fresh debug build; commit them with the change to the commands. The next build embeds them (the `EmbedSystemPrompt` plugin), and `ShellCompletionsTests` checks the embedded text is the files. Not part of `all` |
| `scripts/check test` | `swift test`; then the `CommandRunner` suites again inside an outer Seatbelt sandbox to exercise the nested-sandbox fallback; `cargo test --workspace` |
| `scripts/check format` | Auto-fix formatting with swift-format and rustfmt |
| `scripts/check eval [context\|compare]` | Runs the on-device model evaluation (the separate `harness/Evals` package, so the gate never builds it; `WISP_MODEL_TESTS=1` is set for you): every suite but the context eval, or with `context` only the context eval, which is a measurement for design decisions (ADR 0045) and takes hours, or with `compare` the suites that decide delegation on each model `WISP_EVAL_MODELS` names, one model at a time ([measurements.md](measurements.md#comparing-models)); reports classifier accuracy and every miss, asserts no dangerous command rated safe (not in the gate), and ends with a summary table, model by suite |
| `scripts/check mlx-live <model directory>` | The MLX live test (`MLXLiveTests`) on real weights: builds with `--traits MLX` in `harness/.build/mlx`, so the gate's build is untouched, copies MLX's Metal library beside each test bundle's binary as `mlx.metallib`, and runs it with `WISP_MLX_TESTS=1` (needs the Metal toolchain and a model directory; not in the gate; ADR 0047) |
| `scripts/check coverage` | `swift test --enable-code-coverage` plus an `llvm-cov` per-file line report for the harness sources (not in the gate) |
| `scripts/check hygiene` | Staged-file checks: conflict markers, trailing whitespace, files over 1 MiB (one named exception, ADR 0042), commit author uses a GitHub noreply address; the lockfiles keep their MLX pins (below) |
| `scripts/check palette` | `Style.Palette` (Swift) and `tools/wisp-tui/src/palette.rs` define the colours twice; fails, naming the colour and both values, when a Swift colour is missing from Rust or differs. Names map by upper-casing at word breaks (`tokensIn` is `TOKENS_IN`); aliases (`tokensOut = glow`) are resolved; Rust may have colours of its own (`DEEP`, `SENT`, `WHITE`) |
| `scripts/check all` | Everything above, in that order |
| `scripts/check install-hooks` | Points `core.hooksPath` at `.githooks/` |

Run `scripts/check install-hooks` once after cloning. The pre-commit hook runs `hygiene`, `palette`, `lint`, `build`,
and `test`; on a warm build cache this takes a few seconds. Bypass with `git commit --no-verify` only for
work-in-progress commits on a branch that will be squashed.

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
--scratch-path harness/.build/mlx`) so the new lockfile carries the pins. Neither check uses the network.

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
