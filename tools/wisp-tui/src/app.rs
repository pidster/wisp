//! The front end's state and rendering: finished lines go above into the terminal's own scrollback,
//! the band at the bottom holds the reply in progress, the input or an approval dialog, and the status.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Padding, Paragraph};
use std::cell::Cell;
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use unicode_width::UnicodeWidthChar;

use crate::editor::{Edit, Editor};
use crate::markdown;
use crate::palette;
use crate::picker::Picker;
use crate::protocol::{Approval, Inbound, Notice, Outbound, Status, ToolOutput, Turn, View};

/// Rows the band occupies with a one-row input: reply in progress, dialog, a half-height strip, the
/// input, a half-height strip, status. The strips are rows of half-block glyphs in the tint, which read
/// as half a line of padding above and below the input; a terminal cannot tint less than a row. The
/// input grows by a row for each further row its text needs, up to `MAX_INPUT_ROWS`.
pub const BAND_HEIGHT: u16 = 6;
/// The band row the input's first row sits on.
pub const INPUT_ROW: u16 = 3;
/// The band row the status sits on with a one-row input; it is always the band's last row.
#[cfg(test)]
pub const STATUS_ROW: u16 = 5;
/// Rows the input grows to at most; longer text scrolls within them, keeping the cursor's row in sight.
pub const MAX_INPUT_ROWS: u16 = 6;
/// Cells the prompt (`› `) takes; continuation rows are indented to match.
const PROMPT_CELLS: usize = 2;
/// Cells of margin on each side of the band and of every committed line.
pub const MARGIN: u16 = 1;
/// The input row's placeholder when nothing is typed.
pub const PLACEHOLDER: &str = "Ask wisp to do anything";
/// The placeholder in command mode, where what is typed runs as a shell command (ADR 0049).
pub const COMMAND_PLACEHOLDER: &str =
    "Run a command yourself: sandboxed, no approval, the model is told";
/// How many submitted lines Up and Down can recall; the same bound as the chat's `/history`.
pub const RECALL_LIMIT: usize = 100;

/// A line committed to scrollback, with its style.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryLine {
    /// The text.
    pub text: String,
    /// How it is drawn.
    pub kind: LineKind,
}

/// What a history line is, for styling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    /// The user's own input, echoed.
    User,
    /// A command the user ran from command mode, echoed with its `!` (ADR 0049).
    Command,
    /// The model's reply, in the little Markdown `markdown::spans` renders.
    Reply,
    /// A line inside a fenced block of a reply, shown as it is.
    Code,
    /// A fence opening or closing a block.
    Fence,
    /// A tool call or result.
    Tool,
    /// A note from wisp.
    Note,
    /// An error.
    Error,
    /// Output of a slash command.
    Output,
    /// A tool's output, indented under its result line, and the fold line after it.
    ToolOutput,
}

/// Text rows the output and context panel shows at most.
pub const PANEL_ROWS: usize = 16;

/// What the panel over the band shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PanelKind {
    /// The last tool output, in full.
    Output,
    /// The model's context: for the turn, or `None` for the next request.
    Context(Option<u64>),
    /// The table of turns.
    Turns,
    /// The facts the model is given (`/inspect facts`).
    Facts,
    /// The running summary of earlier turns (`/inspect summary`).
    Summary,
    /// The model's thinking (`/inspect thinking`, ADR 0053): every turn's, or one turn's.
    Thinking(Option<u64>),
}

/// A panel over the band: text to scroll, opened by Ctrl-O or by a view from wisp.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Panel {
    /// What it shows.
    pub kind: PanelKind,
    /// The text, unwrapped.
    pub text: String,
    /// The first row shown, of the wrapped text.
    pub scroll: usize,
    /// How many turns the conversation has had, for stepping through them.
    pub turns: u64,
}

impl Panel {
    /// The title on the top border.
    fn title(&self) -> String {
        match self.kind {
            PanelKind::Output => " output ".into(),
            PanelKind::Context(None) => " context · next request ".into(),
            PanelKind::Context(Some(turn)) => format!(" context · turn {turn} "),
            PanelKind::Turns => " context · turns ".into(),
            PanelKind::Facts => " facts ".into(),
            PanelKind::Summary => " summary ".into(),
            PanelKind::Thinking(None) => " thinking ".into(),
            PanelKind::Thinking(Some(turn)) => format!(" thinking · turn {turn} "),
        }
    }

    /// The keys, on the bottom border.
    fn hint(&self) -> &'static str {
        if matches!(self.kind, PanelKind::Context(_)) {
            " ↑↓ scroll · ←→ turns · esc close "
        } else {
            " ↑↓ scroll · esc close "
        }
    }
}

/// `text` as rows of at most `width` cells: control characters dropped and tabs spaced, long lines
/// broken at the width.
fn wrap_rows(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut rows = Vec::new();
    for line in text.lines() {
        let line = sanitise(line);
        let mut row = String::new();
        let mut cells = 0;
        for c in line.chars() {
            let w = c.width().unwrap_or(0);
            if cells + w > width {
                rows.push(std::mem::take(&mut row));
                cells = 0;
            }
            row.push(c);
            cells += w;
        }
        rows.push(row);
    }
    if rows.is_empty() {
        rows.push(String::new());
    }
    rows
}

/// `line` with tabs as four spaces and other control characters (an escape sequence's start) removed,
/// so tool output cannot drive the terminal.
fn sanitise(line: &str) -> String {
    line.chars()
        .filter_map(|c| match c {
            '\t' => Some("    ".to_string()),
            c if c.is_control() => None,
            c => Some(c.to_string()),
        })
        .collect()
}

/// What the main loop should do after a key.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Nothing beyond a redraw.
    None,
    /// Send this line to wisp.
    Send(Inbound),
    /// Leave.
    Quit,
}

/// Several completions for the word before the cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Suggestions {
    /// Where the word starts, in characters.
    pub from: usize,
    /// The candidates.
    pub candidates: Vec<String>,
    /// The candidate the next Tab puts in.
    pub next: usize,
}

/// The longest start every word shares.
fn common_prefix(words: &[String]) -> String {
    let Some(first) = words.first() else {
        return String::new();
    };
    let mut prefix: Vec<char> = first.chars().collect();
    for word in &words[1..] {
        let shared = prefix
            .iter()
            .zip(word.chars())
            .take_while(|(a, b)| **a == *b)
            .count();
        prefix.truncate(shared);
    }
    prefix.into_iter().collect()
}

/// What the status line says about turns.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TurnState {
    /// This turn is running.
    Running(u64),
    /// The last turn took `seconds`, and failed or not.
    Ended {
        /// How long it took.
        seconds: f64,
        /// Whether it ended in an error.
        failed: bool,
        /// Tokens read and written, when the model reports them.
        tokens: Option<(u64, u64)>,
    },
}

/// What the turn under way is doing, as wisp last said, timed on this side.
#[derive(Debug, Clone, PartialEq)]
pub struct Activity {
    /// Such as `running git status`.
    pub doing: String,
    /// When the turn began.
    pub turn_started: Instant,
    /// When it began doing this.
    pub since: Instant,
    /// Whether the model is thinking (ADR 0053), which the busy box draws as a thought bubble from `since`.
    pub thinking: bool,
}

/// The thought bubble the busy box draws while the model thinks (ADR 0053, the operator's design of
/// 2026-10-04): it grows, then its dots cycle, the last four frames looping for as long as it thinks.
pub const THINKING_FRAMES: [&str; 7] = [
    ".",
    ".o",
    ".oO",
    ".oO( thinking )",
    ".oO( thinking. )",
    ".oO( thinking.. )",
    ".oO( thinking... )",
];

/// How long each frame of the thought bubble shows.
pub const THINKING_FRAME: Duration = Duration::from_millis(280);

/// The index into `THINKING_FRAMES` of the frame shown `elapsed` after thinking began: the first seven in
/// order, then the last four again and again.
pub fn thinking_frame(elapsed: Duration) -> usize {
    let step =
        usize::try_from(elapsed.as_millis() / THINKING_FRAME.as_millis()).unwrap_or(usize::MAX);
    let first_loop = THINKING_FRAMES.len() - 4;
    if step < THINKING_FRAMES.len() {
        step
    } else {
        first_loop + (step - first_loop) % 4
    }
}

/// How long from `elapsed` until the thought bubble's next frame, so the loop wakes in time to draw it.
pub fn until_next_frame(elapsed: Duration) -> Duration {
    let frame = THINKING_FRAME.as_millis();
    let into = elapsed.as_millis() % frame;
    Duration::from_millis(u64::try_from(frame - into).unwrap_or(1))
}

impl Activity {
    /// The working line at `now`: the turn's seconds, what it is doing, and for how long when that is
    /// not the whole turn, as `12 s · running git status (8 s)`. The same words as the terminal chat.
    pub fn label(&self, now: Instant) -> String {
        let turn = now.saturating_duration_since(self.turn_started).as_secs();
        let doing = now.saturating_duration_since(self.since).as_secs();
        let later =
            self.since.saturating_duration_since(self.turn_started) > Duration::from_millis(500);
        if later && doing != turn {
            format!("{turn} s · {} ({doing} s)", self.doing)
        } else {
            format!("{turn} s · {}", self.doing)
        }
    }
}

/// The whole state.
#[derive(Debug, Default)]
#[allow(clippy::struct_excessive_bools)]
pub struct App {
    /// Lines waiting to be inserted above the band.
    pub pending: Vec<HistoryLine>,
    /// The reply so far on the current line, not yet committed.
    pub partial: String,
    /// What the user has typed.
    pub editor: Editor,
    /// The last status wisp sent.
    pub status: Option<Status>,
    /// An approval awaiting an answer.
    pub approval: Option<Approval>,
    /// Approvals that arrived while one was shown, oldest first: commands waiting in `wisp mcp` servers can
    /// arrive at any time, beside this conversation's own.
    pub queued: VecDeque<Approval>,
    /// A choice awaiting an answer.
    pub picker: Option<Picker>,
    /// The id of the completion asked for and not yet answered.
    pub completing: Option<String>,
    /// Completion requests sent, for their ids.
    pub completions_asked: u64,
    /// Candidates from the last completion with more than one, shown above the input and cycled by
    /// Tab; any other edit clears them.
    pub suggestions: Option<Suggestions>,
    /// Whether a turn is in progress (input is held until the next status).
    pub busy: bool,
    /// Whether the input box is in command mode: `!` typed at the start of the line, so what is typed runs as a
    /// shell command (ADR 0049) and the box takes the command colour.
    pub command_mode: bool,
    /// Keys typed while a turn runs, in order: not shown as accepted, and applied to the input when the turn
    /// ends (the next status), as if typed then.
    pub held: Vec<Edit>,
    /// The turn under way, or how the last one ended, for the status line.
    pub turn: Option<TurnState>,
    /// What the turn under way is doing, and since when, for the status line.
    pub activity: Option<Activity>,
    /// Whether the reply is inside a fenced block; a turn's end closes one left open.
    pub in_fence: bool,
    /// Whether wisp said goodbye.
    pub exited: bool,
    /// Lines submitted this session, oldest first, for Up and Down.
    pub recall: Vec<String>,
    /// The recalled line being shown, as an index into `recall`; `None` while editing a fresh line.
    pub recall_at: Option<usize>,
    /// What was typed before Up was first pressed, restored by Down past the newest line.
    pub draft: String,
    /// The last tool output wisp sent, for Ctrl-O.
    pub last_output: Option<ToolOutput>,
    /// The panel over the band, when open.
    pub panel: Option<Panel>,
    /// Whether an `/inspect context` request from a key is awaiting its view.
    pub context_asked: bool,
    /// Notifications wisp asked to be posted, written to the terminal between frames.
    pub notices: Vec<Notice>,
    /// The width the band was last sized for, so scrolling knows how the text wraps.
    band_width: Cell<u16>,
}

impl App {
    /// The working line while a turn runs, or `None` when there is nothing to say.
    pub fn working_label(&self, now: Instant) -> Option<String> {
        match self.turn {
            Some(TurnState::Running(_)) => {
                self.activity.as_ref().map(|activity| activity.label(now))
            }
            _ => None,
        }
    }

    /// What changes on screen with time alone while a turn runs: the working line's seconds and, while the
    /// model thinks, the thought bubble's frame; an idle wake redraws only when this has changed.
    pub fn live_label(&self, now: Instant) -> Option<String> {
        let working = self.working_label(now)?;
        Some(match self.thinking_since() {
            Some(_) => format!("{working} {}", self.busy_label(now)),
            None => working,
        })
    }

    /// A turn's start or end: the status line's turn state, and at the end the line of what the turn ran
    /// (ADR 0051), under the reply as a muted note.
    fn turned(&mut self, turn: &Turn) {
        self.flush_partial();
        self.in_fence = false;
        if !turn.is_start() {
            self.activity = None;
        }
        if let Some(ran) = &turn.ran {
            self.push(ran, LineKind::Note);
        }
        if let Some(cited) = &turn.cited {
            self.push(cited, LineKind::Note);
        }
        self.turn = Some(if turn.is_start() {
            self.busy = true;
            TurnState::Running(turn.number)
        } else {
            TurnState::Ended {
                seconds: turn.seconds.unwrap_or(0.0),
                failed: turn.outcome.as_deref() == Some("error"),
                tokens: turn.input_tokens.zip(turn.output_tokens),
            }
        });
    }

