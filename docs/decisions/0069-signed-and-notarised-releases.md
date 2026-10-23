# ADR 0069: Releases can be signed with a Developer ID and notarised, off until the operator turns it on

Date: 2026-10-22. Status: accepted; amended by [ADR 0071](0071-signed-releases-by-default.md), which makes signing
the default from 0.30.1. Amends [ADR 0012](0012-homebrew-release.md): the release can be signed and notarised; unsigned
stays the default.

## Context

ADR 0012 shipped `wisp` unsigned through a Homebrew tap, since Homebrew does not quarantine what it downloads and so
Gatekeeper never meets the binary. Unsigned in practice means signed ad hoc: the linker signs every arm64 executable
with no certificate (`flags=0x20002(adhoc,linker-signed)` on 0.29.0's installed `wisp` and `wisp-tui`). A tarball
downloaded by a browser or curl is quarantined and refused, so the release notes say to use Homebrew. Three items in
the backlog wait on a signature ("When wisp can be signed"): a notification helper app, a DMG, and Private Cloud
Compute.

On 2026-10-22 the operator enrolled in the Apple Developer Program, made a Developer ID Application certificate, and
stored a `notarytool` keychain profile, `wisp-notary`, with an App Store Connect team API key. Probed the same day on
this Mac, with 0.29.0's release build (`wisp` with the MLX trait), signed by hand:

| Probe | Result |
| --- | --- |
| `codesign --force --options runtime --timestamp --sign "Developer ID Application: …"` | Signed with the hardened runtime and a secure timestamp; authority chain Developer ID Application, Developer ID Certification Authority, Apple Root CA |
| The signed `wisp --version`, and `!uname -m` and `!touch /etc/…` in a piped `wisp chat --plain` | Runs; `sandbox-exec` runs the command and still refuses the write to `/private/etc` |
| A one-word reply from `mlx:Qwen3-1.7B-4bit` | Answers: MLX's Metal library loads under the hardened runtime with no entitlements (no `allow-jit` or library-validation exception) |
| `notarytool submit` of the zipped binary, `--wait` | Accepted, "Ready for distribution", no issues in the log, in about a minute |
| The signed `wisp` and `mlx.metallib`, both given a Safari quarantine attribute | Gatekeeper lets it run; `wisp doctor`'s MLX finding loads the library, and the MLX model answers |

A Developer ID certificate's name comes from the developer account. For an individual account that is the person's
legal name, written into every signed binary, where `codesign -dv` shows it to anyone; a published binary cannot be
renamed. An organisation account names the organisation instead, but needs a legal entity and a D-U-N-S number. The
operator chose on 2026-10-22 to keep releases unsigned for now, with the signing built and ready.

## Decision

1. **`scripts/release` signs when `WISP_SIGN_IDENTITY` is set**, to a Developer ID Application identity's full name,
   or a part of it that matches exactly one valid identity in `security find-identity -v -p codesigning`. Unset, the
   release is as before. The identity is a setting rather than a constant in the script, so a later certificate, an
   organisation's included, changes nothing in the repository.
2. **Preflight checks both credentials before the slow steps**: the identity is a Developer ID Application one and
   matches exactly one, and `notarytool history --keychain-profile "$WISP_NOTARY_PROFILE"` (default `wisp-notary`)
   signs in to Apple. History reads the team's submissions and changes nothing.
3. **Signed after `strip`**, which would invalidate a signature, and before the version, doctor, and completion
   checks, so those run the signed binaries: `wisp` and `wisp-tui`, each with the hardened runtime, no entitlements,
   and Apple's secure timestamp, so a signature stays valid after the certificate expires; then
   `codesign --verify --strict`. `mlx.metallib` is data, not code, and is not signed.
4. **Notarised before packaging**: both binaries, zipped with `ditto`, to `notarytool submit --wait`; the release stops,
   with the submission's log, unless Apple's verdict is `Accepted`. A bare executable cannot carry a stapled ticket,
   so Gatekeeper fetches it online the first time it meets the binary. `--dry-run` signs and prints the submission
   instead of making it.
5. **The release notes follow**: signed, they say the tarball's binaries are signed and notarised, so a direct
   download runs; unsigned, they keep ADR 0012's line to use Homebrew.
6. **`wisp doctor` says who signed the running `wisp`** (`CodeSignature`): the certificate's name, `signed ad hoc`
   for an unsigned release or a build from source, `not signed`, or why the signature could not be read. Never a
   failure, since all of them run.

## Consequences

- Nothing changes for 0.29.1's users unless the operator sets `WISP_SIGN_IDENTITY` for that release; the doctor's new
  finding says `signed ad hoc` for it.
- Once a release is signed, the certificate's name is public in every binary of it, for good.
- A signed release needs the network for the timestamp and the notary service, and adds the notarisation's minute or
  so; a rejection stops the release before anything is tagged.
- The certificate made on 2026-10-22 reads valid until 2027-02-01, shorter than the five years a Developer ID
  certificate usually has; binaries signed before then stay valid through their timestamp, but signing after it
  needs a new certificate.
- Whether Homebrew installs a signed binary with its signature intact is not yet verified; it relinks binaries only
  when their load commands name a Homebrew path, which wisp's do not. The first signed release checks it at the verify
  step, where `wisp doctor`'s `signature` line names the signer, or says `signed ad hoc` if Homebrew re-signed it.
- The notification helper app and a DMG still wait, now on their own work rather than on a certificate; Private Cloud
  Compute still needs App Store distribution, which a Developer ID does not give.
