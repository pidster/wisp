# ADR 0091: Wisp.app opens a window to install, update, and manage models

Date: 2026-11-28. Status: proposed 2026-11-28, at the operator's request; built the same day, not yet released.
Extends [ADR 0073](0073-wisp-install-and-the-finder.md) (the Finder dialog) and
[ADR 0074](0074-wisp-update.md) (`wisp update`).

## Context

Opening `Wisp.app` from the Finder showed a single dialog (ADR 0073). It offered **Install**, or, with `updates.check`
on and a newer release found, **Update** (ADR 0074, decision 6). It could not show which releases exist or what
changed in them. With `updates.check` off it never offered an update at all, and the models could be managed only
from a terminal or a chat.

On 2026-11-28 the operator asked for a modest extension: click to install, as before; click to update, listing the
latest versions; and manage models. The same day they chose:

- **The form:** one small window, not a chain of dialogs.
- **The versions:** the recent releases listed, with only the newest installable. The older ones are for reading.
- **The model actions:** list, enable and disable, check, uninstall, and pull and add.

They also asked that the terminal can do whatever the window does, in a form people can read. They asked, too, that the window follow Apple's Human Interface Guidelines.

## Decision

1. **A window when opened from the Finder.** `Wisp.app` opened with no terminal (`AppInstall.isFinderLaunch`, as
   before) opens one window with three tabs. Closing the window, or Quit, ends it. The window is a view of
   `AppPanel` in `WispCore`. Everything it does goes through the calls the terminal makes, and every question it puts
   is a sheet on the window. The work is tested without AppKit.
   - **Apple's Human Interface Guidelines** shape the layout, as for a macOS settings window:
     - Toolbar tabs, one pane per job: **Install**, **Updates**, and **Models**, the last with Add a Model and
       Activity. The window is titled after the selected pane and takes its height. It opens at Install while wisp
       is not on `PATH`, and at Models otherwise. The operator chose tabs over one long page on 2026-11-28.
     - Each pane is a grouped form, each section's explanation in its footer.
     - A switch for a model's on or off state, and a menu for its other actions.
     - Title-case buttons, with an ellipsis where more input follows.
     - The system's warning symbol.
     - The standard menu bar: the app menu (About, Check for Updates…, which opens the Updates tab and checks, Services,
       Hide, Hide Others, Show All, Quit), File (Close), Edit,
       Window (Minimize, Zoom, Bring All to Front), and Help, which opens the guide.
   - **Alerts:**
     - The action the person started is the default, and Cancel answers Escape.
     - Uninstall's button is marked destructive, and Return cancels.
     - In the publisher question, Return cancels too, since running an untrusted publisher's weights is the risky
       choice.
   - **Quit** closes the window, so the session ends and the backends shut down, as after a command.
2. **Install**, as the dialog did: it says whether wisp is on `PATH` and where, and offers **Install** when it is not
   (`AppInstall.welcome`, `AppInstall.install`).
3. **Update: the recent releases, and only the newest installed.**
   - **Check for Updates** asks GitHub for the recent releases (`releases?per_page=10`). Drafts and pre-releases are
     left out, and the newest five are shown, each with its day and its notes. The running one is marked.
   - The ask is one request, made when the person clicks, even with `updates.check` off. Clicking is asking, as
     running `wisp update` is (ADR 0074, decision 6). It sends what a check sends (decision 7).
   - The newest release is kept in `~/.wisp/update.json` and recorded as `update.check` with `source` `finder`, so
     the doctor and the chat agree with the window.
   - **Update** appears only when the newest is newer than the running app, has a disk image, and this install can
     replace itself. It asks first, then does what `wisp update` does (ADR 0074, decisions 1 to 4). Older releases are
     not installed: an older wisp may not read what a newer one wrote.
   - With `updates.check` on and a check due, opening the window checks, as the dialog did.
   - **What's New** shows this version's own notes in a few lines, with links to its release page and to all
     releases. The notes are its section of the changelog, written into the app at the version bump by
     `scripts/check release-notes` and embedded at build time, so showing them asks GitHub nothing. A test fails
     while the resource and the changelog's section differ. The operator asked for this on 2026-11-28.
4. **Models, as `wisp models` does them** (`ModelActions`, with a new face, `finder`, which the audit records as
   `source`). Each action asks what the terminal asks, as a sheet:
   - **The listing:** the models `wisp models list` shows. Each runtime that could not be asked is named under it, as
     the terminal names it.
   - **Enable and disable:** turning an MLX model on checks it when its capabilities are undeclared (ADR 0056).
   - **Check:** the model is loaded and asked its three questions.
   - **Uninstall:** offered for a local runtime's model only. The plan is shown, and the person types the name
     (ADR 0075, decision 3).
   - **Pull:** a Hugging Face repository is typed, and the publisher question and the download question are put
     (ADR 0052). The progress is shown, and **Stop** keeps what arrived.
   - **Add:** a GGUF file is chosen in an open panel (ADR 0082, decision 2).
   - One action runs at a time, and what each says is shown below the list.
5. **The terminal can do the same.** Install, update, and every model action were already in the terminal. The
   listing of releases is added, and the notes: `wisp update --notes` prints the shipped notes and links, and
   `wisp update --releases` prints the same releases with their days, the running one
   marked, a few lines of each release's notes, and what can be done about the newest, then records it as the
   window's check does.
6. **The model may list the releases.** The default policy refuses `wisp update` to the model, and allowed only
   `wisp update --check` on its own (ADR 0074, amended 2026-11-17). It now allows `wisp update --releases` and
   `wisp update --notes` on their own too. They only report, as the check does.

## Consequences

- The `wisp` executable gains SwiftUI and AppKit code: a view and the wiring of sheets and panels. Its logic stays in
  `WispCore`. The dialog's code goes.
- With `updates.check` off, the app still reaches the network only when the person clicks **Check for Updates** or
  **Pull**.
- The window registers the model backends before it opens and shuts them down after it closes, as a command does.
- Before acceptance:
  - It needs a run from the Finder on a released or notarised `Wisp.app`, which this change could not do from a
    terminal.
  - The operator decides whether decision 6 stands.
