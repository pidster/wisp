# ADR 0089: The release can take its notary credentials from 1Password

Date: 2026-11-22. Status: proposed; not yet agreed by the operator, who is still weighing it. Would amend
[ADR 0069](0069-signed-and-notarised-releases.md), decisions 2 and 4 (where `notarytool`'s credentials come from).

## Context

ADR 0069 notarises with a `notarytool` keychain profile, `wisp-notary`, which holds an App Store Connect team API key:
the key file `AuthKey_<KeyID>.p8`, its Key ID, and the Issuer ID (`docs/release.md`, "Signing"). `notarytool` reads the
profile from the login keychain each time it is called: preflight's sign-in check, each submission, and the log of a
rejected one.

A release takes from about 15 minutes (`--skip-eval`) to well over an hour (with the eval), and the profile has to be
readable at the end of it, not only at the start. It has not always been:

| Date | Release | What happened |
| --- | --- | --- |
| 2026-11-05 | 0.35.1 | The keychain locked during the eval's hour; the release failed at notarisation. Preflight has since asked the profile again after the eval |
| 2026-11-17 | 0.35.3, run 6 | The app's submission was accepted; the DMG's, a few minutes later, failed with "No Keychain password item found for profile: wisp-notary". Nothing was published |
| 2026-11-17 | 0.35.3, run 7 | The same, at the same step. Unlocking the login keychain made the profile readable again each time |

Each time the person had to be at the Mac, unlock the keychain, and rerun a release that had already built, signed,
and notarised the app. In runs 6 and 7, `codesign` signed the DMG with the Developer ID key from the same login
keychain moments before `notarytool` failed, so whether the keychain as a whole had locked, or only the profile's
item had become unreadable, is not established; either way the cause is a keychain item that must stay readable for
the whole run.

The operator keeps secrets in 1Password, whose command-line tool `op` (2.41 on the releasing Mac) reads an item's
field by reference (`op://<vault>/<item>/<field>`), after the person approves the access in the 1Password app, by
Touch ID or the account password. `op read --out-file <path> --file-mode 0600` writes a field straight to a file,
so the value never passes through a shell variable, an argument list, or the release's output. `notarytool` takes
the same three credentials directly, as `--key <path> --key-id <id> --issuer <id>`, instead of `--keychain-profile`.

The Developer ID private key that `codesign` uses is a different matter: `codesign` signs only with an identity in a
keychain, so 1Password cannot stand in for it, and it is out of scope here.

## Decision

1. **A 1Password item, named by `WISP_NOTARY_OP`, is an alternative to the keychain profile.** The person stores the
   `.p8` key as a file field and the Key ID and Issuer ID as text fields in one 1Password item, and sets
   `WISP_NOTARY_OP=op://<vault>/<item>` in the environment the release runs in. Neither the reference nor the
   values are written into the repository. Unset, the release uses the keychain profile exactly as now
   (`WISP_NOTARY_PROFILE`, default `wisp-notary`), so a Mac without 1Password is unchanged.
2. **Preflight fetches the credentials once, before the slow steps.** With `WISP_NOTARY_OP` set, `scripts/release`
   makes a private directory (`mktemp -d`, mode 700), writes the key into it with `op read --out-file … --file-mode
   0600`, reads the two IDs, and removes the directory on every exit. The script's only `trap` today is set at the publish
   stage, for its recovery instructions, so an `EXIT` trap set at the fetch removes the directory and then runs that
   recovery once the publish stage has begun. The person
   approves 1Password's prompt once, when they start the release, which they are at the Mac to do anyway; the rest of
   the run needs nobody.
3. **Every `notarytool` call takes the same credentials**, through one shell function that expands to either
   `--keychain-profile "$NOTARY_PROFILE"` or `--key … --key-id … --issuer …`: the sign-in check, each submission, and
   a rejection's log. `--dry-run` prints which source it would use, never a value.
4. **The sign-in check stays, and says what Apple said.** Preflight still runs `notarytool history` with the
   credentials before the slow steps, so a wrong item fails in seconds. Its message prints `notarytool`'s own error
   instead of assuming a locked keychain: on 2026-11-17 the real cause was Apple's 403 for an unsigned developer
   agreement, which the current message hid. With 1Password, the second check after the eval is unnecessary, since
   nothing it reads can lock, and is kept only for the keychain profile.
5. **Nothing secret is logged or shown.** The key is only ever a path to a mode-600 file in the private directory;
   the IDs are passed as arguments to `notarytool`, which is how Apple's own instructions pass them, and are not
   secret on their own.

### Open question: when to fetch

Decision 2 fetches once in preflight. The alternative is to fetch just before each `notarytool` call and remove the
file straight after:

| | Once, in preflight (proposed) | Before each call |
| --- | --- | --- |
| When the person approves 1Password | At the start, when they launch the release | About 15 to 60 minutes in, possibly twice |
| Runs unattended after the start | Yes | No: it waits on the prompt, and can time out unanswered |
| The key on disk | In a private mode-600 file for the run, then removed | Seconds per call |

Once in preflight is proposed because the point of the change is a release that cannot fail part-way while the
person is away; a key held for one run in a private file is a smaller standing exposure than today's keychain profile,
which holds it permanently.

## Consequences

- A release with `WISP_NOTARY_OP` set no longer fails at notarisation because the keychain locked; it needs the
  person once, at the start, to approve 1Password.
- `codesign`'s Developer ID key stays in the login keychain. If the keychain does lock during a run, signing could
  fail in the same way; it has not so far, including the DMG's signature in runs 6 and 7, made moments before the
  profile was found unreadable.
- The `.p8` key, which Apple offers to download once, gains a second home in 1Password; the person can then remove the
  keychain profile, or keep it as the fallback when `WISP_NOTARY_OP` is unset.
- A release depends on the 1Password app being installed, unlocked, and set to allow the CLI when the variable is
  set; preflight reports `op`'s own error if it is not, before anything slow starts.
- `docs/release.md`, "Signing", gains the 1Password set-up beside the keychain one, and the preflight description
  changes with decision 4.
