//! `wisp-tui`: a terminal front end for `wisp chat --json`. The conversation scrolls in the
//! terminal's own scrollback; a band at the bottom (ratatui's inline viewport) holds the reply in
//! progress, the input or an approval dialog in its place, and the status line, and grows to fit them.
//!
//! Usage: `wisp-tui [chat arguments…]`; every argument is passed to `wisp chat`. `WISP_BIN` names the
//! wisp binary (default `wisp` on `PATH`).

mod app;
mod editor;
mod markdown;
mod notify;
mod palette;
mod picker;
mod protocol;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event as TermEvent, KeyCode, KeyEventKind,
    KeyModifiers,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{BeginSynchronizedUpdate, EndSynchronizedUpdate};
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget, Wrap};
use ratatui::{Terminal, TerminalOptions, Viewport};

use app::{Action, App, BAND_HEIGHT, HistoryLine, LineKind, MARGIN};
use editor::Edit;
use markdown::Tone;
use notify::Sequence;
use protocol::{Inbound, Outbound};

/// What the main loop waits on.
enum Incoming {
    /// A line from wisp's stdout.
    Line(String),
    /// A line from wisp's stderr.
    Stderr(String),
    /// wisp's stderr closed: everything it wrote there has arrived.
    StderrClosed,
    /// wisp's stdout closed.
    Closed,
    /// A terminal event.
    Terminal(TermEvent),
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if version_requested(&args) {
        println!(
            "{}",
            version_display(
                env!("CARGO_PKG_VERSION"),
                env!("WISP_BUILD_COMMIT"),
                env!("WISP_BUILD_MODIFIED") == "true",
                env!("WISP_BUILD_RELEASE") == "true",
            )
        );
        return Ok(());
    }
    let mut child = spawn(&args)?;
    let stdout = child.stdout.take().context("wisp stdout")?;
    let stderr = child.stderr.take().context("wisp stderr")?;
    let mut stdin = child.stdin.take().context("wisp stdin")?;
    // The first line says what this front end does for wisp: it answers approvals, and posts
    // notifications when the terminal it runs in has a sequence for them (ADR 0044). Declaring `notify`
    // only then keeps the route simple: wisp never sends a notification this terminal cannot post.
    let sequence = notify::detect(|key| std::env::var(key).ok());
    // A wisp that failed at start-up may already have closed its stdin; the loop then sees its stdout close,
    // and its stderr is shown on the way out, so a failed write is not an error of its own.
    let _ = stdin
        .write_all(Inbound::hello(sequence.is_some()).line().as_bytes())
        .and_then(|()| stdin.flush());
    let (tx, rx) = mpsc::channel::<Incoming>();
    let out_tx = tx.clone();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if out_tx.send(Incoming::Line(line)).is_err() {
                return;
            }
        }
        let _ = out_tx.send(Incoming::Closed);
    });
    let err_tx = tx.clone();
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if err_tx.send(Incoming::Stderr(line)).is_err() {
                return;
            }
        }
        let _ = err_tx.send(Incoming::StderrClosed);
    });
    thread::spawn(move || {
        loop {
            match event::poll(Duration::from_millis(100)) {
                Ok(true) => match event::read() {
                    Ok(event) => {
                        if tx.send(Incoming::Terminal(event)).is_err() {
                            return;
                        }
                    }
                    Err(_) => return,
                },
                Ok(false) => {}
                Err(_) => return,
            }
        }
    });

    let mut terminal = ratatui::init_with_options(TerminalOptions {
        viewport: Viewport::Inline(BAND_HEIGHT),
    });
    // Bracketed paste delivers a paste as one event, so its newlines and keys cannot submit or edit.
    let _ = execute!(std::io::stdout(), EnableBracketedPaste);
    let result = run(&mut terminal, &rx, &mut stdin, sequence);
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    let ending = shut_down(&mut child, Some(stdin), QUIT_BOUND);
    // What wisp wrote to stderr after the loop stopped reading, such as why it could not start.
    for line in remaining_stderr(&rx, STDERR_BOUND) {
        eprintln!("{line}");
    }
    if matches!(ending, Ending::Stopped) {
        eprintln!(
            "wisp-tui: wisp did not exit within {} s of /quit, so it was stopped",
            QUIT_BOUND.as_secs()
        );
    }
    result?;
    if let Some(code) = exit_code(&ending) {
        std::process::exit(code);
    }
    Ok(())
}

/// How long wisp has, once asked to quit, to save its transcript and exit before it is stopped.
const QUIT_BOUND: Duration = Duration::from_secs(5);

/// How long the rest of wisp's stderr is waited for after it has exited.
const STDERR_BOUND: Duration = Duration::from_secs(1);

/// How wisp's process ended.
#[derive(Debug)]
enum Ending {
    /// It exited, with this status.
    Exited(ExitStatus),
    /// It did not exit in time and was killed.
    Stopped,
}

/// Ends wisp, bounded: sends `/quit` (which saves the transcript, as in the terminal chat), closes its stdin
/// so that it reads the end of its input even if it did not take the line, and waits up to `bound` for it to
/// exit, killing it after that. Leaving with Ctrl-C or Ctrl-D comes here, as wisp's own exit does.
fn shut_down(child: &mut Child, stdin: Option<impl Write>, bound: Duration) -> Ending {
    if let Some(mut stdin) = stdin {
        let quit = Inbound::Message {
            text: "/quit".into(),
        };
        // wisp may have gone already; then there is nothing to tell it.
        let _ = stdin
            .write_all(quit.line().as_bytes())
            .and_then(|()| stdin.flush());
    }
    let deadline = Instant::now() + bound;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ending::Exited(status),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Ending::Stopped;
            }
        }
    }
}

/// The stderr lines still to arrive, up to the end of wisp's stderr or `bound`, whichever is first; every
/// other kind of line is dropped, as nothing is drawn any more.
fn remaining_stderr(rx: &mpsc::Receiver<Incoming>, bound: Duration) -> Vec<String> {
    let deadline = Instant::now() + bound;
    let mut lines = Vec::new();
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        match rx.recv_timeout(left) {
            Ok(Incoming::Stderr(line)) => lines.push(line),
            Ok(Incoming::StderrClosed) | Err(_) => break,
            Ok(_) => {}
        }
    }
    lines
}

/// The exit code wisp-tui leaves with: none when wisp exited cleanly, wisp's own when it failed (1 for a
/// signal), and 1 when it had to be stopped.
fn exit_code(ending: &Ending) -> Option<i32> {
    match ending {
        Ending::Exited(status) if status.success() => None,
        Ending::Exited(status) => Some(status.code().unwrap_or(1)),
        Ending::Stopped => Some(1),
    }
}

/// The version `--version` prints, the same rule as `WispVersion.display` in the harness: the bare version
/// for a release build; otherwise `-dev`, `+` and the commit when one is known, and ` (modified)` when the
/// working tree had changes.
fn version_display(version: &str, commit: &str, modified: bool, release: bool) -> String {
    if release {
        return version.to_string();
    }
    if commit.is_empty() {
        return format!("{version}-dev");
    }
    let suffix = if modified { " (modified)" } else { "" };
    format!("{version}-dev+{commit}{suffix}")
}

/// Whether the only argument asks for the version; the front end's version is wisp's.
fn version_requested(args: &[String]) -> bool {
    args.len() == 1 && (args[0] == "--version" || args[0] == "-V")
}

