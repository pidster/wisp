# ADR 0030: Notifications through osascript, bounded and audited, without approval

Date: 2026-09-23. Status: accepted. Amended by [ADR 0044](0044-host-effects.md): `notify` is a host
effect, posted by the front end or the terminal when they can, and by `osascript` only as the last route.

## Context

A delegated task that takes minutes, a build or a triage, should be able to tell the user when it is
done, and a person scripting wisp should be able to do the same. macOS notifications are the natural
channel. Two things shaped the design: how a command-line binary can post one at all, and whether the
model posting one should go through the approval gate like a command.

## Decision

- **Mechanism.** `UserNotifications` needs an app bundle; in the `wisp` binary it aborts with an
  uncaught exception (probed 2026-09-23). `osascript -e 'display notification …'` works from a plain
  binary. The script is a fixed list of lines; the title, subtitle, and body are arguments read from
  `argv`, so the model's text never becomes AppleScript.
- **Faces.** A model tool, `notify` (title, message), and a subcommand, `wisp notify <message>`
  (`--title`, `--subtitle`, `--sound`), share one `Notifier` per session.
- **No approval.** A banner changes nothing on disk, in a repository, or on the network, which is what
  the gate protects. Instead: text bounded (64 and 256 characters, control characters stripped), a
  per-minute limit across the process (default 5), an off switch in `config.json`, and every attempt
  audited as a new `notification` event with its source and outcome. The tool can still be left out of
  a conversation by name like any other.

## Consequences

- The model can tell you a long task has finished without you watching the terminal; a harness
  delegating through `respond` can ask it to.
- Banners appear as coming from Script Editor, and macOS may ask once to allow them. A helper app
  bundle posting through `UserNotifications` would fix both; it is planned for when wisp can be signed
  (`backlog.md`).
- A misbehaving model can post at most five banners a minute, each visible in the audit log.
- Tests: the argument list, cleaning, the off switch, the empty-message and rate-limit refusals on an
  injected clock, the audit event, and the tool's replies (`NotifierTests`); the real `osascript` path
  was exercised by hand from the CLI and from the model the same day.