    /// Applies one line from wisp.
    pub fn handle(&mut self, outbound: Outbound) {
        match outbound {
            Outbound::Output { text } => {
                self.flush_partial();
                for line in text.lines() {
                    self.push(line, LineKind::Output);
                }
            }
            Outbound::Delta { text } => {
                self.partial.push_str(&text);
                while let Some(index) = self.partial.find('\n') {
                    let line = self.partial[..index].to_string();
                    self.partial.drain(..=index);
                    self.push_reply(&line);
                }
            }
            Outbound::Note { text } => {
                self.flush_partial();
                let kind = if text.starts_with("error") {
                    LineKind::Error
                } else {
                    LineKind::Note
                };
                self.push(&text, kind);
                self.context_asked = false;
            }
            Outbound::Status(status) => {
                self.flush_partial();
                self.status = Some(status);
                self.busy = false;
                self.release_held();
            }
            Outbound::Activity {
                doing,
                turn_seconds,
                thinking,
                ..
            } => {
                let now = Instant::now();
                self.activity = doing.map(|doing| Activity {
                    doing,
                    turn_started: now
                        .checked_sub(Duration::from_secs_f64(turn_seconds.max(0.0)))
                        .unwrap_or(now),
                    since: now,
                    thinking,
                });
            }
            Outbound::Turn(turn) => self.turned(&turn),
            Outbound::Event(event) => {
                if event.text.is_some() || event.output.is_some() {
                    self.flush_partial();
                }
                if let Some(line) = event.text {
                    let kind = if event.kind == "error" {
                        LineKind::Error
                    } else {
                        LineKind::Tool
                    };
                    self.push(&line, kind);
                }
                if let Some(output) = event.output {
                    self.show_output(output);
                }
            }
            Outbound::Approval(approval) => self.arrived(approval),
            Outbound::Withdrawn { id } => self.withdrawn(&id),
            Outbound::Choice(choice) => {
                self.flush_partial();
                self.panel = None;
                self.picker = Some(Picker::new(choice));
            }
            Outbound::View(view) => {
                self.flush_partial();
                self.open_view(view);
            }
            Outbound::Completions {
                id,
                from,
                candidates,
            } => self.completed(&id, from, candidates),
            Outbound::Notify(notice) => self.notices.push(notice),
            Outbound::Exit => self.exited = true,
            Outbound::Unknown => {}
        }
    }

    /// Shows an approval in place of any panel, or queues it behind the one shown.
    fn arrived(&mut self, approval: Approval) {
        self.flush_partial();
        self.panel = None;
        if self.approval.is_some() {
            self.queued.push_back(approval);
        } else {
            self.approval = Some(approval);
        }
    }

    /// Drops an approval that no longer waits: the dialog shown is replaced by the next queued one, with a
    /// note, and a queued one is removed quietly.
    fn withdrawn(&mut self, id: &str) {
        if self
            .approval
            .as_ref()
            .is_some_and(|approval| approval.id == id)
        {
            if let Some(approval) = self.approval.take() {
                self.push(
                    &format!("⚠ answered elsewhere: {}", approval.command),
                    LineKind::Note,
                );
            }
            self.approval = self.queued.pop_front();
        } else {
            self.queued.retain(|approval| approval.id != id);
        }
    }

    /// Folds a tool's output into scrollback: the first lines wisp says to show, then a line saying
    /// how many are left. The whole text stays for the panel.
    fn show_output(&mut self, output: ToolOutput) {
        let lines: Vec<&str> = output.text.lines().collect();
        let shown = output.shown_lines.min(lines.len());
        let mut pending: Vec<String> = lines[..shown]
            .iter()
            .map(|line| format!("    {}", sanitise(line)))
            .collect();
        if lines.len() > shown {
            let hidden = lines.len() - shown;
            let plural = if hidden == 1 { "" } else { "s" };
            pending.push(format!(
                "    … {hidden} more line{plural} · ctrl-o shows all"
            ));
        }
        for line in pending {
            self.push(&line, LineKind::ToolOutput);
        }
        self.last_output = Some(output);
    }

    /// Opens the panel on a view from wisp, unless a dialog holds the band.
    fn open_view(&mut self, view: View) {
        self.context_asked = false;
        if self.approval.is_some() || self.picker.is_some() {
            return;
        }
        let kind = match (view.kind.as_str(), view.turn) {
            ("turns", _) => PanelKind::Turns,
            ("facts", _) => PanelKind::Facts,
            ("summary", _) => PanelKind::Summary,
            ("thinking", turn) => PanelKind::Thinking(turn),
            (_, turn) => PanelKind::Context(turn),
        };
        // Stepping keeps the reader's place: a new view of the same kind starts at the top.
        self.panel = Some(Panel {
            kind,
            text: view.text,
            scroll: 0,
            turns: view.turns,
        });
    }

    /// Ctrl-O: opens the last tool output in the panel, or closes the panel when it shows that.
    pub fn toggle_output(&mut self) {
        if self.approval.is_some() || self.picker.is_some() {
            return;
        }
        if self
            .panel
            .as_ref()
            .is_some_and(|p| p.kind == PanelKind::Output)
        {
            self.panel = None;
            return;
        }
        let Some(output) = &self.last_output else {
            self.push("no tool output to show yet", LineKind::Note);
            return;
        };
        let mut text = output.text.clone();
        if output.truncated {
            let gap = if text.ends_with('\n') { "" } else { "\n" };
            text = format!(
                "{text}{gap}… truncated: {} lines, {} bytes in all",
                output.lines, output.bytes
            );
        }
        self.panel = Some(Panel {
            kind: PanelKind::Output,
            text,
            scroll: 0,
            turns: 0,
        });
    }

    /// Ctrl-T: asks wisp for the context of the next request, when no turn runs and no dialog is open;
    /// the panel opens when the view arrives. The request is not echoed into scrollback.
    pub fn show_context(&mut self) -> Action {
        if self.busy || self.approval.is_some() || self.picker.is_some() || self.context_asked {
            return Action::None;
        }
        self.ask_context(None)
    }

    /// Sends `/inspect context next` or `/inspect context N` and remembers that a view is awaited.
    fn ask_context(&mut self, turn: Option<u64>) -> Action {
        self.context_asked = true;
        let text = match turn {
            Some(turn) => format!("/inspect context {turn}"),
            None => "/inspect context next".to_string(),
        };
        Action::Send(Inbound::Message { text })
    }

    /// Left or Right in a context panel: the previous or next turn's context, the next request's
    /// after the latest turn. Ignored while a request is outstanding or the panel is not a context.
    pub fn step_turn(&mut self, forward: bool) -> Action {
        let Some(Panel {
            kind: PanelKind::Context(at),
            turns,
            ..
        }) = &self.panel
        else {
            return Action::None;
        };
        if self.context_asked {
            return Action::None;
        }
        let (at, turns) = (*at, *turns);
        let target = match (at, forward) {
            (None, true) => return Action::None,
            (None, false) if turns == 0 => return Action::None,
            (None, false) => Some(turns),
            (Some(turn), false) if turn <= 1 => return Action::None,
            (Some(turn), false) => Some(turn - 1),
            (Some(turn), true) if turn >= turns => None,
            (Some(turn), true) => Some(turn + 1),
        };
        self.ask_context(target)
    }

    /// Rows of text the panel shows for a band `width` wide, and how many it holds in all.
    fn panel_rows(&self, width: u16) -> (Vec<String>, usize) {
        let Some(panel) = &self.panel else {
            return (Vec::new(), 1);
        };
        let rows = wrap_rows(&panel.text, dialog_width(width));
        let visible = rows.len().clamp(1, PANEL_ROWS);
        (rows, visible)
    }

    /// Scrolls the panel by `rows` (negative is up), within its text.
    fn scroll_panel(&mut self, rows: isize) {
        let width = self.band_width.get();
        let (all, visible) = self.panel_rows(if width == 0 { 80 } else { width });
        let Some(panel) = &mut self.panel else {
            return;
        };
        let max = all.len().saturating_sub(visible);
        panel.scroll = panel.scroll.saturating_add_signed(rows).min(max);
    }

    /// `PageUp`: a page up in the panel.
    pub fn page_up(&mut self) {
        self.scroll_panel(-isize::try_from(PANEL_ROWS).unwrap_or(1));
    }

    /// `PageDown`: a page down in the panel.
    pub fn page_down(&mut self) {
        self.scroll_panel(isize::try_from(PANEL_ROWS).unwrap_or(1));
    }

    /// Commits the partial reply line, if any.
    fn flush_partial(&mut self) {
        if !self.partial.is_empty() {
            let line = std::mem::take(&mut self.partial);
            self.push_reply(&line);
        }
    }

    /// Commits one reply line, as code while a fenced block is open.
    fn push_reply(&mut self, line: &str) {
        let kind = if markdown::is_fence(line) {
            self.in_fence = !self.in_fence;
            LineKind::Fence
        } else if self.in_fence {
            LineKind::Code
        } else {
            LineKind::Reply
        };
        self.push(line, kind);
    }

    fn push(&mut self, text: &str, kind: LineKind) {
        self.pending.push(HistoryLine {
            text: text.to_string(),
            kind,
        });
    }

    /// Takes the lines to insert above the band.
    pub fn take_pending(&mut self) -> Vec<HistoryLine> {
        std::mem::take(&mut self.pending)
    }

    /// The notifications wisp has asked for since the last call, oldest first.
    pub fn take_notices(&mut self) -> Vec<Notice> {
        std::mem::take(&mut self.notices)
    }

    /// A character typed.
    pub fn type_char(&mut self, c: char) -> Action {
        if let Some(approval) = &self.approval {
            let decision = if approval.is_fact() {
                match c.to_ascii_lowercase() {
                    'k' => "keep",
                    'd' => "drop",
                    _ => return Action::None,
                }
            } else {
                match c.to_ascii_lowercase() {
                    'y' => "once",
                    's' => "session",
                    'p' => "project",
                    'a' => "always",
                    'n' => "no",
                    _ => return Action::None,
                }
            };
            let id = approval.id.clone();
            self.push(&answered(&approval.command, decision), LineKind::Note);
            self.approval = self.queued.pop_front();
            return Action::Send(Inbound::Answer {
                id,
                decision: decision.to_string(),
            });
        }
        // A choice with toggles takes Space, to turn the highlighted row on or off, and no typing.
        if let Some(picker) = &mut self.picker
            && picker.choice.toggles
        {
            if c == ' ' {
                picker.toggle();
            }
            return Action::None;
        }
        if self.holding() {
            self.held.push(Edit::Insert(c));
            return Action::None;
        }
        // `!` at the start of the line is the switch to command mode, not text, whatever follows it; after
        // other text, or in command mode, it is text.
        if c == '!'
            && self.typing()
            && self.picker.is_none()
            && self.editor.cursor() == 0
            && !self.command_mode
        {
            self.command_mode = true;
            self.suggestions = None;
            return Action::None;
        }
        self.edit(&Edit::Insert(c));
        Action::None
    }

    /// Whether keys are held rather than taken: while a turn runs and nothing else (a dialog, a choice, the
    /// panel) wants them.
    fn holding(&self) -> bool {
        self.busy && self.approval.is_none() && self.picker.is_none() && self.panel.is_none()
    }

    /// Applies the keys held while the turn ran, in order, as if typed now.
    fn release_held(&mut self) {
        for edit in std::mem::take(&mut self.held) {
            match edit {
                Edit::Insert(c) => {
                    self.type_char(c);
                }
                other => self.edit(&other),
            }
        }
    }

    /// Puts a line into the input as recalling it does: a line that starts with `!` returns in command mode,
    /// without its `!`.
    fn set_line(&mut self, line: &str) {
        if let Some(command) = line.strip_prefix('!') {
            self.command_mode = true;
            self.editor.set(command);
        } else {
            self.command_mode = false;
            self.editor.set(line);
        }
    }

    /// The input as a line, as `set_line` takes it back: `!` before it in command mode.
    fn line(&self) -> String {
        let text = self.editor.text();
        if self.command_mode {
            format!("!{text}")
        } else {
            text
        }
    }

    /// Whether the input takes edits: with no dialog up and no turn running, or while a choice that
    /// takes typed text is open.
    fn typing(&self) -> bool {
        match &self.picker {
            Some(picker) => picker.choice.accepts_text,
            None => self.approval.is_none() && !self.busy && self.panel.is_none(),
        }
    }

    /// An edit to the input: held while a turn is running, ignored while a dialog wants its keys. In command
    /// mode, Backspace at the start of the line, or Delete in an empty box, returns to the normal prompt; a paste
    /// that starts with `!` at the start of the line enters command mode, as typing `!` does.
    pub fn edit(&mut self, edit: &Edit) {
        if self.holding() {
            self.held.push(edit.clone());
            return;
        }
        if !self.typing() {
            return;
        }
        self.suggestions = None;
        self.completing = None;
        let in_box = self.picker.is_none() && self.editor.is_empty();
        // Backspace at the start of the line takes back the `!`, keeping what follows as ordinary text;
        // Delete leaves command mode only in an empty box, as it deletes forwards.
        let at_start = self.picker.is_none() && self.editor.cursor() == 0;
        if self.command_mode
            && ((at_start && matches!(edit, Edit::Backspace))
                || (in_box && matches!(edit, Edit::Delete)))
        {
            self.command_mode = false;
            return;
        }
        if let Edit::Paste(text) = edit
            && at_start
            && !self.command_mode
            && let Some(command) = text.strip_prefix('!')
        {
            self.command_mode = true;
            self.editor.apply(&Edit::Paste(command.to_string()));
            return;
        }
        self.editor.apply(edit);
    }

    /// Tab: cycles through the suggestions on show, or asks wisp to complete the slash command being
    /// typed.
    pub fn complete(&mut self) -> Action {
        if !self.typing() || self.picker.is_some() {
            return Action::None;
        }
        if let Some(suggestions) = &mut self.suggestions {
            let candidate = suggestions.candidates[suggestions.next].clone();
            suggestions.next = (suggestions.next + 1) % suggestions.candidates.len();
            self.editor.replace(suggestions.from, &candidate);
            return Action::None;
        }
        let text = self.editor.text();
        if !text.starts_with('/') {
            return Action::None;
        }
        self.completions_asked += 1;
        let id = format!("k{}", self.completions_asked);
        self.completing = Some(id.clone());
        Action::Send(Inbound::Complete {
            id,
            text,
            cursor: self.editor.cursor(),
        })
    }