/// The name the child is given at spawn, its `argv[0]` (ADR 0061), so `ps` tells the chat behind a
/// front end from one typed at a terminal. wisp finds its own executable by the kernel's path, never
/// by `argv[0]`.
const CHILD_NAME: &str = "wisp chat (tui)";

/// The command that starts `wisp chat --json` on `bin` with the given extra arguments, named
/// `CHILD_NAME`, its three streams piped.
fn chat_command(bin: &str, args: &[String]) -> Command {
    let mut command = Command::new(bin);
    command
        .arg0(CHILD_NAME)
        .arg("chat")
        .arg("--json")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// Starts `wisp chat --json` with the given extra arguments.
fn spawn(args: &[String]) -> Result<Child> {
    let bin = std::env::var("WISP_BIN").unwrap_or_else(|_| "wisp".to_string());
    chat_command(&bin, args)
        .spawn()
        .with_context(|| format!("cannot start {bin} chat --json"))
}

/// The loop: apply wisp's lines and the keys, insert finished lines above, redraw the band.
fn run(
    terminal: &mut ratatui::DefaultTerminal,
    rx: &mpsc::Receiver<Incoming>,
    stdin: &mut impl Write,
    sequence: Option<Sequence>,
) -> Result<()> {
    let mut app = App::default();
    let mut posted = 0;
    let mut height = BAND_HEIGHT;
    let mut shown_label: Option<String> = None;
    terminal.draw(|frame| app.render(frame, frame.area()))?;
    loop {
        // The thought bubble (ADR 0053) wakes the loop for each of its frames; otherwise four times a second.
        let wait = app
            .next_frame_in(Instant::now())
            .unwrap_or(Duration::from_millis(250));
        let incoming = match rx.recv_timeout(wait) {
            Ok(incoming) => Some(incoming),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
        };
        // While a turn runs, the working line's seconds tick: a wake with nothing redraws only when its
        // text has changed, so the cursor does not move four times a second.
        let label = app.live_label(Instant::now());
        let ticked = incoming.is_none() && label.is_some() && label != shown_label;
        let changed = changes_the_band(incoming.as_ref()) || ticked;
        match incoming {
            Some(Incoming::Line(line)) => app.handle(Outbound::parse(&line)),
            Some(Incoming::Stderr(line)) => app.handle(Outbound::Note { text: line }),
            Some(Incoming::Closed) => app.exited = true,
            Some(Incoming::Terminal(TermEvent::Paste(text))) => app.edit(&Edit::Paste(text)),
            Some(Incoming::Terminal(TermEvent::Key(key))) if key.kind == KeyEventKind::Press => {
                let action = apply_key(&mut app, command_for(key.code, key.modifiers));
                match action {
                    Action::None => {}
                    Action::Send(inbound) => {
                        stdin.write_all(inbound.line().as_bytes())?;
                        stdin.flush()?;
                    }
                    Action::Quit => return Ok(()),
                }
            }
            Some(Incoming::Terminal(_) | Incoming::StderrClosed) | None => {}
        }
        // Lines no key returned, such as a page of an output the panel scrolled to (ADR 0050).
        for request in app.take_requests() {
            stdin.write_all(request.line().as_bytes())?;
            stdin.flush()?;
        }
        if !changed {
            continue;
        }
        shown_label = app.live_label(Instant::now());
        // One synchronized update per frame: the terminal shows the finished frame, not the cleared band
        // of a resize or the steps of inserting lines, which it would otherwise paint as they arrive.
        let _ = execute!(std::io::stdout(), BeginSynchronizedUpdate);
        let frame = paint(terminal, &mut app, &mut height);
        let _ = execute!(std::io::stdout(), EndSynchronizedUpdate);
        frame?;
        // Between frames, so a sequence is never split by one of the frame's own.
        post_notices(&mut std::io::stdout(), &mut app, sequence, &mut posted);
        if app.exited {
            return Ok(());
        }
    }
}

/// Writes the notifications wisp asked for since the last frame, when the terminal has a sequence for
/// them; they are dropped otherwise (wisp sends none unless `hello` declared `notify`). A failed write
/// loses a banner, never the session.
fn post_notices(out: &mut impl Write, app: &mut App, sequence: Option<Sequence>, posted: &mut u64) {
    let notices = app.take_notices();
    if let Some(sequence) = sequence {
        let _ = notify::post(out, sequence, &notices, posted);
    }
}

/// Whether what arrived can change what the band shows. Nothing in the band animates, so a wake with
/// nothing, a key release, or focus and mouse events leave it as drawn; drawing anyway would show and
/// move the cursor four times a second, which some terminals paint as a flicker or a restarted blink.
fn changes_the_band(incoming: Option<&Incoming>) -> bool {
    match incoming {
        None | Some(Incoming::StderrClosed) => false,
        Some(Incoming::Terminal(TermEvent::Key(key))) => key.kind == KeyEventKind::Press,
        Some(Incoming::Terminal(event)) => {
            matches!(event, TermEvent::Paste(_) | TermEvent::Resize(..))
        }
        Some(Incoming::Line(_) | Incoming::Stderr(_) | Incoming::Closed) => true,
    }
}

/// What a key does: in the status bar while it has the focus (`bar_key`), otherwise to the input, a dialog, a
/// choice, or the panel, whichever has the keys.
fn apply_key(app: &mut App, key: Key) -> Action {
    if app.focused().is_some() {
        return bar_key(app, key);
    }
    match key {
        Key::Interrupt => app.interrupt(),
        Key::Cancel => app.cancel(),
        Key::Complete => app.complete(),
        Key::Submit => app.submit(),
        Key::Type(c) => app.type_char(c),
        Key::Edit(Edit::Left) if app.panel.is_some() => app.step_turn(false),
        Key::Edit(Edit::Right) if app.panel.is_some() => app.step_turn(true),
        Key::Edit(edit) => {
            app.edit(&edit);
            Action::None
        }
        Key::RecallPrevious => {
            app.recall_previous();
            Action::None
        }
        Key::RecallNext => {
            app.recall_next();
            Action::None
        }
        Key::ToggleOutput => {
            app.toggle_output();
            Action::None
        }
        Key::ShowContext => app.show_context(),
        Key::PageUp => {
            app.page_up();
            Action::None
        }
        Key::PageDown => {
            app.page_down();
            Action::None
        }
        Key::Previous | Key::Nothing => Action::None,
    }
}

/// A key while the status bar has the focus: Left and Right (and Alt- or Ctrl-) move between its items, Tab and
/// Shift-Tab too, wrapping around, Home and End to the first and the last; Enter or Space opens the item; Up or Esc
/// returns to the input as it was. Any other key returns to the input and does there what it always does, so a
/// character typed goes in and Ctrl-C quits as it would. Nothing here answers a dialog: opening one starts its grace.
fn bar_key(app: &mut App, key: Key) -> Action {
    match key {
        Key::Edit(Edit::Left | Edit::WordLeft) => app.step_bar(false, false),
        Key::Edit(Edit::Right | Edit::WordRight) => app.step_bar(true, false),
        Key::Complete => app.step_bar(true, true),
        Key::Previous => app.step_bar(false, true),
        Key::Edit(Edit::Home) => app.bar_edge(false),
        Key::Edit(Edit::End) => app.bar_edge(true),
        Key::Submit | Key::Type(' ') => return app.activate(),
        Key::RecallPrevious | Key::Cancel => app.leave_bar(),
        Key::RecallNext | Key::PageUp | Key::PageDown | Key::Nothing => {}
        other => {
            app.leave_bar();
            return apply_key(app, other);
        }
    }
    Action::None
}

/// The band's next height, when it should change: at once when the input needs more rows, but back
/// down only once the input is empty, as it is when a message is sent. Shrinking remakes the terminal,
/// so doing it on every Backspace across a wrap would remake it back and forth while the user types.
fn next_height(current: u16, wanted: u16, input_empty: bool) -> Option<u16> {
    (wanted > current || (wanted < current && input_empty)).then_some(wanted)
}

/// What a key asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Key {
    /// Cancel a dialog, or quit.
    Interrupt,
    /// Esc: leave an open choice unanswered.
    Cancel,
    /// Tab: complete the slash command being typed; in the status bar, the next item.
    Complete,
    /// Shift-Tab: in the status bar, the previous item.
    Previous,
    /// Send the input.
    Submit,
    /// A character: typed into the input, or an answer to a dialog.
    Type(char),
    /// An edit to the input.
    Edit(Edit),
    /// The previous submitted line.
    RecallPrevious,
    /// The next submitted line, or back to the draft.
    RecallNext,
    /// Ctrl-O: the last tool output in full, or back.
    ToggleOutput,
    /// Ctrl-T: the model's context in a panel.
    ShowContext,
    /// `PageUp`: a page up in an open panel.
    PageUp,
    /// `PageDown`: a page down in an open panel.
    PageDown,
    /// Nothing wisp-tui uses.
    Nothing,
}

