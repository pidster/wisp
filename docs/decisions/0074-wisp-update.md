# ADR 0074: `wisp update` replaces Wisp.app, and an opt-in check says when to

Date: 2026-10-23. Status: accepted by the operator on 2026-10-23; built 2026-10-23 for 0.31.0. Follows
[ADR 0072](0072-a-dmg-and-a-declared-layout.md) (`Wisp.app` in a disk image) and
[ADR 0073](0073-wisp-install-and-the-finder.md) (`wisp install`, and the Finder dialog).

Amended 2026-10-23, after 0.31.1 shipped: the first real update, a 0.31.0 `Wisp.app` from the released disk image
in a scratch folder to 0.31.1, ran in about 4 s: `wisp update --check` named 0.31.1; the update downloaded
`Wisp-0.31.1.dmg` (19.2 MB) to `~/Downloads`, matched its checksum, checked the app as signed by the team and
notarised, and swapped it in, leaving nothing beside it; the swapped app passed Gatekeeper ("Notarized Developer ID")
and `codesign --verify --deep --strict`, the link `wisp install` had made ran 0.31.1, and `update.check` and
`update.install` were recorded. Decision 1 said the `.sha256` is saved beside the image; it is read and not saved.
App Management in `/Applications` was not part of this run.

## Context

A Homebrew install updates with `brew upgrade`; `Wisp.app` from the disk image had no way to. The operator chose on
2026-10-23 a manual update with an opt-in check ([roadmap.md](../roadmap.md), 0.31.0, stage 4), and on the same day
settled the rest: the update runs from a terminal, and from the Finder dialog when the check is on; when the app
cannot be replaced, wisp stops and opens the disk image for the person to drag; the image is saved to `~/Downloads`;
a newer version is shown by `wisp doctor` and in the chat's status line.

wisp has said since its first release that nothing leaves the Mac unless the person chooses a remote model. A check
for updates is a request to GitHub, so it is off until asked for.

macOS 13 and later protect apps in `/Applications` from being changed by another app ("App Management"), unless the
change comes from the app's own developer or the changing app has the person's permission. Probed on this Mac on
2026-10-23 from a shell under Ghostty, with a copy of the signed probe app in `/Applications` launched once through
`open`: writing a file inside the bundle, renaming it, and swapping a new copy in with `renamex_np`'s `RENAME_SWAP`
all succeeded. Whether Ghostty holds the permission was not read, so a refusal on another Mac, or from another
terminal, is handled rather than ruled out.

Probed on 2026-10-23 with the code built here:

| Probe | Result |
| --- | --- |
| `codesign --verify --deep --strict` with the requirement below, on 0.30.1's notarised `Wisp Notifier.app` from Homebrew | Passes |
| The same on the probe `Wisp.app`, signed with the Developer ID but not notarised | Fails; without the `notarized` clause it passes, so the clause is what refuses it |
| Mounting the probe disk image with `hdiutil attach -nobrowse -readonly`, checking its app, and detaching | Mounted and detached, no mount left; the app refused as not notarised, and as the wrong version when asked for another |
| `wisp update --check` and `wisp update` against GitHub, the latest release being 0.30.1 | First failed: 0.30.1 has no disk image, so the check refused the release; after the change in decision 1, both say 0.30.1 is the latest |
| `wisp doctor` with `updates.check` on, twice | Checked once, recorded an `update.check` event, and the second run read the kept answer |
| The status line, with a newer version in `update.json` | `0.31.9 available` before the approval mode in plain chat, and `"update":"0.31.9"` in `wisp chat --json`'s `status` line |

## Decision

1. **`wisp update`, for the person.** It reads the latest release from GitHub's API
   (`api.github.com/repos/pidster/wisp/releases/latest`), and when its version is newer than the running one,
   downloads `Wisp-X.Y.Z.dmg` and its `.sha256` to `~/Downloads`, where they stay for the person to tidy; a file
   already there that matches the checksum is used rather than fetched again. `--check` only reports. A release with
   no disk image (one before 0.31.0, or made with `--unsigned`) still names its version, so a check reports it, and
   only an update stops, saying it has none. The default policy refuses `wisp update` to the model.
2. **Checked before it replaces anything.** The image's `sha256` must match the published one; the image is mounted
   read-only and out of sight; its `Wisp.app` must be `com.pidster.wisp`, of the version the release names, and pass
   a strict check of its whole signature against the requirement that it is signed with a Developer ID of the team
   `LFQFWCB8Y3` and notarised. Any failure stops the update with the reason, and nothing is replaced.
3. **Replaced whole, the old kept until the new is in place.** The new app is copied beside the old one, on the same
   volume, under a hidden name, checked again, and swapped with the old in one step (`renamex_np`, `RENAME_SWAP`);
   only then is the old one removed. The links `wisp install` made keep pointing at the same path. A `wisp` already
   running, such as an MCP server, goes on with the old code until it is started again, and wisp says so.
4. **When the app cannot be replaced**, because the folder is not writable or macOS refuses the change, wisp leaves the
   app as it was, says why, and opens the checked image in the Finder for the person to drag the new app over. It
   never asks for an administrator's password.
5. **Other installs are told what to do.** From Homebrew, `wisp update` changes nothing and says
   `brew upgrade pidster/tap/wisp` (with `--check`, it still reports the latest version); from a build or an
   unpacked tarball, that it cannot update one; from the disk image, or a copy macOS runs where it was downloaded, to
   move the app to Applications first.
6. **`updates.check`, off by default.** When on, wisp asks GitHub at most once a day, when a chat starts, when
   `wisp doctor` runs, and when `Wisp.app` is opened from the Finder, and keeps the answer in `~/.wisp/update.json`.
   A newer version is shown in `wisp doctor`'s `update` line and in the chat's status line (`0.31.1 available`), in
   the plain chat and in `wisp-tui`; the check never installs. With it on, the Finder dialog offers **Update** when a
   newer version is out, and does what `wisp update` does. With it off, nothing reaches the network until the person
   runs `wisp update`.
7. **What is sent**: one HTTPS request to GitHub's API with the user agent `wisp`, and, for an update, the downloads
   from GitHub's release storage. No identifier of the person or the Mac, and no version, is sent beyond what any
   HTTPS request carries.
8. **Audited.** Each check is an `update.check` event, and each update an `update.install` event, with the versions,
   the outcome, and the reason a check or update stopped.

## Consequences

- An update is a download the person can see and keep, and a check of its signature and notarisation before anything
  changes; a tampered or wrong image is refused, not installed.
- `wisp update` in a terminal attributes the change to the terminal app, which macOS may refuse; the person then drags
  the app from the opened image, as they did to install it.
- The status line gains a field (`update` in `wisp chat --json`'s `status` line); a front end that does not know it
  ignores it.
- The README's "nothing leaves your machine" stays true by default; the trust page lists the check and the update beside
  the model downloads the person asks for.