    /// Applies completions if they answer the request still open: one fills in with a space after it,
    /// several fill in what they share and show above the input.
    fn completed(&mut self, id: &str, from: usize, candidates: Vec<String>) {
        if self.completing.as_deref() != Some(id) {
            return;
        }
        self.completing = None;
        match candidates.len() {
            0 => {}
            1 => self.editor.replace(from, &format!("{} ", candidates[0])),
            _ => {
                let shared = common_prefix(&candidates);
                if shared.chars().count() > self.editor.cursor().saturating_sub(from) {
                    self.editor.replace(from, &shared);
                }
                self.suggestions = Some(Suggestions {
                    from,
                    candidates,
                    next: 0,
                });
            }
        }
    }

    /// Answers the open choice with `value`, `None` for no answer, and closes it; a choice with toggles is
    /// answered with `values`, the rows left on, or with nothing when it is left.
    fn choose(&mut self, value: Option<String>, values: Option<Vec<String>>) -> Action {
        let Some(picker) = self.picker.take() else {
            return Action::None;
        };
        self.editor.take();
        Action::Send(Inbound::Choose {
            id: picker.choice.id,
            value,
            values,
        })
    }

    /// Esc: leaves an open choice unanswered; otherwise nothing.
    pub fn cancel(&mut self) -> Action {
        if self.panel.take().is_some() {
            return Action::None;
        }
        self.choose(None, None)
    }

    /// Enter: sends the input as a message, echoing it into history; with a choice open, answers it.
    pub fn submit(&mut self) -> Action {
        if let Some(picker) = &self.picker {
            if let Some(values) = picker.values() {
                return self.choose(None, Some(values));
            }
            let answer = picker.answer(&self.editor.text());
            return self.choose(answer, None);
        }
        if self.approval.is_some() || self.busy {
            return Action::None;
        }
        // A command goes to wisp as the line plain chat takes, `!` and the command; so does text that starts
        // with `!`, which wisp runs as a command too.
        let typed = self.editor.text().trim().to_string();
        let command = if self.command_mode {
            Some(typed.clone())
        } else {
            typed.strip_prefix('!').map(|rest| rest.trim().to_string())
        };
        if typed.is_empty() || command.as_deref() == Some("") {
            return Action::None;
        }
        self.editor.take();
        self.command_mode = false;
        self.suggestions = None;
        let text = if let Some(command) = &command {
            self.push(&format!("! {command}"), LineKind::Command);
            format!("!{command}")
        } else {
            self.push(&format!("› {typed}"), LineKind::User);
            typed
        };
        if self.recall.last() != Some(&text) {
            self.recall.push(text.clone());
            if self.recall.len() > RECALL_LIMIT {
                self.recall.remove(0);
            }
        }
        self.recall_at = None;
        self.draft.clear();
        self.busy = true;
        Action::Send(Inbound::Message { text })
    }

    /// Up: replaces the input with the previous submitted line, keeping what was typed as the draft.
    pub fn recall_previous(&mut self) {
        if self.panel.is_some() {
            self.scroll_panel(-1);
            return;
        }
        if let Some(picker) = &mut self.picker {
            picker.step(false);
            return;
        }
        if self.approval.is_some() || self.busy || self.recall.is_empty() {
            return;
        }
        let index = match self.recall_at {
            None => {
                self.draft = self.line();
                self.recall.len() - 1
            }
            Some(index) => index.saturating_sub(1),
        };
        self.recall_at = Some(index);
        let line = self.recall[index].clone();
        self.set_line(&line);
    }

    /// Down: moves to the next submitted line, and past the newest back to the draft.
    pub fn recall_next(&mut self) {
        if self.panel.is_some() {
            self.scroll_panel(1);
            return;
        }
        if let Some(picker) = &mut self.picker {
            picker.step(true);
            return;
        }
        if self.approval.is_some() || self.busy {
            return;
        }
        let Some(index) = self.recall_at else {
            return;
        };
        if index + 1 < self.recall.len() {
            self.recall_at = Some(index + 1);
            let line = self.recall[index + 1].clone();
            self.set_line(&line);
        } else {
            self.recall_at = None;
            let draft = std::mem::take(&mut self.draft);
            self.set_line(&draft);
        }
    }

    /// Ctrl-C or Ctrl-D: cancel a dialog first, otherwise quit.
    pub fn interrupt(&mut self) -> Action {
        if self.panel.take().is_some() {
            return Action::None;
        }
        if self.picker.is_some() {
            return self.cancel();
        }
        if let Some(approval) = self.approval.take() {
            // Refusing is the default answer: a command is not run, a fact is not kept.
            let decision = if approval.is_fact() { "drop" } else { "no" };
            self.push(&answered(&approval.command, decision), LineKind::Note);
            self.approval = self.queued.pop_front();
            return Action::Send(Inbound::Answer {
                id: approval.id,
                decision: decision.into(),
            });
        }
        Action::Quit
    }

    /// Whether nothing is typed.
    pub fn input_is_empty(&self) -> bool {
        self.editor.is_empty()
    }

    /// The band's height for a terminal `width` cells wide: the base, plus a row for each further row
    /// the input's text needs, up to `MAX_INPUT_ROWS`.
    /// While a dialog is asked it takes the input's place: the reply row, the dialog, a blank row, and the
    /// status.
    pub fn band_height(&self, width: u16) -> u16 {
        self.band_width.set(width);
        if let Some(picker) = &self.picker {
            return u16::try_from(picker.rows(dialog_width(width)))
                .unwrap_or(u16::MAX)
                .saturating_add(DIALOG_FRAME + DIALOG_SPACING);
        }
        if let Some(approval) = &self.approval {
            let rows = dialog_lines(approval, dialog_width(width)).len();
            return u16::try_from(rows)
                .unwrap_or(u16::MAX)
                .saturating_add(DIALOG_FRAME + DIALOG_SPACING);
        }
        if self.panel.is_some() {
            let (_, visible) = self.panel_rows(width);
            return u16::try_from(visible)
                .unwrap_or(u16::MAX)
                .saturating_add(DIALOG_FRAME + DIALOG_SPACING);
        }
        BAND_HEIGHT + self.input_rows(width).saturating_sub(1)
    }

    /// Rows the input needs at `width`, from 1 to `MAX_INPUT_ROWS`.
    fn input_rows(&self, width: u16) -> u16 {
        let inner = usize::from(width.saturating_sub(MARGIN * 2)).saturating_sub(PROMPT_CELLS);
        let rows = self.editor.rows(inner).rows.len();
        u16::try_from(rows)
            .unwrap_or(MAX_INPUT_ROWS)
            .clamp(1, MAX_INPUT_ROWS)
    }

    /// Draws an open choice in the input's place: a border around the question, the options, the keys,
    /// and the typed row with the terminal's cursor in it when the choice takes text.
    fn render_picker(&self, frame: &mut Frame, picker: &Picker, area: Rect, inset: Rect) {
        let mut lines = picker.lines(dialog_width(area.width));
        let typed_row = picker.choice.accepts_text.then(|| {
            lines.push(Line::from(vec![
                Span::styled("› ", palette::prompt()),
                Span::styled(self.editor.text(), palette::user()),
            ]));
            lines.len() - 1
        });
        let height = u16::try_from(lines.len())
            .unwrap_or(u16::MAX)
            .saturating_add(DIALOG_FRAME);
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(palette::wisp())
            .title(Span::styled(" choose ", palette::wisp()))
            .padding(Padding::horizontal(1));
        let dialog = Rect {
            y: area.y + 1,
            height: height.min(area.height.saturating_sub(DIALOG_SPACING)),
            ..inset
        };
        frame.render_widget(Paragraph::new(lines).block(block), dialog);
        // The terminal's cursor sits in the typed row: the border, the padding, and the prompt.
        if let Some(row) = typed_row {
            let column = u16::try_from(self.editor.rows(usize::MAX).column).unwrap_or(0);
            let x = dialog.x.saturating_add(2 + PROMPT_CELLS_U16 + column);
            let y = dialog.y + 1 + u16::try_from(row).unwrap_or(0);
            frame.set_cursor_position((x.min(area.right().saturating_sub(1)), y));
        }
    }

    /// Draws an approval in the input's place: a border coloured by the risk (wisp's own colour for a
    /// fact to keep, which has none), and the dialog inside.
    fn render_approval(frame: &mut Frame, approval: &Approval, area: Rect, inset: Rect) {
        let lines = if approval.is_fact() {
            fact_lines(approval, dialog_width(area.width))
        } else {
            dialog_lines(approval, dialog_width(area.width))
        };
        let height = u16::try_from(lines.len())
            .unwrap_or(u16::MAX)
            .saturating_add(DIALOG_FRAME);
        let style = if approval.is_fact() {
            palette::wisp()
        } else {
            palette::level(&approval.level)
        };
        let title = if approval.is_fact() {
            String::from(" keep as a permanent fact? · wisp mcp ")
        } else if approval.is_mcp() {
            format!(" approve · {} · wisp mcp ", approval.level)
        } else {
            format!(" approve · {} ", approval.level)
        };
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(style)
            .title(Span::styled(title, style))
            .padding(Padding::horizontal(1));
        let dialog = Rect {
            y: area.y + 1,
            height: height.min(area.height.saturating_sub(DIALOG_SPACING)),
            ..inset
        };
        frame.render_widget(Paragraph::new(lines).block(block), dialog);
    }

    /// Draws the panel in the dialogs' place: a rounded border titled for what it shows, the visible
    /// rows of the text, and the keys on the bottom edge.
    fn render_panel(&self, frame: &mut Frame, area: Rect, inset: Rect) {
        let Some(panel) = &self.panel else {
            return;
        };
        let (rows, visible) = self.panel_rows(area.width);
        let first = panel.scroll.min(rows.len().saturating_sub(visible));
        let lines: Vec<Line<'static>> = rows
            .into_iter()
            .skip(first)
            .take(visible)
            .map(|row| Line::from(Span::styled(row, palette::body())))
            .collect();
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(palette::wisp())
            .title(Span::styled(panel.title(), palette::wisp()))
            .title_bottom(Span::styled(panel.hint(), palette::muted()))
            .padding(Padding::horizontal(1));
        let height = u16::try_from(visible)
            .unwrap_or(u16::MAX)
            .saturating_add(DIALOG_FRAME);
        let dialog = Rect {
            y: area.y + 1,
            height: height.min(area.height.saturating_sub(DIALOG_SPACING)),
            ..inset
        };
        frame.render_widget(Paragraph::new(lines).block(block), dialog);
    }