/// The key map. Readline's bindings where a terminal user expects them (Ctrl-A, E, U, K, W), Alt with an
/// arrow or `b`/`f` for words (what macOS terminals send for Option-arrow), and Alt-Enter for a newline,
/// since a terminal cannot tell Shift-Enter from Enter without the keyboard protocol few support.
fn command_for(code: KeyCode, modifiers: KeyModifiers) -> Key {
    let control = modifiers.contains(KeyModifiers::CONTROL);
    let alt = modifiers.contains(KeyModifiers::ALT);
    match code {
        KeyCode::Char('c' | 'd') if control => Key::Interrupt,
        KeyCode::Char('a') if control => Key::Edit(Edit::Home),
        KeyCode::Char('e') if control => Key::Edit(Edit::End),
        KeyCode::Char('u') if control => Key::Edit(Edit::KillToStart),
        KeyCode::Char('k') if control => Key::Edit(Edit::KillToEnd),
        KeyCode::Char('w') if control => Key::Edit(Edit::DeleteWordBefore),
        KeyCode::Char('b') if alt => Key::Edit(Edit::WordLeft),
        KeyCode::Char('f') if alt => Key::Edit(Edit::WordRight),
        KeyCode::Char('o') if control => Key::ToggleOutput,
        KeyCode::Char('t') if control => Key::ShowContext,
        KeyCode::Char(_) if control => Key::Nothing,
        KeyCode::Char(c) => Key::Type(c),
        KeyCode::Enter if alt => Key::Edit(Edit::Newline),
        KeyCode::Enter => Key::Submit,
        KeyCode::Backspace if alt || control => Key::Edit(Edit::DeleteWordBefore),
        KeyCode::Backspace => Key::Edit(Edit::Backspace),
        KeyCode::Delete => Key::Edit(Edit::Delete),
        KeyCode::Left if alt || control => Key::Edit(Edit::WordLeft),
        KeyCode::Right if alt || control => Key::Edit(Edit::WordRight),
        KeyCode::Left => Key::Edit(Edit::Left),
        KeyCode::Right => Key::Edit(Edit::Right),
        KeyCode::Home => Key::Edit(Edit::Home),
        KeyCode::End => Key::Edit(Edit::End),
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        KeyCode::Esc => Key::Cancel,
        KeyCode::Tab => Key::Complete,
        KeyCode::BackTab => Key::Previous,
        KeyCode::Up => Key::RecallPrevious,
        KeyCode::Down => Key::RecallNext,
        _ => Key::Nothing,
    }
}

/// One frame: the lines finished since the last go above the band, the band takes the height the
/// input needs, and the band is drawn.
fn paint(terminal: &mut ratatui::DefaultTerminal, app: &mut App, height: &mut u16) -> Result<()> {
    let width = terminal.size()?.width;
    for line in app.take_pending() {
        insert(terminal, &line, width)?;
    }
    if let Some(wanted) = next_height(*height, app.band_height(width), app.input_is_empty()) {
        regrow(terminal, wanted)?;
        *height = wanted;
    }
    terminal.draw(|frame| app.render(frame, frame.area()))?;
    Ok(())
}

/// Gives the band a new height. ratatui fixes an inline viewport's height when the terminal is made, so
/// the band is cleared, the cursor put at its top, and a terminal made afresh there: growing reserves
/// the new rows by scrolling when the band is at the bottom; shrinking leaves the band where it starts,
/// and the lines inserted above it later close the gap below.
fn regrow(terminal: &mut ratatui::DefaultTerminal, height: u16) -> Result<()> {
    let top = terminal.get_frame().area().as_position();
    terminal.clear()?;
    terminal.set_cursor_position(top)?;
    *terminal = Terminal::with_options(
        CrosstermBackend::new(std::io::stdout()),
        TerminalOptions {
            viewport: Viewport::Inline(height),
        },
    )?;
    Ok(())
}

/// Writes one history line into scrollback above the band, wrapped to the width.
fn insert(terminal: &mut ratatui::DefaultTerminal, line: &HistoryLine, width: u16) -> Result<()> {
    let rendered = styled(line);
    let inner = width.saturating_sub(MARGIN * 2).max(1);
    let shown: String = rendered
        .spans
        .iter()
        .map(|span| span.content.as_ref())
        .collect();
    let height = wrapped_height(&shown, inner);
    if let Some(tint) = sent_tint(line.kind) {
        // A sent line looks like the input it came from, a shade darker: its tint edge to edge, with
        // half-block strips above and below, since a terminal cannot tint less than a row. A command's line
        // has the command colour's darker shade (ADR 0049).
        terminal.insert_before(height + 2, move |buffer| {
            sent(buffer, rendered, width, inner, height, tint);
        })?;
        return Ok(());
    }
    terminal.insert_before(height, move |buffer| {
        Paragraph::new(rendered)
            .wrap(Wrap { trim: false })
            .render(Rect::new(MARGIN.min(width / 2), 0, inner, height), buffer);
    })?;
    Ok(())
}

/// The background and strip styles a sent line is drawn in: an ordinary prompt's on the sent tint, a
/// command's on the command colour's darker shade, an outside command's on the outside colour's, a help request's on
/// the help colour's; `None` for every other line.
fn sent_tint(kind: LineKind) -> Option<(Style, Style)> {
    match kind {
        LineKind::User => Some((palette::sent_background(), palette::sent_edge())),
        LineKind::Command => Some((
            palette::command_sent_background(),
            palette::command_sent_edge(),
        )),
        LineKind::Outside => Some((
            palette::outside_sent_background(),
            palette::outside_sent_edge(),
        )),
        LineKind::Help => Some((palette::help_sent_background(), palette::help_sent_edge())),
        _ => None,
    }
}

