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
use std::process::{Child, Command, Stdio};
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
    stdin.write_all(Inbound::hello(sequence.is_some()).line().as_bytes())?;
    stdin.flush()?;
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
    let _ = child.wait();
    result
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

/// Starts `wisp chat --json` with the given extra arguments.
fn spawn(args: &[String]) -> Result<Child> {
    let bin = std::env::var("WISP_BIN").unwrap_or_else(|_| "wisp".to_string());
    Command::new(&bin)
        .arg("chat")
        .arg("--json")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
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
                let action = match command_for(key.code, key.modifiers) {
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
                    Key::Nothing => Action::None,
                };
                match action {
                    Action::None => {}
                    Action::Send(inbound) => {
                        stdin.write_all(inbound.line().as_bytes())?;
                        stdin.flush()?;
                    }
                    Action::Quit => return Ok(()),
                }
            }
            Some(Incoming::Terminal(_)) | None => {}
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
        None => false,
        Some(Incoming::Terminal(TermEvent::Key(key))) => key.kind == KeyEventKind::Press,
        Some(Incoming::Terminal(event)) => {
            matches!(event, TermEvent::Paste(_) | TermEvent::Resize(..))
        }
        Some(Incoming::Line(_) | Incoming::Stderr(_) | Incoming::Closed) => true,
    }
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
    /// Tab: complete the slash command being typed.
    Complete,
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
/// command's on the command colour's darker shade; `None` for every other line.
fn sent_tint(kind: LineKind) -> Option<(Style, Style)> {
    match kind {
        LineKind::User => Some((palette::sent_background(), palette::sent_edge())),
        LineKind::Command => Some((
            palette::command_sent_background(),
            palette::command_sent_edge(),
        )),
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
        LineKind::User | LineKind::Command => palette::user(),
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
        LineKind::Tool | LineKind::ToolOutput | LineKind::Note | LineKind::Fence => {
            palette::muted()
        }
        LineKind::Error => palette::ember(),
    };
    Line::from(Span::styled(line.text.clone(), style))
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
    use super::{
        App, Edit, Incoming, Key, KeyCode, KeyModifiers, Outbound, Sequence, TermEvent,
        changes_the_band, command_for, next_height, post_notices, version_display,
        version_requested, wrapped_height,
    };
    use super::{HistoryLine, Line, LineKind, palette, styled};
    use ratatui::crossterm::event::{KeyEvent, KeyEventKind, KeyEventState};

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
}
