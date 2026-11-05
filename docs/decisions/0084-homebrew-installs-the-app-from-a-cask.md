# ADR 0084: Homebrew installs Wisp.app from a cask, and the formula migrates to it

Date: 2026-11-04. Status: accepted by the operator: decisions 1 to 4 on 2026-11-01, decisions 5 to 10 on 2026-11-04
(decision 5 in place of the stub agreed earlier, decision 6 in place of `conflicts_with formula:`); 0.34.2 the bridge,
0.35.0 the move. Amends
[ADR 0012](0012-homebrew-release.md) (the tap carries a cask, not a formula) and
[ADR 0072](0072-a-dmg-and-a-declared-layout.md) (`Wisp.app` is the one package Homebrew and a download share), and
[ADR 0082](0082-a-llama-cpp-server-wisp-starts.md) (the router's job moves to the app, decision 8).

## Context

Since 0.31.0 a signed release carries two packages: the tarball the Homebrew formula installs into the Cellar, with
its own layout declared in `wisp-layout.json`, and `Wisp.app` in a notarised disk image, which `wisp update` updates
in place (ADR 0072, [ADR 0074](0074-wisp-update.md)). Two packages mean two layouts to declare and check, two ways
for the llama.cpp router's job to be registered ([ADR 0082](0082-a-llama-cpp-server-wisp-starts.md): a Login Item
from the app, a file in `~/Library/LaunchAgents` through Homebrew's `opt` link from the formula), and two answers to
"how do I update". The operator chose on 2026-11-01 to have Homebrew install `Wisp.app`, so there is one package,
and to move the formula's few installs over.

Homebrew moves a formula to a cask itself. A tap's `tap_migrations.json` names where a formula went; when a person's
`brew update` pulls a commit that deletes the formula, and the name it lists is a cask in the target tap, Homebrew
says "has been migrated from a formula to a cask", unlinks the formula, and installs the cask
(`cmd/update_report/reporter.rb`, `migrate_tap_migration`, Homebrew 7.0; the same path, into `homebrew/cask`, moved
`vercel`, `meld`, and `mitmproxy` out of homebrew/core). The stub formula agreed on 2026-11-01 would stop that:
while a formula named `wisp` exists in a tap other than the core one, Homebrew resolves the name to the formula, not
the cask (`cli/named_args.rb`), so every person would move by hand, and the formula would have to go later anyway.

Homebrew's move installs the cask only when the person trusts it, or the whole tap (`ensure_trusted_migration_target!`
in the same file; tap trust, required for taps other than Homebrew's own since Homebrew 6.0.0). Installing a fully
qualified name trusts only that item (Homebrew's `docs/Tap-Trust.md`, "Installing from a tap"), so a person who ran
`brew install pidster/tap/wisp` trusts the formula, not the cask, and the move stops at a warning naming
`brew trust --cask pidster/tap/wisp` and `brew install --cask pidster/tap/wisp`. Probed on the operator's Mac on
2026-11-04 with 0.34.1's formula installed from a scratch tap ([measurements.md](../measurements.md), "Homebrew's move
from the formula to the cask"): with the formula alone trusted, the move warned and installed nothing; those two
commands, run as given, installed the cask without its links or completions, the formula's still in the way; with
the cask trusted beforehand, the move ran whole.

## Decision

1. **A cask, `wisp`, in `pidster/tap`**, installing `Wisp.app` from the release's disk image into the Applications
   folder. `brew install pidster/tap/wisp` resolves to it once the formula is gone.
2. **`auto_updates true`.** `wisp update` keeps updating the app in place, as it does for a download; `brew upgrade`
   leaves the cask alone unless `--greedy` is given, and `brew upgrade --greedy` brings it to the cask's version.
3. **`binary` links** `Wisp.app`'s `wisp` and `wisp-tui` into Homebrew's `bin`, so the commands are on `PATH` as the
   formula's were. wisp started through the link resolves it and finds the app's parts, as `wisp install`'s links do
   (ADR 0072, decision 4; the release already checks it).
4. **Completions from the binary**, as the formula did: the cask's `generate_completions_from_executable` runs
   `wisp completions bash|zsh|fish` at install into Homebrew's completion folders.
5. **The formula migrates to the cask through `tap_migrations.json`** (the operator, 2026-11-04, choosing Homebrew's
   own move over the stub). 0.35.0's commit to the tap adds `Casks/wisp.rb`, deletes `Formula/wisp.rb`, and adds
   `tap_migrations.json` with `{"wisp": "pidster/tap/wisp"}`. A person with the formula installed sees the move on
   their next `brew update`: the formula unlinked, the cask installed, and Homebrew's line saying to remove the old keg
   with `brew uninstall --formula --force wisp` when convenient. The move happens once, on the update that pulls the
   deletion; a person past it with the formula still installed, whose move failed, or who trusts only the formula,
   moves by hand: `brew trust pidster/tap`, `brew uninstall --formula wisp`, and
   `brew install --cask pidster/tap/wisp`, which the bridge release, the doctor, and the install guide name
   (decisions 7 and 10). The first trusts the whole tap, not the cask alone (the operator, 2026-11-05): Homebrew's
   `Trust.trusted?` accepts any item of a trusted tap, so it covers the cask (read in Homebrew 7.0.12's
   `trust.rb`; the probe trusted the cask alone), and whatever the tap adds later. Homebrew's trust is a list each
   person keeps; no signature or attestation adds to it, and only Homebrew's own taps are trusted without it.
6. **No `conflicts_with formula:`.** Homebrew 7.0's cask installer checks only `conflicts_with cask:`
   (`cask/installer.rb`, `check_conflicts`), so the stanza agreed on 2026-11-01 would do nothing, and the migration
   leaves the old keg installed but unlinked, which it must not refuse.
7. **wisp says where it came from, and whether the move finished** (as agreed on 2026-11-04, after the first
   wording was found unreachable: a wisp from the formula after 0.35.0 is 0.34.2 or older, so only code shipped by
   then runs there). `wisp doctor`'s `install` finding names the install: the cask, `Wisp.app` dragged from the disk
   image, the formula, or neither. From the formula it fails, saying the formula ends at 0.34.2, with the three
   commands of decision 5; `wisp update` there refuses with the same commands. From the app it warns while
   Homebrew's Cellar still holds a `wisp` keg, which the move leaves unlinked, naming
   `brew uninstall --formula --force wisp`, and fails when the `wisp` on `PATH` is still the formula's, the move
   unfinished. A wisp run from the cask is `Wisp.app`, so `wisp update`, the Login Item, and the rest work as for a
   download; `wisp install` says the commands are already on `PATH` when a folder on `PATH` links to the running
   app, rather than adding a second set.
8. **The router's job moves with the install.** A router registered by the formula is a file in
   `~/Library/LaunchAgents` naming the formula's `opt` link, which goes when the old keg is uninstalled. wisp from
   the app already leaves another install's job alone; when that job's program no longer exists, it is this
   person's router with nothing behind it, so wisp from the app removes the file and registers its Login Item in its
   place, as `mend` does for an orphaned job, and says so.
9. **`brew uninstall --zap` removes wisp's data** (the operator chose Homebrew's usual practice over keeping it):
   `~/.wisp`, the threads, approvals, facts, and the audit log among it, the router's LaunchAgent file
   (`~/Library/LaunchAgents/com.pidster.wisp.llamacpp.plist`), and the preferences of `com.pidster.wisp` and
   `com.pidster.wisp.notifier`. A plain `brew uninstall` removes only the app and its links, as before. `WISP_HOME`
   elsewhere is not touched: the cask cannot know it.
10. **A bridge release, 0.34.2, the formula's last** (the operator, 2026-11-04, once the trust check was found). It
    publishes both: the formula at 0.34.2, with caveats naming the move, and the cask beside it, so the commands of
    decision 5 work from that day. Everything wisp itself does for the move (decisions 7 and 8) ships in 0.34.2, so
    the formula's last wisp says how to move and the cask's first knows the formula. 0.35.0 then changes only the
    tap: the formula deleted and `tap_migrations.json` added, moving at once whoever trusts the cask or the tap.
    The move was tried on 2026-11-04 on a formula installed on the operator's Mac, from a scratch tap, with
    formula-only trust and with the cask trusted (Context); every message wisp gives names the three commands in
    that order, the formula's uninstall before the cask's install.

## Consequences

- The release writes `Casks/wisp.rb` with the disk image's checksum; 0.34.2 writes the formula too, 0.35.0 deletes
  it. The cask needs the disk image, so an `--unsigned` release has nothing for Homebrew and says so. Every release
  after 0.35.0 changes only the cask.
- The tarball stays an asset of the release, for a person who unpacks it by hand; nothing in Homebrew uses it.
- The formula's layout (`wisp-layout.json`, `AppInstall.Source.homebrew`) stays readable, since unlinked kegs and
  missed moves remain for a while; nothing new is built for it.
- Docs that say `brew install pidster/tap/wisp` stay right; those that describe the formula's Cellar layout, `brew
  upgrade pidster/tap/wisp`, or the formula's `opt` link change.
- Most formula installs will move by hand: Homebrew's automatic move needs trust that installing the formula by
  name did not give. The bridge release and the doctor are what tell them.
- With the formula and the cask both in the tap (0.34.2 to 0.35.0), `brew install pidster/tap/wisp` still installs
  the formula; the cask needs `--cask`, and while the formula's `wisp` is linked the cask installs without its
  links or completions (probed), so the formula is uninstalled first.