/// Draws a sent line into `buffer`: a `▄` strip, the text on its tint across the whole width, and a `▀`
/// strip; `tint` is the background and the strips' style.
fn sent(
    buffer: &mut ratatui::buffer::Buffer,
    text: Line<'static>,
    width: u16,
    inner: u16,
    height: u16,
    tint: (Style, Style),
) {
    let (background, edge) = tint;
    let strip = |glyph: &str| Paragraph::new(glyph.repeat(usize::from(width))).style(edge);
    strip("▄").render(Rect::new(0, 0, width, 1), buffer);
    Paragraph::new("")
        .style(background)
        .render(Rect::new(0, 1, width, height), buffer);
    Paragraph::new(text)
        .style(background)
        .wrap(Wrap { trim: false })
        .render(Rect::new(MARGIN.min(width / 2), 1, inner, height), buffer);
    strip("▀").render(Rect::new(0, height + 1, width, 1), buffer);
}

/// A history line in its colours; a reply's Markdown is rendered here, as the line is committed.
fn styled(line: &HistoryLine) -> Line<'static> {
    let style = match line.kind {
        LineKind::User | LineKind::Command | LineKind::Outside | LineKind::Help => palette::user(),
        LineKind::Reply => {
            return Line::from(
                markdown::spans(&line.text)
                    .into_iter()
                    .map(|(text, tone)| {
                        let style = match tone {
                            Tone::Plain => palette::body(),
                            Tone::Strong => palette::strong(),
                            Tone::Emphasis => palette::emphasis(),
                            Tone::Code => palette::code(),
                            Tone::Heading => palette::heading(),
                            Tone::Bullet => palette::muted(),
                        };
                        Span::styled(text, style)
                    })
                    .collect::<Vec<_>>(),
            );
        }
        LineKind::Code => palette::code(),
        LineKind::Output => palette::body(),
        LineKind::Tool | LineKind::Note => {
            if let Some((end, lead)) = lead(line.kind, &line.text) {
                let (head, rest) = line.text.split_at(end);
                return Line::from(vec![
                    Span::styled(head.to_string(), lead),
                    Span::styled(rest.to_string(), palette::muted()),
                ]);
            }
            palette::muted()
        }
        LineKind::ToolOutput | LineKind::Fence => palette::muted(),
        LineKind::Error => palette::ember(),
    };
    Line::from(Span::styled(line.text.clone(), style))
}

/// Where a line's lead ends, and its colour, so what happened stands apart from the muted rest: a tool call's `⚙` and
/// tool name in `WISP`, a stretch of thinking's `∴ thought` in `HELP`'s grey, and an answered or waiting approval's
/// `⚠` and words up to the colon in `AMBER`, or `EMBER` when it was refused. None for any other line.
fn lead(kind: LineKind, text: &str) -> Option<(usize, Style)> {
    let word = |glyph: &str| {
        let after = text.strip_prefix(glyph)?;
        Some(glyph.len() + after.find(' ').unwrap_or(after.len()))
    };
    match kind {
        LineKind::Tool if text.starts_with("⚙ ") => word("⚙ ").map(|end| (end, palette::wisp())),
        LineKind::Tool if text.starts_with("∴ ") => {
            word("∴ ").map(|end| (end, palette::thinking()))
        }
        LineKind::Tool | LineKind::Note if text.starts_with("⚠ ") => {
            let end = text.find(':')?;
            let style = if text[..end] == *"⚠ refused" {
                palette::ember()
            } else {
                palette::amber()
            };
            Some((end, style))
        }
        _ => None,
    }
}

/// Rows `text` takes at `width`, counting characters (wide glyphs may take one more).
fn wrapped_height(text: &str, width: u16) -> u16 {
    let width = usize::from(width.max(1));
    let rows: usize = text
        .split('\n')
        .map(|part| part.chars().count().max(1).div_ceil(width))
        .sum();
    rows.try_into().unwrap_or(u16::MAX).max(1)
}

