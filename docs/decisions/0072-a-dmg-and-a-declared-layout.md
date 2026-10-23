# ADR 0072: A DMG holding Wisp.app, and each package declaring its layout

Date: 2026-10-23. Status: accepted by the operator on 2026-10-23 (the declared layout and `Wisp.app`'s layout; the
home's location left open, below); the declared layout, and `Wisp.app` and the DMG in the release (`scripts/wisp-app`,
`scripts/wisp-dmg`), built 2026-10-23 for 0.31.0. Amends [ADR 0012](0012-homebrew-release.md) (a second package beside the formula) and
[ADR 0047](0047-mlx-in-the-release.md) (where `Wisp.app` keeps the Metal library).

## Context

wisp ships through a Homebrew tap. Since 0.30.1 the release is signed with a Developer ID and notarised (ADR 0071),
so a download outside Homebrew runs. On 2026-10-23 the operator chose a disk image holding `Wisp.app` as the second
package, put on `PATH` by wisp itself, and `wisp update` for it ([roadmap.md](../roadmap.md), 0.31.0).

wisp finds its parts by searching from its own real path: `wisp-tui` beside it or in a `bin` beside its folder (since
0.18.1, after 0.17.0 moved `wisp` into `libexec` and `wisp chat` fell back to the plain chat without a word),
`Wisp Notifier.app` beside it (ADR 0070), and MLX finds `mlx.metallib` beside it itself (ADR 0047). The backlog
planned, with the operator on 2026-10-04, that each package declare where its parts are rather than each new layout
adding to the search: a fact of the package, not a setting for the person.

Probed on this Mac on 2026-10-23, with 0.30.1's signed release build in a `Wisp.app` under `~/Library/Caches`
(`wisp` and `wisp-tui` in `Contents/MacOS`, `Wisp Notifier.app` in `Contents/Helpers`):

| Probe | Result |
| --- | --- |
| The bundle signed inside out with the Developer ID, hardened runtime, and `codesign --verify --strict --deep` | Passes |
| The Metal library as `Contents/MacOS/mlx.metallib`, beside `wisp`, where MLX looks first | MLX loads it, but the app's signature breaks: "a sealed resource is missing or invalid"; `Contents/MacOS` holds only code |
| The library as `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`, `wisp` run as `Contents/MacOS/wisp` | `mlx:Qwen3-1.7B-4bit` answers: MLX finds it through the main bundle's resources |
| The same, `wisp` run through a link in a `bin` folder outside the app | MLX fails, "Failed to load the default metallib": Foundation's main bundle is the link's folder, not the app |
| A bundle opened with `Bundle(url:)` in a test program | It joins `Bundle.allBundles`, the list whose resources MLX also searches |
| `wisp doctor` from the app through the link | Signed by the Developer ID; `wisp-tui` found beside `wisp`; the notifier not found, since it is not beside `wisp` |

## Decision

1. **Each package declares its layout.** `Wisp.app`'s `Info.plist` holds a `WispLayout` dictionary, and the formula
   writes `wisp-layout.json` beside `wisp` in `libexec`; both map `frontEnd`, `notifier`, and `metalLibrary` to paths
   relative to `wisp`'s folder. `PackageLayout` reads it once a process from `wisp`'s real path: the app's
   `Info.plist` when `wisp` is in an app's `Contents/MacOS`, else the manifest. Keys it does not know are left alone,
   so a later package may declare more; an absolute path, or a value that is not a path, makes the declaration
   malformed.
2. **The declared part comes first, the search after.** `wisp-tui` is looked for at `WISP_TUI` when it is set (for an
   odd set-up, as `WISP_BIN` is for `wisp-tui`), then where the package declares it, then by the search of before;
   `Wisp Notifier.app` where the package declares it, then beside `wisp`. A build directory, or a tarball unpacked by
   hand, declares nothing and works as it did.
3. **`wisp doctor`'s `package` finding** checks every declared part: all present passes, naming the declaration; a
   part missing fails, naming it and where it should be; a declaration that cannot be read fails; none declared
   passes, saying wisp searches beside itself. 0.17.0's regression would have failed it before release.
4. **`Wisp.app`'s layout.** `wisp`, the app's executable, and `wisp-tui` in `Contents/MacOS`; `Wisp Notifier.app` in
   `Contents/Helpers`, its bundle identifier unchanged so the person's notification permission carries over
   (ADR 0070); the Metal library in `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`. MLX does not read
   the declaration, so `wisp` opens its own app bundle at start-up (`PackageLayout.openAppBundle()`), which puts the
   app's resources in MLX's search however `wisp` was started; the doctor's `MLX` finding searches them too. The
   formula's layout is unchanged.
5. **The home is not moved in 0.31.0**: `~/.wisp`, or `WISP_HOME`, for every package, so a person with both a
   Homebrew and a DMG install has one set of threads, approvals, and facts. Apple's conventions put an app's data under
   `~/Library/Application Support` and its settings in `UserDefaults`, binding only on a sandboxed app, which wisp is
   not. Where the home belongs is decided with the work on protecting wisp's state from other agents and processes
   running as the same person (keychain-held keys, answers that need the person present, encryption at rest), which
   may change what is kept where; the operator chose on 2026-10-23 to settle it there.

## Consequences

- A new layout is a change to its package's declaration, not to wisp's search, and the doctor checks it.
- The formula gains a file in `libexec`; an install from 0.30.1 or earlier has none and searches as before.
- `Wisp.app` started through a link finds its library only because `wisp` opens its bundle first; a future MLX that
  stops searching the opened bundles would fail the doctor's `MLX` finding, not silently.
- A signed release builds the DMG: `Wisp.app`, a link to `/Applications`, and a read-me, the app notarised with the
  binaries and stapled, then the image signed, notarised, and stapled. An unsigned release (`--unsigned`) builds
  neither, since Gatekeeper refuses an app signed ad hoc that was downloaded.
- What opening `Wisp.app` from the Finder does, `wisp install`, and `wisp update` are built in the stages that follow:
  the first two in [ADR 0073](0073-wisp-install-and-the-finder.md), a dialog offering to install. `LSUIElement`
  keeps the app out of the Dock.
