# ADR 0047: MLX in the release

Date: 2026-10-03. Status: accepted. Amends [ADR 0012](0012-homebrew-release.md) (the release is no longer
one binary: it carries MLX's Metal library beside it) and [ADR 0019](0019-model-backends.md) (MLX was a
self-build option only).

## Context

`mlx:` models run in wisp's process through MLX Swift, behind the `MLX` package trait so the ordinary
build and the sandboxed pre-commit hook never need the Metal toolchain. The release was built without the
trait, because MLX compiles its kernels into a Metal library at build time and loads it at run time, and
the one-file release did not carry it.

MLX's search, `load_default_library` in `mlx/backend/metal/device.cpp` (mlx-swift 0.31.6), takes the first
of: `mlx.metallib` in the directory of the image holding MLX's own code (`dladdr` on one of its functions,
`dli_fname`); `Resources/mlx.metallib` there; `default.metallib` in a `mlx-swift_Cmlx.bundle` beside the
main bundle or in a loaded bundle's resources (what `swift build` leaves); `Resources/default.metallib` in
the image's directory. SwiftPM links MLX statically, so the image is `wisp` itself, or the test bundle's
binary under `swift test`.

A probe on 2026-10-03 on this Mac (M4 Max, macOS 27, Xcode 27.0 27A266a, mlx-swift 0.31.6):

| Question | Finding |
| --- | --- |
| What the build needs | The Metal toolchain, a separate Xcode component (`xcodebuild -downloadComponent MetalToolchain`; 868 MB installed here, already present). Nothing else |
| Build time | A release build with the trait in a fresh scratch path: about 10 minutes, package resolution included (8 minutes, then 1.7 for wisp's own modules after an interrupted first run); a clean debug build with tests, 9.5 minutes |
| The library | `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, 3.8 MB (0.7 MB gzipped) |
| The binary | Stripped, 15.1 MB without the trait and 32.8 MB with it; gzipped, 7.0 MB and 12.2 MB. The release tarball grows by about 6 MB |
| `mlx.metallib` beside the binary, bundle removed | `mlx-community/Qwen3-1.7B-4bit` answered a text-only prompt in 3 s including the weight load. With no library at all, MLX fails with "Failed to load the default metallib" |
| A link to the binary, as Homebrew's `bin/wisp` to the Cellar | `dli_fname` is the real path: an absolute link from another directory, a relative link, a lookup through `PATH`, and the two-link chain `bin/wisp` → `Cellar/…/bin/wisp` → `../libexec/wisp` all found the library beside the real binary, and the last answered a prompt |
| The live test | `MLXLiveTests` under `swift test --traits MLX` fails as before without the library; with `mlx.metallib` copied into `WispMLXTests.xctest/Contents/MacOS` it passed: a text reply in 1.7 s and the `current_date` tool loop 3 of 3 |

## Decision

The release is built with `--traits MLX` and ships `mlx.metallib`, the build's `default.metallib` under
MLX's first-searched name, beside `wisp` in the tarball. The Homebrew formula installs `wisp` and
`mlx.metallib` into `libexec` and links `bin/wisp` to `libexec/wisp`; no wrapper script is needed, since
MLX sees the real path. Putting the library in `bin` would link a non-executable into Homebrew's `bin`.

`wisp doctor` gains an `MLX` finding: in a build with the trait, it repeats MLX's search from the directory
`dladdr` reports for wisp's own image and loads the library it finds on the default Metal device; it fails
when nothing is found or the library does not load. In a build without the trait it passes and says so.
The release script checks that finding on the staged binary, away from the build's bundle.

`scripts/check mlx-live <model directory>` runs the live test: it builds with the trait in a scratch path
of its own (`harness/.build/mlx`, so the gate's build is not rebuilt), copies the library beside each test
bundle's binary, and runs `MLXLiveTests`. It stays outside the gate, like the evaluations.

## Consequences

- MLX models work from a Homebrew install without a self-build. The download grows by about 6 MB and the
  installed size by about 21 MB.
- Releasing needs the Metal toolchain; the release preflight checks for it.
- The library must come from the same build as the binary: kernels are looked up by name, and a library
  from another MLX version may lack one. The release copies it from the build it ships, and the doctor
  finding loads it but does not run a kernel.
- `harness/Package.resolved` pins MLX and its dependencies, so the release's trait build resolves the same
  versions as any other build and does not dirty the tree.
- A layout change upstream (a new name, a new search order) would show as the doctor finding failing on the
  staged binary, which stops the release.
