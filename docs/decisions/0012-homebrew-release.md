# ADR 0012: Release through a Homebrew tap, unsigned, semver from 0.1.0

Date: 2026-09-17. Status: accepted. Amended by [ADR 0047](0047-mlx-in-the-release.md): the release also carries
MLX's Metal library, `mlx.metallib`, beside the binary.

## Context

wisp is a single dependency-free arm64 binary (SwiftPM links its packages statically; the Swift
runtime and FoundationModels are part of macOS 27). Candidate channels were a Homebrew tap, a signed and
notarised `.pkg` into `/usr/local/bin`, and a bare tarball. A `.pkg` requires Developer ID signing and
notarisation to pass Gatekeeper; a tap does not, because Homebrew does not apply the quarantine attribute.

## Decision

- Homebrew tap `pidster/homebrew-tap` is the only install channel for now. The formula installs a prebuilt
  tarball from the GitHub release, so users need neither Xcode nor a Swift toolchain.
- Versions are semver starting at 0.1.0, tagged `vX.Y.Z`, with `WispVersion.current` as the single
  source and a preflight check that the tag matches.
- The binary is unsigned. Signing and a `.pkg` are deferred until there is a reason to distribute outside
  Homebrew.
- Releases are produced by `scripts/release` on a developer machine until CI has a macOS 27 runner.
- The project license is MIT (`LICENSE`), as the Cargo workspace already declared.

## Consequences

- Users on Homebrew get upgrades and uninstall for free; users without Homebrew must build from source.
- The formula requires macOS 27 (`depends_on macos: :golden_gate`, Homebrew's symbol for it) and arm64; the
  binary's deployment target is a second guard and `wisp doctor` explains a failure.
- An unsigned binary downloaded any other way (browser, curl) will be quarantined and blocked; the
  release page must say to use Homebrew.