    /// Draws the band into `area`. Text is inset by the margin everywhere; the input's tint runs edge
    /// to edge with half-block strips above and below it.
    pub fn render(&self, frame: &mut Frame, area: Rect) {
        let margin = MARGIN.min(area.width / 2);
        let inset = Rect {
            x: area.x + margin,
            width: area.width.saturating_sub(margin * 2),
            ..area
        };
        let row = |index: u16, rect: Rect| Rect::new(rect.x, rect.y + index, rect.width, 1);
        let plain = |frame: &mut Frame, index: u16, line: Line<'static>| {
            if index < area.height {
                frame.render_widget(Paragraph::new(line), row(index, inset));
            }
        };
        plain(
            frame,
            0,
            Line::from(Span::styled(self.partial.clone(), palette::body())),
        );
        if self.panel.is_some() {
            self.render_panel(frame, area, inset);
            plain(
                frame,
                area.height.saturating_sub(1),
                self.status_line(inset.width),
            );
            return;
        }
        if let Some(suggestions) = &self.suggestions {
            plain(
                frame,
                1,
                Line::from(Span::styled(
                    suggestions.candidates.join("  "),
                    palette::muted(),
                )),
            );
        }
        if let Some(picker) = &self.picker {
            self.render_picker(frame, picker, area, inset);
            plain(
                frame,
                area.height.saturating_sub(1),
                self.status_line(inset.width),
            );
            return;
        }
        if let Some(approval) = &self.approval {
            Self::render_approval(frame, approval, area, inset);
            plain(
                frame,
                area.height.saturating_sub(1),
                self.status_line(inset.width),
            );
            return;
        }
        // Command mode tints the box and its strips in the command colour.
        let (background, edge) = if self.command_mode {
            (palette::command_background(), palette::command_edge())
        } else {
            (palette::input_background(), palette::input_edge())
        };
        let strip = |frame: &mut Frame, index: u16, glyph: &str| {
            if index < area.height {
                let text = glyph.repeat(usize::from(area.width));
                frame.render_widget(Paragraph::new(text).style(edge), row(index, area));
            }
        };
        // The input has the rows the band leaves between its fixed rows: reply, dialog, the two strips,
        // and the status.
        let input_rows = area.height.saturating_sub(BAND_HEIGHT - 1).max(1);
        let status_row = INPUT_ROW + input_rows + 1;
        strip(frame, INPUT_ROW - 1, "▄");
        let (lines, cursor) = self.input_lines(usize::from(inset.width), usize::from(input_rows));
        for (offset, line) in (0..input_rows).zip(lines) {
            let index = INPUT_ROW + offset;
            if index >= area.height {
                break;
            }
            frame.render_widget(Paragraph::new("").style(background), row(index, area));
            frame.render_widget(Paragraph::new(line).style(background), row(index, inset));
        }
        // The terminal's own cursor marks where typing goes, while typing is taken.
        if let Some((line, column)) = cursor {
            let x = inset
                .x
                .saturating_add(u16::try_from(column).unwrap_or(u16::MAX));
            let y = area.y + INPUT_ROW + u16::try_from(line).unwrap_or(0);
            frame.set_cursor_position((x.min(area.right().saturating_sub(1)), y));
        }
        strip(frame, status_row - 1, "▀");
        plain(frame, status_row, self.status_line(inset.width));
    }

    /// The input's rows in `width` cells, at most `visible` of them, and the cursor's row among those
    /// shown and its column, when typing is taken. The first row carries the prompt and the rest are
    /// indented to match; a tall input shows the rows around the cursor.
    fn input_lines(
        &self,
        width: usize,
        visible: usize,
    ) -> (Vec<Line<'static>>, Option<(usize, usize)>) {
        // While a turn runs the box is inactive: dimmed, with what wisp is doing where the cursor would be, or
        // the thought bubble while the model thinks.
        if self.busy {
            let label = self.busy_label(Instant::now());
            let line = if self.thinking_since().is_some() {
                Line::from(Span::styled(label, palette::busy()))
            } else {
                Line::from(vec![
                    Span::styled("… ", palette::busy()),
                    Span::styled(label, palette::busy()),
                ])
            };
            return (vec![line], None);
        }
        let (prompt, prompt_style, text_style) = if self.command_mode {
            ("!", palette::command_prompt(), palette::command_text())
        } else {
            ("›", palette::prompt(), palette::user())
        };
        if self.editor.is_empty() {
            let placeholder = Line::from(vec![
                Span::styled(format!("{prompt} "), prompt_style),
                if self.command_mode {
                    Span::styled(COMMAND_PLACEHOLDER, palette::command_placeholder())
                } else {
                    Span::styled(PLACEHOLDER, palette::muted())
                },
            ]);
            let typing = self.approval.is_none();
            return (vec![placeholder], typing.then_some((0, PROMPT_CELLS)));
        }
        let layout = self.editor.rows(width.saturating_sub(PROMPT_CELLS));
        let first = layout.first_shown(visible);
        let lines = layout
            .rows
            .iter()
            .enumerate()
            .skip(first)
            .take(visible)
            .map(|(index, text)| {
                let lead = if index == 0 {
                    format!("{prompt} ")
                } else {
                    " ".repeat(PROMPT_CELLS)
                };
                Line::from(vec![
                    Span::styled(lead, prompt_style),
                    Span::styled(text.clone(), text_style),
                ])
            })
            .collect();
        let typing = self.approval.is_none();
        (
            lines,
            typing.then_some((layout.row - first, PROMPT_CELLS + layout.column)),
        )
    }

    /// When the model began thinking, while it thinks and a turn runs; `None` otherwise.
    pub fn thinking_since(&self) -> Option<Instant> {
        self.activity
            .as_ref()
            .filter(|activity| activity.thinking && self.busy)
            .map(|activity| activity.since)
    }

    /// How long the loop may wait for input before the busy box needs drawing again: until the thought
    /// bubble's next frame while the model thinks, `None` otherwise.
    pub fn next_frame_in(&self, now: Instant) -> Option<Duration> {
        self.thinking_since()
            .map(|since| until_next_frame(now.saturating_duration_since(since)))
    }

    /// What the inactive box says while a turn runs at `now`: `working:` and what wisp last said it is doing (a
    /// tool and its argument, a command, waiting for the model), or the thought bubble's frame while the model
    /// thinks, and how many keys are held for when it ends.
    pub fn busy_label(&self, now: Instant) -> String {
        let doing = match (self.thinking_since(), self.activity.as_ref()) {
            (Some(since), _) => {
                THINKING_FRAMES[thinking_frame(now.saturating_duration_since(since))].to_string()
            }
            (None, Some(activity)) => format!("working: {}", activity.doing),
            (None, None) => "working…".to_string(),
        };
        match self.held.len() {
            0 => doing,
            1 => format!("{doing} · 1 key held"),
            n => format!("{doing} · {n} keys held"),
        }
    }

    /// The status row for a band `width` cells wide: on the left the model and its context use, the
    /// directory with its branch and line changes; on the right the approval mode, the turn, and its
    /// tokens, pushed to the right edge. When both do not fit, the directory shortens to its last
    /// folder, and failing that the two sides simply follow each other.
    fn status_line(&self, width: u16) -> Line<'static> {
        let Some(status) = &self.status else {
            return Line::from(Span::styled("connecting…", palette::muted()));
        };
        let sep = || Span::styled(" · ", palette::muted());
        let left = |directory: String| {
            let mut spans = vec![Span::styled(status.model.clone(), palette::wisp())];
            if let Some(used) = status.context_used {
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                let percent = (used * 100.0).round() as u8;
                // Quiet below half the window, bright from half, amber from 80%, where condensing is near.
                let style = if used >= 0.8 {
                    palette::amber()
                } else if used >= 0.5 {
                    palette::glow()
                } else {
                    palette::muted()
                };
                spans.push(Span::styled(":", palette::muted()));
                spans.push(Span::styled(format!("{percent}% used"), style));
            }
            spans.push(sep());
            spans.push(Span::styled(directory, palette::wisp()));
            if let Some(branch) = &status.branch {
                spans.push(Span::styled(":", palette::muted()));
                spans.push(Span::styled(branch.clone(), palette::glow()));
            }
            match (status.added, status.removed) {
                (Some(added), Some(removed)) if added + removed > 0 => {
                    spans.push(Span::styled(format!("+{added}"), palette::added()));
                    spans.push(Span::styled(format!("-{removed}"), palette::removed()));
                }
                _ if status.dirty == Some(true) => spans.push(Span::styled("*", palette::amber())),
                _ => {}
            }
            spans
        };
        let mut right = vec![Span::styled(status.approval.clone(), palette::muted())];
        match self.turn {
            Some(TurnState::Running(number)) => {
                right.push(sep());
                right.push(Span::styled(format!("turn {number}…"), palette::wisp()));
                if let Some(label) = self.working_label(Instant::now()) {
                    right.push(sep());
                    right.push(Span::styled(label, palette::muted()));
                }
            }
            Some(TurnState::Ended {
                seconds,
                failed,
                tokens,
            }) => {
                right.push(sep());
                right.push(if failed {
                    Span::styled(format!("last:failed {seconds:.1}s"), palette::ember())
                } else {
                    Span::styled(format!("last:{seconds:.1}s"), palette::muted())
                });
                if let Some((input, output)) = tokens {
                    right.push(sep());
                    right.push(Span::styled(
                        format!("↓{}", grouped(input)),
                        palette::tokens_in(),
                    ));
                    right.push(Span::raw(" "));
                    right.push(Span::styled(
                        format!("↑{}", grouped(output)),
                        palette::tokens_out(),
                    ));
                }
            }
            None => {}
        }
        let cells = |spans: &[Span<'static>]| spans.iter().map(Span::width).sum::<usize>();
        let right_cells = cells(&right);
        let mut spans = left(status.directory.clone());
        if cells(&spans) + right_cells + 3 > usize::from(width) {
            let last = status
                .directory
                .rsplit('/')
                .next()
                .unwrap_or(&status.directory);
            spans = left(format!("…/{last}"));
        }
        let gap = usize::from(width).saturating_sub(cells(&spans) + right_cells);
        if gap >= 3 {
            spans.push(Span::raw(" ".repeat(gap)));
        } else {
            spans.push(sep());
        }
        spans.extend(right);
        Line::from(spans)
    }
}

/// `n` with thousands separated by commas, as the terminal chat's footer writes it.
fn grouped(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// The prompt's cells as a row offset.
const PROMPT_CELLS_U16: u16 = 2;
/// Rows a dialog's border and nothing else take: the top and bottom edges.
const DIALOG_FRAME: u16 = 2;
/// Rows around a dialog in the band besides its own: the reply row above it, then a blank row and the
/// status below, so the dialog is set off from the status as it is from the reply.
const DIALOG_SPACING: u16 = 3;
/// Rows a long command may wrap to in the dialog before it is cut.
const COMMAND_ROWS: usize = 4;
/// Reasons the dialog lists; the classifier rarely gives more.
const DIALOG_REASONS: usize = 4;

/// Cells of text across a dialog in a band `width` wide: less the margins, the borders, and the
/// padding inside them.
fn dialog_width(width: u16) -> usize {
    usize::from(width.saturating_sub(MARGIN * 2 + 4)).max(1)
}

/// What a dialog says, each line fitted to `width` cells: the command, wrapped; the line it is part
/// of, when it is one part of one; the directory; the reasons; the pattern the answer is remembered
/// under; an empty row; and the keys, worded as `wisp chat` words them.
fn dialog_lines(approval: &Approval, width: usize) -> Vec<Line<'static>> {
    let mut command = Editor::default();
    command.set(&approval.command);
    let rows = command.rows(width).rows;
    let mut lines: Vec<Line<'static>> = rows
        .iter()
        .take(COMMAND_ROWS)
        .enumerate()
        .map(|(index, row)| {
            let text = if index + 1 == COMMAND_ROWS && rows.len() > COMMAND_ROWS {
                fit(&format!("{row}…"), width)
            } else {
                row.clone()
            };
            Line::from(Span::styled(text, palette::user()))
        })
        .collect();
    let muted = |text: String| Line::from(Span::styled(fit(&text, width), palette::muted()));
    if approval.is_mcp() {
        let client = approval.client.as_deref().unwrap_or("an MCP client");
        let thread = approval
            .thread
            .as_deref()
            .map_or(String::new(), |thread| format!(", thread {thread}"));
        lines.push(muted(format!("waiting in wisp mcp for {client}{thread}")));
    }
    if approval.line != approval.command {
        lines.push(muted(format!("part of: {}", approval.line)));
    }
    lines.push(muted(format!("in {}", approval.directory)));
    for reason in approval.reasons.iter().take(DIALOG_REASONS) {
        lines.push(Line::from(Span::styled(
            fit(&format!("- {reason}"), width),
            palette::body(),
        )));
    }
    lines.push(muted(format!("remembered as {}", approval.pattern)));
    // One empty row sets the keys apart from what they answer.
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        fit("[y]once [s]ession [p]roject 30d [a]lways 30d [n]o", width),
        palette::body(),
    )));
    lines
}

/// What a dialog asking to keep a fact says, each line fitted to `width` cells: the fact, where it waits,
/// what it is and who said it, what keeping it means, an empty row, and the keys.
fn fact_lines(approval: &Approval, width: usize) -> Vec<Line<'static>> {
    let muted = |text: String| Line::from(Span::styled(fit(&text, width), palette::muted()));
    let mut lines = vec![Line::from(Span::styled(
        fit(&approval.command, width),
        palette::user(),
    ))];
    let client = approval.client.as_deref().unwrap_or("an MCP client");
    let thread = approval
        .thread
        .as_deref()
        .map_or(String::new(), |thread| format!(", thread {thread}"));
    lines.push(muted(format!("asked by {client}{thread} in wisp mcp")));
    if let Some(fact) = &approval.fact {
        lines.push(muted(format!(
            "fact {} ({}), from the {}",
            fact.id, fact.subject, fact.source
        )));
    }
    lines.push(Line::from(Span::styled(
        fit(
            "kept across sessions as yours, in ~/.wisp/facts.json",
            width,
        ),
        palette::body(),
    )));
    // One empty row sets the keys apart from what they answer.
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        fit("[k]eep [d]rop (stays in its thread)", width),
        palette::body(),
    )));
    lines
}

