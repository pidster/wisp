# notify

Shows the user a macOS notification: a title and a message, the way a long-running task says it has
finished or that it needs you. The same notifier backs `wisp notify` on the command line
([wisp.md](../wisp.md)). Decided in [ADR 0030](../decisions/0030-notifications.md); how it is posted, in
[ADR 0044](../decisions/0044-host-effects.md).

## Arguments

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `title` | string | yes | A few words; cut to 64 characters. |
| `message` | string | yes | One or two sentences; cut to 256 characters. |

## Result

`notification posted via <route>` (`host`, `terminal`, `app`, or `osascript`, below), or `error:
notification not shown: <reason>` when notifications are off, the message is empty, the per-minute limit
is reached, or every route failed. The model is told the reason and can say so. Delivery is not awaited:
a route that took the notification has done its part.

## Limits and controls

| Control | Value |
| --- | --- |
| Text | Control characters become spaces; title and subtitle 64 characters, message 256, with an ellipsis when cut |
| Rate | At most `notifications.perMinute` (default 5) in any minute, across every conversation of the process |
| Off switch | `notifications.enabled: false` in `config.json`; every request is then refused |
| Approval | None: a banner changes nothing on the Mac. Leave the tool out of a conversation with `--tool` or `tools` if it should not notify |
| Terminal text | For the escape sequences, every control character (ESC, BEL, the C1 terminators) becomes a space and `;` becomes `,`, on top of the cleaning above, so the text can neither end a sequence nor be read as its parameters |
| Audit | Every request, posted or refused, is a `notification` event with the title, body, source (`model`, `user`, or `watch` for `wisp watch`), outcome, the route taken, and why earlier routes were skipped ([logging.md](../logging.md)) |

## How it is posted

The limit, the bounds, and the off switch apply first; then the first of four routes that works posts it,
in this order:

| Route | When | Posted as |
| --- | --- | --- |
| `host` | Under `wisp chat --json`, when the front end's `hello` declared `notify` (`wisp-tui` does in a terminal that has a sequence): wisp sends a `notify` line and the front end writes the sequence between its frames | The terminal |
| `terminal` | Plain chat and the one-shot commands (`wisp notify`, `wisp watch`, `wisp "…"`), when `/dev/tty` opens and `TERM_PROGRAM` (or, when unset, `TERM`) names a terminal with a notification sequence: Ghostty, iTerm2, and WezTerm post OSC 9 (`ESC ] 9 ; title: message BEL`), kitty OSC 99 (the title and the message as two chunks). Written to `/dev/tty`, never to stdout. Never under `--json` (the front end owns the terminal) or `wisp mcp` (the client does) | The terminal, under its name and icon; clicking it returns to the terminal |
| `app` | With `notifications.viaTerminalApp` on (the default) and `__CFBundleIdentifier` set: `display notification` sent to that app (`tell application id …`); macOS asks once for Automation consent per app | The terminal app (probed 2026-09-30 in Terminal.app and Ghostty) |
| `osascript` | Always, last | Script Editor |

Terminal.app has no sequence, and `tmux` does not pass one through, so in either a notification falls
through to the app route, and to `osascript` only without it. `wisp doctor` names the route it would take
in the terminal it runs in.

**A terminal may hold back its own banner while its window has focus.** Probed 2026-09-30: Ghostty posted
the OSC 9 banner only once another app was in front. That is the terminal route's behaviour by design,
since a person looking at the terminal sees the output; the app route posts regardless.

The two AppleScript routes run `/usr/bin/osascript` with a fixed script; the title, subtitle, message,
and the app's bundle identifier are passed as arguments and read from `argv`, so nothing the model writes
is ever parsed as AppleScript. Apple's notification framework needs an app bundle and aborts in a
command-line binary (probed on this Mac, 2026-09-23), which is why the last route exists at all. macOS
shows its banner as coming from Script Editor, and the first one may ask you to allow notifications for
it.

If notifications collect in Notification Center without popping up, Script Editor's alert style is set
to deliver quietly, or a Focus mode is on: in System Settings, Notifications, Script Editor, choose
Banners or Alerts. Seen on this Mac on 2026-09-23: both test notifications arrived in the stack and
neither showed a banner. For the terminal route the same applies to the terminal's own row.

### Probing the app route

The app route is off until it is shown to work on macOS 27: whether a banner sent to a terminal app by
bundle identifier is attributed to that app, and not to Script Editor. To check it in the terminal you use:

```
wisp notify --route app "probe"
```

The first time, macOS asks whether wisp's terminal may control the app (Automation); allow it and run the
command again, since the first attempt gives up after five seconds. Then look at the banner: it should
show your terminal's name and icon. Probed 2026-09-30 on macOS 27 in Terminal.app and Ghostty, both
attributed to the terminal, so the route is on by default; `wisp config set notifications.viaTerminalApp
false` turns it off, and notifications then fall through to `osascript` (Script Editor).
`wisp notify --route terminal "probe"` checks the terminal route the same way.

A helper app posting through Apple's `UserNotifications`, so banners come from Wisp itself, is planned
for when wisp can be signed ([backlog.md](../backlog.md), "When wisp can be signed").

## Implementation

`Notifier` in `harness/Sources/WispCore/Support/Notifier.swift`, one per session so the rate limit covers
every conversation, tested in `NotifierTests` with an injected runner and clock. The routes are
`NotificationRoutes` and `TerminalNotification` in `Support/NotificationRoutes.swift`, carried by each
face's `SessionHost`, tested in `NotificationRoutesTests` with an injected environment and terminal
writer. `NotifyTool` is the model-facing wrapper and posts through the host. `wisp-tui`'s side is
`tools/wisp-tui/src/notify.rs`.
