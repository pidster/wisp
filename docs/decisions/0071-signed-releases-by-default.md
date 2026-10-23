# ADR 0071: Releases are signed and notarised by default

Date: 2026-10-23. Status: accepted. Amends [ADR 0069](0069-signed-and-notarised-releases.md): signing, built there and
left off, is on unless the release says otherwise.

## Context

ADR 0069 built Developer ID signing and notarisation into `scripts/release` and left it off: an individual developer
account's certificate carries the person's legal name, written into every signed binary for good, and on 2026-10-22
the operator chose to keep releases unsigned for now. 0.29.1 and 0.30.0 shipped that way, signed ad hoc by the linker
(`wisp`, `wisp-tui`) and by `scripts/notifier-app` (`Wisp Notifier.app`), and `spctl` rejects all three.

On 2026-10-23 the operator turned signing on by default, and asked for 0.30.1 to be the first signed release.

## Decision

1. **`scripts/release` signs unless told not to.** `WISP_SIGN_IDENTITY` still names the identity, and defaults to
   `Developer ID Application`, which matches the one Developer ID Application identity a releasing Mac holds; preflight
   still refuses a name matching none or several, and a notary profile that cannot sign in, before the slow steps.
2. **`--unsigned` opts out**, for a Mac without the certificate or a release that must not carry the name; the release
   is then as before ADR 0069's signing, and preflight says so. An empty `WISP_SIGN_IDENTITY` is not an opt-out, so a
   variable left blank by mistake cannot ship an unsigned release.
3. Everything else is ADR 0069's: the hardened runtime with no entitlements, the secure timestamp, notarisation of
   both binaries and the helper bundle before anything is tagged, and release notes that follow the signature.

## Consequences

- From 0.30.1, every release names its signer, "Developer ID Application: Stuart Williams (LFQFWCB8Y3)", and
  `wisp doctor`'s `signature` line shows it; a tarball downloaded directly runs.
- A release needs the certificate's key in the keychain and the network for the timestamp and the notary service, or
  `--unsigned`. The certificate reads valid until 2027-02-01; after that a new one is needed to sign, and the default
  finds it by the same name.
- ADR 0069's open question, whether Homebrew installs a signed binary with its signature intact, is answered by the
  first signed release's verify step: on 2026-10-23, 0.30.1 installed by Homebrew kept the Developer ID signature on
  `wisp`, `wisp-tui`, and `Wisp Notifier.app` (`codesign --verify --strict` passes; `wisp doctor` names the signer),
  and the release's tarball, given a Safari quarantine attribute, ran with no prompt.
- `Wisp Notifier.app` is signed with the same identity as the binaries; its bundle identifier, and so the person's
  notification permission, is unchanged (ADR 0070).
