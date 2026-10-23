# ADR 0073: `wisp install` puts Wisp.app on PATH, and the Finder offers it

Date: 2026-10-23. Status: accepted by the operator on 2026-10-23; built 2026-10-23 for 0.31.0. Follows
[ADR 0072](0072-a-dmg-and-a-declared-layout.md), which put `Wisp.app` in a disk image and left what installs it, and
what opening it from the Finder does, to this stage.

## Context

`Wisp.app` is dragged to Applications from the disk image, but a terminal finds `wisp` only on `PATH`. The operator
chose on 2026-10-23 that wisp links itself, with no administrator's password, rather than an installer package
writing to `/usr/local/bin` ([roadmap.md](../roadmap.md), 0.31.0, stage 3). Until now the image's read-me listed
`ln -sf` lines to type, and the app opened from the Finder started `wisp` with no terminal, which exited within two
seconds with nothing shown.

Probed on this Mac on 2026-10-23, with the release build in a `Wisp.app` signed with the Developer ID under
`~/Library/Caches`: `wisp install` into a scratch folder made both links and printed the `PATH` line; run again it
reported them current; `wisp doctor` through the link found the app's Metal library, every declared part, and the
signature; `wisp uninstall` removed both. Opened with `open`, as the Finder opens it, `wisp` stayed running on the
dialog instead of exiting.

`wisp completions install` already set the pattern for writing outside `~/.wisp`: replace only what wisp wrote, and
print what to add to a shell's start-up file rather than edit it.

## Decision

1. **`wisp install [FOLDER]`** links `wisp` and `wisp-tui` from the app's `Contents/MacOS` into `~/.local/bin`, or
   the folder named, creating it. It runs only from `Wisp.app` (`AppInstall.source`, by the declared layout): from
   the disk image's read-only volume or the temporary copy macOS runs an app opened where it was downloaded (App
   Translocation) it says to drag the app to Applications first; from Homebrew, which links `wisp` itself, and from a
   build or an unpacked tarball, it refuses and says why. Run again, it reports the links as current.
2. **What is in the way is never overwritten without a word.** A file that is not a link is never replaced; a link
   to anything else (an older app, a build) is replaced only with `--force`. When either is in the way nothing is
   changed, and each is named.
3. **`wisp uninstall [FOLDER]` knows its links by where they point**: it removes `wisp` and `wisp-tui` from the
   folder only when they are links into the app it runs from, and names anything else it leaves. No record of what
   was linked is kept, so nothing in `~/.wisp` goes stale, and the home's future (ADR 0072, decision 5) is not
   bound. It removes neither the app nor `~/.wisp`.
4. **`PATH` is advised, never edited.** When the folder is not on `PATH`, install prints the line to add for the
   shell `$SHELL` names (`~/.zshrc`, `~/.bash_profile`, or fish's `fish_add_path`).
5. **Opened from the Finder, `Wisp.app` shows a dialog.** `wisp` takes itself to be opened from the Finder when it
   runs from an app with no arguments (or only an older macOS's `-psn_` argument), no terminal on stdin, and
   `launchd` as its parent (`AppInstall.isFinderLaunch`). The dialog says wisp is a command-line tool and offers
   **Install**, which does what `wisp install` does and shows the result; `Cancel` quits. Already installed, it
   says where and how to start; with something in the way, or from the disk image, it says what to run or do and
   offers nothing. The Finder's `PATH` is `launchd`'s, not a terminal's, so the dialog's `PATH` advice is a
   condition ("if a new terminal cannot find wisp"); a login shell is not started to find out.
6. **The model may do neither.** The default policy refuses `wisp install` and `wisp uninstall` to the model: what a
   shell runs as `wisp` is the person's to choose. `wisp completions install` stays allowed.

Neither command reads or writes `~/.wisp`, and neither is audited, as `wisp completions install` is not: both run in
the person's terminal or at their click, and change only links outside the home that `ls -l` shows.

## Consequences

- The image's read-me and the install guide say `wisp install`, not `ln -sf` lines.
- Links point to `/Applications/Wisp.app/Contents/MacOS/…`, so replacing the app whole (stage 4, `wisp update`)
  keeps them; moving the app breaks them, and `wisp install --force` from its new place mends them.
- `wisp` started through such a link resolves its real path into the app, so the declared layout and MLX's library
  are found as ADR 0072 describes; `wisp-tui` started through its link finds `wisp` on `PATH`, in the same folder.
- A shell with both a Homebrew `wisp` and the app's on `PATH` runs whichever comes first; install does not look for
  the other. Both share `~/.wisp`.
- `wisp install` and `wisp uninstall` are subcommands, so a prompt that is exactly the word `install` must now be
  given as `wisp respond install`.