/// `text` cut to `width` cells, ending in an ellipsis when cut.
fn fit(text: &str, width: usize) -> String {
    let cells: usize = text.chars().map(|c| c.width().unwrap_or(0)).sum();
    if cells <= width {
        return text.to_string();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in text.chars() {
        let w = c.width().unwrap_or(0);
        if used + w + 1 > width {
            break;
        }
        out.push(c);
        used += w;
    }
    out.push('…');
    out
}

/// The scrollback's record of an answered dialog.
fn answered(command: &str, decision: &str) -> String {
    let what = match decision {
        "once" => "approved for this turn",
        "session" => "approved for this session",
        "project" => "approved in this project for 30 days",
        "always" => "approved everywhere for 30 days",
        "keep" => "kept as a permanent fact",
        "drop" => "dropped, left in its thread",
        _ => "refused",
    };
    format!("⚠ {what}: {command}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Choice, ChoiceOption, Event, FactAsk};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::style::Modifier;
    use serde_json::Value;

    fn event(kind: &str, text: Option<&str>) -> Event {
        Event {
            kind: kind.into(),
            call: Some("c".into()),
            details: Value::Null,
            text: text.map(str::to_string),
            output: None,
        }
    }

    fn result_with(text: &str, shown: usize) -> Outbound {
        let mut e = event("tool.result", Some("  ↳ ok"));
        e.output = Some(ToolOutput {
            id: "0123456789abcdef".into(),
            text: text.into(),
            lines: text.lines().count() as u64,
            bytes: text.len() as u64,
            truncated: false,
            shown_lines: shown,
        });
        Outbound::Event(e)
    }

    fn numbered(n: usize) -> String {
        (1..=n).fold(String::new(), |text, i| text + &format!("line {i}\n"))
    }

    fn texts(app: &mut App) -> Vec<(String, LineKind)> {
        app.take_pending()
            .into_iter()
            .map(|l| (l.text, l.kind))
            .collect()
    }

    fn view(kind: &str, turn: Option<u64>, turns: u64) -> Outbound {
        Outbound::View(View {
            kind: kind.into(),
            turn,
            turns,
            text: "# Context\nbody".into(),
        })
    }

    #[test]
    fn tool_output_folds_after_its_note_and_says_how_many_lines_remain() {
        let mut app = App::default();
        app.handle(result_with(&numbered(5), 2));
        assert_eq!(
            texts(&mut app),
            vec![
                ("  ↳ ok".into(), LineKind::Tool),
                ("    line 1".into(), LineKind::ToolOutput),
                ("    line 2".into(), LineKind::ToolOutput),
                (
                    "    … 3 more lines · ctrl-o shows all".into(),
                    LineKind::ToolOutput
                ),
            ]
        );
        assert_eq!(
            app.last_output.as_ref().map(|o| o.id.as_str()),
            Some("0123456789abcdef")
        );
        // Everything fits: no fold line.
        app.handle(result_with(&numbered(2), 20));
        assert_eq!(texts(&mut app).len(), 3);
        // shownLines 0 shows none, only the fold.
        app.handle(result_with(&numbered(4), 0));
        let lines = texts(&mut app);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1].0, "    … 4 more lines · ctrl-o shows all");
        // Control characters never reach the terminal.
        app.handle(result_with("a\u{1b}[31mred\tx\n", 5));
        assert_eq!(texts(&mut app)[1].0, "    a[31mred    x");
    }

    #[test]
    fn a_result_without_a_note_or_a_shown_count_still_folds() {
        let mut app = App::default();
        let mut e = event("tool.result", None);
        e.output = Some(
            serde_json::from_str(r#"{"id":"i","text":"a\nb\n","lines":2,"bytes":4}"#)
                .unwrap_or_else(|e| panic!("output: {e}")),
        );
        app.handle(Outbound::Event(e));
        assert_eq!(
            texts(&mut app).len(),
            2,
            "no note, two lines, default 20 shown"
        );
        app.handle(result_with(&numbered(25), 20));
        let lines = texts(&mut app);
        assert_eq!(
            lines.last().map(|l| l.0.as_str()),
            Some("    … 5 more lines · ctrl-o shows all")
        );
    }

    #[test]
    fn ctrl_o_opens_the_whole_output_in_a_scrollable_panel_and_closes_it() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.toggle_output();
        assert!(app.panel.is_none(), "nothing to show yet");
        assert_eq!(texts(&mut app)[0].1, LineKind::Note);
        app.handle(result_with(&numbered(40), 3));
        app.take_pending();
        app.toggle_output();
        assert_eq!(
            app.band_height(60),
            16 + 2 + 3,
            "rows, border, reply row, a blank row, status"
        );
        let rows = drawn(&app, 60);
        assert!(rows[1].starts_with(" ╭ output "), "{rows:?}");
        assert!(rows[2].contains("line 1"), "{rows:?}");
        assert!(rows[18].contains("↑↓ scroll · esc close"), "{rows:?}");
        // Typing is ignored while it is open.
        app.type_char('x');
        assert!(app.editor.is_empty());
        app.recall_next();
        app.recall_next();
        assert!(drawn(&app, 60)[2].contains("line 3"));
        app.recall_previous();
        assert!(drawn(&app, 60)[2].contains("line 2"));
        app.page_down();
        app.page_down();
        app.page_down();
        let rows = drawn(&app, 60);
        assert!(
            rows[2].contains("line 25"),
            "scroll stops at the end: {rows:?}"
        );
        assert!(rows[18].contains("scroll"));
        app.page_up();
        assert!(drawn(&app, 60)[2].contains("line 9"));
        assert_eq!(app.cancel(), Action::None);
        assert!(app.panel.is_none());
        assert_eq!(app.band_height(60), BAND_HEIGHT);
        app.toggle_output();
        app.toggle_output();
        assert!(app.panel.is_none(), "Ctrl-O again closes it");
        app.toggle_output();
        assert_eq!(
            app.interrupt(),
            Action::None,
            "Ctrl-C closes the panel first"
        );
        assert_eq!(app.interrupt(), Action::Quit);
    }

    #[test]
    fn a_short_output_panel_is_only_as_tall_as_its_text_and_notes_truncation() {
        let mut app = App::default();
        let mut e = event("tool.result", None);
        e.output = Some(ToolOutput {
            id: "i".into(),
            text: "one\ntwo\n".into(),
            lines: 900,
            bytes: 90_000,
            truncated: true,
            shown_lines: 20,
        });
        app.handle(Outbound::Event(e));
        app.toggle_output();
        assert_eq!(app.band_height(60), 3 + 2 + 3);
        let rows = drawn(&app, 60);
        assert!(
            rows[4].contains("truncated: 900 lines, 90000 bytes"),
            "{rows:?}"
        );
    }

    #[test]
    fn an_approval_or_a_choice_arriving_closes_the_panel() {
        let mut app = App::default();
        app.handle(result_with("a\n", 1));
        app.toggle_output();
        assert!(app.panel.is_some());
        app.handle(Outbound::Approval(approval("git push", "git push", &[])));
        assert!(app.panel.is_none());
        app.toggle_output();
        assert!(app.panel.is_none(), "Ctrl-O does nothing under a dialog");
        assert_eq!(app.show_context(), Action::None);
        app.approval = None;
        app.toggle_output();
        app.handle(Outbound::Choice(choice(&["a"], false)));
        assert!(app.panel.is_none());
    }

    #[test]
    fn ctrl_t_asks_for_the_context_only_when_idle_and_a_view_opens_the_panel() {
        let mut app = App {
            status: Some(Status::default()),
            busy: true,
            ..Default::default()
        };
        assert_eq!(app.show_context(), Action::None, "not while a turn runs");
        app.busy = false;
        assert_eq!(
            app.show_context(),
            Action::Send(Inbound::Message {
                text: "/inspect context next".into()
            })
        );
        assert!(app.take_pending().is_empty(), "not echoed");
        assert_eq!(app.show_context(), Action::None, "one request at a time");
        app.handle(view("context", None, 4));
        assert!(!app.context_asked);
        let rows = drawn(&app, 60);
        assert!(
            rows[1].starts_with(" ╭ context · next request "),
            "{rows:?}"
        );
        assert!(rows[3].contains("body"));
        assert!(rows.iter().any(|r| r.contains("←→ turns")), "{rows:?}");
        app.handle(view("context", Some(3), 4));
        assert!(drawn(&app, 60)[1].contains(" context · turn 3 "));
        app.handle(view("turns", None, 4));
        let rows = drawn(&app, 60);
        assert!(rows[1].contains(" context · turns "));
        assert!(!rows.iter().any(|r| r.contains("←→ turns")));
        assert_eq!(
            app.step_turn(false),
            Action::None,
            "no stepping in the table"
        );
        app.handle(view("facts", None, 4));
        let rows = drawn(&app, 60);
        assert!(rows[1].contains(" facts "), "{rows:?}");
        assert!(!rows.iter().any(|r| r.contains("←→ turns")));
        app.handle(view("summary", None, 4));
        let rows = drawn(&app, 60);
        assert!(rows[1].contains(" summary "), "{rows:?}");
        assert!(!rows.iter().any(|r| r.contains("←→ turns")));
    }

    #[test]
    fn left_and_right_step_through_turns_one_request_at_a_time() {
        let ask = |text: &str| Action::Send(Inbound::Message { text: text.into() });
        let mut app = App::default();
        app.handle(view("context", None, 4));
        assert_eq!(
            app.step_turn(true),
            Action::None,
            "nothing after the next request"
        );
        assert_eq!(app.step_turn(false), ask("/inspect context 4"));
        assert_eq!(
            app.step_turn(false),
            Action::None,
            "a request is outstanding"
        );
        app.handle(view("context", Some(4), 4));
        assert_eq!(app.step_turn(false), ask("/inspect context 3"));
        app.handle(view("context", Some(1), 4));
        assert_eq!(app.step_turn(false), Action::None, "not below turn 1");
        assert_eq!(app.step_turn(true), ask("/inspect context 2"));
        app.handle(view("context", Some(4), 4));
        assert_eq!(app.step_turn(true), ask("/inspect context next"));
        // An invalid turn answers with a note, which clears the outstanding flag.
        app.handle(Outbound::Note {
            text: "no turn 9: this conversation's turns run from 1 to 4".into(),
        });
        assert!(!app.context_asked);
        assert_eq!(app.step_turn(false), ask("/inspect context 3"));
        // No turns yet: nowhere to step back to.
        let mut fresh = App::default();
        fresh.handle(view("context", None, 0));
        assert_eq!(fresh.step_turn(false), Action::None);
        // Esc closes; Left does nothing without a panel.
        assert_eq!(app.cancel(), Action::None);
        assert_eq!(app.step_turn(false), Action::None);
    }

    #[test]
    fn long_panel_lines_wrap_and_control_characters_are_dropped() {
        assert_eq!(wrap_rows("abcdef", 4), vec!["abcd", "ef"]);
        assert_eq!(wrap_rows("a\u{1b}b\tc", 20), vec!["ab    c"]);
        assert_eq!(wrap_rows("", 4), vec![""]);
        assert_eq!(wrap_rows("x\n\ny", 4), vec!["x", "", "y"]);
    }

    fn turn(phase: &str, number: u64, seconds: Option<f64>, outcome: Option<&str>) -> Turn {
        Turn {
            phase: phase.into(),
            number,
            seconds,
            outcome: outcome.map(str::to_string),
            input_tokens: None,
            output_tokens: None,
            ran: None,
            cited: None,
        }
    }

    #[test]
    fn a_turns_end_shows_what_it_ran_under_the_reply_muted() {
        let mut app = App::default();
        app.handle(Outbound::Turn(turn("start", 1, None, None)));
        app.handle(Outbound::Delta {
            text: "Removed it.".into(),
        });
        let mut ended = turn("end", 1, Some(1.0), Some("ok"));
        ended.ran = Some("ran: no tools".into());
        app.handle(Outbound::Turn(ended));
        assert_eq!(
            texts(&mut app),
            vec![
                ("Removed it.".to_string(), LineKind::Reply),
                ("ran: no tools".to_string(), LineKind::Note)
            ]
        );
        app.handle(Outbound::Turn(turn("end", 2, Some(1.0), Some("ok"))));
        assert!(texts(&mut app).is_empty());
        // The entries a reply cites that do not exist are named beside it (ADR 0055).
        let mut cited = turn("end", 3, Some(1.0), Some("ok"));
        cited.ran = Some("ran: inspect".into());
        cited.cited = Some("cited but not in this conversation: entries 19–30 (12)".into());
        app.handle(Outbound::Turn(cited));
        assert_eq!(
            texts(&mut app),
            vec![
                ("ran: inspect".to_string(), LineKind::Note),
                (
                    "cited but not in this conversation: entries 19–30 (12)".to_string(),
                    LineKind::Note
                )
            ]
        );
    }

    #[test]
    fn deltas_commit_whole_lines_and_status_flushes_the_rest() {
        let mut app = App::default();
        app.handle(Outbound::Delta {
            text: "The ".into(),
        });
        app.handle(Outbound::Delta {
            text: "date\nis".into(),
        });
        assert_eq!(
            app.take_pending(),
            vec![HistoryLine {
                text: "The date".into(),
                kind: LineKind::Reply
            }]
        );
        assert_eq!(app.partial, "is");
        app.handle(Outbound::Status(Status::default()));
        assert_eq!(app.take_pending()[0].text, "is");
        assert!(app.partial.is_empty());
        assert!(!app.busy);
    }

    #[test]
    fn events_show_the_line_wisp_words_and_turns_mark_the_status() {
        let mut app = App::default();
        app.handle(Outbound::Event(event(
            "tool.call",
            Some("⚙ run_command git status"),
        )));
        app.handle(Outbound::Event(event("prompt", None)));
        app.handle(Outbound::Event(event(
            "error",
            Some("  ↳ error: no such file"),
        )));
        let lines = app.take_pending();
        assert_eq!(
            lines
                .iter()
                .map(|line| (line.text.as_str(), line.kind))
                .collect::<Vec<_>>(),
            vec![
                ("⚙ run_command git status", LineKind::Tool),
                ("  ↳ error: no such file", LineKind::Error)
            ]
        );
        app.handle(Outbound::Turn(turn("start", 3, None, None)));
        assert!(app.busy);
        assert_eq!(app.turn, Some(TurnState::Running(3)));
        app.handle(Outbound::Delta {
            text: "done".into(),
        });
        app.handle(Outbound::Turn(turn("end", 3, Some(2.25), Some("ok"))));
        assert_eq!(app.take_pending()[0].text, "done");
        assert_eq!(
            app.turn,
            Some(TurnState::Ended {
                seconds: 2.25,
                failed: false,
                tokens: None
            })
        );
        app.handle(Outbound::Turn(turn("end", 4, Some(0.5), Some("error"))));
        assert_eq!(
            app.turn,
            Some(TurnState::Ended {
                seconds: 0.5,
                failed: true,
                tokens: None
            })
        );
        let mut counted = turn("end", 5, Some(3.1), Some("ok"));
        counted.input_tokens = Some(4009);
        counted.output_tokens = Some(79);
        app.handle(Outbound::Turn(counted));
        assert_eq!(
            app.turn,
            Some(TurnState::Ended {
                seconds: 3.1,
                failed: false,
                tokens: Some((4009, 79))
            })
        );
    }

    fn choice(options: &[&str], accepts_text: bool) -> Choice {
        Choice {
            id: "c1".into(),
            title: "approval.classifier: what judges each command".into(),
            options: options
                .iter()
                .map(|v| ChoiceOption {
                    value: (*v).into(),
                    label: (*v).into(),
                    detail: String::new(),
                    cells: Vec::new(),
                    on: None,
                })
                .collect(),
            current: Some("system-model".into()),
            accepts_text,
            toggles: false,
            columns: Vec::new(),
        }
    }

    #[test]
    fn a_choice_with_toggles_takes_space_and_saves_the_rows_left_on() {
        let mut app = App {
            status: Some(Status::default()),
            busy: true,
            ..Default::default()
        };
        let mut models = choice(&["system", "ollama:a"], false);
        models.toggles = true;
        models.current = Some("system".into());
        models.columns = vec![crate::protocol::ChoiceColumn {
            heading: "MODEL".into(),
            drop: 0,
        }];
        for (option, on) in models.options.iter_mut().zip([true, false]) {
            option.cells = vec![option.value.clone()];
            option.on = Some(on);
        }
        app.handle(Outbound::Choice(models.clone()));
        let rows = drawn(&app, 80);
        assert!(
            rows.iter().any(|row| row.contains("▸ [x] * system")),
            "{rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("  [ ]   ollama:a")),
            "{rows:?}"
        );
        app.type_char(' ');
        app.recall_next();
        app.type_char(' ');
        app.type_char('x');
        assert!(
            app.editor.is_empty(),
            "a choice with toggles takes no typing"
        );
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: None,
                values: Some(vec!["ollama:a".into()])
            })
        );
        // The save runs as part of the `/models` command, so the box stays busy until wisp's next status, and the
        // check that enabling an MLX model runs shows each line of its progress as it comes (ADR 0056).
        assert!(app.busy);
        app.handle(Outbound::Note {
            text: "  tool calling: passed in 1.2 s".into(),
        });
        assert!(
            app.take_pending()
                .iter()
                .any(|line| line.text == "  tool calling: passed in 1.2 s"),
            "progress is shown while the save runs"
        );
        // Esc leaves it: nothing is saved.
        app.handle(Outbound::Choice(models));
        assert_eq!(
            app.cancel(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: None,
                values: None
            })
        );
    }

    #[test]
    fn a_choice_takes_the_arrows_enter_and_esc_and_takes_the_input_place() {
        let mut app = App {
            status: Some(Status::default()),
            busy: true,
            ..Default::default()
        };
        app.handle(Outbound::Choice(choice(
            &["rules", "system-model", "coreml"],
            false,
        )));
        assert_eq!(
            app.band_height(60),
            1 + 5 + 2 + 2,
            "reply, question, three options, keys, border, a blank row, status"
        );
        let rows = drawn(&app, 60);
        assert!(rows[1].starts_with(" ╭ choose "), "{rows:?}");
        assert!(rows[4].contains("▸ system-model *"), "{rows:?}");
        app.recall_next();
        app.type_char('x');
        assert!(app.editor.is_empty(), "a fixed choice takes no typing");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: Some("coreml".into()),
                values: None
            })
        );
        assert!(app.picker.is_none());
        app.handle(Outbound::Choice(choice(&[], true)));
        for c in "30".chars() {
            app.type_char(c);
        }
        let typed = drawn(&app, 60);
        assert!(typed.iter().any(|row| row.contains("› 30")), "{typed:?}");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: Some("30".into()),
                values: None
            })
        );
        assert!(app.editor.is_empty());
        app.handle(Outbound::Choice(choice(&["a"], false)));
        assert_eq!(
            app.cancel(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: None,
                values: None
            })
        );
        app.handle(Outbound::Choice(choice(&["a"], false)));
        assert!(matches!(
            app.interrupt(),
            Action::Send(Inbound::Choose { value: None, .. })
        ));
        assert_eq!(
            app.cancel(),
            Action::None,
            "Esc with nothing open does nothing"
        );
    }

    fn completions(id: &str, from: usize, candidates: &[&str]) -> Outbound {
        Outbound::Completions {
            id: id.into(),
            from,
            candidates: candidates.iter().map(|c| (*c).to_string()).collect(),
        }
    }

    #[test]
    fn tab_asks_wisp_and_fills_in_one_match_or_what_several_share() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.editor.set("hello");
        assert_eq!(
            app.complete(),
            Action::None,
            "only a slash command completes"
        );
        app.editor.set("/con");
        assert_eq!(
            app.complete(),
            Action::Send(Inbound::Complete {
                id: "k1".into(),
                text: "/con".into(),
                cursor: 4
            })
        );
        app.handle(completions("k1", 0, &["/config"]));
        assert_eq!(app.editor.text(), "/config ");
        // Several fill in what they share, show above the input, and Tab cycles through them.
        app.editor.set("/config set approval.c");
        app.complete();
        app.handle(completions(
            "k2",
            12,
            &["approval.classifier", "approval.coremlModel"],
        ));
        assert_eq!(app.editor.text(), "/config set approval.c");
        let rows = drawn(&app, 80);
        assert!(
            rows[1].contains("approval.classifier  approval.coremlModel"),
            "{rows:?}"
        );
        app.complete();
        assert_eq!(app.editor.text(), "/config set approval.classifier");
        app.complete();
        assert_eq!(app.editor.text(), "/config set approval.coremlModel");
        app.complete();
        assert_eq!(app.editor.text(), "/config set approval.classifier");
        // Typing clears them; a late answer to an older request is ignored.
        app.type_char(' ');
        assert!(app.suggestions.is_none());
        app.complete();
        app.handle(completions("k1", 0, &["/stale"]));
        assert_eq!(app.editor.text(), "/config set approval.classifier ");
        app.handle(completions("k3", 32, &["coreml", "rules"]));
        assert_eq!(
            common_prefix(&["coreml".into(), "coremlx".into()]),
            "coreml"
        );
        assert_eq!(common_prefix(&[]), "");
    }

    #[test]
    fn fenced_blocks_are_code_until_they_close_or_the_turn_ends() {
        let mut app = App::default();
        app.handle(Outbound::Delta {
            text: "Run:\n```sh\ngit **status**\n```\nthen\n```\nleft open\n".into(),
        });
        let kinds: Vec<LineKind> = app.take_pending().iter().map(|line| line.kind).collect();
        assert_eq!(
            kinds,
            vec![
                LineKind::Reply,
                LineKind::Fence,
                LineKind::Code,
                LineKind::Fence,
                LineKind::Reply,
                LineKind::Fence,
                LineKind::Code
            ]
        );
        app.handle(Outbound::Turn(turn("end", 1, Some(1.0), Some("ok"))));
        app.handle(Outbound::Delta {
            text: "fresh\n".into(),
        });
        assert_eq!(app.take_pending()[0].kind, LineKind::Reply);
    }

    #[test]
    fn keys_drive_input_and_approvals() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        for c in "hi".chars() {
            assert_eq!(app.type_char(c), Action::None);
        }
        app.edit(&Edit::Backspace);
        app.type_char('o');
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message { text: "ho".into() })
        );
        assert!(app.busy);
        assert_eq!(
            app.take_pending()[0],
            HistoryLine {
                text: "› ho".into(),
                kind: LineKind::User
            }
        );
        // Typing while busy is held, not shown; a dialog takes over the keys.
        app.type_char('x');
        assert!(app.editor.is_empty() && app.held == vec![Edit::Insert('x')]);
        app.handle(Outbound::Approval(Approval {
            id: "a1".into(),
            command: "git push".into(),
            line: "git push".into(),
            pattern: "git push *".into(),
            directory: "/r".into(),
            level: "dangerous".into(),
            reasons: vec!["changes repository state".into()],
            ..Approval::default()
        }));
        // The reasons are in the dialog, not the scrollback.
        assert!(app.take_pending().is_empty());
        assert_eq!(app.type_char('q'), Action::None);
        assert_eq!(
            app.type_char('S'),
            Action::Send(Inbound::Answer {
                id: "a1".into(),
                decision: "session".into()
            })
        );
        assert!(app.approval.is_none());
        assert_eq!(
            app.take_pending()[0].text,
            "⚠ approved for this session: git push"
        );
        assert_eq!(app.interrupt(), Action::Quit);
    }

    fn approval(command: &str, line: &str, reasons: &[&str]) -> Approval {
        Approval {
            id: "a".into(),
            command: command.into(),
            line: line.into(),
            pattern: "git push *".into(),
            directory: "/repo".into(),
            level: "dangerous".into(),
            reasons: reasons.iter().map(|r| (*r).to_string()).collect(),
            ..Approval::default()
        }
    }

    fn mcp_approval(id: &str, command: &str) -> Approval {
        Approval {
            id: id.into(),
            command: command.into(),
            line: command.into(),
            pattern: "git push *".into(),
            directory: "/repo".into(),
            level: "moderate".into(),
            source: Some("mcp".into()),
            thread: Some("git".into()),
            client: Some("claude-code".into()),
            ..Approval::default()
        }
    }

    fn fact_to_keep(id: &str) -> Approval {
        Approval {
            id: id.into(),
            command: "release codename = BLUE HERON".into(),
            line: "release codename = BLUE HERON".into(),
            level: "safe".into(),
            source: Some("mcp".into()),
            thread: Some("git".into()),
            client: Some("claude-code".into()),
            kind: Some("fact".into()),
            fact: Some(FactAsk {
                id: "c3".into(),
                subject: "entity".into(),
                name: "release codename".into(),
                value: "BLUE HERON".into(),
                source: "model".into(),
            }),
            ..Approval::default()
        }
    }

    #[test]
    fn a_fact_to_keep_is_answered_keep_or_drop_and_refused_by_default() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.handle(Outbound::Approval(fact_to_keep("mcp-1")));
        // The command keys mean nothing here.
        assert_eq!(app.type_char('y'), Action::None);
        assert!(app.approval.is_some());
        assert_eq!(
            app.type_char('k'),
            Action::Send(Inbound::Answer {
                id: "mcp-1".into(),
                decision: "keep".into()
            })
        );
        assert!(app.approval.is_none());
        assert!(app.take_pending().iter().any(|line| {
            line.text
                .contains("kept as a permanent fact: release codename")
        }));
        app.handle(Outbound::Approval(fact_to_keep("mcp-2")));
        assert_eq!(
            app.type_char('D'),
            Action::Send(Inbound::Answer {
                id: "mcp-2".into(),
                decision: "drop".into()
            })
        );
        // Ctrl-C refuses: a fact is dropped, as a command is refused.
        app.handle(Outbound::Approval(fact_to_keep("mcp-3")));
        assert_eq!(
            app.interrupt(),
            Action::Send(Inbound::Answer {
                id: "mcp-3".into(),
                decision: "drop".into()
            })
        );
    }

    #[test]
    fn a_fact_to_keep_says_what_it_is_and_where_it_waits() {
        let lines: Vec<String> = fact_lines(&fact_to_keep("mcp-1"), 60)
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .map(|span| span.content.as_ref())
                    .collect()
            })
            .collect();
        assert_eq!(lines[0], "release codename = BLUE HERON");
        assert!(
            lines.contains(&"asked by claude-code, thread git in wisp mcp".to_string()),
            "{lines:?}"
        );
        assert!(
            lines.contains(&"fact c3 (entity), from the model".to_string()),
            "{lines:?}"
        );
        assert_eq!(
            lines.last().map(String::as_str),
            Some("[k]eep [d]rop (stays in its thread)")
        );
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.handle(Outbound::Approval(fact_to_keep("mcp-1")));
        let screen = drawn(&app, 60).join("\n");
        assert!(
            screen.contains("keep as a permanent fact? · wisp mcp"),
            "{screen}"
        );
        // Withdrawn when it is answered elsewhere, as a command is.
        app.handle(Outbound::Withdrawn { id: "mcp-1".into() });
        assert!(app.approval.is_none());
    }

    #[test]
    fn approvals_from_wisp_mcp_queue_behind_the_one_shown_and_can_be_withdrawn() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.handle(Outbound::Approval(approval("git push", "git push", &[])));
        app.handle(Outbound::Approval(mcp_approval("mcp-1", "git tag v1")));
        app.handle(Outbound::Approval(mcp_approval("mcp-2", "git push --tags")));
        assert_eq!(app.queued.len(), 2);
        // Answering the one shown brings up the next.
        assert_eq!(
            app.type_char('y'),
            Action::Send(Inbound::Answer {
                id: "a".into(),
                decision: "once".into()
            })
        );
        assert_eq!(app.approval.as_ref().map(|a| a.id.as_str()), Some("mcp-1"));
        // A queued one answered elsewhere leaves quietly; the one shown leaves with a note.
        app.handle(Outbound::Withdrawn { id: "mcp-2".into() });
        assert!(app.queued.is_empty());
        app.take_pending();
        app.handle(Outbound::Withdrawn { id: "mcp-1".into() });
        assert!(app.approval.is_none());
        assert_eq!(
            app.take_pending()[0].text,
            "⚠ answered elsewhere: git tag v1"
        );
        // An unknown id changes nothing.
        app.handle(Outbound::Withdrawn { id: "mcp-9".into() });
        assert!(app.approval.is_none());
    }

    #[test]
    fn an_mcp_approval_says_where_it_waits() {
        let lines: Vec<String> = dialog_lines(&mcp_approval("mcp-1", "git push"), 60)
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .map(|span| span.content.as_ref())
                    .collect()
            })
            .collect();
        assert!(
            lines.contains(&"waiting in wisp mcp for claude-code, thread git".to_string()),
            "{lines:?}"
        );
        let own: Vec<String> = dialog_lines(&approval("git push", "git push", &[]), 60)
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .map(|span| span.content.as_ref())
                    .collect()
            })
            .collect();
        assert!(!own.iter().any(|line| line.contains("wisp mcp")));
    }

    fn drawn(app: &App, width: u16) -> Vec<String> {
        let height = app.band_height(width);
        let mut terminal = Terminal::new(TestBackend::new(width, height)).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer().clone();
        (0..height)
            .map(|y| {
                (0..width)
                    .map(|x| buffer[(x, y)].symbol().to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn a_dialog_takes_the_input_place_with_everything_inside_a_border() {
        let mut app = App {
            status: Some(Status {
                model: "system".into(),
                ..Status::default()
            }),
            busy: true,
            ..Default::default()
        };
        app.handle(Outbound::Approval(approval(
            "git push",
            "git add -A && git push",
            &["changes repository state", "reaches the network"],
        )));
        // Reply row, border, command, line, directory, two reasons, pattern, a space, keys, border, a blank
        // row, status.
        assert_eq!(app.band_height(60), 13);
        let rows = drawn(&app, 60);
        assert!(rows[1].starts_with(" ╭ approve · dangerous "), "{rows:?}");
        assert_eq!(rows[2].trim_end_matches([' ', '│']), " │ git push");
        assert!(rows[3].contains("part of: git add -A && git push"));
        assert!(rows[4].contains("in /repo"));
        assert!(rows[5].contains("- changes repository state"));
        assert!(rows[6].contains("- reaches the network"));
        assert!(rows[7].contains("remembered as git push *"));
        // The keys stand one empty row below the pattern, inside the border.
        assert!(rows[8].starts_with(" │"), "{rows:?}");
        assert!(rows[8].trim_matches([' ', '│']).is_empty(), "{rows:?}");
        assert!(rows[9].contains("[y]once [s]ession [p]roject 30d [a]lways 30d [n]o"));
        assert!(rows[10].starts_with(" ╰"));
        // A blank row sets the dialog off from the status, as the reply row does above it.
        assert!(rows[11].trim().is_empty(), "{rows:?}");
        assert!(rows[12].contains("system"));
        // A command that is its whole line has no "part of" row: command, directory, pattern, space, keys.
        let only_command = approval("git push", "git push", &[]);
        assert_eq!(dialog_lines(&only_command, 50).len(), 5);
        // Answering gives the band back to the input.
        app.type_char('n');
        app.busy = false;
        assert_eq!(app.band_height(60), BAND_HEIGHT);
        assert_eq!(app.take_pending()[0].text, "⚠ refused: git push");
    }

    #[test]
    fn a_long_command_wraps_and_long_lines_are_cut_to_fit() {
        let long = approval(&"x".repeat(50), "y", &[&"r".repeat(40)]);
        let lines = dialog_lines(&long, 20);
        let text = |line: &Line| {
            line.spans
                .iter()
                .map(|s| s.content.as_ref())
                .collect::<String>()
        };
        assert_eq!(text(&lines[0]), "x".repeat(20));
        assert_eq!(text(&lines[2]), "x".repeat(10));
        assert_eq!(text(&lines[5]), format!("- {}…", "r".repeat(17)));
        let huge = approval(&"z".repeat(200), "z", &[]);
        let cut = dialog_lines(&huge, 20);
        assert_eq!(text(&cut[3]), format!("{}…", "z".repeat(19)));
        assert!(text(&cut[4]).starts_with("part of"));
        assert_eq!(fit("日本語", 5), "日本…");
        assert_eq!(fit("short", 5), "short");
    }

    #[test]
    fn up_and_down_recall_submitted_lines() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        // Nothing to recall yet: Up leaves the input alone.
        app.recall_previous();
        assert!(app.editor.is_empty());
        for line in ["first", "second", "second", "third"] {
            app.editor.set(line);
            app.submit();
            app.handle(Outbound::Status(Status::default()));
        }
        // A line repeating the one before it is kept once.
        assert_eq!(app.recall, vec!["first", "second", "third"]);
        app.editor.set("draft");
        app.recall_previous();
        assert_eq!(app.editor.text(), "third");
        app.recall_previous();
        app.recall_previous();
        assert_eq!(app.editor.text(), "first");
        // Up at the oldest stays there.
        app.recall_previous();
        assert_eq!(app.editor.text(), "first");
        app.recall_next();
        assert_eq!(app.editor.text(), "second");
        app.recall_next();
        app.recall_next();
        // Down past the newest restores what was being typed.
        assert_eq!(app.editor.text(), "draft");
        assert_eq!(app.recall_at, None);
        app.recall_next();
        assert_eq!(app.editor.text(), "draft");
        // A recalled line can be edited and sent; it joins the end of the list.
        app.recall_previous();
        app.type_char('!');
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "third!".into()
            })
        );
        assert_eq!(app.recall.last().map(String::as_str), Some("third!"));
        // Busy or in a dialog, the keys do nothing.
        app.recall_previous();
        assert!(app.editor.is_empty());
    }

    #[test]
    fn edits_go_to_the_input_only_while_typing_is_taken() {
        let mut app = App::default();
        app.edit(&Edit::Paste("git log\n-3".into()));
        app.edit(&Edit::Home);
        app.type_char('>');
        assert_eq!(app.editor.text(), ">git log\n-3");
        app.busy = true;
        app.edit(&Edit::KillToEnd);
        assert_eq!(app.editor.text(), ">git log\n-3");
        app.busy = false;
        app.approval = Some(Approval {
            id: "a".into(),
            command: "x".into(),
            line: "x".into(),
            pattern: "x".into(),
            directory: "/".into(),
            level: "moderate".into(),
            reasons: vec![],
            ..Approval::default()
        });
        app.edit(&Edit::Backspace);
        assert_eq!(app.editor.text(), ">git log\n-3");
    }

    #[test]
    fn the_terminal_cursor_sits_where_typing_goes() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.editor.set("hello world");
        app.edit(&Edit::WordLeft);
        let backend = TestBackend::new(40, BAND_HEIGHT);
        let mut terminal = Terminal::new(backend).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        // The margin, the prompt's two cells, then "hello ".
        let position = terminal.get_cursor_position().expect("cursor");
        assert_eq!((position.x, position.y), (MARGIN + 2 + 6, INPUT_ROW));
        // Longer than the row: the text wraps, and a one-row band shows the cursor's row.
        app.editor.set(&"x".repeat(100));
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let position = terminal.get_cursor_position().expect("cursor");
        // 36 cells a row after the margins and the prompt: 100 = 36 + 36 + 28.
        assert_eq!((position.x, position.y), (MARGIN + 2 + 28, INPUT_ROW));
    }

    #[test]
    fn the_band_grows_with_the_input_and_draws_every_row() {
        let mut app = App {
            status: Some(Status {
                model: "system".into(),
                ..Status::default()
            }),
            ..Default::default()
        };
        assert_eq!(app.band_height(40), BAND_HEIGHT);
        app.editor.set("first line\nsecond\nthird");
        assert_eq!(app.band_height(40), BAND_HEIGHT + 2);
        app.editor.set(&"line\n".repeat(20));
        assert_eq!(app.band_height(40), BAND_HEIGHT + MAX_INPUT_ROWS - 1);
        app.editor.set("first line\nsecond\nthird");
        let height = app.band_height(40);
        let backend = TestBackend::new(40, height);
        let mut terminal = Terminal::new(backend).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer();
        let row = |index: u16| -> String {
            (0..40)
                .map(|x| buffer[(x, index)].symbol().to_string())
                .collect::<String>()
                .trim_end()
                .to_string()
        };
        assert_eq!(row(INPUT_ROW), " › first line");
        assert_eq!(row(INPUT_ROW + 1), "   second");
        assert_eq!(row(INPUT_ROW + 2), "   third");
        assert_eq!(buffer[(0, INPUT_ROW + 2)].bg, palette::DEEP);
        assert_eq!(buffer[(0, INPUT_ROW + 3)].symbol(), "▀");
        assert!(
            row(height - 1).starts_with(" system"),
            "status: {}",
            row(height - 1)
        );
        let position = terminal.get_cursor_position().expect("cursor");
        assert_eq!((position.x, position.y), (MARGIN + 2 + 5, INPUT_ROW + 2));
    }

    #[test]
    fn recall_keeps_only_the_latest_lines() {
        let mut app = App::default();
        for index in 0..=RECALL_LIMIT {
            app.editor.set(&format!("line {index}"));
            app.submit();
            app.busy = false;
        }
        assert_eq!(app.recall.len(), RECALL_LIMIT);
        assert_eq!(app.recall[0], "line 1");
    }

    #[test]
    fn a_running_turn_says_what_it_is_doing_and_for_how_long() {
        let start = Instant::now();
        let activity = |doing: &str, after: u64| Activity {
            doing: doing.into(),
            turn_started: start,
            since: start + Duration::from_secs(after),
            thinking: false,
        };
        let at = |seconds: u64| start + Duration::from_secs(seconds);
        assert_eq!(
            activity("waiting for the model", 0).label(at(3)),
            "3 s · waiting for the model"
        );
        assert_eq!(
            activity("running git status", 4).label(at(12)),
            "12 s · running git status (8 s)"
        );
        let mut app = App::default();
        app.handle(Outbound::Turn(turn("start", 1, None, None)));
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"running git status","asking":false,"turnSeconds":2.0}"#,
        ));
        let label = app.working_label(Instant::now()).unwrap_or_default();
        assert!(label.starts_with("2 s · running git status"), "{label}");
        app.handle(Outbound::Turn(turn("end", 1, Some(2.5), Some("ok"))));
        assert_eq!(app.activity, None);
        assert_eq!(app.working_label(Instant::now()), None);
    }

    #[test]
    fn the_status_line_names_the_last_turns_tokens_when_the_model_reports_them() {
        let text = |tokens| {
            let app = App {
                status: Some(Status {
                    model: "system".into(),
                    directory: "~/x".into(),
                    branch: None,
                    dirty: None,
                    added: None,
                    removed: None,
                    approval: "moderate".into(),
                    context_used: None,
                }),
                turn: Some(TurnState::Ended {
                    seconds: 3.1,
                    failed: false,
                    tokens,
                }),
                ..Default::default()
            };
            app.status_line(120)
                .spans
                .iter()
                .map(|span| span.content.to_string())
                .collect::<String>()
        };
        assert!(text(Some((4009, 79))).ends_with("moderate · last:3.1s · ↓4,009 ↑79"));
        assert!(text(None).ends_with("moderate · last:3.1s"));
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(1_234_567), "1,234,567");
    }

    #[test]
    fn the_status_line_puts_changes_after_the_branch_and_the_rest_on_the_right() {
        let status = Status {
            model: "system".into(),
            directory: "~/src/github.com/pidster/wisp".into(),
            branch: Some("main".into()),
            dirty: Some(true),
            added: Some(12),
            removed: Some(3),
            approval: "approve at moderate".into(),
            context_used: Some(0.15),
        };
        let app = App {
            status: Some(status.clone()),
            ..Default::default()
        };
        let line = app.status_line(80);
        let text: String = line
            .spans
            .iter()
            .map(|span| span.content.to_string())
            .collect();
        assert!(
            text.starts_with("system:15% used · ~/src/github.com/pidster/wisp:main+12-3   "),
            "{text}"
        );
        assert!(
            text.ends_with("approve at moderate") && line.width() == 80,
            "{text}"
        );
        let branch = line.spans.iter().find(|span| span.content == "main");
        assert_eq!(branch.map(|span| span.style.fg), Some(Some(palette::GLOW)));
        let used = line.spans.iter().find(|span| span.content == "15% used");
        assert_eq!(used.map(|span| span.style.fg), Some(Some(palette::MIST)));
        let half = App {
            status: Some(Status {
                context_used: Some(0.6),
                ..status.clone()
            }),
            ..Default::default()
        };
        let half_line = half.status_line(80);
        let bright = half_line
            .spans
            .iter()
            .find(|span| span.content == "60% used");
        assert_eq!(bright.map(|span| span.style.fg), Some(Some(palette::GLOW)));
        assert_eq!(palette::TOKENS_OUT, palette::GLOW);
        let added = line.spans.iter().find(|span| span.content == "+12");
        assert_eq!(added.map(|span| span.style.fg), Some(Some(palette::ADDED)));
        let removed = line.spans.iter().find(|span| span.content == "-3");
        assert_eq!(
            removed.map(|span| span.style.fg),
            Some(Some(palette::REMOVED))
        );
        // Too narrow for the whole path: it shortens to its last folder.
        let narrow: String = app
            .status_line(50)
            .spans
            .iter()
            .map(|span| span.content.to_string())
            .collect();
        assert!(
            narrow.starts_with("system:15% used · …/wisp:main+12-3"),
            "{narrow}"
        );
        // Dirty without counts, as before a first commit, is a star.
        let unborn = App {
            status: Some(Status {
                added: None,
                removed: None,
                ..status
            }),
            ..Default::default()
        };
        let text: String = unborn
            .status_line(80)
            .spans
            .iter()
            .map(|span| span.content.to_string())
            .collect();
        assert!(text.contains("wisp:main*"), "{text}");
    }

    #[test]
    fn the_band_renders_status_input_and_dialog() {
        let app = App {
            status: Some(Status {
                model: "system".into(),
                directory: "~/x".into(),
                branch: Some("main".into()),
                dirty: Some(false),
                added: Some(0),
                removed: Some(0),
                approval: "--yes".into(),
                context_used: Some(0.137),
            }),
            editor: {
                let mut editor = Editor::default();
                editor.set("hello");
                editor
            },
            partial: "so far".into(),
            ..Default::default()
        };
        let backend = TestBackend::new(60, BAND_HEIGHT);
        let mut terminal = Terminal::new(backend).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer();
        let row = |index: u16| -> String {
            (0..60)
                .map(|x| buffer[(x, index)].symbol().to_string())
                .collect::<String>()
                .trim_end()
                .to_string()
        };
        assert_eq!(row(0), " so far");
        assert_eq!(row(1), "");
        assert_eq!(row(INPUT_ROW), " › hello");
        assert_eq!(
            row(STATUS_ROW),
            format!(" system:14% used · ~/x:main{}--yes", " ".repeat(27))
        );
        // The input row's tint runs edge to edge, with half-block strips above and below in the tint.
        assert_eq!(buffer[(0, INPUT_ROW)].bg, palette::DEEP);
        assert_eq!(buffer[(59, INPUT_ROW)].bg, palette::DEEP);
        assert_eq!(buffer[(0, INPUT_ROW - 1)].symbol(), "▄");
        assert_eq!(buffer[(59, INPUT_ROW - 1)].fg, palette::DEEP);
        assert_eq!(buffer[(0, INPUT_ROW + 1)].symbol(), "▀");
        assert_eq!(buffer[(0, INPUT_ROW + 1)].bg, ratatui::style::Color::Reset);
        assert_eq!(buffer[(0, STATUS_ROW)].bg, ratatui::style::Color::Reset);
        assert_eq!(buffer[(1, INPUT_ROW)].fg, palette::GLOW);
        // An empty input shows the placeholder; a nearly full context turns amber.
        let mut status = app.status.clone().unwrap_or_default();
        status.context_used = Some(0.9);
        let empty = App {
            status: Some(status),
            ..Default::default()
        };
        terminal
            .draw(|frame| empty.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer();
        let text: String = (0..60)
            .map(|x| buffer[(x, INPUT_ROW)].symbol().to_string())
            .collect();
        assert_eq!(text.trim_end(), format!(" › {PLACEHOLDER}"));
        let row3: String = (0..60)
            .map(|x| buffer[(x, STATUS_ROW)].symbol().to_string())
            .collect();
        let at = row3.find("90% used").unwrap_or(0);
        let column = u16::try_from(row3[..at].chars().count()).unwrap_or(0);
        assert!(at > 0, "no context part in {row3}");
        assert_eq!(buffer[(column, STATUS_ROW)].fg, palette::AMBER);
    }

    #[test]
    fn a_bang_in_an_empty_box_enters_command_mode_and_backspace_at_the_start_or_delete_leaves_it() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        // `!` into an empty box is the switch, not text.
        assert_eq!(app.type_char('!'), Action::None);
        assert!(app.command_mode && app.editor.is_empty());
        for c in "ls".chars() {
            app.type_char(c);
        }
        assert_eq!(app.editor.text(), "ls");
        // Backspace deletes text first; at the start of the line it leaves command mode.
        app.edit(&Edit::Backspace);
        app.edit(&Edit::Backspace);
        assert!(app.command_mode && app.editor.is_empty());
        app.edit(&Edit::Backspace);
        assert!(!app.command_mode && app.editor.is_empty());
        // Backspace with the cursor at the start leaves command mode and keeps the text as ordinary input.
        app.type_char('!');
        for c in "git status".chars() {
            app.type_char(c);
        }
        app.edit(&Edit::Home);
        app.edit(&Edit::Backspace);
        assert_eq!(
            (app.editor.text().as_str(), app.command_mode),
            ("git status", false)
        );
        // The opposite: `!` typed at the start of a line with text enters command mode around that text.
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.command_mode),
            ("git status", true)
        );
        // In command mode a `!` at the start is text.
        app.type_char('!');
        assert_eq!(app.editor.text(), "!git status");
        app.edit(&Edit::Backspace);
        app.edit(&Edit::Backspace);
        assert!(!app.command_mode);
        app.edit(&Edit::KillToEnd);
        // Delete in an empty box leaves it too; with text, Delete deletes forwards and stays.
        app.type_char('!');
        app.type_char('x');
        app.edit(&Edit::Home);
        app.edit(&Edit::Delete);
        assert!(app.command_mode && app.editor.is_empty());
        assert!(app.command_mode);
        app.edit(&Edit::Delete);
        assert!(!app.command_mode);
        // A `!` after other text stays text, and in a box emptied by other edits the next `!` switches again.
        app.type_char('a');
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.command_mode),
            ("a!", false)
        );
        app.edit(&Edit::KillToStart);
        app.type_char('!');
        assert!(app.command_mode && app.editor.is_empty());
        // A paste that starts with `!` into an empty box enters command mode with the rest.
        app.edit(&Edit::Backspace);
        app.edit(&Edit::Paste("!git log -3".into()));
        assert_eq!(
            (app.editor.text().as_str(), app.command_mode),
            ("git log -3", true)
        );
    }

    #[test]
    fn sending_in_command_mode_runs_the_command_and_returns_the_box_to_normal() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.type_char('!');
        // An empty command sends nothing.
        assert_eq!(app.submit(), Action::None);
        assert!(app.command_mode && !app.busy);
        app.editor.set(" git status --short ");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "!git status --short".into()
            })
        );
        assert!(!app.command_mode && app.editor.is_empty() && app.busy);
        assert_eq!(
            app.take_pending(),
            vec![HistoryLine {
                text: "! git status --short".into(),
                kind: LineKind::Command
            }]
        );
        // Its output arrives as a `command.typed` event and folds like a tool's.
        app.handle(Outbound::parse(
            r#"{"type":"event","kind":"command.typed","call":null,"turn":null,"details":{},"text":null,"output":{"id":"e1","text":"a\nb\nc\n","lines":3,"bytes":6,"truncated":false,"shownLines":2}}"#,
        ));
        let lines: Vec<String> = app.take_pending().into_iter().map(|l| l.text).collect();
        assert_eq!(
            lines,
            vec!["    a", "    b", "    … 1 more line · ctrl-o shows all"]
        );
        assert_eq!(app.last_output.as_ref().map(|o| o.id.as_str()), Some("e1"));
        app.handle(Outbound::Status(Status::default()));
        // Text in the normal box that starts with `!` is what wisp runs as a command, and is shown as one.
        app.editor.set("!pwd");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "!pwd".into()
            })
        );
        assert_eq!(app.take_pending()[0].kind, LineKind::Command);
        app.handle(Outbound::Status(Status::default()));
        // A command recalled comes back in command mode, and the draft keeps its mode too.
        assert_eq!(app.recall, vec!["!git status --short", "!pwd"]);
        app.editor.set("half");
        app.recall_previous();
        assert_eq!(
            (app.editor.text().as_str(), app.command_mode),
            ("pwd", true)
        );
        app.recall_next();
        assert_eq!(
            (app.editor.text().as_str(), app.command_mode),
            ("half", false)
        );
        app.editor.set("");
        app.type_char('!');
        app.type_char('w');
        app.recall_previous();
        app.recall_next();
        assert_eq!((app.editor.text().as_str(), app.command_mode), ("w", true));
    }

    #[test]
    fn the_thought_bubble_grows_then_its_last_four_frames_loop() {
        let at = |frames: u32| THINKING_FRAME * frames + Duration::from_millis(1);
        let shown: Vec<&str> = (0..15)
            .map(|n| THINKING_FRAMES[thinking_frame(at(n))])
            .collect();
        assert_eq!(
            shown,
            [
                ".",
                ".o",
                ".oO",
                ".oO( thinking )",
                ".oO( thinking. )",
                ".oO( thinking.. )",
                ".oO( thinking... )",
                ".oO( thinking )",
                ".oO( thinking. )",
                ".oO( thinking.. )",
                ".oO( thinking... )",
                ".oO( thinking )",
                ".oO( thinking. )",
                ".oO( thinking.. )",
                ".oO( thinking... )",
            ]
        );
        // Within a frame the bubble holds; the loop wakes at the next frame's start.
        assert_eq!(thinking_frame(Duration::ZERO), 0);
        assert_eq!(
            thinking_frame(THINKING_FRAME.saturating_sub(Duration::from_millis(1))),
            0
        );
        assert_eq!(until_next_frame(Duration::ZERO), THINKING_FRAME);
        assert_eq!(
            until_next_frame(THINKING_FRAME + Duration::from_millis(30)),
            THINKING_FRAME.saturating_sub(Duration::from_millis(30))
        );
    }

    #[test]
    fn the_busy_box_draws_the_thought_bubble_while_the_model_thinks() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.handle(Outbound::Turn(turn("start", 1, None, None)));
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"thinking","asking":false,"turnSeconds":0.5,"thinking":true}"#,
        ));
        let Some(since) = app.thinking_since() else {
            panic!("not thinking");
        };
        assert_eq!(app.busy_label(since), ".");
        assert_eq!(
            app.busy_label(since + THINKING_FRAME * 3),
            ".oO( thinking )"
        );
        assert_eq!(
            app.busy_label(since + THINKING_FRAME * 7),
            ".oO( thinking )"
        );
        // The box holds the bubble alone, dimmed, with no cursor; the loop wakes for its frames.
        let (lines, cursor) = app.input_lines(60, 1);
        assert!(cursor.is_none());
        assert!(
            lines[0]
                .spans
                .iter()
                .all(|span| span.style == palette::busy())
        );
        assert!(
            app.next_frame_in(since)
                .is_some_and(|wait| wait <= THINKING_FRAME)
        );
        let early = app.live_label(since).unwrap_or_default();
        let later = app.live_label(since + THINKING_FRAME).unwrap_or_default();
        assert!(
            early.ends_with(" .") && later.ends_with(" .o"),
            "{early} / {later}"
        );
        // A key held meanwhile is counted after the bubble.
        app.type_char('x');
        assert_eq!(app.busy_label(since), ". · 1 key held");
        // When it stops thinking, the box says what wisp is doing again and the loop keeps its pace.
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"waiting for the model","asking":false,"turnSeconds":3.0}"#,
        ));
        assert_eq!(app.thinking_since(), None);
        assert_eq!(app.next_frame_in(Instant::now()), None);
        assert_eq!(
            app.busy_label(Instant::now()),
            "working: waiting for the model · 1 key held"
        );
        // Thinking is shown only while a turn runs.
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"thinking","asking":false,"turnSeconds":3.0,"thinking":true}"#,
        ));
        app.busy = false;
        assert_eq!(app.thinking_since(), None);
    }

    #[test]
    fn the_models_thinking_is_folded_like_output_and_opens_in_its_own_panel() {
        let mut app = App::default();
        app.handle(Outbound::parse(
            r#"{"type":"event","kind":"model.reasoning","details":{"phase":"end"},"text":"∴ thought for 1.2 s, 9 tokens","output":{"id":"0123456789abcdef","text":"one\ntwo\nthree\n","lines":3,"bytes":14,"truncated":false,"shownLines":1}}"#,
        ));
        let texts: Vec<String> = app.pending.iter().map(|line| line.text.clone()).collect();
        assert!(
            texts.iter().any(|t| t == "∴ thought for 1.2 s, 9 tokens"),
            "{texts:?}"
        );
        assert!(texts.iter().any(|t| t.contains("one")), "{texts:?}");
        assert!(!texts.iter().any(|t| t.contains("three")), "{texts:?}");
        app.handle(Outbound::parse(
            r##"{"type":"view","kind":"thinking","turn":2,"turns":3,"text":"# The model's thinking in turn 2"}"##,
        ));
        let Some(panel) = app.panel.as_ref() else {
            panic!("no panel");
        };
        assert_eq!(panel.kind, PanelKind::Thinking(Some(2)));
        assert_eq!(panel.title(), " thinking · turn 2 ");
    }

    #[test]
    fn keys_typed_while_a_turn_runs_are_held_and_applied_when_it_ends() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.editor.set("hello");
        app.submit();
        app.handle(Outbound::Turn(turn("start", 1, None, None)));
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"read_file README.md","asking":false,"turnSeconds":1.0}"#,
        ));
        // Typed meanwhile: not taken into the box, and not lost.
        for c in "!ls".chars() {
            assert_eq!(app.type_char(c), Action::None);
        }
        app.edit(&Edit::Backspace);
        assert!(app.editor.is_empty() && !app.command_mode);
        assert_eq!(app.held.len(), 4);
        assert_eq!(
            app.busy_label(Instant::now()),
            "working: read_file README.md · 4 keys held"
        );
        // Enter does not send while held.
        assert_eq!(app.submit(), Action::None);
        // The box is dimmed, says what wisp is doing, and has no cursor.
        let (lines, cursor) = app.input_lines(60, 1);
        assert!(cursor.is_none());
        let text: String = lines[0]
            .spans
            .iter()
            .map(|span| span.content.as_ref())
            .collect();
        assert_eq!(text, "… working: read_file README.md · 4 keys held");
        assert!(
            lines[0]
                .spans
                .iter()
                .all(|span| span.style == palette::busy())
        );
        assert!(drawn(&app, 60)[usize::from(INPUT_ROW)].contains("working: read_file"));
        // The turn ends and the keys apply in order: `!` switches, `l` and `s` type, Backspace deletes `s`.
        app.handle(Outbound::Turn(turn("end", 1, Some(1.0), Some("ok"))));
        app.handle(Outbound::Status(Status::default()));
        assert!(app.held.is_empty() && !app.busy);
        assert_eq!((app.editor.text().as_str(), app.command_mode), ("l", true));
        // With no activity yet, the box still says it is working.
        app.busy = true;
        app.activity = None;
        assert_eq!(app.busy_label(Instant::now()), "working…");
        // A dialog takes its keys even while busy; they are not held.
        app.approval = Some(approval("rm x", "rm x", &[]));
        app.type_char('q');
        assert!(app.held.is_empty());
    }

    #[test]
    fn command_mode_tints_the_box_in_the_command_colour_with_black_text() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.type_char('!');
        let width = 80;
        let height = app.band_height(width);
        let mut terminal = Terminal::new(TestBackend::new(width, height)).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer().clone();
        let row: String = (0..width)
            .map(|x| buffer[(x, INPUT_ROW)].symbol().to_string())
            .collect();
        assert_eq!(row.trim_end(), format!(" ! {COMMAND_PLACEHOLDER}"));
        assert_eq!(buffer[(0, INPUT_ROW)].bg, palette::COMMAND);
        assert_eq!(buffer[(width - 1, INPUT_ROW)].bg, palette::COMMAND);
        assert_eq!(buffer[(1, INPUT_ROW)].fg, palette::BLACK);
        assert!(!buffer[(3, INPUT_ROW)].modifier.contains(Modifier::BOLD));
        assert_eq!(buffer[(0, INPUT_ROW - 1)].fg, palette::COMMAND);
        assert_eq!(buffer[(0, INPUT_ROW + 1)].fg, palette::COMMAND);
        app.editor.set("ls");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer().clone();
        assert_eq!(buffer[(3, INPUT_ROW)].symbol(), "l");
        assert_eq!(buffer[(3, INPUT_ROW)].fg, palette::BLACK);
        assert_eq!(buffer[(3, INPUT_ROW)].bg, palette::COMMAND);
        // Typed text is bold, as in the normal box; the empty box's hint is not.
        assert!(buffer[(3, INPUT_ROW)].modifier.contains(Modifier::BOLD));
        let position = terminal.get_cursor_position().expect("cursor");
        assert_eq!((position.x, position.y), (MARGIN + 2 + 2, INPUT_ROW));
        // Back to normal, the box is the deep tint again.
        app.editor.set("");
        app.edit(&Edit::Backspace);
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        assert_eq!(
            terminal.backend().buffer()[(0, INPUT_ROW)].bg,
            palette::DEEP
        );
    }
}
