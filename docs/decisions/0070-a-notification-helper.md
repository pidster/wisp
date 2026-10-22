# ADR 0070: A notification helper of wisp's own, Wisp Notifier.app

Date: 2026-10-22. Status: accepted; built 2026-10-22 for 0.30.0. Amends [ADR 0030](0030-notifications.md) and
[ADR 0044](0044-host-effects.md): a fifth route, `helper`, tried first.

## Context

wisp posts a notification by the first of four routes that works (ADR 0044): the front end, the terminal's escape
sequence, `display notification` sent to the terminal app, and `osascript`. Every one of them posts under someone
else's name and icon: the terminal's, or Script Editor's. A terminal holds its own banner back while its window has
focus. The backlog's "When wisp can be signed" planned `Wisp Notifier.app`, a bundle posting through
`UserNotifications`, and named the open question to settle first: whether macOS grants notification permission to
the bundle as shipped, unsigned.

Probed on this Mac on 2026-10-22 with a minimal bundle (`LSUIElement`, `requestAuthorization`, then one post), each
with a bundle identifier never seen before:

| Probe | Result |
| --- | --- |
| Signed ad hoc, and with the Developer ID, run from a folder under `/private/tmp` | Refused with no prompt, `UNErrorDomain` code 1, "Notifications are not allowed for this application", both alike, and still after `lsregister -f` |
| With the Developer ID, from `~/Applications` | The prompt; allowed; the banner posted |
| Signed ad hoc, from `~/Applications` | The prompt; the request returned code 1 while the prompt was still on screen; once allowed, the status read authorized and the banner posted |
| Signed ad hoc, from `~/Library/Caches`, standing in for Homebrew's `libexec` | The prompt; allowed; posted |
| The executable run directly, not through `open` | Refused with no prompt until the bundle was registered with LaunchServices; registered, the prompt, and posted |
| A banner clicked, carrying a terminal's bundle identifier | The helper heard the click and brought Ghostty forward |
| An allowed bundle (a debug build) replaced by another build (a release build) of the same identifier in another folder, the first removed | Still authorized, and posted without asking: the permission follows the bundle identifier, not the build or its place |

So a Developer ID is not needed, a Homebrew upgrade keeps the permission, and the helper must live outside a
temporary folder and be registered with LaunchServices before it is run. The operator chose this for 0.30.0, and on
the questions put to them: the helper tried first by every face; permission asked at the first notification, which
also goes by the routes of today; a setting to turn it off.

## Decision

1. **The bundle.** `Wisp Notifier.app`, bundle identifier `com.pidster.wisp.notifier`, never to change since the
   person's permission is kept under it; display name "Wisp"; `LSUIElement`, so no Dock icon; its icon the
   homepage's wisp (`site/home/wisp.jpg`) cropped square to its head (360 pixels at 202, 100) in a rounded tile,
   committed as `harness/Notifier/AppIcon-1024.png`. `scripts/notifier-app` assembles the bundle around the
   `WispNotifier` executable, building `AppIcon.icns` from that PNG with `sips` and `iconutil` (the `.icns`, at
   1.4 MB, is over the gate's limit for a committed file), and signs it, ad hoc, or with the Developer ID when
   `WISP_SIGN_IDENTITY` is set (ADR 0069).
2. **What it does.** One command a run, from `NotifierProtocol` in `WispNotifierKit`, a library both sides link so
   neither drifts: `--status` prints the permission (`not-determined`, `denied`, `authorized`, `provisional`);
   `--ask` asks the person and prints the answer, reading it again after the request, which can fail while the
   prompt is still up; `--post` posts one notification when allowed and exits 3 otherwise, decides nothing else,
   and carries the terminal's bundle identifier, so a click brings that app forward. Run with no arguments, as
   macOS runs it for a click, it waits a few seconds for the click and exits. A request's identifier names the
   notification, so a repeat replaces a banner rather than adding one.
3. **The route.** `helper`, first in every face's plan, when `notifications.viaHelper` is on (the default) and the
   bundle is beside `wisp`. wisp registers it with LaunchServices once a process, reads `--status`, and posts with
   `--post` when it is allowed; refused, missing, or failing, the notification goes on down the routes of today, and
   the audit says why the helper was passed over. When the permission is not yet asked, wisp starts `--ask` without
   waiting for it and posts this notification by the next route, so none is lost to the prompt.
4. **`wisp doctor`'s `notifier` finding** says where the helper is and its permission, or that it is off or missing.
   Never a failure: the other routes still post.

## Consequences

- Banners come from "Wisp", with its icon and a row of its own in Notification settings, in every face, and post
  while the terminal has focus; clicking one brings the terminal wisp ran in forward.
- The first notification after an install prompts once; until the person answers, notifications post as before.
  Refused, they always do, and the doctor says so.
- The tarball and the formula carry the bundle; Homebrew's upgrade replaces it in a new Cellar folder, and the
  permission stays.
- A build from source has no bundle until `scripts/notifier-app` makes one beside its `wisp`; the route is then
  skipped as missing, and the other routes post.