#[cfg(test)]
mod tests {
    use super::Action;
    use super::{
        App, Edit, Incoming, Key, KeyCode, KeyModifiers, Outbound, Sequence, TermEvent,
        changes_the_band, command_for, next_height, post_notices, version_display,
        version_requested, wrapped_height,
    };
    use super::{CHILD_NAME, chat_command};
    use super::{Ending, exit_code, remaining_stderr, shut_down};
    use super::{HistoryLine, Line, LineKind, palette, styled};
    use super::{app::BarItem, app::DIALOG_GRACE, apply_key, protocol::Inbound};
    use ratatui::crossterm::event::{KeyEvent, KeyEventKind, KeyEventState};
    use std::os::unix::process::ExitStatusExt;
    use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    /// A stand-in for wisp: `sh -c script` with its stdin piped.
    fn fake_wisp(script: &str) -> std::io::Result<(Child, ChildStdin)> {
        let mut child = Command::new("/bin/sh")
            .arg("-c")
            .arg(script)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| std::io::Error::other("no stdin"))?;
        Ok((child, stdin))
    }

    #[test]
    fn quitting_sends_quit_and_waits_for_wisp_to_exit() -> std::io::Result<()> {
        // A wisp that leaves when told /quit, with a status of its own to show the line arrived.
        let (mut child, stdin) = fake_wisp(
            r#"while read -r line; do case "$line" in *'"/quit"'*) exit 7;; esac; done; exit 9"#,
        )?;
        let ending = shut_down(&mut child, Some(stdin), Duration::from_secs(10));
        assert!(
            matches!(&ending, Ending::Exited(status) if status.code() == Some(7)),
            "{ending:?}"
        );
        assert_eq!(exit_code(&ending), Some(7));
        Ok(())
    }

    #[test]
    fn quitting_closes_wisps_stdin_so_reading_to_the_end_ends_it() -> std::io::Result<()> {
        // One that ignores the line still reads the end of its input.
        let (mut child, stdin) = fake_wisp("cat >/dev/null; exit 0")?;
        let ending = shut_down(&mut child, Some(stdin), Duration::from_secs(10));
        assert!(matches!(&ending, Ending::Exited(status) if status.success()));
        assert_eq!(exit_code(&ending), None);
        Ok(())
    }

    #[test]
    fn a_wisp_that_does_not_exit_is_stopped_after_the_bound() -> std::io::Result<()> {
        let (mut child, stdin) = fake_wisp("exec sleep 30")?;
        let started = Instant::now();
        let ending = shut_down(&mut child, Some(stdin), Duration::from_millis(200));
        assert!(matches!(ending, Ending::Stopped), "{ending:?}");
        assert!(started.elapsed() < Duration::from_secs(5));
        // Reaped: nothing is left running.
        assert!(child.try_wait().is_ok_and(|status| status.is_some()));
        assert_eq!(exit_code(&ending), Some(1));
        Ok(())
    }

    /// The child is named `wisp chat (tui)` at spawn (ADR 0061). The stand-in for wisp is `/bin/sh`,
    /// which reads the script named by its first argument, `chat`, from its working directory; the
    /// script prints its own process's arguments as `ps` shows them.
    #[test]
    fn the_child_is_named_at_spawn() -> std::io::Result<()> {
        let folder = std::env::temp_dir().join(format!("wisp-tui-arg0-{}", std::process::id()));
        std::fs::create_dir_all(&folder)?;
        std::fs::write(folder.join("chat"), "ps -o args= -p $$\n")?;
        let mut command = chat_command("/bin/sh", &["--model".to_string(), "system".to_string()]);
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(args, ["chat", "--json", "--model", "system"]);
        assert_eq!(command.get_program(), "/bin/sh");
        let output = command.current_dir(&folder).stdin(Stdio::null()).output()?;
        std::fs::remove_dir_all(&folder)?;
        // Inside wisp's own sandbox (the hook run through run_command) ps is refused, so the
        // name cannot be read.
        if String::from_utf8_lossy(&output.stderr).contains("Operation not permitted") {
            eprintln!("the_child_is_named_at_spawn: ps cannot run here (a sandbox), skipped");
            return Ok(());
        }
        let shown = String::from_utf8_lossy(&output.stdout);
        assert_eq!(
            shown.trim_end(),
            format!("{CHILD_NAME} chat --json --model system")
        );
        Ok(())
    }

    #[test]
    fn the_rest_of_stderr_is_read_to_its_end() {
        let (tx, rx) = mpsc::channel();
        for incoming in [
            Incoming::Line("{}".into()),
            Incoming::Stderr("error: no such model".into()),
            Incoming::Stderr("see wisp models".into()),
            Incoming::StderrClosed,
            Incoming::Stderr("after the end".into()),
        ] {
            assert!(tx.send(incoming).is_ok());
        }
        assert_eq!(
            remaining_stderr(&rx, Duration::from_secs(5)),
            vec!["error: no such model", "see wisp models"]
        );
        // Without its end, the wait is bounded.
        let started = Instant::now();
        let (_tx, quiet) = mpsc::channel();
        assert_eq!(
            remaining_stderr(&quiet, Duration::from_millis(50)),
            Vec::<String>::new()
        );
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn wisp_tui_leaves_with_wisps_status_when_it_failed() {
        assert_eq!(exit_code(&Ending::Exited(ExitStatus::from_raw(0))), None);
        assert_eq!(
            exit_code(&Ending::Exited(ExitStatus::from_raw(64 << 8))),
            Some(64)
        );
        // Killed by a signal: no code of its own.
        assert_eq!(exit_code(&Ending::Exited(ExitStatus::from_raw(9))), Some(1));
    }

    #[test]
    fn only_what_can_change_the_band_redraws_it() {
        let key = |kind| {
            Incoming::Terminal(TermEvent::Key(KeyEvent {
                code: KeyCode::Char('x'),
                modifiers: KeyModifiers::NONE,
                kind,
                state: KeyEventState::NONE,
            }))
        };
        assert!(!changes_the_band(None));
        assert!(!changes_the_band(Some(&key(KeyEventKind::Release))));
        assert!(!changes_the_band(Some(&Incoming::Terminal(
            TermEvent::FocusGained
        ))));
        assert!(changes_the_band(Some(&key(KeyEventKind::Press))));
        assert!(changes_the_band(Some(&Incoming::Terminal(
            TermEvent::Resize(80, 24)
        ))));
        assert!(changes_the_band(Some(&Incoming::Terminal(
            TermEvent::Paste("p".into())
        ))));
        assert!(changes_the_band(Some(&Incoming::Line("{}".into()))));
        assert!(changes_the_band(Some(&Incoming::Stderr("note".into()))));
        assert!(changes_the_band(Some(&Incoming::Closed)));
    }

    #[test]
    fn the_band_grows_at_once_and_shrinks_only_when_the_input_is_empty() {
        assert_eq!(next_height(6, 8, false), Some(8));
        assert_eq!(next_height(8, 7, false), None);
        assert_eq!(next_height(8, 6, true), Some(6));
        assert_eq!(next_height(6, 6, true), None);
    }

    #[test]
    fn keys_map_to_the_edits_a_terminal_user_expects() {
        let none = KeyModifiers::NONE;
        let ctrl = KeyModifiers::CONTROL;
        let alt = KeyModifiers::ALT;
        assert_eq!(command_for(KeyCode::Char('x'), none), Key::Type('x'));
        assert_eq!(
            command_for(KeyCode::Char('X'), KeyModifiers::SHIFT),
            Key::Type('X')
        );
        assert_eq!(command_for(KeyCode::Char('c'), ctrl), Key::Interrupt);
        assert_eq!(command_for(KeyCode::Char('d'), ctrl), Key::Interrupt);
        assert_eq!(command_for(KeyCode::Char('a'), ctrl), Key::Edit(Edit::Home));
        assert_eq!(command_for(KeyCode::Char('e'), ctrl), Key::Edit(Edit::End));
        assert_eq!(
            command_for(KeyCode::Char('u'), ctrl),
            Key::Edit(Edit::KillToStart)
        );
        assert_eq!(
            command_for(KeyCode::Char('k'), ctrl),
            Key::Edit(Edit::KillToEnd)
        );
        assert_eq!(
            command_for(KeyCode::Char('w'), ctrl),
            Key::Edit(Edit::DeleteWordBefore)
        );
        assert_eq!(command_for(KeyCode::Char('z'), ctrl), Key::Nothing);
        assert_eq!(
            command_for(KeyCode::Char('b'), alt),
            Key::Edit(Edit::WordLeft)
        );
        assert_eq!(
            command_for(KeyCode::Char('f'), alt),
            Key::Edit(Edit::WordRight)
        );
        assert_eq!(command_for(KeyCode::Enter, none), Key::Submit);
        assert_eq!(command_for(KeyCode::Enter, alt), Key::Edit(Edit::Newline));
        assert_eq!(
            command_for(KeyCode::Backspace, none),
            Key::Edit(Edit::Backspace)
        );
        assert_eq!(
            command_for(KeyCode::Backspace, alt),
            Key::Edit(Edit::DeleteWordBefore)
        );
        assert_eq!(command_for(KeyCode::Delete, none), Key::Edit(Edit::Delete));
        assert_eq!(command_for(KeyCode::Left, none), Key::Edit(Edit::Left));
        assert_eq!(command_for(KeyCode::Right, alt), Key::Edit(Edit::WordRight));
        assert_eq!(command_for(KeyCode::Left, ctrl), Key::Edit(Edit::WordLeft));
        assert_eq!(command_for(KeyCode::Home, none), Key::Edit(Edit::Home));
        assert_eq!(command_for(KeyCode::End, none), Key::Edit(Edit::End));
        assert_eq!(command_for(KeyCode::Up, none), Key::RecallPrevious);
        assert_eq!(command_for(KeyCode::Down, none), Key::RecallNext);
        assert_eq!(command_for(KeyCode::F(1), none), Key::Nothing);
        assert_eq!(command_for(KeyCode::Tab, none), Key::Complete);
        assert_eq!(command_for(KeyCode::Esc, none), Key::Cancel);
        assert_eq!(command_for(KeyCode::Char('o'), ctrl), Key::ToggleOutput);
        assert_eq!(command_for(KeyCode::Char('t'), ctrl), Key::ShowContext);
        assert_eq!(command_for(KeyCode::Char('t'), none), Key::Type('t'));
        assert_eq!(command_for(KeyCode::PageUp, none), Key::PageUp);
        assert_eq!(command_for(KeyCode::PageDown, none), Key::PageDown);
    }

    #[test]
    fn replies_are_committed_with_their_markdown_rendered() {
        let line = |text: &str, kind| HistoryLine {
            text: text.into(),
            kind,
        };
        let text = |rendered: &Line| -> String {
            rendered
                .spans
                .iter()
                .map(|span| span.content.as_ref())
                .collect()
        };
        let reply = styled(&line("Use `git log` **now**", LineKind::Reply));
        assert_eq!(text(&reply), "Use git log now");
        assert_eq!(reply.spans[1].style, palette::code());
        assert_eq!(reply.spans[3].style, palette::strong());
        // Code and everything that is not a reply keep their text as it is.
        let code = styled(&line("let **x** = 1", LineKind::Code));
        assert_eq!(
            (text(&code), code.spans[0].style),
            ("let **x** = 1".into(), palette::code())
        );
        assert_eq!(text(&styled(&line("`raw`", LineKind::Tool))), "`raw`");
    }

    #[test]
    fn what_happened_leads_its_line_in_its_own_colour() {
        let spans = |text: &str, kind| -> Vec<(String, ratatui::style::Style)> {
            styled(&HistoryLine {
                text: text.into(),
                kind,
            })
            .spans
            .iter()
            .map(|span| (span.content.to_string(), span.style))
            .collect()
        };
        let muted = palette::muted();
        assert_eq!(
            spans("⚙ edit_file append /tmp/a", LineKind::Tool),
            [
                ("⚙ edit_file".into(), palette::wisp()),
                (" append /tmp/a".into(), muted)
            ]
        );
        assert_eq!(
            spans("∴ thought for 3.3 s, 13 tokens", LineKind::Tool),
            [
                ("∴ thought".into(), palette::thinking()),
                (" for 3.3 s, 13 tokens".into(), muted)
            ]
        );
        assert_eq!(
            spans("⚠ approved for this turn: git push", LineKind::Note),
            [
                ("⚠ approved for this turn".into(), palette::amber()),
                (": git push".into(), muted)
            ]
        );
        assert_eq!(
            spans("⚠ refused: git push", LineKind::Note),
            [
                ("⚠ refused".into(), palette::ember()),
                (": git push".into(), muted)
            ]
        );
        assert_eq!(
            spans("⚙ read_file", LineKind::Tool),
            [
                ("⚙ read_file".into(), palette::wisp()),
                (String::new(), muted)
            ]
        );
        // A result, a step, and a tool's output stay muted throughout.
        for (text, kind) in [
            ("  ↳ exit 0", LineKind::Tool),
            ("   · safe by rules", LineKind::Tool),
            ("⚙ not a call", LineKind::ToolOutput),
            ("⚠ no colon here", LineKind::Note),
        ] {
            assert_eq!(spans(text, kind), [(text.to_string(), muted)], "{text}");
        }
    }

    #[test]
    fn a_sent_line_sits_on_its_tint_between_half_block_strips() {
        let mut buffer = ratatui::buffer::Buffer::empty(ratatui::layout::Rect::new(0, 0, 12, 3));
        let text = styled(&HistoryLine {
            text: "› hi".into(),
            kind: LineKind::User,
        });
        super::sent(
            &mut buffer,
            text,
            12,
            10,
            1,
            (palette::sent_background(), palette::sent_edge()),
        );
        let row = |y: u16| {
            (0..12)
                .map(|x| buffer[(x, y)].symbol().to_string())
                .collect::<String>()
        };
        assert_eq!(row(0), "▄".repeat(12));
        assert_eq!(row(1).trim_end(), " › hi");
        assert_eq!(row(2), "▀".repeat(12));
        assert_eq!(
            buffer[(11, 1)].bg,
            palette::SENT,
            "the tint runs edge to edge"
        );
        assert_eq!(buffer[(0, 0)].fg, palette::SENT);
    }

    #[test]
    fn a_commands_line_sits_on_the_command_colours_darker_shade_in_light_text() {
        let line = HistoryLine {
            text: "! git status".into(),
            kind: LineKind::Command,
        };
        let text = styled(&line);
        assert_eq!(text.spans[0].style, palette::user());
        let tint = super::sent_tint(LineKind::Command)
            .unwrap_or((palette::sent_background(), palette::sent_edge()));
        let mut buffer = ratatui::buffer::Buffer::empty(ratatui::layout::Rect::new(0, 0, 16, 3));
        super::sent(&mut buffer, text, 16, 14, 1, tint);
        assert_eq!(buffer[(15, 1)].bg, palette::COMMAND_SENT);
        assert_eq!(buffer[(1, 1)].fg, palette::WHITE);
        assert_eq!(buffer[(0, 0)].fg, palette::COMMAND_SENT);
        assert_eq!(buffer[(0, 2)].fg, palette::COMMAND_SENT);
        assert_eq!(
            super::sent_tint(LineKind::User),
            Some((palette::sent_background(), palette::sent_edge()))
        );
        assert_eq!(super::sent_tint(LineKind::Note), None);
        // An outside command's line sits on the outside colour's darker shade, in the same light text.
        let outside = HistoryLine {
            text: "!! brew upgrade".into(),
            kind: LineKind::Outside,
        };
        let text = styled(&outside);
        assert_eq!(text.spans[0].style, palette::user());
        let tint = super::sent_tint(LineKind::Outside)
            .unwrap_or((palette::sent_background(), palette::sent_edge()));
        let mut buffer = ratatui::buffer::Buffer::empty(ratatui::layout::Rect::new(0, 0, 16, 3));
        super::sent(&mut buffer, text, 16, 14, 1, tint);
        assert_eq!(buffer[(15, 1)].bg, palette::OUTSIDE_SENT);
        assert_eq!(buffer[(1, 1)].fg, palette::WHITE);
        assert_eq!(buffer[(0, 0)].fg, palette::OUTSIDE_SENT);
        assert_eq!(buffer[(0, 2)].fg, palette::OUTSIDE_SENT);
        // A help request's line sits on the help colour's darker shade, a dark grey.
        let help = HistoryLine {
            text: "? models".into(),
            kind: LineKind::Help,
        };
        let text = styled(&help);
        assert_eq!(text.spans[0].style, palette::user());
        let tint = super::sent_tint(LineKind::Help)
            .unwrap_or((palette::sent_background(), palette::sent_edge()));
        let mut buffer = ratatui::buffer::Buffer::empty(ratatui::layout::Rect::new(0, 0, 16, 3));
        super::sent(&mut buffer, text, 16, 14, 1, tint);
        assert_eq!(buffer[(15, 1)].bg, palette::HELP_SENT);
        assert_eq!(buffer[(0, 0)].fg, palette::HELP_SENT);
    }

    #[test]
    fn notices_are_written_after_the_frame_and_only_once() {
        let mut app = App::default();
        app.handle(Outbound::parse(
            r#"{"type":"notify","title":"Build","subtitle":null,"body":"done","sound":false}"#,
        ));
        // A notify line changes nothing on screen but is a line, so a frame is painted and the notice
        // written after it.
        assert!(changes_the_band(Some(&Incoming::Line(String::new()))));
        let mut out = Vec::new();
        let mut posted = 0;
        post_notices(&mut out, &mut app, Some(Sequence::Osc9), &mut posted);
        assert_eq!(out, b"\x1b]9;Build: done\x07");
        post_notices(&mut out, &mut app, Some(Sequence::Osc9), &mut posted);
        assert_eq!(out.len(), b"\x1b]9;Build: done\x07".len(), "drained");
        // Without a sequence nothing is written, and the queue still drains.
        app.handle(Outbound::parse(
            r#"{"type":"notify","title":"t","body":"b"}"#,
        ));
        let mut none = Vec::new();
        post_notices(&mut none, &mut app, None, &mut posted);
        assert!(none.is_empty() && app.notices.is_empty());
    }

    #[test]
    fn version_display_covers_release_clean_modified_and_unknown() {
        assert_eq!(version_display("1.2.3", "abc1234", true, true), "1.2.3");
        assert_eq!(version_display("1.2.3", "", false, true), "1.2.3");
        assert_eq!(
            version_display("1.2.3", "abc1234", false, false),
            "1.2.3-dev+abc1234"
        );
        assert_eq!(
            version_display("1.2.3", "abc1234", true, false),
            "1.2.3-dev+abc1234 (modified)"
        );
        assert_eq!(version_display("1.2.3", "", true, false), "1.2.3-dev");
    }

    #[test]
    fn version_is_only_the_bare_flag() {
        assert!(version_requested(&["--version".to_string()]));
        assert!(version_requested(&["-V".to_string()]));
        assert!(!version_requested(&[
            "--model".to_string(),
            "--version".to_string()
        ]));
        assert!(!version_requested(&[]));
    }

    #[test]
    fn wrapped_height_counts_rows() {
        assert_eq!(wrapped_height("", 10), 1);
        assert_eq!(wrapped_height("short", 10), 1);
        assert_eq!(wrapped_height("exactly ten", 11), 1);
        assert_eq!(wrapped_height("twelve chars", 10), 2);
        assert_eq!(wrapped_height("a\nb", 10), 2);
    }

    /// A chat at its prompt: a status with a context gauge, so the bar has its model and gauge.
    fn at_the_prompt() -> App {
        let mut app = App::default();
        app.handle(Outbound::parse(
            r#"{"type":"status","model":"system","directory":"~/x","approval":"ask","contextUsed":0.2}"#,
        ));
        app
    }

    fn typed(app: &mut App, text: &str) {
        for c in text.chars() {
            apply_key(app, Key::Type(c));
        }
    }

    fn mcp_approval(id: &str) -> Outbound {
        Outbound::parse(&format!(
            r#"{{"type":"approval","id":"{id}","command":"git push","line":"git push","pattern":"git push *","directory":"/r","level":"moderate","reasons":[],"source":"mcp"}}"#
        ))
    }

    fn mcp_question(id: &str) -> Outbound {
        Outbound::parse(&format!(
            r#"{{"type":"choice","id":"{id}","title":"Which config?","options":[{{"value":"a","label":"a"}},{{"value":"b","label":"b"}}],"current":null,"acceptsText":false,"kind":"question","source":"mcp"}}"#
        ))
    }

    #[test]
    fn down_from_the_inputs_last_row_focuses_the_model_and_up_or_esc_returns() {
        // An empty box, and a one-line one, are on their last row.
        let mut app = at_the_prompt();
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(app.focused(), Some(BarItem::Model));
        apply_key(&mut app, Key::RecallPrevious);
        assert_eq!(app.focused(), None);
        typed(&mut app, "hello");
        apply_key(&mut app, Key::Edit(Edit::Left));
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(app.focused(), Some(BarItem::Model));
        // Down again stays; Esc returns with the line and its cursor as they were.
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(app.focused(), Some(BarItem::Model));
        apply_key(&mut app, Key::Cancel);
        assert_eq!(app.focused(), None);
        assert_eq!(
            (app.editor.text(), app.editor.cursor()),
            ("hello".into(), 4)
        );
        // Before wisp's first status there is no bar to go to.
        let mut connecting = App::default();
        apply_key(&mut connecting, Key::RecallNext);
        assert_eq!(connecting.focused(), None);
    }

    #[test]
    fn down_from_an_upper_row_moves_the_cursor_not_the_focus() {
        let mut app = at_the_prompt();
        typed(&mut app, "first");
        apply_key(&mut app, Key::Edit(Edit::Newline));
        typed(&mut app, "second");
        apply_key(&mut app, Key::Edit(Edit::Home));
        assert_eq!(app.editor.cursor(), 0);
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(app.focused(), None, "the cursor went down a row");
        assert_eq!(app.editor.cursor(), 6);
        // Up from the second row goes back up, not to an earlier line.
        apply_key(&mut app, Key::RecallPrevious);
        assert_eq!(app.editor.cursor(), 0);
        assert_eq!(app.editor.text(), "first\nsecond");
        // From the last row, the bar.
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(app.focused(), Some(BarItem::Model));
    }

    #[test]
    fn left_right_tab_home_and_end_move_between_the_items_in_order() {
        let mut app = at_the_prompt();
        typed(&mut app, "draft");
        app.handle(mcp_question("mcp-q1"));
        app.handle(mcp_approval("mcp-1"));
        app.handle(Outbound::parse(
            r#"{"type":"turn","phase":"end","turn":1,"seconds":1.5,"outcome":"ok"}"#,
        ));
        assert_eq!(
            app.bar_items(),
            vec![
                BarItem::Model,
                BarItem::Context,
                BarItem::Questions,
                BarItem::Approvals,
                BarItem::Turn
            ]
        );
        apply_key(&mut app, Key::RecallNext);
        let mut seen = vec![app.focused()];
        for _ in 0..5 {
            apply_key(&mut app, Key::Edit(Edit::Right));
            seen.push(app.focused());
        }
        // Right stops at the last.
        assert_eq!(
            seen,
            [
                BarItem::Model,
                BarItem::Context,
                BarItem::Questions,
                BarItem::Approvals,
                BarItem::Turn,
                BarItem::Turn
            ]
            .map(Some)
        );
        apply_key(&mut app, Key::Edit(Edit::Left));
        assert_eq!(app.focused(), Some(BarItem::Approvals));
        apply_key(&mut app, Key::Edit(Edit::WordLeft));
        assert_eq!(app.focused(), Some(BarItem::Questions));
        // Tab and Shift-Tab wrap around; Home and End go to the ends.
        apply_key(&mut app, Key::Edit(Edit::End));
        apply_key(&mut app, Key::Complete);
        assert_eq!(app.focused(), Some(BarItem::Model));
        apply_key(&mut app, Key::Previous);
        assert_eq!(app.focused(), Some(BarItem::Turn));
        apply_key(&mut app, Key::Edit(Edit::Home));
        assert_eq!(app.focused(), Some(BarItem::Model));
        // Left at the first stays; the draft never changed.
        apply_key(&mut app, Key::Edit(Edit::Left));
        assert_eq!(app.focused(), Some(BarItem::Model));
        assert_eq!(app.editor.text(), "draft");
    }

    #[test]
    fn a_key_typed_in_the_bar_returns_to_the_input_and_goes_in() {
        let mut app = at_the_prompt();
        typed(&mut app, "hell");
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(apply_key(&mut app, Key::Type('o')), Action::None);
        assert_eq!(app.focused(), None);
        assert_eq!(app.editor.text(), "hello");
        // An edit does the same, and so does a paste.
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::Edit(Edit::Backspace));
        assert_eq!((app.focused(), app.editor.text()), (None, "hell".into()));
        apply_key(&mut app, Key::RecallNext);
        app.edit(&Edit::Paste("o!".into()));
        assert_eq!((app.focused(), app.editor.text()), (None, "hello!".into()));
        // Ctrl-C with nothing open quits from the bar as from the input.
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(apply_key(&mut app, Key::Interrupt), Action::Quit);
    }

    #[test]
    fn enter_or_space_on_the_model_sends_what_slash_model_sends() {
        let mut app = at_the_prompt();
        typed(&mut app, "a draft");
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(
            apply_key(&mut app, Key::Submit),
            Action::Send(Inbound::Message {
                text: "/model".into()
            })
        );
        // The focus is back on the input, held while wisp answers, and nothing was echoed or recalled.
        assert!(app.busy && app.focused().is_none());
        assert!(app.take_pending().is_empty() && app.recall.is_empty());
        // wisp's picker opens over the box with the draft parked, and the draft is back once it is answered.
        app.handle(Outbound::parse(
            r#"{"type":"choice","id":"c1","title":"Switch to which model?","options":[{"value":"system","label":"system"},{"value":"ollama:q","label":"ollama:q"}],"current":"system","acceptsText":false}"#,
        ));
        assert!(app.picker.is_some() && app.editor.is_empty());
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(
            apply_key(&mut app, Key::Submit),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: Some("ollama:q".into()),
                values: None
            })
        );
        assert_eq!(app.editor.text(), "a draft");
        app.handle(Outbound::parse(
            r#"{"type":"status","model":"ollama:q","directory":"~/x","approval":"ask"}"#,
        ));
        // Space opens it too.
        apply_key(&mut app, Key::RecallNext);
        assert!(matches!(
            apply_key(&mut app, Key::Type(' ')),
            Action::Send(Inbound::Message { .. })
        ));
        assert_eq!(app.editor.text(), "a draft", "the space is not typed");
    }

    #[test]
    fn enter_on_questions_opens_the_first_waiting_questions_picker() {
        let mut app = at_the_prompt();
        typed(&mut app, "draft");
        app.handle(mcp_question("mcp-q1"));
        app.handle(mcp_question("mcp-q2"));
        assert!(app.picker.is_none() && app.questions_waiting() == 2);
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::Edit(Edit::Right));
        apply_key(&mut app, Key::Edit(Edit::Right));
        assert_eq!(app.focused(), Some(BarItem::Questions));
        // Opening answers nothing.
        assert_eq!(apply_key(&mut app, Key::Submit), Action::None);
        assert_eq!(
            app.picker.as_ref().map(|picker| picker.choice.id.as_str()),
            Some("mcp-q1")
        );
        assert_eq!(
            app.questions_waiting(),
            2,
            "the one shown and the one behind"
        );
        // Answered with the picker's own keys; the draft comes back, and the next one waits behind it again.
        assert_eq!(
            apply_key(&mut app, Key::Submit),
            Action::Send(Inbound::Choose {
                id: "mcp-q1".into(),
                value: Some("a".into()),
                values: None
            })
        );
        assert_eq!(app.editor.text(), "draft");
        assert!(app.picker.is_none() && app.questions_waiting() == 1);
    }

    #[test]
    fn enter_on_approvals_opens_the_dialog_in_its_grace_so_focus_never_answers_it() {
        let mut app = at_the_prompt();
        typed(&mut app, "draft");
        app.handle(mcp_approval("mcp-1"));
        assert!(app.approval.is_none() && app.approvals_waiting() == 1);
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::Edit(Edit::End));
        assert_eq!(app.focused(), Some(BarItem::Approvals));
        assert_eq!(apply_key(&mut app, Key::Submit), Action::None);
        assert_eq!(app.approval.as_ref().map(|a| a.id.as_str()), Some("mcp-1"));
        // A key at once, even an answer's letter, is held for the box, as for a dialog that arrives.
        assert_eq!(apply_key(&mut app, Key::Type('y')), Action::None);
        assert!(app.approval.is_some());
        app.clock.advance(DIALOG_GRACE);
        assert_eq!(
            apply_key(&mut app, Key::Type('n')),
            Action::Send(Inbound::Answer {
                id: "mcp-1".into(),
                decision: "no".into()
            })
        );
        assert_eq!(app.editor.text(), "drafty");
        assert_eq!(app.focused(), None);
    }

    #[test]
    fn a_dialog_arriving_while_the_bar_has_the_focus_takes_it_and_waits_out_its_grace() {
        let mut app = at_the_prompt();
        apply_key(&mut app, Key::RecallNext);
        assert_eq!(app.focused(), Some(BarItem::Model));
        // With the box empty a request from wisp mcp opens at once, over the bar's focus.
        app.handle(mcp_approval("mcp-2"));
        assert!(app.approval.is_some());
        assert_eq!(app.focused(), None);
        assert_eq!(apply_key(&mut app, Key::Submit), Action::None);
        assert_eq!(apply_key(&mut app, Key::Type(' ')), Action::None);
        assert_eq!(apply_key(&mut app, Key::Type('y')), Action::None);
        assert!(app.approval.is_some(), "nothing answered it");
        // Once it closes the focus is the input's.
        assert_eq!(
            apply_key(&mut app, Key::Interrupt),
            Action::Send(Inbound::Answer {
                id: "mcp-2".into(),
                decision: "no".into()
            })
        );
        assert_eq!(app.focused(), None);
    }

    #[test]
    fn the_gauge_and_the_last_turn_open_the_context_and_the_turn_list() {
        let mut app = at_the_prompt();
        app.handle(Outbound::parse(
            r#"{"type":"turn","phase":"end","turn":1,"seconds":1.5,"outcome":"ok"}"#,
        ));
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::Edit(Edit::Right));
        assert_eq!(app.focused(), Some(BarItem::Context));
        assert_eq!(
            apply_key(&mut app, Key::Submit),
            Action::Send(Inbound::Message {
                text: "/inspect context next".into()
            })
        );
        app.handle(Outbound::parse(
            r#"{"type":"view","kind":"context","turn":null,"turns":1,"text":"ctx"}"#,
        ));
        assert!(app.panel.is_some());
        apply_key(&mut app, Key::Cancel);
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::Edit(Edit::End));
        assert_eq!(app.focused(), Some(BarItem::Turn));
        assert_eq!(
            apply_key(&mut app, Key::Submit),
            Action::Send(Inbound::Message {
                text: "/inspect context turns".into()
            })
        );
    }

    #[test]
    fn questions_and_approvals_are_items_only_while_something_waits() {
        let mut app = at_the_prompt();
        assert_eq!(app.bar_items(), vec![BarItem::Model, BarItem::Context]);
        apply_key(&mut app, Key::RecallNext);
        apply_key(&mut app, Key::Edit(Edit::End));
        assert_eq!(app.focused(), Some(BarItem::Context));
        // Without a gauge, the model alone.
        let mut bare = App::default();
        bare.handle(Outbound::parse(
            r#"{"type":"status","model":"system","directory":"~/x","approval":"ask"}"#,
        ));
        assert_eq!(bare.bar_items(), vec![BarItem::Model]);
        // A waiting question withdrawn while it has the focus: the focus falls back to the model.
        let mut gone = at_the_prompt();
        typed(&mut gone, "x");
        gone.handle(mcp_question("mcp-q9"));
        apply_key(&mut gone, Key::RecallNext);
        apply_key(&mut gone, Key::Edit(Edit::End));
        assert_eq!(gone.focused(), Some(BarItem::Questions));
        gone.handle(Outbound::parse(r#"{"type":"withdrawn","id":"mcp-q9"}"#));
        assert_eq!(gone.bar_items(), vec![BarItem::Model, BarItem::Context]);
        assert_eq!(gone.focused(), Some(BarItem::Model));
        assert_eq!(
            apply_key(&mut gone, Key::Submit),
            Action::Send(Inbound::Message {
                text: "/model".into()
            })
        );
    }

    #[test]
    fn shift_tab_is_the_bars_previous_item_and_nothing_in_the_input() {
        assert_eq!(
            command_for(KeyCode::BackTab, KeyModifiers::SHIFT),
            Key::Previous
        );
        let mut app = at_the_prompt();
        typed(&mut app, "x");
        assert_eq!(apply_key(&mut app, Key::Previous), Action::None);
        assert_eq!(app.editor.text(), "x");
    }
}
