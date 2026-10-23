//! The front end's state and rendering: the conversation in the pane above (ADR 0068), and the band at the bottom
//! holding the reply in progress, the input or an approval dialog, and the status.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Padding, Paragraph};
use std::cell::Cell;
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use unicode_width::UnicodeWidthChar;

use crate::editor::{Edit, Editor};
use crate::markdown;
use crate::palette;
use crate::pane::Pane;
use crate::picker::Picker;
use crate::protocol::{
    Approval, Choice, Inbound, Notice, Outbound, Status, ToolOutput, Turn, View,
};
use crate::transcript::Transcript;

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
/// The placeholder in outside mode, where what is typed runs as a shell command outside the sandbox (ADR 0064,
/// amended 2026-10-14).
pub const OUTSIDE_PLACEHOLDER: &str =
    "Run a command yourself OUTSIDE the sandbox: it may write anywhere you can";
/// The placeholder in help mode, where Enter shows the help.
pub const HELP_PLACEHOLDER: &str =
    "Enter for every command, or a word to find the ones that mention it";
/// How many submitted lines Up and Down can recall; the same bound as the chat's `/history`.
pub const RECALL_LIMIT: usize = 100;
/// How long the keyboard must be quiet after an approval dialog appears before a key answers it. A key
/// pressed sooner was meant for the input box (the person was typing when the dialog came up): it is held
/// for the box and the wait starts again, so a dialog is never answered by a letter typed before it was seen.
pub const DIALOG_GRACE: Duration = Duration::from_millis(500);
/// The longest a turn's seconds are taken as, so a nonsensical `turnSeconds` cannot overflow a `Duration`.
const LONGEST_TURN: Duration = Duration::from_hours(24);

/// The clock dialogs are timed by: the system's, unless a test has set it.
#[derive(Debug, Default)]
pub struct Clock {
    /// The time a test has set; `None` reads the system clock.
    fixed: Cell<Option<Instant>>,
}

impl Clock {
    /// The time now.
    pub fn now(&self) -> Instant {
        self.fixed.get().unwrap_or_else(Instant::now)
    }

    /// Moves the clock on by `by`, fixing it from then on.
    #[cfg(test)]
    pub fn advance(&self, by: Duration) {
        self.fixed.set(Some(self.now() + by));
    }
}

/// `seconds` as a duration, for a value a front end only displays: negative, not a number, or past a day
/// is taken as zero or a day rather than panicking.
fn bounded_seconds(seconds: f64) -> Duration {
    if seconds.is_nan() || seconds <= 0.0 {
        return Duration::ZERO;
    }
    Duration::try_from_secs_f64(seconds).map_or(LONGEST_TURN, |duration| duration.min(LONGEST_TURN))
}

/// A line of the conversation, with its style.
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
    /// A command the user ran outside the sandbox, echoed with its `!!` (ADR 0064, amended 2026-10-14).
    Outside,
    /// A request for the help from help mode, echoed with its `?`.
    Help,
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
    /// A tool's output, or a stretch of thinking, indented under its result line.
    ToolOutput,
    /// The info line of an output or a stretch of thinking that folds: `▸ 248 lines · 12.0 KiB · exit 0` (ADR 0068).
    Fold,
}

/// Whether a line begins a new part of a turn, to be set apart by a blank line from the line before it: a tool call
/// (`⚙`) or a stretch of thinking (`∴`), the reply's first line, or the `ran:` line under it. Not straight after a
/// sent line, whose tinted strip already sets it apart, nor at the very start.
pub(crate) fn starts_part(previous: Option<LineKind>, kind: LineKind, text: &str) -> bool {
    let reply = |kind| matches!(kind, LineKind::Reply | LineKind::Code | LineKind::Fence);
    let Some(previous) = previous else {
        return false;
    };
    if matches!(
        previous,
        LineKind::User | LineKind::Command | LineKind::Outside | LineKind::Help
    ) {
        return false;
    }
    match kind {
        LineKind::Tool => text.starts_with('⚙') || text.starts_with('∴'),
        LineKind::Note => text.starts_with("ran:"),
        kind => reply(kind) && !reply(previous),
    }
}

/// What the input box sends: a message, a command run in the sandbox (`!`, ADR 0049), a command run outside it
/// (`!!`, ADR 0064, amended 2026-10-14), or a request for the help (`?`). `!` typed at the start of the line steps up
/// one mode, `?` there in the normal box enters help mode, and Backspace there (or Delete in an empty box) steps down
/// one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InputMode {
    /// The normal prompt: a message for the model, or a chat command.
    #[default]
    Normal,
    /// Command mode: what is typed runs as a shell command in the sandbox, and the box takes the command colour.
    Command,
    /// Outside mode: what is typed runs as a shell command outside the sandbox, and the box takes the outside colour.
    Outside,
    /// Help mode: Enter shows `/help`, only the lines that mention what is typed when something is, and the box
    /// turns grey.
    Help,
}

impl InputMode {
    /// The marks the line wisp is sent starts with in this mode: none, `!`, `!!`, or `?`.
    #[must_use]
    pub fn marks(self) -> &'static str {
        match self {
            InputMode::Normal => "",
            InputMode::Command => "!",
            InputMode::Outside => "!!",
            InputMode::Help => "?",
        }
    }

    /// The mode a `!` typed at the start of the line switches to, or `None` in outside and help mode, where it is
    /// text.
    #[must_use]
    pub fn up(self) -> Option<Self> {
        match self {
            InputMode::Normal => Some(InputMode::Command),
            InputMode::Command => Some(InputMode::Outside),
            InputMode::Outside | InputMode::Help => None,
        }
    }

    /// The mode Backspace at the start of the line (or Delete in an empty box) steps back to.
    #[must_use]
    pub fn down(self) -> Self {
        match self {
            InputMode::Outside => InputMode::Command,
            InputMode::Command | InputMode::Help | InputMode::Normal => InputMode::Normal,
        }
    }

    /// The mode a line's marks put the box in, and the text after them: `!!` outside, `!` command, `?` help, else
    /// normal.
    #[must_use]
    pub fn split(line: &str) -> (Self, &str) {
        if let Some(rest) = line.strip_prefix("!!") {
            (InputMode::Outside, rest)
        } else if let Some(rest) = line.strip_prefix('!') {
            (InputMode::Command, rest)
        } else if let Some(rest) = line.strip_prefix('?') {
            (InputMode::Help, rest)
        } else {
            (InputMode::Normal, line)
        }
    }
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

/// Pages of a tool's output whole the panel holds at once: scrolling past them loads the next and drops
/// the farthest, so an output of up to wisp's 16 MiB ceiling is never held whole (ADR 0050).
pub const OUTPUT_PAGES_HELD: usize = 4;

/// The whole of a tool's output in the panel, asked of wisp a page at a time as the panel scrolls (ADR
/// 0050): the pages held run in order from `first`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PagedOutput {
    /// The id of the event that recorded the output, which every request names.
    pub id: String,
    /// The event's audit session, when wisp named one.
    pub session: Option<String>,
    /// wisp's line saying what it is: the whole from the output store, or what the tool returned and why.
    pub header: String,
    /// The pages in all.
    pub pages: u64,
    /// The first page held, from 1; 0 before any has arrived.
    pub first: u64,
    /// The pages held, in order.
    pub held: VecDeque<String>,
    /// The page asked for and not yet arrived.
    pub asked: Option<u64>,
}

impl PagedOutput {
    /// The last page held; 0 before any.
    fn last(&self) -> u64 {
        self.first + self.held.len() as u64 - u64::from(!self.held.is_empty())
    }

    /// The panel's rows at `width` cells: the header, a line when earlier pages are not held, each page held,
    /// and a line when later ones are not; with the row each held page starts on.
    fn rows(&self, width: usize) -> (Vec<String>, Vec<usize>) {
        let mut rows = wrap_rows(&self.header, width);
        if self.first > 1 {
            rows.push(format!("↑ pages 1–{} above: scroll up", self.first - 1));
        }
        let mut starts = Vec::with_capacity(self.held.len());
        for page in &self.held {
            starts.push(rows.len());
            rows.extend(wrap_rows(page, width));
        }
        if self.last() < self.pages {
            rows.push(format!(
                "↓ page {} of {}: scroll down for more",
                self.last(),
                self.pages
            ));
        }
        (rows, starts)
    }

    /// The request for page `page`, remembered as asked.
    fn ask(&mut self, page: u64) -> Inbound {
        self.asked = Some(page);
        Inbound::Output {
            id: self.id.clone(),
            session: self.session.clone(),
            page,
        }
    }

    /// Takes page `page` into the pages held when it follows the last or precedes the first, dropping the
    /// farthest beyond `OUTPUT_PAGES_HELD`, and moves `scroll` so the rows in view stay in view. Any other
    /// page, arriving late, is ignored.
    fn take(&mut self, page: u64, text: String, scroll: &mut usize, width: usize) {
        if self.asked == Some(page) {
            self.asked = None;
        }
        if self.held.is_empty() {
            self.first = page;
            self.held.push_back(text);
            *scroll = 0;
            return;
        }
        // Where the view is: a page held and a row within it, or the header above them.
        let (_, starts) = self.rows(width);
        let anchor = starts
            .iter()
            .rposition(|start| *start <= *scroll)
            .map(|index| (self.first + index as u64, *scroll - starts[index]));
        if page == self.last() + 1 {
            self.held.push_back(text);
            if self.held.len() > OUTPUT_PAGES_HELD {
                self.held.pop_front();
                self.first += 1;
            }
        } else if page + 1 == self.first {
            self.held.push_front(text);
            self.first = page;
            if self.held.len() > OUTPUT_PAGES_HELD {
                self.held.pop_back();
            }
        } else {
            return;
        }
        let (rows, starts) = self.rows(width);
        if let Some((at, offset)) = anchor {
            *scroll = at
                .checked_sub(self.first)
                .and_then(|index| usize::try_from(index).ok())
                .and_then(|index| starts.get(index))
                .map_or(0, |start| start + offset);
        }
        *scroll = (*scroll).min(rows.len().saturating_sub(1));
    }
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
    /// For an output, its whole as wisp sends it a page at a time; until a page arrives the panel shows
    /// `text`, the output as the event carried it.
    pub paged: Option<PagedOutput>,
}

impl Panel {
    /// The title on the top border.
    fn title(&self) -> String {
        match self.kind {
            PanelKind::Output => match &self.paged {
                Some(paged) if paged.held.is_empty() => {
                    " output · asking wisp for the whole ".into()
                }
                Some(paged) if paged.pages > 1 => format!(
                    " output · pages {}–{} of {} ",
                    paged.first,
                    paged.last(),
                    paged.pages
                ),
                _ => " output ".into(),
            },
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
pub(crate) fn sanitise(line: &str) -> String {
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

/// An item of the status bar that can take the focus (Down from the input's last row) and does something when
/// activated with Enter or Space, in the order the bar shows them, left to right. Each opens a view or a dialog that
/// already exists; none answers anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BarItem {
    /// The model: sends `/model`, which offers the models to switch to in a picker.
    Model,
    /// The context gauge (`15% used`): the model's context in the panel, as Ctrl-T opens it.
    Context,
    /// Whether the model thinks (`think off`): sends `/think`, which offers the choices in a picker.
    Think,
    /// `questions: N`, the model's questions waiting for the person: the first one's picker.
    Questions,
    /// `approvals: N`, the approvals (commands, and facts to keep) waiting: the first one's dialog.
    Approvals,
    /// The last turn's time and tokens: the turn list (`/inspect context turns`) in the panel.
    Turn,
}

impl BarItem {
    /// What activating it does, for the hint above the input.
    fn hint(self) -> &'static str {
        match self {
            Self::Model => "switch the model",
            Self::Context => "show the context",
            Self::Think => "set the thinking",
            Self::Questions => "answer the question",
            Self::Approvals => "answer the approval",
            Self::Turn => "list the turns",
        }
    }
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
    /// Whether Ctrl-C stops what is under way, sent as `interrupt`: a command typed after `!`, or a model's
    /// turn (ADR 0049, amended 2026-10-09 and 2026-10-11).
    pub stoppable: bool,
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
    /// The conversation, element by element, as the pane draws it (ADR 0068).
    pub transcript: Transcript,
    /// Where the pane is in the conversation.
    pub pane: Pane,
    /// How many of the transcript's lines a test has taken (`take_pending`).
    #[cfg(test)]
    taken: usize,
    /// The reply so far on the current line, not yet committed.
    pub partial: String,
    /// What the user has typed.
    pub editor: Editor,
    /// The last status wisp sent.
    pub status: Option<Status>,
    /// An approval awaiting an answer.
    pub approval: Option<Approval>,
    /// Approvals that arrived while one was shown, oldest first: commands waiting in `wisp mcp` servers can
    /// arrive at any time, beside this conversation's own. One from `wisp mcp` also waits here while the input
    /// box has text in it, so it never takes over a line being typed; the status line says it waits.
    pub queued: VecDeque<Approval>,
    /// When the keyboard was last active around the approval shown: when it appeared, then each key pressed
    /// within `DIALOG_GRACE` of the last. `None` once the grace has passed, and a key answers the dialog.
    pub dialog_quiet_from: Option<Instant>,
    /// The clock the grace is timed by.
    pub clock: Clock,
    /// A choice awaiting an answer.
    pub picker: Option<Picker>,
    /// The model's questions that arrived while a choice was open, oldest first (ADR 0062): questions waiting in
    /// `wisp mcp` servers can arrive at any time, and one of those also waits here while the input box has text.
    pub queued_questions: VecDeque<Choice>,
    /// The id of the completion asked for and not yet answered.
    pub completing: Option<String>,
    /// Completion requests sent, for their ids.
    pub completions_asked: u64,
    /// Candidates from the last completion with more than one, shown above the input and cycled by
    /// Tab; any other edit clears them.
    pub suggestions: Option<Suggestions>,
    /// Whether a turn is in progress (input is held until the next status).
    pub busy: bool,
    /// The command typed after `!` that wisp is running, until the next status: it has no timeout, so Ctrl-C
    /// stops it rather than quitting (ADR 0049, amended 2026-10-09).
    pub running_command: Option<String>,
    /// Whether Ctrl-C has asked wisp to stop `running_command`; a second Ctrl-C then quits.
    pub stopping: bool,
    /// Whether the line sent last is a chat command (`/…`), which starts no model turn, until the next status:
    /// stoppable work it reports (a `/models pull`, ADR 0059) is shown and stopped as a running command, while
    /// a message's stoppable activity is the model's turn (ADR 0049, amended 2026-10-11).
    pub slash_sent: bool,
    /// The input box's mode: normal, command mode (`!` typed at the start of the line, so what is typed runs as a
    /// shell command, ADR 0049, and the box takes the command colour), or outside mode (`!` typed again at the start,
    /// so it runs outside the sandbox, ADR 0064 amended 2026-10-14, and the box takes the outside colour), or help
    /// mode (`?` typed at the start of the normal box, so Enter shows the help, and the box turns grey).
    pub mode: InputMode,
    /// Keys typed while a turn runs, or in a dialog's grace, in order: not shown as accepted, and applied to the
    /// input box when it next takes typing (the turn has ended and no dialog or choice is open), as if typed
    /// then. They are never replayed into a dialog or a choice.
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
    /// Lines for wisp that no key returned, such as a page of an output the panel scrolled to; the main
    /// loop sends them after each event.
    pub requests: Vec<Inbound>,
    /// The output pages asked of wisp and not yet arrived, by event id and page, newest last: a page that
    /// was not asked for is `/show`'s or `/last`'s, and opens the panel; one asked for a panel since closed
    /// is dropped.
    outputs_asked: VecDeque<(String, u64)>,
    /// The panel over the band, when open.
    pub panel: Option<Panel>,
    /// Whether an `/inspect context` request from a key is awaiting its view.
    pub context_asked: bool,
    /// Notifications wisp asked to be posted, written to the terminal between frames.
    pub notices: Vec<Notice>,
    /// The width the band was last sized for, so scrolling knows how the text wraps.
    band_width: Cell<u16>,
    /// The status bar item with the focus, while the bar has it (`focused` says whether it still does); `None`
    /// while the input has it.
    pub bar: Option<BarItem>,
    /// The line the input box held when a picker opened over it (from the status bar, with a draft typed), put back
    /// when the picker closes, so a picker's typed answer never takes in, or clears, what was being written.
    pub parked: Option<String>,
    /// An OSC 52 sequence setting the clipboard (Ctrl-Y, ADR 0068), written to the terminal between frames.
    pub copied: Option<Vec<u8>>,
    /// A line said in the row above the input until the next key, such as what Ctrl-Y copied.
    pub flash: Option<String>,
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
    /// model thinks, the thought bubble's frame; an idle wake redraws only when this has changed. While a
    /// command typed after `!` runs, its seconds in the busy box.
    pub fn live_label(&self, now: Instant) -> Option<String> {
        if self.busy && self.running_command.is_some() {
            return Some(self.busy_label(now));
        }
        let working = self.working_label(now)?;
        Some(match self.thinking_since() {
            Some(_) => format!("{working} {}", self.busy_label(now)),
            None => working,
        })
    }

    /// A `vcs` line: the version control's part of the status line as a read after the status found it. Only that part
    /// changes, so a turn under way, or the input held, stays as it is; before the first status there is nothing to
    /// redraw.
    fn redraw_place(&mut self, vcs: crate::protocol::VcsUpdate) {
        if let Some(status) = self.status.as_mut() {
            status.vcs = vcs.vcs;
            status.branch = vcs.branch;
            status.dirty = vcs.dirty;
            status.added = vcs.added;
            status.removed = vcs.removed;
        }
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
        if let Some(verified) = &turn.verified {
            self.push(verified, LineKind::Note);
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

    /// Applies one line from wisp. A dialog, a choice, or the panel that it opens over the input takes the focus
    /// from the status bar; the focus returns to the input, not the bar, when they close.
    pub fn handle(&mut self, outbound: Outbound) {
        self.apply(outbound);
        if !self.bar_open() {
            self.bar = None;
        }
    }

    /// Applies one line from wisp to the state, as `handle` does.
    fn apply(&mut self, outbound: Outbound) {
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
            Outbound::Vcs(vcs) => self.redraw_place(vcs),
            Outbound::Status(status) => {
                self.flush_partial();
                self.status = Some(status);
                self.busy = false;
                self.running_command = None;
                self.slash_sent = false;
                self.stopping = false;
                // Nothing is under way at a prompt, so nothing is left for Ctrl-C to stop.
                self.activity = None;
                self.show_next();
            }
            Outbound::Activity {
                doing,
                turn_seconds,
                thinking,
                stoppable,
                ..
            } => {
                // Stoppable work a chat command started (a `/models pull`, ADR 0059) is held as the command
                // running, so the busy box shows its progress and Ctrl-C stops it; a message's stoppable activity
                // is the model's turn, which `interrupt()` stops without it.
                if stoppable && self.slash_sent && self.running_command.is_none() {
                    self.running_command.clone_from(&doing);
                    self.stopping = false;
                    self.busy = true;
                }
                let now = Instant::now();
                self.activity = doing.map(|doing| Activity {
                    doing,
                    turn_started: now
                        .checked_sub(bounded_seconds(turn_seconds))
                        .unwrap_or(now),
                    since: now,
                    thinking,
                    stoppable,
                });
            }
            Outbound::Turn(turn) => self.turned(&turn),
            Outbound::Event(event) => self.event(event),
            Outbound::Approval(approval) => self.arrived(approval),
            Outbound::Withdrawn { id } => self.withdrawn(&id),
            Outbound::Choice(choice) if choice.is_question() => self.asked(choice),
            Outbound::Choice(choice) => {
                self.flush_partial();
                self.open_picker(choice);
            }
            Outbound::View(view) if view.kind == "output" => {
                self.flush_partial();
                self.output_page(view);
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

    /// An audit event: its line, the exit status of a command it reports, and an output, which the element it ends
    /// takes.
    fn event(&mut self, event: crate::protocol::Event) {
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
        // A command's exit status, for the info line its output folds to.
        if let Some(status) = event
            .details
            .get("exitStatus")
            .and_then(serde_json::Value::as_i64)
        {
            self.transcript.set_exit(status);
        }
        if let Some(output) = event.output {
            self.show_output(output);
        }
    }

    /// Opens a picker for `choice` in the input's place. A line in the box is parked, and put back when the
    /// picker closes (`close_picker`), so a picker that takes typed text starts empty and the draft survives it.
    fn open_picker(&mut self, choice: Choice) {
        if self.picker.is_none() && !self.editor.is_empty() {
            self.parked = Some(self.line());
            self.editor.take();
            self.mode = InputMode::Normal;
            self.suggestions = None;
        }
        self.panel = None;
        self.bar = None;
        self.picker = Some(Picker::new(choice));
    }

    /// Clears what was typed into a picker that has closed, and puts back the line parked when it opened.
    fn close_picker(&mut self) {
        self.editor.take();
        if let Some(line) = self.parked.take() {
            self.set_line(&line);
        }
    }

    /// Whether the status bar can take the focus: wisp has sent a status, no turn runs, and nothing (a dialog, a
    /// choice, the panel) is open over the input.
    fn bar_open(&self) -> bool {
        self.status.is_some()
            && !self.busy
            && self.approval.is_none()
            && self.picker.is_none()
            && self.panel.is_none()
    }

    /// The model's questions waiting for the person (ADR 0062): the one on screen, if any, and those queued, this
    /// conversation's or from `wisp mcp`.
    pub fn questions_waiting(&self) -> usize {
        self.queued_questions.len()
            + usize::from(
                self.picker
                    .as_ref()
                    .is_some_and(|picker| picker.choice.is_question()),
            )
    }

    /// The approvals waiting for the person: the dialog on screen, if any, and those queued (from `wisp mcp`, while
    /// a line is typed), commands and facts to keep alike.
    pub fn approvals_waiting(&self) -> usize {
        self.queued.len() + usize::from(self.approval.is_some())
    }

    /// The status bar's items that can take the focus now, in the order shown: the model, the context gauge when
    /// wisp reports it, the questions and the approvals waiting when there are any, and the last turn once one has
    /// ended. None while the bar cannot take the focus.
    pub fn bar_items(&self) -> Vec<BarItem> {
        let Some(status) = &self.status else {
            return Vec::new();
        };
        let mut items = vec![BarItem::Model];
        if status.think.is_some() {
            items.push(BarItem::Think);
        }
        if status.context_used.is_some() {
            items.push(BarItem::Context);
        }
        if self.questions_waiting() > 0 {
            items.push(BarItem::Questions);
        }
        if self.approvals_waiting() > 0 {
            items.push(BarItem::Approvals);
        }
        if matches!(self.turn, Some(TurnState::Ended { .. })) {
            items.push(BarItem::Turn);
        }
        items
    }

    /// The item with the focus, while the bar has it: the one chosen, or the model when that one has gone (its last
    /// question answered elsewhere, say). `None` while the input has the focus or the bar cannot take it.
    pub fn focused(&self) -> Option<BarItem> {
        let item = self.bar.filter(|_| self.bar_open())?;
        Some(if self.bar_items().contains(&item) {
            item
        } else {
            BarItem::Model
        })
    }

    /// Down from the input's last row: the focus moves to the bar's first item, the model, when the bar can take it.
    fn focus_bar(&mut self) {
        if self.bar_open() {
            self.suggestions = None;
            self.bar = Some(BarItem::Model);
        }
    }

    /// Up or Esc in the bar: the focus returns to the input, its line and cursor as they were.
    pub fn leave_bar(&mut self) {
        self.bar = None;
    }

    /// Left or Right (Shift-Tab or Tab, which wrap around) in the bar: the previous or next item.
    pub fn step_bar(&mut self, forward: bool, wrap: bool) {
        let Some(item) = self.focused() else {
            return;
        };
        let items = self.bar_items();
        let at = items.iter().position(|each| *each == item).unwrap_or(0);
        let last = items.len().saturating_sub(1);
        let next = match (forward, wrap) {
            (true, _) if at < last => at + 1,
            (true, true) => 0,
            (false, _) if at > 0 => at - 1,
            (false, true) => last,
            _ => at,
        };
        self.bar = items.get(next).copied();
    }

    /// Home or End in the bar: the first item or the last.
    pub fn bar_edge(&mut self, last: bool) {
        if self.focused().is_none() {
            return;
        }
        let items = self.bar_items();
        self.bar = if last { items.last() } else { items.first() }.copied();
    }

    /// Enter or Space on the focused item: opens what it names, and the focus returns to the input. It only opens:
    /// the model sends `/model`, which offers the models in a picker; the questions show the first waiting
    /// question's picker; the approvals the first waiting approval's dialog, which takes its keys only after its grace
    /// (`DIALOG_GRACE`), as one that arrives does; the gauge and the turn ask for the context and the turn list.
    /// Nothing here answers a dialog or a choice.
    pub fn activate(&mut self) -> Action {
        let Some(item) = self.focused() else {
            return Action::None;
        };
        self.bar = None;
        match item {
            BarItem::Model => {
                // What `submit` does for a slash command, without echoing it: the box is held until wisp's
                // status, and the choice it sends opens as `/model` typed would.
                self.busy = true;
                self.slash_sent = true;
                Action::Send(Inbound::Message {
                    text: "/model".into(),
                })
            }
            BarItem::Context => self.show_context(),
            BarItem::Think => {
                // As the model's item: the box is held until wisp's status, and `/think`'s choice opens as typed.
                self.busy = true;
                self.slash_sent = true;
                Action::Send(Inbound::Message {
                    text: "/think".into(),
                })
            }
            BarItem::Turn => {
                if self.context_asked {
                    return Action::None;
                }
                self.context_asked = true;
                Action::Send(Inbound::Message {
                    text: "/inspect context turns".into(),
                })
            }
            BarItem::Questions => {
                if let Some(question) = self.queued_questions.pop_front() {
                    self.open_picker(question);
                }
                Action::None
            }
            BarItem::Approvals => {
                if let Some(approval) = self.queued.pop_front() {
                    self.approval = Some(approval);
                    self.panel = None;
                    self.dialog_quiet_from = Some(self.clock.now());
                }
                Action::None
            }
        }
    }

    /// Shows an approval in place of any panel, or queues it behind the one shown. One from `wisp mcp` that
    /// arrives while the input box has text waits until the box is empty, with a note saying so.
    fn arrived(&mut self, approval: Approval) {
        self.flush_partial();
        if self.approval.is_none() && approval.is_mcp() && !self.editor.is_empty() {
            self.push(
                &format!(
                    "⚠ waiting in wisp mcp: {} · its dialog opens when the input is empty, or from the status bar",
                    approval.command
                ),
                LineKind::Note,
            );
        }
        self.queued.push_back(approval);
        self.show_next();
    }

    /// Shows the model's question in place of any panel, or queues it behind the choice open. One from `wisp mcp`
    /// that arrives while the input box has text waits until the box is empty, with a note saying so (ADR 0062).
    fn asked(&mut self, question: Choice) {
        self.flush_partial();
        if self.picker.is_none() && question.is_mcp() && !self.editor.is_empty() {
            self.push(
                &format!(
                    "? the model asks in wisp mcp: {} · its dialog opens when the input is empty, or from the status bar",
                    question.title
                ),
                LineKind::Note,
            );
        }
        self.queued_questions.push_back(question);
        self.show_next();
    }

    /// Brings up the next approval when none is shown, and gives the input box the keys held for it. This
    /// conversation's own approvals show at once; one from `wisp mcp` only while the box is empty. A dialog
    /// that appears starts its grace (`DIALOG_GRACE`). Held keys go into the box only with no turn running and
    /// nothing open over it, and before a queued approval is considered, since they are typing in progress.
    fn show_next(&mut self) {
        self.release_held();
        if self.approval.is_some() {
            return;
        }
        let empty = self.editor.is_empty();
        if let Some(index) = self
            .queued
            .iter()
            .position(|approval| !approval.is_mcp() || empty)
        {
            self.approval = self.queued.remove(index);
            self.panel = None;
            self.dialog_quiet_from = Some(self.clock.now());
            return;
        }
        // The model's next question, once no choice is open; one from wisp mcp only while the box is empty.
        if self.picker.is_none()
            && let Some(index) = self
                .queued_questions
                .iter()
                .position(|question| !question.is_mcp() || empty)
            && let Some(question) = self.queued_questions.remove(index)
        {
            self.open_picker(question);
        }
    }

    /// Whether the approval shown is in its grace: it appeared, or a key was pressed, less than `DIALOG_GRACE`
    /// ago. A key in the grace restarts it; once the keyboard has been quiet that long the grace ends for good.
    fn in_grace(&mut self) -> bool {
        let Some(since) = self.dialog_quiet_from else {
            return false;
        };
        let now = self.clock.now();
        if self.approval.is_some() && now.saturating_duration_since(since) < DIALOG_GRACE {
            self.dialog_quiet_from = Some(now);
            true
        } else {
            self.dialog_quiet_from = None;
            false
        }
    }

    /// Drops an approval or a choice that no longer waits (answered another way, withdrawn, or timed out): the
    /// dialog shown is replaced by the next queued one, and an open choice closes, each with a note; a queued
    /// approval is removed quietly.
    fn withdrawn(&mut self, id: &str) {
        if self
            .picker
            .as_ref()
            .is_some_and(|picker| picker.choice.id == id)
        {
            if let Some(picker) = self.picker.take() {
                self.close_picker();
                self.push(
                    &format!("⚠ no longer waiting: {}", picker.choice.title),
                    LineKind::Note,
                );
            }
            self.show_next();
        } else if self
            .approval
            .as_ref()
            .is_some_and(|approval| approval.id == id)
        {
            if let Some(approval) = self.approval.take() {
                self.push(
                    &format!("⚠ no longer waiting: {}", approval.command),
                    LineKind::Note,
                );
            }
            self.show_next();
        } else {
            self.queued.retain(|approval| approval.id != id);
            self.queued_questions.retain(|question| question.id != id);
        }
    }

    /// Gives a tool's output to the element it ends, which draws it (`Element::body_lines`); it is also the last
    /// output, for Ctrl-O.
    fn show_output(&mut self, output: ToolOutput) {
        self.transcript.attach(output.clone());
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
            paged: None,
        });
    }

    /// A page of an output whole (ADR 0050): taken into the output panel that asked for it, or, sent
    /// unasked by `/show` or `/last`, opening the panel on it. A page for a panel since closed is dropped, and
    /// nothing opens over a dialog. When wisp holds no such output the panel keeps what the event carried,
    /// under wisp's line saying so.
    fn output_page(&mut self, view: View) {
        if self.approval.is_some() || self.picker.is_some() {
            return;
        }
        let asked = self
            .outputs_asked
            .iter()
            .position(|(id, page)| *id == view.id && *page == view.page)
            .and_then(|index| self.outputs_asked.remove(index))
            .is_some();
        let waiting = matches!(
            &self.panel,
            Some(Panel { kind: PanelKind::Output, paged: Some(paged), .. }) if paged.id == view.id
        );
        if !waiting {
            if asked || view.page != 1 {
                return; // a late page for a panel since closed
            }
            self.panel = Some(Panel {
                kind: PanelKind::Output,
                text: String::new(),
                scroll: 0,
                turns: 0,
                paged: Some(PagedOutput {
                    id: view.id.clone(),
                    session: view.session.clone(),
                    ..PagedOutput::default()
                }),
            });
        }
        let width = dialog_width(self.panel_width());
        let Some(panel) = &mut self.panel else {
            return;
        };
        if view.pages == 0 {
            panel.paged = None;
            panel.text = if panel.text.is_empty() {
                view.header
            } else {
                format!("{}\n{}", view.header, panel.text)
            };
            return;
        }
        let Some(paged) = &mut panel.paged else {
            return;
        };
        paged.header = view.header;
        paged.pages = view.pages;
        if view.session.is_some() {
            paged.session = view.session;
        }
        if view.page == 0 || view.page > view.pages {
            paged.asked = None;
            return;
        }
        paged.take(view.page, view.text, &mut panel.scroll, width);
    }

    /// The band's width as last drawn, or 80 before the first frame.
    fn panel_width(&self) -> u16 {
        match self.band_width.get() {
            0 => 80,
            width => width,
        }
    }

    /// The lines for wisp waiting to be sent, oldest first.
    pub fn take_requests(&mut self) -> Vec<Inbound> {
        std::mem::take(&mut self.requests)
    }

    /// Queues a request for a page of an output and remembers it as asked (at most 16 remembered).
    fn request_output(&mut self, request: Inbound) {
        if let Inbound::Output { id, page, .. } = &request {
            self.outputs_asked.push_back((id.clone(), *page));
            if self.outputs_asked.len() > 16 {
                self.outputs_asked.pop_front();
            }
        }
        self.requests.push(request);
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
        // The selected element's output, while one is selected (ADR 0068); otherwise the last.
        let selected = self
            .pane
            .selected
            .and_then(|index| self.transcript.elements.get(index))
            .and_then(|element| element.body.clone());
        let Some(output) = selected.as_ref().or(self.last_output.as_ref()) else {
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
        // What the event carried shows at once; wisp is asked for the whole, from its output store when the
        // model was given only part of it (ADR 0050), and the first page replaces it.
        let mut paged = (!output.id.is_empty()).then(|| PagedOutput {
            id: output.id.clone(),
            ..PagedOutput::default()
        });
        if let Some(request) = paged.as_mut().map(|paged| paged.ask(1)) {
            self.request_output(request);
        }
        self.panel = Some(Panel {
            kind: PanelKind::Output,
            text,
            scroll: 0,
            turns: 0,
            paged,
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
        let rows = match &panel.paged {
            Some(paged) if !paged.held.is_empty() => paged.rows(dialog_width(width)).0,
            _ => wrap_rows(&panel.text, dialog_width(width)),
        };
        let visible = rows.len().clamp(1, PANEL_ROWS);
        (rows, visible)
    }

    /// Scrolls the panel by `rows` (negative is up), within its text. An output's whole asks wisp for the
    /// next page when the scroll meets the end of the pages held, or the previous one when it meets the top.
    fn scroll_panel(&mut self, rows: isize) {
        let (all, visible) = self.panel_rows(self.panel_width());
        let Some(panel) = &mut self.panel else {
            return;
        };
        let max = all.len().saturating_sub(visible);
        panel.scroll = panel.scroll.saturating_add_signed(rows).min(max);
        let Some(paged) = &mut panel.paged else {
            return;
        };
        if paged.asked.is_some() || paged.held.is_empty() {
            return;
        }
        let request = if rows > 0 && panel.scroll >= max && paged.last() < paged.pages {
            Some(paged.ask(paged.last() + 1))
        } else if rows < 0 && panel.scroll == 0 && paged.first > 1 {
            Some(paged.ask(paged.first - 1))
        } else {
            None
        };
        if let Some(request) = request {
            self.request_output(request);
        }
    }

    /// `PageUp`: a page up in the panel when one is open, otherwise in the pane.
    pub fn page_up(&mut self) {
        if self.panel.is_some() {
            self.scroll_panel(-isize::try_from(PANEL_ROWS).unwrap_or(1));
        } else {
            self.scroll_pane(-self.pane.page());
        }
    }

    /// `PageDown`: a page down in the panel when one is open, otherwise in the pane.
    pub fn page_down(&mut self) {
        if self.panel.is_some() {
            self.scroll_panel(isize::try_from(PANEL_ROWS).unwrap_or(1));
        } else {
            self.scroll_pane(self.pane.page());
        }
    }

    /// Scrolls the pane by `rows` (negative is up).
    pub fn scroll_pane(&mut self, rows: isize) {
        self.pane.scroll(&self.transcript, rows);
    }

    /// Whether an element is selected and has the keys: nothing (a dialog, a choice, the panel) is open over the
    /// input (ADR 0068).
    pub fn navigating(&self) -> bool {
        self.pane.selected.is_some()
            && self.approval.is_none()
            && self.picker.is_none()
            && self.panel.is_none()
    }

    /// Shift-Up or Shift-Down, or Up or Down while an element is selected: the previous or next element, staying at
    /// either end; Shift-Up from the input selects the last. The element is brought into view.
    pub fn step_element(&mut self, forward: bool) {
        if self.approval.is_some() || self.picker.is_some() || self.panel.is_some() {
            return;
        }
        let count = self.transcript.elements.len();
        if count == 0 {
            return;
        }
        self.bar = None;
        self.suggestions = None;
        self.pane.selected = Some(match self.pane.selected {
            None if forward => return,
            None => count - 1,
            Some(index) if forward => (index + 1).min(count - 1),
            Some(index) => index.saturating_sub(1),
        });
        self.pane.reveal(&self.transcript);
    }

    /// Right, Left, or Enter on the selected element: opens its body (`Some(true)`), folds it (`Some(false)`), or
    /// toggles it (`None`), keeping it in view. An element whose body does not fold is left as it is.
    pub fn fold_element(&mut self, open: Option<bool>) {
        let Some(element) = self
            .pane
            .selected
            .and_then(|index| self.transcript.elements.get_mut(index))
        else {
            return;
        };
        if !element.folds() {
            return;
        }
        element.open = open.unwrap_or(!element.open);
        element.changed();
        self.pane.reveal(&self.transcript);
    }

    /// Ctrl-Y: copies the selected element, or with none selected the last reply, to the clipboard through the
    /// terminal (OSC 52), as plain text and with its body whole; the row above the input says what was copied.
    pub fn copy(&mut self) {
        let element = match self.pane.selected {
            Some(index) => self.transcript.elements.get(index),
            None => self
                .transcript
                .elements
                .iter()
                .rev()
                .find(|element| element.what() == "the reply"),
        };
        let Some(element) = element else {
            self.flash = Some("nothing to copy yet".into());
            return;
        };
        let text = element.plain_text();
        let (copied, cut) = crate::clipboard::bounded(&text);
        let size = crate::transcript::size(u64::try_from(copied.len()).unwrap_or(u64::MAX));
        let what = element.what();
        self.copied = Some(crate::clipboard::osc52(copied));
        self.flash = Some(if cut {
            format!("copied the first {size} of {what}; the clipboard takes no more at once")
        } else if element.released {
            format!("copied {what}, {size}, without its output, which wisp holds: ctrl-o pages it")
        } else {
            format!(
                "copied {what}, {size}, to the clipboard (a terminal without OSC 52 copies nothing)"
            )
        });
    }

    /// The clipboard sequence Ctrl-Y asked for, to write to the terminal.
    pub fn take_copied(&mut self) -> Option<Vec<u8>> {
        self.copied.take()
    }

    /// Esc, or a key that belongs to the input, while an element is selected: the keys return to the input, the
    /// pane staying where it is.
    pub fn leave_elements(&mut self) {
        self.pane.selected = None;
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

    /// Adds a line to the conversation.
    fn push(&mut self, text: &str, kind: LineKind) {
        self.transcript.push(text, kind);
    }

    /// The lines drawn since a test last took them, with an empty note for each blank row between parts.
    #[cfg(test)]
    pub fn take_pending(&mut self) -> Vec<HistoryLine> {
        let lines = self.transcript.lines();
        let new = lines[self.taken.min(lines.len())..].to_vec();
        self.taken = lines.len();
        new
    }

    /// The notifications wisp has asked for since the last call, oldest first.
    pub fn take_notices(&mut self) -> Vec<Notice> {
        std::mem::take(&mut self.notices)
    }

    /// A character typed. With an approval shown it is an answer, unless the dialog is in its grace, when it
    /// is held for the input box instead. Typed while the status bar has the focus, it returns the focus to the
    /// input and goes in, so nothing typed is lost.
    pub fn type_char(&mut self, c: char) -> Action {
        self.bar = None;
        if self.approval.is_some() && self.in_grace() {
            self.held.push(Edit::Insert(c));
            return Action::None;
        }
        if let Some(approval) = &self.approval {
            let decision = if approval.is_fact() {
                match c.to_ascii_lowercase() {
                    'k' => "keep",
                    'd' => "drop",
                    _ => return Action::None,
                }
            } else if approval.outside_sandbox {
                // A run outside the sandbox is approved once or refused; nothing remembers it (ADR 0064).
                match c.to_ascii_lowercase() {
                    'y' => "once",
                    'n' => "no",
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
            let note = if approval.outside_sandbox && decision == "once" {
                format!("⚠ approved once, outside the sandbox: {}", approval.command)
            } else {
                answered(&approval.command, decision)
            };
            self.push(&note, LineKind::Note);
            self.approval = None;
            self.show_next();
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
        self.type_into_box(c);
        Action::None
    }

    /// A character for the input box: `!` at the start of the line steps up a mode (normal to command mode,
    /// command mode to outside mode), `?` there in the normal box enters help mode, anything else is an edit.
    fn type_into_box(&mut self, c: char) {
        if c == '?'
            && self.mode == InputMode::Normal
            && self.typing()
            && self.picker.is_none()
            && self.editor.cursor() == 0
        {
            self.mode = InputMode::Help;
            self.suggestions = None;
            return;
        }
        // `!` at the start of the line is the switch, not text, whatever follows it; after other text, or in
        // outside mode, it is text.
        if c == '!'
            && self.typing()
            && self.picker.is_none()
            && self.editor.cursor() == 0
            && let Some(up) = self.mode.up()
        {
            self.mode = up;
            self.suggestions = None;
            return;
        }
        self.edit_input(&Edit::Insert(c));
    }

    /// Whether keys are held rather than taken: while a turn runs and nothing else (a dialog, a choice, the
    /// panel) wants them.
    fn holding(&self) -> bool {
        self.busy && self.approval.is_none() && self.picker.is_none() && self.panel.is_none()
    }

    /// Applies the keys held, in order, as if typed now, into the input box only: with a turn running or a
    /// dialog, a choice, or the panel open they stay held for later, so they can never answer a dialog.
    fn release_held(&mut self) {
        if self.busy || self.approval.is_some() || self.picker.is_some() || self.panel.is_some() {
            return;
        }
        for edit in std::mem::take(&mut self.held) {
            match edit {
                Edit::Insert(c) => self.type_into_box(c),
                other => self.edit_input(&other),
            }
        }
    }

    /// Puts a line into the input as recalling it does: a line that starts with `!!` returns in outside mode
    /// without its `!!`, one that starts with `!` in command mode without its `!`; `! !x`, a command whose text
    /// starts with `!`, returns in command mode as `!x`.
    fn set_line(&mut self, line: &str) {
        let (mode, text) = InputMode::split(line);
        let text = match mode {
            InputMode::Command => text
                .strip_prefix(' ')
                .filter(|t| t.starts_with('!'))
                .unwrap_or(text),
            InputMode::Normal | InputMode::Outside | InputMode::Help => text,
        };
        self.mode = mode;
        self.editor.set(text);
    }

    /// The input as a line, as `set_line` takes it back: its mode's marks before it, and in command mode a space
    /// between the `!` and text that starts with `!`, so that it stays a command in the sandbox.
    fn line(&self) -> String {
        Self::marked(self.mode, &self.editor.text())
    }

    /// `text` with `mode`'s marks before it, as wisp parses the line: a space between command mode's `!` and text
    /// that starts with `!`, which would otherwise read as `!!` and run outside the sandbox.
    fn marked(mode: InputMode, text: &str) -> String {
        if mode == InputMode::Command && text.starts_with('!') {
            format!("! {text}")
        } else {
            format!("{}{text}", mode.marks())
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

    /// An edit to the input: held while a turn is running or a dialog is in its grace, ignored while a dialog
    /// wants its keys. An edit that leaves the box empty lets an approval waiting for that show. An edit (a paste,
    /// say) while the status bar has the focus returns the focus to the input first.
    pub fn edit(&mut self, edit: &Edit) {
        self.bar = None;
        if self.approval.is_some() && self.in_grace() {
            self.held.push(edit.clone());
            return;
        }
        self.edit_input(edit);
        self.show_next();
    }

    /// An edit to the input, as `edit` takes it, without a dialog's grace. In command or outside mode, Backspace at
    /// the start of the line, or Delete in an empty box, steps back one mode (outside to command, command to
    /// normal); a paste at the start of the line steps up a mode for each `!` it starts with, as typing them does.
    fn edit_input(&mut self, edit: &Edit) {
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
        // Backspace at the start of the line takes back the last `!`, keeping what follows; Delete steps back only
        // in an empty box, as it deletes forwards.
        let at_start = self.picker.is_none() && self.editor.cursor() == 0;
        if self.mode != InputMode::Normal
            && ((at_start && matches!(edit, Edit::Backspace))
                || (in_box && matches!(edit, Edit::Delete)))
        {
            self.mode = self.mode.down();
            return;
        }
        if let Edit::Paste(text) = edit
            && at_start
            && text.starts_with('!')
            && self.mode.up().is_some()
        {
            let mut rest = text.as_str();
            while let Some(after) = rest.strip_prefix('!')
                && let Some(up) = self.mode.up()
            {
                self.mode = up;
                rest = after;
            }
            self.editor.apply(&Edit::Paste(rest.to_string()));
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
        self.close_picker();
        if picker.choice.is_question() {
            let what = match &value {
                Some(answer) => format!("answered: {answer}"),
                None => String::from("declined"),
            };
            self.push(
                &format!("? {what} · {}", picker.choice.title),
                LineKind::Note,
            );
        }
        let action = Action::Send(Inbound::Choose {
            id: picker.choice.id,
            value,
            values,
        });
        self.show_next();
        action
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
            // An action row (`/models`' "pull a model…", ADR 0059) answers with its value alone.
            if let Some(value) = picker.action() {
                return self.choose(Some(value), None);
            }
            if let Some(values) = picker.values() {
                return self.choose(None, Some(values));
            }
            let answer = picker.answer(&self.editor.text());
            return self.choose(answer, None);
        }
        if self.approval.is_some() || self.busy {
            return Action::None;
        }
        // A command goes to wisp as the line plain chat takes, its marks and the command (`marked`); so does text
        // in the normal box that starts with `!`, which wisp runs as a command too. Text in the normal box that
        // starts with `!!` would run outside the sandbox without the box having shown it, so it is put into outside
        // mode instead, unsent, for the person to see and send with a second Enter.
        let typed = self.editor.text().trim().to_string();
        // Help mode sends `?` and what is typed, which wisp reads as `/help` filtered by it; a bare `?` is the whole
        // list.
        if self.mode == InputMode::Help {
            return self.send_help(&typed);
        }
        let (mode, command) = match self.mode {
            InputMode::Normal => match InputMode::split(&typed) {
                (InputMode::Outside, rest) => {
                    let rest = rest.trim_start().to_string();
                    self.mode = InputMode::Outside;
                    self.editor.set(&rest);
                    return Action::None;
                }
                (InputMode::Command, rest) => (InputMode::Command, Some(rest.trim().to_string())),
                (InputMode::Normal | InputMode::Help, _) => (InputMode::Normal, None),
            },
            mode => (mode, Some(typed.clone())),
        };
        if typed.is_empty() || command.as_deref() == Some("") {
            return Action::None;
        }
        self.editor.take();
        self.mode = InputMode::Normal;
        self.suggestions = None;
        let text = if let Some(command) = &command {
            let (echo, kind) = if mode == InputMode::Outside {
                ("!!", LineKind::Outside)
            } else {
                ("!", LineKind::Command)
            };
            self.push(&format!("{echo} {command}"), kind);
            self.running_command = Some(command.clone());
            self.stopping = false;
            Self::marked(mode, command)
        } else {
            self.push(&format!("› {typed}"), LineKind::User);
            typed
        };
        self.slash_sent = command.is_none() && text.starts_with('/');
        if self.recall.last() != Some(&text) {
            self.recall.push(text.clone());
            if self.recall.len() > RECALL_LIMIT {
                self.recall.remove(0);
            }
        }
        self.recall_at = None;
        self.draft.clear();
        self.busy = true;
        self.show_next();
        Action::Send(Inbound::Message { text })
    }

    /// Enter in help mode: echoes `?` and what was typed on the help colour's darker shade, sends them, and returns
    /// the box to normal.
    fn send_help(&mut self, typed: &str) -> Action {
        let text = format!("?{typed}");
        self.editor.take();
        self.mode = InputMode::Normal;
        self.suggestions = None;
        let echo = if typed.is_empty() {
            "?".to_string()
        } else {
            format!("? {typed}")
        };
        self.push(&echo, LineKind::Help);
        self.slash_sent = true;
        if self.recall.last() != Some(&text) {
            self.recall.push(text.clone());
            if self.recall.len() > RECALL_LIMIT {
                self.recall.remove(0);
            }
        }
        self.recall_at = None;
        self.draft.clear();
        self.busy = true;
        self.show_next();
        Action::Send(Inbound::Message { text })
    }

    /// Cells of text across the input's rows, as `input_lines` lays them out for the band's width.
    fn input_width(&self) -> usize {
        usize::from(self.panel_width().saturating_sub(MARGIN * 2))
            .saturating_sub(self.prompt_cells())
    }

    /// Cells the input's prompt takes: `PROMPT_CELLS`, and one more for outside mode's `!!`.
    fn prompt_cells(&self) -> usize {
        match self.mode {
            InputMode::Outside => PROMPT_CELLS + 1,
            InputMode::Normal | InputMode::Command | InputMode::Help => PROMPT_CELLS,
        }
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
        if self.approval.is_some() || self.busy {
            return;
        }
        // In a message of several rows, Up moves the cursor a row; from the first row it recalls.
        if self.typing() && self.editor.step_row(self.input_width(), false) {
            return;
        }
        if self.recall.is_empty() {
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

    /// Down: moves to the next submitted line, and past the newest back to the draft; on a fresh line, to the
    /// status bar.
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
        // In a message of several rows, Down moves the cursor a row; from the last row it recalls the next line
        // while recalling, and otherwise moves the focus to the status bar.
        if self.typing() && self.editor.step_row(self.input_width(), true) {
            return;
        }
        let Some(index) = self.recall_at else {
            self.focus_bar();
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
            self.show_next();
        }
    }

    /// Ctrl-C or Ctrl-D: cancel a dialog first; while a command typed after `!` runs, or a model's turn that
    /// wisp says can be stopped, ask wisp to stop it (`interrupt`), and quit on a second press while it is
    /// stopping (ADR 0049, amended 2026-10-09 and 2026-10-11); otherwise quit.
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
            self.show_next();
            return Action::Send(Inbound::Answer {
                id: approval.id,
                decision: decision.into(),
            });
        }
        let stoppable = self.running_command.is_some()
            || self
                .activity
                .as_ref()
                .is_some_and(|activity| activity.stoppable);
        if self.busy && stoppable && !self.stopping {
            self.stopping = true;
            return Action::Send(Inbound::Interrupt);
        }
        Action::Quit
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
        let inner =
            usize::from(width.saturating_sub(MARGIN * 2)).saturating_sub(self.prompt_cells());
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
        // The model's question is visibly the model's (ADR 0062), never styled as an approval.
        let title = if picker.choice.is_mcp() {
            " the model asks · wisp mcp "
        } else if picker.choice.is_question() {
            " the model asks "
        } else {
            " choose "
        };
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(palette::wisp())
            .title(Span::styled(title, palette::wisp()))
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
        } else if approval.outside_sandbox {
            let from = if approval.is_mcp() {
                " · wisp mcp"
            } else {
                ""
            };
            format!(" approve OUTSIDE the sandbox · {}{from} ", approval.level)
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

    /// Draws the whole screen into `area`: the pane above, and the band at the bottom at the height it needs, leaving
    /// the pane a row at least.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let band = self
            .band_height(area.width)
            .min(area.height.saturating_sub(1))
            .max(1)
            .min(area.height);
        let pane = Rect {
            height: area.height - band,
            ..area
        };
        self.pane.render(frame, &self.transcript, pane);
        self.render(
            frame,
            Rect {
                y: area.y + pane.height,
                height: band,
                ..area
            },
        );
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
        // Command mode tints the box and its strips in the command colour, outside mode in the outside colour.
        let (background, edge) = match self.mode {
            InputMode::Command => (palette::command_background(), palette::command_edge()),
            InputMode::Outside => (palette::outside_background(), palette::outside_edge()),
            InputMode::Help => (palette::help_background(), palette::help_edge()),
            InputMode::Normal => (palette::input_background(), palette::input_edge()),
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
        // The terminal's own cursor marks where typing goes, while typing is taken; with the focus in the status
        // bar there is none, and the row above the input names the bar's keys.
        if let Some(item) = self.focused() {
            plain(frame, 1, bar_hint(item, usize::from(inset.width)));
        } else if let Some(flash) = &self.flash {
            plain(
                frame,
                1,
                Line::from(Span::styled(
                    fit(flash, usize::from(inset.width)),
                    palette::muted(),
                )),
            );
        } else if self.navigating() {
            plain(frame, 1, element_hint(usize::from(inset.width)));
        } else if let Some((line, column)) = cursor {
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
        let (prompt, prompt_style, text_style) = match self.mode {
            InputMode::Command => ("!", palette::command_prompt(), palette::command_text()),
            InputMode::Outside => ("!!", palette::command_prompt(), palette::command_text()),
            InputMode::Help => ("?", palette::command_prompt(), palette::command_text()),
            InputMode::Normal => ("›", palette::prompt(), palette::user()),
        };
        let cells = self.prompt_cells();
        if self.editor.is_empty() {
            let placeholder = Line::from(vec![
                Span::styled(format!("{prompt} "), prompt_style),
                match self.mode {
                    InputMode::Command => {
                        Span::styled(COMMAND_PLACEHOLDER, palette::command_placeholder())
                    }
                    InputMode::Outside => {
                        Span::styled(OUTSIDE_PLACEHOLDER, palette::command_placeholder())
                    }
                    InputMode::Help => {
                        Span::styled(HELP_PLACEHOLDER, palette::command_placeholder())
                    }
                    InputMode::Normal => Span::styled(PLACEHOLDER, palette::muted()),
                },
            ]);
            let typing = self.approval.is_none();
            return (vec![placeholder], typing.then_some((0, cells)));
        }
        let layout = self.editor.rows(width.saturating_sub(cells));
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
                    " ".repeat(cells)
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
            typing.then_some((layout.row - first, cells + layout.column)),
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
        if let Some(command) = &self.running_command {
            return self.command_label(command, now);
        }
        let doing = match (self.thinking_since(), self.activity.as_ref()) {
            // Asked to stop: wisp's own words once it says them, and how to quit, until the turn ends.
            _ if self.stopping => {
                let doing = self
                    .activity
                    .as_ref()
                    .map(|activity| activity.doing.clone())
                    .filter(|doing| doing.starts_with("stopping"))
                    .unwrap_or_else(|| "stopping the turn".to_string());
                format!("{doing} · Ctrl-C again quits")
            }
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

    /// What the inactive box says while a command typed after `!` runs: what wisp says it is doing, for how
    /// long, and how Ctrl-C stops it, as `running ollama pull … · 12 s · Ctrl-C stops it`; once asked to
    /// stop, `stopping … · Ctrl-C again quits`. Held keys are counted as for a turn.
    fn command_label(&self, command: &str, now: Instant) -> String {
        let (doing, seconds) = match self.activity.as_ref() {
            Some(activity) => (
                activity.doing.clone(),
                now.saturating_duration_since(activity.turn_started)
                    .as_secs(),
            ),
            None => (format!("running {command}"), 0),
        };
        let doing = if self.stopping && !doing.starts_with("stopping") {
            format!("stopping {command}")
        } else {
            doing
        };
        let hint = if self.stopping {
            "Ctrl-C again quits"
        } else {
            "Ctrl-C stops it"
        };
        let label = format!("{doing} · {seconds} s · {hint}");
        match self.held.len() {
            0 => label,
            1 => format!("{label} · 1 key held"),
            n => format!("{label} · {n} keys held"),
        }
    }

    /// The context gauge after the model, `:15% used`, coloured by how full the window is; `None` when wisp does
    /// not report it.
    fn gauge_spans(&self, focus: Option<BarItem>) -> Option<Vec<Span<'static>>> {
        let used = self.status.as_ref()?.context_used?;
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
        Some(vec![
            Span::raw(" "),
            item_span(focus, BarItem::Context, format!("{percent}% used"), style),
        ])
    }

    /// Whether the model thinks, after its name, for a model that can: ` (off)`.
    fn think_spans(&self, focus: Option<BarItem>) -> Vec<Span<'static>> {
        let Some(think) = self.status.as_ref().and_then(|status| status.think.clone()) else {
            return Vec::new();
        };
        vec![
            Span::styled(" (", palette::muted()),
            item_span(focus, BarItem::Think, think, palette::wisp()),
            Span::styled(")", palette::muted()),
        ]
    }

    /// What waits for the person, so it never waits unseen (a question or an approval from `wisp mcp` waits behind
    /// a line being typed, and opens from here): `questions: N · approvals: N`, each only when there are some.
    fn waiting_spans(&self, focus: Option<BarItem>) -> Vec<Span<'static>> {
        let mut spans = Vec::new();
        let questions = self.questions_waiting();
        if questions > 0 {
            spans.push(item_span(
                focus,
                BarItem::Questions,
                format!("questions: {questions}"),
                palette::glow(),
            ));
        }
        let approvals = self.approvals_waiting();
        if approvals > 0 {
            if !spans.is_empty() {
                spans.push(separator());
            }
            spans.push(item_span(
                focus,
                BarItem::Approvals,
                format!("approvals: {approvals}"),
                palette::amber(),
            ));
        }
        spans
    }

    /// The turn: the one running and what it is doing, or the last one's time and tokens.
    fn turn_spans(&self, focus: Option<BarItem>) -> Vec<Span<'static>> {
        let mut spans = Vec::new();
        match self.turn {
            Some(TurnState::Running(number)) => {
                spans.push(Span::styled(format!("turn {number}"), palette::wisp()));
                if let Some(label) = self.working_label(Instant::now()) {
                    spans.push(separator());
                    spans.push(Span::styled(label, palette::muted()));
                }
            }
            Some(TurnState::Ended {
                seconds,
                failed,
                tokens,
            }) => {
                let (text, style) = if failed {
                    (format!("last:failed {seconds:.1}s"), palette::ember())
                } else {
                    (format!("last:{seconds:.1}s"), palette::muted())
                };
                spans.push(item_span(focus, BarItem::Turn, text, style));
                if let Some((input, output)) = tokens {
                    spans.push(separator());
                    spans.push(Span::styled(
                        format!("↓{}", grouped(input)),
                        palette::tokens_in(),
                    ));
                    spans.push(Span::raw(" "));
                    spans.push(Span::styled(
                        format!("↑{}", grouped(output)),
                        palette::tokens_out(),
                    ));
                }
            }
            None => {}
        }
        spans
    }

    /// The status row for a band `width` cells wide: on the left the model, its context use, and whether it
    /// thinks, the directory with its branch and line changes; on the right the questions and approvals waiting, a newer
    /// wisp when `updates.check` found one (ADR 0074), the approval mode, the
    /// turn, and its tokens, pushed to the right edge. The item with the focus is drawn in black on its own colour.
    /// When it does not all fit, parts go in turn: the directory shortens to its last folder, then the approval
    /// mode and the turn go (the turn stays while it has the focus), then the directory, then the context gauge
    /// (unless it has the focus); what is left is cut at the edge, never wrapped.
    fn status_line(&self, width: u16) -> Line<'static> {
        let Some(status) = &self.status else {
            return Line::from(Span::styled("connecting…", palette::muted()));
        };
        let focus = self.focused();
        let model = item_span(focus, BarItem::Model, status.model.clone(), palette::wisp());
        let gauge = self.gauge_spans(focus);
        let think = self.think_spans(focus);
        let waiting = self.waiting_spans(focus);
        let turn = self.turn_spans(focus);
        let mut rest = Vec::new();
        if let Some(update) = &status.update {
            rest.push(Span::styled(
                format!("{update} available"),
                palette::amber(),
            ));
            rest.push(separator());
        }
        rest.push(Span::styled(status.approval.clone(), palette::muted()));
        if !turn.is_empty() {
            rest.push(separator());
            rest.extend(turn.iter().cloned());
        }
        let short = format!(
            "…/{}",
            status
                .directory
                .rsplit('/')
                .next()
                .unwrap_or(&status.directory)
        );
        let kept_turn = if focus == Some(BarItem::Turn) {
            turn
        } else {
            Vec::new()
        };
        // Each layout in turn, from the whole line to the least: whether the gauge stays, the place, and the rest
        // of the right after what waits.
        let layouts = [
            (
                true,
                place_spans(status, status.directory.clone()),
                rest.clone(),
            ),
            (true, place_spans(status, short.clone()), rest),
            (true, place_spans(status, short), kept_turn.clone()),
            (true, Vec::new(), kept_turn.clone()),
            (focus == Some(BarItem::Context), Vec::new(), kept_turn),
        ];
        let cells = |spans: &[Span<'static>]| spans.iter().map(Span::width).sum::<usize>();
        let width = usize::from(width);
        let mut chosen = (Vec::new(), Vec::new());
        for (with_gauge, place, rest) in layouts {
            let mut left = vec![model.clone()];
            if with_gauge {
                left.extend(think.iter().cloned());
            }
            if with_gauge && let Some(gauge) = &gauge {
                left.extend(gauge.iter().cloned());
            }
            left.extend(place);
            let mut right = waiting.clone();
            if !right.is_empty() && !rest.is_empty() {
                right.push(separator());
            }
            right.extend(rest);
            let needed = cells(&left) + cells(&right) + if right.is_empty() { 0 } else { 3 };
            chosen = (left, right);
            if needed <= width {
                break;
            }
        }
        let (mut spans, right) = chosen;
        if right.is_empty() {
            return Line::from(spans);
        }
        let gap = width.saturating_sub(cells(&spans) + cells(&right));
        if gap >= 3 {
            spans.push(Span::raw(" ".repeat(gap)));
        } else {
            spans.push(separator());
        }
        spans.extend(right);
        Line::from(spans)
    }
}

/// The status line's separator.
fn separator() -> Span<'static> {
    Span::styled(" · ", palette::muted())
}

/// A status bar item's text in its `style`, or in the focus style (`palette::focused`) while it has the focus.
fn item_span(focus: Option<BarItem>, which: BarItem, text: String, style: Style) -> Span<'static> {
    let style = if focus == Some(which) {
        palette::focused(style)
    } else {
        style
    };
    Span::styled(text, style)
}

/// Where the chat is, after the model: ` · ` and the directory as given, its version control and branch as
/// `git(main)`, and the line changes or a star for a dirty tree.
fn place_spans(status: &Status, directory: String) -> Vec<Span<'static>> {
    let mut spans = vec![separator(), Span::styled(directory, palette::wisp())];
    if let Some(vcs) = &status.vcs {
        spans.push(Span::styled(format!(" {vcs}"), palette::muted()));
    }
    if let Some(branch) = &status.branch {
        let open = if status.vcs.is_some() { "(" } else { " (" };
        spans.push(Span::styled(open, palette::muted()));
        spans.push(Span::styled(branch.clone(), palette::glow()));
        spans.push(Span::styled(")", palette::muted()));
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
}

/// The row above the input while an element is selected: the keys that move through the elements and fold them,
/// fitted to `width` cells.
fn element_hint(width: usize) -> Line<'static> {
    let text = "↑↓ elements · → unfold · ← fold · enter toggles · ctrl-o output · ctrl-y copies · esc back";
    Line::from(Span::styled(fit(text, width), palette::muted()))
}

/// The row above the input while the status bar has the focus: what Enter does on the focused item, and the
/// bar's keys, fitted to `width` cells.
fn bar_hint(item: BarItem, width: usize) -> Line<'static> {
    let text = format!("enter: {} · ←→ move · ↑ esc back to the input", item.hint());
    Line::from(Span::styled(fit(&text, width), palette::muted()))
}

/// `n` with thousands separated by commas, as the terminal chat's footer writes it.
pub(crate) fn grouped(n: u64) -> String {
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
/// under; an empty row; and the keys, worded as `wisp chat` words them. A run outside the sandbox
/// (ADR 0064) says so under the command, in the dangerous colour, is never remembered, and offers
/// only once or no.
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
    if approval.outside_sandbox {
        lines.push(Line::from(Span::styled(
            fit(
                "runs OUTSIDE the sandbox: it may write anywhere you can",
                width,
            ),
            palette::level("dangerous"),
        )));
    }
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
    let (remembered, keys) = if approval.outside_sandbox {
        (
            String::from("never remembered: this run only"),
            "[y]once [n]o",
        )
    } else {
        (
            format!("remembered as {}", approval.pattern),
            "[y]once [s]ession [p]roject 30d [a]lways 30d [n]o",
        )
    };
    lines.push(muted(remembered));
    // One empty row sets the keys apart from what they answer.
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(fit(keys, width), palette::body())));
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

/// The scrollback's record of an answered dialog: `✓` for what was approved or kept, `⚠` for what was refused or
/// dropped.
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
    let mark = if matches!(decision, "once" | "session" | "project" | "always" | "keep") {
        '✓'
    } else {
        '⚠'
    };
    format!("{mark} {what}: {command}")
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
            ..View::default()
        })
    }

    #[test]
    fn an_answer_is_marked_by_whether_it_went_through() {
        assert_eq!(
            answered("git push", "once"),
            "✓ approved for this turn: git push"
        );
        assert_eq!(
            answered("codename", "keep"),
            "✓ kept as a permanent fact: codename"
        );
        assert_eq!(answered("git push", "no"), "⚠ refused: git push");
        assert_eq!(
            answered("codename", "drop"),
            "⚠ dropped, left in its thread: codename"
        );
    }
    #[test]
    fn tool_output_folds_after_its_note_to_an_info_line_and_its_last_lines() {
        let mut app = App::default();
        app.handle(result_with(&numbered(5), 2));
        assert_eq!(
            texts(&mut app),
            vec![
                ("  ↳ ok".into(), LineKind::Tool),
                ("    ▸ 5 lines · 35 bytes".into(), LineKind::Fold),
                ("    line 4".into(), LineKind::ToolOutput),
                ("    line 5".into(), LineKind::ToolOutput),
            ]
        );
        assert_eq!(
            app.last_output.as_ref().map(|o| o.id.as_str()),
            Some("0123456789abcdef")
        );
        // Everything fits: no fold line.
        app.handle(result_with(&numbered(2), 20));
        assert_eq!(texts(&mut app).len(), 3);
        // shownLines 0 shows none, only the info line.
        app.handle(result_with(&numbered(4), 0));
        let lines = texts(&mut app);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1].0, "    ▸ 4 lines · 28 bytes");
        // Control characters never reach the terminal.
        app.handle(result_with("a\u{1b}[31mred\tx\n", 5));
        assert_eq!(texts(&mut app)[1].0, "    a[31mred    x");
    }

    #[test]
    fn a_commands_exit_status_reaches_the_info_line_of_its_output() {
        let mut app = App::default();
        app.handle(Outbound::Event(event(
            "tool.call",
            Some("⚙ run_command swift test"),
        )));
        let mut outcome = event("command.outcome", Some("  ↳ exit 1"));
        outcome.details = serde_json::json!({"exitStatus": 1});
        app.handle(Outbound::Event(outcome));
        let mut result = event("tool.result", None);
        result.output = Some(ToolOutput {
            id: "e".into(),
            text: numbered(30),
            lines: 30,
            bytes: 2048,
            truncated: false,
            shown_lines: 20,
        });
        app.handle(Outbound::Event(result));
        let lines: Vec<String> = texts(&mut app).into_iter().map(|line| line.0).collect();
        assert_eq!(
            lines,
            vec![
                "⚙ run_command swift test",
                "  ↳ exit 1",
                "    ▸ 30 lines · 2.0 KiB · exit 1",
                "    line 28",
                "    line 29",
                "    line 30",
            ]
        );
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
        assert_eq!(lines[1].0, "    ▸ 25 lines · 191 bytes");
        assert_eq!(lines.last().map(|l| l.0.as_str()), Some("    line 25"));
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

    /// A page of an output whole, as wisp answers an `output` request.
    fn output_page(id: &str, page: u64, pages: u64, text: &str) -> Outbound {
        Outbound::View(View {
            kind: "output".into(),
            id: id.into(),
            session: Some("s1".into()),
            page,
            pages,
            text: text.into(),
            header: "output c1 from run_command: the whole of it".into(),
            source: "stored".into(),
            ..View::default()
        })
    }

    /// Lines `from` to `to`, numbered, each ending in a newline.
    fn numbered_from(from: usize, to: usize) -> String {
        (from..=to).fold(String::new(), |text, i| text + &format!("line {i}\n"))
    }

    /// The page wanted, from the requests the app queued.
    fn asked(app: &mut App) -> Vec<u64> {
        app.take_requests()
            .into_iter()
            .map(|request| match request {
                Inbound::Output { page, .. } => page,
                other => panic!("not an output request: {other:?}"),
            })
            .collect()
    }

    /// Scrolls down until the app asks for a page, and answers it with 30 lines.
    fn scroll_to_next_page(app: &mut App, id: &str, pages: u64) -> u64 {
        for _ in 0..20 {
            app.page_down();
            if let Some(page) = asked(app).first().copied() {
                let from = usize::try_from(page - 1).unwrap_or(0) * 30 + 1;
                app.handle(output_page(
                    id,
                    page,
                    pages,
                    &numbered_from(from, from + 29),
                ));
                return page;
            }
        }
        panic!("no page asked for")
    }

    #[test]
    fn ctrl_o_asks_for_the_whole_output_and_pages_it_in_as_the_panel_scrolls() {
        let id = "0123456789abcdef";
        let mut app = App::default();
        app.handle(result_with(&numbered(40), 3));
        app.take_pending();
        app.toggle_output();
        assert_eq!(
            app.take_requests(),
            vec![Inbound::Output {
                id: id.into(),
                session: None,
                page: 1
            }]
        );
        // Until the page arrives the panel shows what the event carried, and says it is asking.
        let rows = drawn(&app, 60);
        assert!(rows[1].contains("asking wisp for the whole"), "{rows:?}");
        assert!(rows[2].contains("line 1"), "{rows:?}");
        // The first of six pages: wisp's header, then the page, and a line saying more is below.
        app.handle(output_page(id, 1, 6, &numbered_from(1, 30)));
        let rows = drawn(&app, 60);
        assert!(rows[1].contains("pages 1–1 of 6"), "{rows:?}");
        assert!(
            rows[2].contains("the whole of it") && rows[3].contains("line 1"),
            "{rows:?}"
        );
        // Scrolling to the end asks for the next page, once.
        assert_eq!(scroll_to_next_page(&mut app, id, 6), 2);
        app.page_down();
        app.page_down();
        app.page_down();
        app.page_down();
        let before = drawn(&app, 60);
        assert_eq!(
            asked(&mut app),
            vec![3],
            "asked when the end of page 2 is met"
        );
        assert_eq!(asked(&mut app), Vec::<u64>::new());
        app.page_down();
        assert_eq!(
            asked(&mut app),
            Vec::<u64>::new(),
            "not asked again while it waits"
        );
        // An arriving page keeps the rows in view where they were.
        app.handle(output_page(id, 3, 6, &numbered_from(61, 90)));
        assert_eq!(drawn(&app, 60)[2], before[2]);
        assert_eq!(scroll_to_next_page(&mut app, id, 6), 4);
        // A fifth page drops the first: no more than four are held, and the view stays put.
        for _ in 0..3 {
            app.page_down();
        }
        let before = drawn(&app, 60);
        assert_eq!(asked(&mut app), vec![5]);
        app.handle(output_page(id, 5, 6, &numbered_from(121, 150)));
        let paged = app
            .panel
            .as_ref()
            .and_then(|panel| panel.paged.clone())
            .unwrap_or_default();
        assert_eq!((paged.first, paged.held.len()), (2, OUTPUT_PAGES_HELD));
        assert_eq!(drawn(&app, 60)[2], before[2]);
        // Back at the top, the line says earlier pages are above, and scrolling up asks for page 1 again.
        for _ in 0..40 {
            app.page_up();
        }
        assert!(drawn(&app, 60)[3].contains("↑ pages 1–1 above"));
        assert_eq!(asked(&mut app), vec![1]);
        app.handle(output_page(id, 1, 6, &numbered_from(1, 30)));
        let paged = app
            .panel
            .as_ref()
            .and_then(|panel| panel.paged.clone())
            .unwrap_or_default();
        assert_eq!(
            (paged.first, paged.last()),
            (1, 4),
            "the farthest page went"
        );
        // A page out of order, arriving late, is ignored.
        app.handle(output_page(id, 6, 6, "late\n"));
        assert_eq!(
            app.panel.as_ref().and_then(|p| p.paged.clone()),
            Some(paged)
        );
    }

    #[test]
    fn an_output_wisp_does_not_hold_keeps_what_the_event_carried_under_its_line() {
        let mut app = App::default();
        app.handle(result_with("one\ntwo\n", 1));
        app.take_pending();
        app.toggle_output();
        app.take_requests();
        app.handle(Outbound::View(View {
            kind: "output".into(),
            id: "0123456789abcdef".into(),
            page: 1,
            pages: 0,
            header: "no tool output 0123456789abcdef here".into(),
            source: "missing".into(),
            ..View::default()
        }));
        let panel = app.panel.clone().unwrap_or_else(|| panic!("no panel"));
        assert_eq!(panel.paged, None);
        assert_eq!(
            panel.text,
            "no tool output 0123456789abcdef here\none\ntwo\n"
        );
    }

    #[test]
    fn show_opens_the_panel_on_its_page_and_a_page_for_a_closed_panel_is_dropped() {
        let mut app = App::default();
        // /show and /last send the first page unasked: it opens the panel.
        app.handle(output_page("e9", 1, 1, "the whole\n"));
        let rows = drawn(&app, 60);
        assert!(rows[1].starts_with(" ╭ output "), "{rows:?}");
        assert!(rows[3].contains("the whole"), "{rows:?}");
        assert_eq!(app.take_requests(), Vec::<crate::protocol::Inbound>::new());
        // Ctrl-O, then Esc before wisp answers: the answer opens nothing.
        app.cancel();
        app.handle(result_with("a\n", 1));
        app.toggle_output();
        assert_eq!(asked(&mut app), vec![1]);
        app.cancel();
        assert!(app.panel.is_none());
        app.handle(output_page("0123456789abcdef", 1, 1, "a\n"));
        assert!(app.panel.is_none(), "the panel that asked was closed");
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
            verified: None,
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
                (String::new(), LineKind::Note),
                ("ran: no tools".to_string(), LineKind::Note)
            ]
        );
        app.handle(Outbound::Turn(turn("end", 2, Some(1.0), Some("ok"))));
        assert_eq!(texts(&mut app), Vec::<(String, LineKind)>::new());
        // The entries a reply cites that do not exist are named beside it (ADR 0055).
        let mut cited = turn("end", 3, Some(1.0), Some("ok"));
        cited.ran = Some("ran: inspect".into());
        cited.cited = Some("cited but not in this conversation: entries 19–30 (12)".into());
        app.handle(Outbound::Turn(cited));
        assert_eq!(
            texts(&mut app),
            vec![
                (String::new(), LineKind::Note),
                ("ran: inspect".to_string(), LineKind::Note),
                (
                    "cited but not in this conversation: entries 19–30 (12)".to_string(),
                    LineKind::Note
                )
            ]
        );
        // A result claim the turn's calls do not support follows them (ADR 0060).
        let mut verified = turn("end", 4, Some(1.0), Some("ok"));
        verified.ran = Some("ran: no tools".into());
        verified.verified =
            Some("unsupported: \"Removed the scratch file.\" (no rm, rmdir, unlink, or trash command ran in this turn)".into());
        app.handle(Outbound::Turn(verified));
        assert_eq!(
            texts(&mut app),
            vec![
                (String::new(), LineKind::Note),
                ("ran: no tools".to_string(), LineKind::Note),
                (
                    "unsupported: \"Removed the scratch file.\" (no rm, rmdir, unlink, or trash command ran in this turn)"
                        .to_string(),
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
        assert_eq!(app.partial, "");
        assert!(!app.busy);
    }

    #[test]
    fn each_part_of_a_turn_after_the_first_is_set_apart_by_a_blank_line() {
        let mut app = App::default();
        app.push("› check the network", LineKind::User);
        app.handle(Outbound::Event(event(
            "model.reasoning",
            Some("∴ thought for 1.1 s"),
        )));
        app.handle(Outbound::Event(event(
            "tool.call",
            Some("⚙ system_info network"),
        )));
        app.handle(Outbound::Event(event("tool.result", Some("  ↳ exit 0"))));
        app.handle(Outbound::Event(event("tool.call", Some("⚙ read_file a"))));
        app.handle(Outbound::Event(event(
            "model.reasoning",
            Some("∴ thought for 0.2 s"),
        )));
        app.handle(Outbound::Delta {
            text: "Network interface en0:\n• IPv4\n".into(),
        });
        let mut ended = turn("end", 1, Some(1.0), Some("ok"));
        ended.ran = Some("ran: system_info".into());
        app.handle(Outbound::Turn(ended));
        app.handle(Outbound::Note {
            text: "1 new fact".into(),
        });
        let lines: Vec<String> = app
            .take_pending()
            .into_iter()
            .map(|line| line.text)
            .collect();
        assert_eq!(
            lines,
            [
                "› check the network",
                "∴ thought for 1.1 s",
                "",
                "⚙ system_info network",
                "  ↳ exit 0",
                "",
                "⚙ read_file a",
                "",
                "∴ thought for 0.2 s",
                "",
                "Network interface en0:",
                "• IPv4",
                "",
                "ran: system_info",
                "1 new fact",
            ]
        );
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
        app.status = Some(Status::default());
        let running = status_text(&app, 80);
        assert!(
            running.ends_with("turn 3") && !running.contains('…'),
            "{running:?}"
        );
        app.handle(Outbound::Delta {
            text: "done".into(),
        });
        app.handle(Outbound::Turn(turn("end", 3, Some(2.25), Some("ok"))));
        // The reply is set apart from the tool's lines by a blank one.
        assert_eq!(
            app.take_pending()
                .iter()
                .map(|line| line.text.as_str())
                .collect::<Vec<_>>(),
            ["", "done"]
        );
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
                    action: false,
                })
                .collect(),
            current: Some("system-model".into()),
            accepts_text,
            toggles: false,
            columns: Vec::new(),
            ..Default::default()
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
    fn the_models_pickers_pull_row_answers_with_its_value_and_space_leaves_it() {
        let mut app = App {
            status: Some(Status::default()),
            busy: true,
            ..Default::default()
        };
        let mut models = choice(&["system", "pull…"], false);
        models.toggles = true;
        models.current = Some("system".into());
        models.columns = vec![crate::protocol::ChoiceColumn {
            heading: "MODEL".into(),
            drop: 0,
        }];
        models.options[0].cells = vec!["system".into()];
        models.options[0].on = Some(true);
        models.options[1].label = "pull a model…".into();
        models.options[1].detail = "an MLX model from Hugging Face, after asking".into();
        models.options[1].action = true;
        app.handle(Outbound::Choice(models));
        app.recall_next();
        let rows = drawn(&app, 100);
        assert!(
            rows.iter()
                .any(|row| row.contains("▸  +  pull a model…  an MLX model from Hugging Face")),
            "{rows:?}"
        );
        // Space leaves the action row as it is; Enter on it answers with its value, not the toggles.
        app.type_char(' ');
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: Some("pull…".into()),
                values: None
            })
        );
    }

    #[test]
    fn a_pull_wisp_says_ctrl_c_stops_is_stopped_by_ctrl_c() {
        // `/models pull` runs as a command does: its activity is stoppable, so Ctrl-C asks wisp to stop it (ADR 0059).
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        for c in "/models pull mlx-community/q".chars() {
            app.type_char(c);
        }
        assert!(matches!(app.submit(), Action::Send(_)));
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"pulling mlx-community/q: 1 GB of 2 GB, file 1 of 2","asking":false,"turnSeconds":0,"stoppable":true}"#,
        ));
        assert!(app.busy);
        assert!(app.busy_label(Instant::now()).starts_with(
            "pulling mlx-community/q: 1 GB of 2 GB, file 1 of 2 · 0 s · Ctrl-C stops it"
        ));
        assert_eq!(app.interrupt(), Action::Send(Inbound::Interrupt));
        assert!(app.stopping);
        app.handle(Outbound::Status(Status::default()));
        assert!(app.running_command.is_none() && !app.busy);
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
    fn completion_indices_count_unicode_scalars_on_both_sides() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        // `é` written as `e` and a combining accent is two scalars and one grapheme; the ZWJ emoji is three
        // scalars (person, joiner, laptop) and one grapheme. The protocol counts scalars, as Rust's chars do.
        let line = "/fact add e\u{301} \u{1F469}\u{200D}\u{1F4BB} /he";
        app.editor.set(line);
        let scalars = line.chars().count();
        assert_eq!(scalars, 20);
        assert_eq!(
            app.complete(),
            Action::Send(Inbound::Complete {
                id: "k1".into(),
                text: line.into(),
                cursor: scalars
            })
        );
        // wisp answers with where the word starts, in scalars: the `/` of `/he`.
        let from = scalars - 3;
        app.handle(completions("k1", from, &["/help"]));
        assert_eq!(
            app.editor.text(),
            "/fact add e\u{301} \u{1F469}\u{200D}\u{1F4BB} /help "
        );
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
        assert_eq!(app.take_pending(), Vec::<HistoryLine>::new());
        // A key pressed as the dialog appears was meant for the input: it is held for the box, not an answer,
        // and the held key before it is not replayed into the dialog either.
        assert_eq!(app.type_char('s'), Action::None);
        assert!(app.approval.is_some());
        assert_eq!(app.held, vec![Edit::Insert('x'), Edit::Insert('s')]);
        // Once the keyboard has been quiet for the grace, the dialog's keys answer it.
        settle(&app);
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
            "✓ approved for this session: git push"
        );
        // The held keys go into the box when the turn ends.
        app.handle(Outbound::Status(Status::default()));
        assert_eq!(app.editor.text(), "xs");
        app.editor.take();
        assert_eq!(app.interrupt(), Action::Quit);
    }

    /// Moves the clock past an approval dialog's grace, so its keys answer it.
    fn settle(app: &App) {
        app.clock.advance(DIALOG_GRACE);
    }

    #[test]
    fn a_dialog_never_takes_keys_typed_before_it_was_seen() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.editor.set("run it");
        app.submit();
        // Typed ahead while the turn runs: y, s, a would each answer a dialog.
        for c in "yes".chars() {
            app.type_char(c);
        }
        app.handle(Outbound::Approval(approval("rm x", "rm x", &[])));
        app.handle(Outbound::Approval(mcp_approval("mcp-1", "git tag v1")));
        // Typing on as the dialog appears answers nothing: each key restarts the grace.
        for c in "say".chars() {
            app.clock.advance(Duration::from_millis(300));
            assert_eq!(app.type_char(c), Action::None);
        }
        assert_eq!(app.approval.as_ref().map(|a| a.id.as_str()), Some("a"));
        // Answering after a pause shows the next dialog, which starts a grace of its own.
        settle(&app);
        assert_eq!(
            app.type_char('n'),
            Action::Send(Inbound::Answer {
                id: "a".into(),
                decision: "no".into()
            })
        );
        assert_eq!(app.approval.as_ref().map(|a| a.id.as_str()), Some("mcp-1"));
        assert_eq!(app.type_char('y'), Action::None);
        // The turn ends with a dialog up: the held keys stay held rather than answer it.
        app.handle(Outbound::Status(Status::default()));
        assert!(app.approval.is_some());
        assert_eq!(app.held.len(), 7);
        settle(&app);
        assert_eq!(
            app.type_char('n'),
            Action::Send(Inbound::Answer {
                id: "mcp-1".into(),
                decision: "no".into()
            })
        );
        // With the dialogs gone, everything typed is in the box, in order.
        assert!(app.approval.is_none() && app.held.is_empty());
        assert_eq!(app.editor.text(), "yessayy");
    }

    #[test]
    fn an_mcp_approval_waits_while_a_line_is_typed() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        for c in "draft".chars() {
            app.type_char(c);
        }
        app.handle(Outbound::Approval(mcp_approval("mcp-1", "git push")));
        // It does not take over the box: a note says it waits, and the status line counts it.
        assert!(app.approval.is_none());
        assert_eq!(
            app.take_pending()[0].text,
            "⚠ waiting in wisp mcp: git push · its dialog opens when the input is empty, or from the status bar"
        );
        assert!(drawn(&app, 80).join("\n").contains("approvals: 1"));
        // Typing goes on into the box, `y` included.
        app.type_char('y');
        assert_eq!(app.editor.text(), "drafty");
        // Emptying the box brings it up, in its grace.
        app.edit(&Edit::KillToStart);
        assert_eq!(app.approval.as_ref().map(|a| a.id.as_str()), Some("mcp-1"));
        // The count still names it, the one on screen.
        assert!(drawn(&app, 80).join("\n").contains("approvals: 1"));
        assert_eq!(app.type_char('y'), Action::None);
        settle(&app);
        assert_eq!(
            app.type_char('y'),
            Action::Send(Inbound::Answer {
                id: "mcp-1".into(),
                decision: "once".into()
            })
        );
        // The key held in the grace is typing, and goes into the box.
        assert_eq!(app.editor.text(), "y");
        // Sending a line empties the box too.
        app.handle(Outbound::Approval(mcp_approval("mcp-2", "git tag")));
        assert!(app.approval.is_none());
        app.submit();
        assert_eq!(app.approval.as_ref().map(|a| a.id.as_str()), Some("mcp-2"));
    }

    fn question(id: &str, options: &[&str], mcp: bool) -> Choice {
        let mut choice = choice(options, options.is_empty());
        choice.id = id.into();
        choice.title = "Which config did you mean?".into();
        choice.current = None;
        choice.kind = Some("question".into());
        if mcp {
            choice.source = Some("mcp".into());
            choice.thread = Some("git".into());
            choice.client = Some("claude-code".into());
            choice.request = Some(id.trim_start_matches("mcp-").into());
        }
        choice
    }

    #[test]
    fn the_models_question_is_a_picker_of_its_own_answered_declined_and_queued() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        // A choice: the options, answered with the highlighted one; Esc declines.
        app.handle(Outbound::Choice(question(
            "q1",
            &["~/.wisp", "./wisp.json"],
            false,
        )));
        let Some(picker) = app.picker.clone() else {
            panic!("no picker");
        };
        assert!(picker.choice.is_question() && !picker.choice.is_mcp());
        let text: Vec<String> = picker.lines(60).iter().map(ToString::to_string).collect();
        assert_eq!(text[0], "Which config did you mean?");
        assert_eq!(text[1], "the model asks; your answer goes to the model");
        assert!(
            text.last()
                .is_some_and(|keys| keys.contains("Esc to decline"))
        );
        app.recall_next();
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Choose {
                id: "q1".into(),
                value: Some("./wisp.json".into()),
                values: None
            })
        );
        assert_eq!(
            app.take_pending().last().map(|line| line.text.clone()),
            Some("? answered: ./wisp.json · Which config did you mean?".into())
        );
        // Free text: typed, sent as the value; Ctrl-C declines, as it refuses an approval.
        app.handle(Outbound::Choice(question("q2", &[], false)));
        assert!(app.typing());
        for c in "the one in the repo".chars() {
            app.type_char(c);
        }
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Choose {
                id: "q2".into(),
                value: Some("the one in the repo".into()),
                values: None
            })
        );
        app.handle(Outbound::Choice(question("q3", &[], false)));
        assert_eq!(
            app.interrupt(),
            Action::Send(Inbound::Choose {
                id: "q3".into(),
                value: None,
                values: None
            })
        );
        assert!(app.picker.is_none());
    }

    #[test]
    fn the_models_questions_from_wisp_mcp_queue_behind_a_choice_and_typing() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        // One from wisp mcp arriving while another question is open waits, counted in the status line, and shows
        // once the first is answered; its notes name the client and the thread.
        app.handle(Outbound::Choice(question("q4", &["a", "b"], false)));
        app.handle(Outbound::Choice(question(
            "mcp-a1b2c3d4",
            &["a", "b"],
            true,
        )));
        assert_eq!(app.queued_questions.len(), 1);
        assert_eq!(
            app.questions_waiting(),
            2,
            "the one open and the one behind it"
        );
        app.submit();
        let Some(shown) = app.picker.clone() else {
            panic!("the queued question does not show");
        };
        assert_eq!(shown.choice.id, "mcp-a1b2c3d4");
        let notes: Vec<String> = shown.lines(80).iter().map(ToString::to_string).collect();
        assert_eq!(notes[1], "waiting in wisp mcp for claude-code, thread git");
        assert_eq!(
            notes[2],
            "your answer goes to the model, and to claude-code, which can read this thread"
        );
        // Withdrawn (answered in a terminal first): the picker closes with a note.
        app.handle(Outbound::Withdrawn {
            id: "mcp-a1b2c3d4".into(),
        });
        assert!(app.picker.is_none());
        // A queued one withdrawn leaves quietly.
        app.handle(Outbound::Choice(question("q5", &["a", "b"], false)));
        app.handle(Outbound::Choice(question(
            "mcp-ffff0000",
            &["a", "b"],
            true,
        )));
        app.handle(Outbound::Withdrawn {
            id: "mcp-ffff0000".into(),
        });
        assert!(app.queued_questions.is_empty());
        // One from wisp mcp waits while the input box has text, and shows when it empties.
        app.cancel();
        for c in "typing".chars() {
            app.type_char(c);
        }
        app.handle(Outbound::Choice(question(
            "mcp-00001111",
            &["a", "b"],
            true,
        )));
        assert!(app.picker.is_none() && app.queued_questions.len() == 1);
        assert_eq!(app.questions_waiting(), 1);
        for _ in 0..6 {
            app.edit(&Edit::Backspace);
        }
        assert!(
            app.picker
                .as_ref()
                .is_some_and(|p| p.choice.id == "mcp-00001111")
        );
    }

    #[test]
    fn a_timed_out_approval_or_choice_is_withdrawn() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.handle(Outbound::Approval(approval("rm x", "rm x", &[])));
        app.handle(Outbound::Withdrawn { id: "a".into() });
        assert!(app.approval.is_none());
        assert_eq!(app.take_pending()[0].text, "⚠ no longer waiting: rm x");
        // A choice whose wait lapsed closes, and what was typed into it goes with it.
        app.handle(Outbound::Choice(choice(&["system", "private-cloud"], true)));
        app.type_char('z');
        app.handle(Outbound::Withdrawn { id: "c9".into() });
        assert!(app.picker.is_some());
        app.handle(Outbound::Withdrawn { id: "c1".into() });
        assert!(app.picker.is_none() && app.editor.is_empty());
        assert_eq!(
            app.take_pending()[0].text,
            "⚠ no longer waiting: approval.classifier: what judges each command"
        );
        // A late Enter answers nothing.
        assert_eq!(app.submit(), Action::None);
    }

    #[test]
    fn a_nonsensical_turn_seconds_does_not_panic() {
        for seconds in ["1e300", "-5", "1e20"] {
            let mut app = App::default();
            app.handle(Outbound::parse(&format!(
                r#"{{"type":"activity","doing":"x","asking":false,"turnSeconds":{seconds}}}"#
            )));
            assert!(app.activity.is_some());
        }
        assert_eq!(bounded_seconds(f64::NAN), Duration::ZERO);
        assert_eq!(bounded_seconds(f64::INFINITY), LONGEST_TURN);
        assert_eq!(bounded_seconds(1e300), LONGEST_TURN);
        assert_eq!(bounded_seconds(-1.0), Duration::ZERO);
        assert_eq!(bounded_seconds(2.5), Duration::from_millis(2500));
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
        settle(&app);
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
        settle(&app);
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
    fn a_run_outside_the_sandbox_says_so_and_is_approved_once_or_refused() {
        let outside = Approval {
            outside_sandbox: true,
            ..mcp_approval("mcp-1", "brew upgrade")
        };
        let lines: Vec<String> = dialog_lines(&outside, 70)
            .iter()
            .map(|line| line.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        assert_eq!(lines[0], "brew upgrade");
        assert_eq!(
            lines[1],
            "runs OUTSIDE the sandbox: it may write anywhere you can"
        );
        assert!(lines.iter().any(|l| l == "never remembered: this run only"));
        assert!(!lines.iter().any(|l| l.contains("remembered as")));
        assert_eq!(lines.last().map(String::as_str), Some("[y]once [n]o"));
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.handle(Outbound::Approval(outside.clone()));
        settle(&app);
        let rows = drawn(&app, 70);
        assert!(
            rows[1].starts_with(" ╭ approve OUTSIDE the sandbox · moderate · wisp mcp "),
            "{rows:?}"
        );
        // The scopes that remember mean nothing here.
        for key in ['s', 'p', 'a'] {
            assert_eq!(app.type_char(key), Action::None);
        }
        assert!(app.approval.is_some());
        assert_eq!(
            app.type_char('y'),
            Action::Send(Inbound::Answer {
                id: "mcp-1".into(),
                decision: "once".into()
            })
        );
        assert!(
            app.take_pending().iter().any(|line| {
                line.text == "⚠ approved once, outside the sandbox: brew upgrade"
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
        settle(&app);
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
            "⚠ no longer waiting: git tag v1"
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
        settle(&app);
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
            stoppable: false,
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
                    think: None,
                    update: None,
                    vcs: None,
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
            think: None,
            update: None,
            vcs: Some("git".into()),
        };
        let app = App {
            status: Some(status.clone()),
            ..Default::default()
        };
        let line = app.status_line(90);
        let text: String = line
            .spans
            .iter()
            .map(|span| span.content.to_string())
            .collect();
        assert!(
            text.starts_with("system 15% used · ~/src/github.com/pidster/wisp git(main)+12-3   "),
            "{text}"
        );
        assert!(
            text.ends_with("approve at moderate") && line.width() == 90,
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
            narrow.starts_with("system 15% used · …/wisp git(main)+12-3"),
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
        assert!(text.contains("wisp git(main)*"), "{text}");
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
                think: None,
                update: None,
                vcs: Some("git".into()),
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
            format!(" system 14% used · ~/x git(main){}--yes", " ".repeat(22))
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
    fn a_question_mark_at_the_start_enters_help_mode_and_enter_sends_it_with_the_word() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        assert_eq!(app.type_char('?'), Action::None);
        assert!(app.mode == InputMode::Help && app.editor.is_empty());
        // `!` in help mode is text, and Backspace at the start returns to the normal box.
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("!", InputMode::Help)
        );
        app.edit(&Edit::Backspace);
        app.edit(&Edit::Backspace);
        assert_eq!(app.mode, InputMode::Normal);
        // A bare `?` sends the whole help; a word after it filters it.
        app.type_char('?');
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message { text: "?".into() })
        );
        assert_eq!(app.mode, InputMode::Normal);
        app.busy = false;
        app.type_char('?');
        for c in "think".chars() {
            app.type_char(c);
        }
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "?think".into()
            })
        );
        assert!(app.slash_sent);
        // Each is echoed as `?` and the word, apart, on the help line.
        let echoed: Vec<_> = app
            .take_pending()
            .into_iter()
            .filter(|line| line.kind == LineKind::Help)
            .map(|line| line.text)
            .collect();
        assert_eq!(echoed, ["?", "? think"]);
        // Recalled, it comes back in help mode.
        app.busy = false;
        app.recall_previous();
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("think", InputMode::Help)
        );
        // After other text, `?` is text.
        app.edit(&Edit::Backspace);
        let _ = app.editor.take();
        app.mode = InputMode::Normal;
        for c in "why?".chars() {
            app.type_char(c);
        }
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("why?", InputMode::Normal)
        );
    }

    #[test]
    fn a_bang_in_an_empty_box_enters_command_mode_and_backspace_at_the_start_or_delete_leaves_it() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        // `!` into an empty box is the switch, not text.
        assert_eq!(app.type_char('!'), Action::None);
        assert!(app.mode == InputMode::Command && app.editor.is_empty());
        for c in "ls".chars() {
            app.type_char(c);
        }
        assert_eq!(app.editor.text(), "ls");
        // Backspace deletes text first; at the start of the line it leaves command mode.
        app.edit(&Edit::Backspace);
        app.edit(&Edit::Backspace);
        assert!(app.mode == InputMode::Command && app.editor.is_empty());
        app.edit(&Edit::Backspace);
        assert!(app.mode == InputMode::Normal && app.editor.is_empty());
        // Backspace with the cursor at the start leaves command mode and keeps the text as ordinary input.
        app.type_char('!');
        for c in "git status".chars() {
            app.type_char(c);
        }
        app.edit(&Edit::Home);
        app.edit(&Edit::Backspace);
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("git status", false)
        );
        // The opposite: `!` typed at the start of a line with text enters command mode around that text.
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("git status", true)
        );
        // In command mode a `!` at the start steps up to outside mode (ADR 0064, amended 2026-10-14); there a `!`
        // at the start is text.
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("git status", InputMode::Outside)
        );
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("!git status", InputMode::Outside)
        );
        // Backspace deletes that `!`, then at the start steps back one mode at a time, keeping the text.
        app.edit(&Edit::Backspace);
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("git status", InputMode::Outside)
        );
        app.edit(&Edit::Backspace);
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("git status", InputMode::Command)
        );
        app.edit(&Edit::Backspace);
        assert_eq!(app.mode, InputMode::Normal);
        app.edit(&Edit::KillToEnd);
        // Delete in an empty box leaves it too; with text, Delete deletes forwards and stays.
        app.type_char('!');
        app.type_char('x');
        app.edit(&Edit::Home);
        app.edit(&Edit::Delete);
        assert!(app.mode == InputMode::Command && app.editor.is_empty());
        assert_eq!(app.mode, InputMode::Command);
        app.edit(&Edit::Delete);
        assert_eq!(app.mode, InputMode::Normal);
        // A `!` after other text stays text, and in a box emptied by other edits the next `!` switches again.
        app.type_char('a');
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("a!", false)
        );
        app.edit(&Edit::KillToStart);
        app.type_char('!');
        assert!(app.mode == InputMode::Command && app.editor.is_empty());
        // A paste that starts with `!` into an empty box enters command mode with the rest.
        app.edit(&Edit::Backspace);
        app.edit(&Edit::Paste("!git log -3".into()));
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
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
        assert!(app.mode == InputMode::Command && !app.busy);
        app.editor.set(" git status --short ");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "!git status --short".into()
            })
        );
        assert!(app.mode == InputMode::Normal && app.editor.is_empty() && app.busy);
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
        assert_eq!(lines, vec!["    ▸ 3 lines · 6 bytes", "    b", "    c"]);
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
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("pwd", true)
        );
        app.recall_next();
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("half", false)
        );
        app.editor.set("");
        app.type_char('!');
        app.type_char('w');
        app.recall_previous();
        app.recall_next();
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("w", true)
        );
    }

    #[test]
    fn a_bang_at_the_start_in_command_mode_enters_outside_mode_and_each_backspace_steps_back_one() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.type_char('!');
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("", InputMode::Outside)
        );
        // In outside mode a `!` at the start is text.
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("!", InputMode::Outside)
        );
        // Backspace deletes it; at the start it steps back to command mode, then to the normal prompt.
        app.edit(&Edit::Backspace);
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("", InputMode::Outside)
        );
        app.edit(&Edit::Backspace);
        assert_eq!(app.mode, InputMode::Command);
        app.edit(&Edit::Backspace);
        assert_eq!(app.mode, InputMode::Normal);
        // Delete in an empty box steps back the same way.
        app.type_char('!');
        app.type_char('!');
        app.edit(&Edit::Delete);
        assert_eq!(app.mode, InputMode::Command);
        app.edit(&Edit::Delete);
        assert_eq!(app.mode, InputMode::Normal);
        // With text, Delete deletes forwards and stays outside; Backspace at the start steps back keeping the text.
        app.type_char('!');
        app.type_char('!');
        for c in "xbrew upgrade".chars() {
            app.type_char(c);
        }
        app.edit(&Edit::Home);
        app.edit(&Edit::Delete);
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("brew upgrade", InputMode::Outside)
        );
        app.edit(&Edit::Backspace);
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("brew upgrade", InputMode::Command)
        );
        // A `!` after other text stays text in command mode.
        app.edit(&Edit::End);
        app.type_char('!');
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("brew upgrade!", InputMode::Command)
        );
    }

    #[test]
    fn a_paste_at_the_start_steps_up_a_mode_for_each_bang_it_starts_with() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        let paste = |app: &mut App, text: &str| {
            app.edit(&Edit::Paste(text.into()));
            let seen = (app.editor.text(), app.mode);
            app.editor.take();
            app.mode = InputMode::Normal;
            seen
        };
        assert_eq!(
            paste(&mut app, "!!brew upgrade"),
            ("brew upgrade".into(), InputMode::Outside)
        );
        assert_eq!(paste(&mut app, "!ls"), ("ls".into(), InputMode::Command));
        assert_eq!(paste(&mut app, "!!!x"), ("!x".into(), InputMode::Outside));
        // In command mode at the start, a `!` steps up to outside, as typing it does; the next is text.
        app.type_char('!');
        assert_eq!(paste(&mut app, "!x"), ("x".into(), InputMode::Outside));
        app.type_char('!');
        assert_eq!(paste(&mut app, "!!x"), ("!x".into(), InputMode::Outside));
        // In outside mode it is text, and so it is anywhere but the start.
        app.type_char('!');
        app.type_char('!');
        assert_eq!(paste(&mut app, "!x"), ("!x".into(), InputMode::Outside));
        app.type_char('!');
        app.type_char('a');
        assert_eq!(paste(&mut app, "!!x"), ("a!!x".into(), InputMode::Command));
    }

    #[test]
    fn sending_in_outside_mode_sends_two_marks_and_marks_the_line_apart() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.type_char('!');
        app.type_char('!');
        // An empty command sends nothing.
        assert_eq!(app.submit(), Action::None);
        assert_eq!(app.mode, InputMode::Outside);
        app.editor.set(" brew upgrade ");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "!!brew upgrade".into()
            })
        );
        assert!(app.mode == InputMode::Normal && app.editor.is_empty() && app.busy);
        assert_eq!(app.running_command.as_deref(), Some("brew upgrade"));
        assert_eq!(
            app.take_pending(),
            vec![HistoryLine {
                text: "!! brew upgrade".into(),
                kind: LineKind::Outside
            }]
        );
        app.handle(Outbound::Status(Status::default()));
        // A command mode line whose text starts with `!` keeps a space after its mark, so wisp runs it in the
        // sandbox as the box showed, never as `!!`.
        app.type_char('!');
        app.editor.set("!x");
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "! !x".into()
            })
        );
        assert_eq!(app.take_pending()[0].kind, LineKind::Command);
        app.handle(Outbound::Status(Status::default()));
        // Text in the normal box that starts with `!!` is not sent unseen: the box turns to outside mode with the
        // rest, and a second Enter sends it.
        app.editor.set("!! pwd");
        assert_eq!(app.submit(), Action::None);
        assert_eq!(
            (app.editor.text().as_str(), app.mode, app.busy),
            ("pwd", InputMode::Outside, false)
        );
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "!!pwd".into()
            })
        );
        app.handle(Outbound::Status(Status::default()));
        // Recalled, each comes back in the mode it was sent from.
        assert_eq!(app.recall, vec!["!!brew upgrade", "! !x", "!!pwd"]);
        app.recall_previous();
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("pwd", InputMode::Outside)
        );
        app.recall_previous();
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("!x", InputMode::Command)
        );
        app.recall_previous();
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("brew upgrade", InputMode::Outside)
        );
    }

    #[test]
    fn a_line_and_its_mode_round_trip() {
        let mut app = App::default();
        for line in ["!!brew upgrade", "!ls", "! !x", "hello", "!!!x", ""] {
            app.set_line(line);
            assert_eq!(app.line(), line, "{line}");
        }
        app.set_line("!!a");
        assert_eq!(
            (app.editor.text().as_str(), app.mode),
            ("a", InputMode::Outside)
        );
    }

    #[test]
    fn outside_mode_tints_the_box_in_the_outside_colour_with_two_marks() {
        let mut app = App {
            status: Some(Status::default()),
            ..Default::default()
        };
        app.type_char('!');
        app.type_char('!');
        let width = 90;
        let height = app.band_height(width);
        let mut terminal = Terminal::new(TestBackend::new(width, height)).expect("test terminal");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer().clone();
        let row: String = (0..width)
            .map(|x| buffer[(x, INPUT_ROW)].symbol().to_string())
            .collect();
        assert_eq!(row.trim_end(), format!(" !! {OUTSIDE_PLACEHOLDER}"));
        assert_eq!(buffer[(0, INPUT_ROW)].bg, palette::OUTSIDE);
        assert_eq!(buffer[(width - 1, INPUT_ROW)].bg, palette::OUTSIDE);
        assert_eq!(buffer[(1, INPUT_ROW)].fg, palette::BLACK);
        assert_eq!(buffer[(0, INPUT_ROW - 1)].fg, palette::OUTSIDE);
        assert_eq!(buffer[(0, INPUT_ROW + 1)].fg, palette::OUTSIDE);
        app.editor.set("ls");
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        let buffer = terminal.backend().buffer().clone();
        assert_eq!(buffer[(4, INPUT_ROW)].symbol(), "l");
        assert_eq!(buffer[(4, INPUT_ROW)].fg, palette::BLACK);
        let position = terminal.get_cursor_position().expect("cursor");
        assert_eq!((position.x, position.y), (MARGIN + 3 + 2, INPUT_ROW));
        // A step back, and the box is command mode's colour again.
        app.editor.set("");
        app.edit(&Edit::Backspace);
        terminal
            .draw(|frame| app.render(frame, frame.area()))
            .expect("draw");
        assert_eq!(
            terminal.backend().buffer()[(0, INPUT_ROW)].bg,
            palette::COMMAND
        );
        // Kept apart from the danger colours and from command mode's.
        assert_ne!(palette::OUTSIDE, palette::EMBER);
        assert_ne!(palette::OUTSIDE, palette::REMOVED);
        assert_ne!(palette::OUTSIDE, palette::COMMAND);
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
        let texts: Vec<String> = app
            .transcript
            .lines()
            .into_iter()
            .map(|line| line.text)
            .collect();
        assert!(
            texts.iter().any(|t| t == "∴ thought for 1.2 s, 9 tokens"),
            "{texts:?}"
        );
        // Folded to its info line and its last line, as an output is.
        assert!(
            texts.iter().any(|t| t == "    ▸ 3 lines · 14 bytes"),
            "{texts:?}"
        );
        assert!(texts.iter().any(|t| t == "    three"), "{texts:?}");
        assert!(!texts.iter().any(|t| t.contains("one")), "{texts:?}");
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
        assert!(app.editor.is_empty() && (app.mode == InputMode::Normal));
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
        assert_eq!(
            (app.editor.text().as_str(), (app.mode == InputMode::Command)),
            ("l", true)
        );
        // With no activity yet, the box still says it is working.
        app.busy = true;
        app.activity = None;
        assert_eq!(app.busy_label(Instant::now()), "working…");
        // A dialog takes its keys even while busy; they are not held.
        app.approval = Some(approval("rm x", "rm x", &[]));
        app.type_char('q');
        assert_eq!(app.held, Vec::<crate::editor::Edit>::new());
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

    #[test]
    fn ctrl_c_stops_a_model_turn_and_a_second_press_quits() {
        let mut app = App::default();
        app.handle(Outbound::Status(Status::default()));
        for c in "explain the build".chars() {
            app.type_char(c);
        }
        assert!(matches!(
            app.submit(),
            Action::Send(Inbound::Message { .. })
        ));
        // wisp says the turn can be stopped, as it does for every turn of a face that takes `interrupt`.
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"running make","asking":false,"turnSeconds":0,"stoppable":true}"#,
        ));
        assert!(app.busy && app.running_command.is_none());
        // The first Ctrl-C asks wisp to stop the turn and does not quit; the box says so at once.
        assert_eq!(app.interrupt(), Action::Send(Inbound::Interrupt));
        assert!(app.stopping && app.busy);
        assert_eq!(
            app.busy_label(Instant::now()),
            "stopping the turn · Ctrl-C again quits"
        );
        // wisp's own word for it, once it says it.
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"stopping the turn","asking":false,"turnSeconds":1,"stopping":true}"#,
        ));
        assert_eq!(
            app.busy_label(Instant::now()),
            "stopping the turn · Ctrl-C again quits"
        );
        // A second, while it is stopping, quits.
        assert_eq!(app.interrupt(), Action::Quit);
        // When the turn ends the next prompt's status clears it, and Ctrl-C with nothing running quits.
        app.handle(Outbound::Status(Status::default()));
        assert!(!app.stopping && !app.busy);
        assert_eq!(app.interrupt(), Action::Quit);
    }

    #[test]
    fn ctrl_c_stops_a_typed_command_and_a_second_press_quits() {
        let mut app = App::default();
        app.handle(Outbound::Status(Status::default()));
        app.type_char('!');
        for c in "ollama pull x".chars() {
            app.type_char(c);
        }
        assert_eq!(
            app.submit(),
            Action::Send(Inbound::Message {
                text: "!ollama pull x".into()
            })
        );
        assert_eq!(app.running_command.as_deref(), Some("ollama pull x"));
        let now = Instant::now();
        // Before wisp says what it is doing, the box names the command; then it says what wisp said.
        assert_eq!(
            app.busy_label(now),
            "running ollama pull x · 0 s · Ctrl-C stops it"
        );
        app.handle(Outbound::parse(
            r#"{"type":"activity","doing":"running ollama pull x","asking":false,"turnSeconds":0,"stoppable":true}"#,
        ));
        assert!(
            app.busy_label(Instant::now())
                .starts_with("running ollama pull x · 0 s · Ctrl-C stops it")
        );
        // It ticks with no turn running, so a long command never looks hung.
        assert!(app.live_label(Instant::now()).is_some());
        // The first Ctrl-C asks wisp to stop it and does not quit; the box says so.
        assert_eq!(app.interrupt(), Action::Send(Inbound::Interrupt));
        assert!(app.stopping && app.busy);
        assert!(
            app.busy_label(Instant::now())
                .starts_with("stopping ollama pull x · 0 s · Ctrl-C again quits")
        );
        // A second, while it is stopping, quits, as Ctrl-C does during a model's turn.
        assert_eq!(app.interrupt(), Action::Quit);
        // Once it has ended, Ctrl-C with nothing open quits as before.
        app.handle(Outbound::Status(Status::default()));
        assert!(app.running_command.is_none() && !app.stopping && !app.busy);
        assert_eq!(app.interrupt(), Action::Quit);
        // During a model's turn wisp says cannot be stopped (an older wisp), Ctrl-C quits at once.
        for c in "hi".chars() {
            app.type_char(c);
        }
        assert!(matches!(
            app.submit(),
            Action::Send(Inbound::Message { .. })
        ));
        assert!(app.busy && app.running_command.is_none());
        assert_eq!(app.interrupt(), Action::Quit);
        // Esc does not stop a command, as it does not stop a turn.
        app.handle(Outbound::Status(Status::default()));
        app.type_char('!');
        app.type_char('x');
        assert!(matches!(app.submit(), Action::Send(_)));
        assert_eq!(app.cancel(), Action::None);
        assert!(!app.stopping);
    }

    /// An app at its prompt with a line typed, a question and an approval from `wisp mcp` waiting behind it.
    fn with_both_waiting(model: &str) -> App {
        let mut app = App {
            status: Some(Status {
                model: model.into(),
                directory: "~/src/github.com/pidster/wisp".into(),
                vcs: Some("git".into()),
                branch: Some("main".into()),
                approval: "ask".into(),
                context_used: Some(0.2),
                ..Status::default()
            }),
            ..Default::default()
        };
        for c in "draft".chars() {
            app.type_char(c);
        }
        app.handle(Outbound::Choice(question("mcp-q1", &["a", "b"], true)));
        app.handle(Outbound::Approval(mcp_approval("mcp-1", "git push")));
        app.take_pending();
        app
    }

    fn status_text(app: &App, width: u16) -> String {
        app.status_line(width)
            .spans
            .iter()
            .map(|span| span.content.to_string())
            .collect()
    }

    #[test]
    fn the_status_bar_counts_questions_and_approvals_waiting_and_hides_them_at_none() {
        let mut app = with_both_waiting("system");
        let text = status_text(&app, 100);
        assert!(
            text.ends_with("questions: 1 · approvals: 1 · ask"),
            "{text}"
        );
        let line = app.status_line(100);
        let style = |content: &str| {
            line.spans
                .iter()
                .find(|span| span.content == content)
                .map(|span| span.style)
        };
        assert_eq!(style("approvals: 1"), Some(palette::amber()));
        assert_eq!(style("questions: 1"), Some(palette::glow()));
        // Neither is named, or focusable, with nothing waiting.
        app.queued.clear();
        app.queued_questions.clear();
        let text = status_text(&app, 100);
        assert!(
            !text.contains("questions") && !text.contains("approvals"),
            "{text}"
        );
        assert_eq!(app.bar_items(), vec![BarItem::Model, BarItem::Context]);
        // This conversation's own question, on screen, counts as one.
        app.editor.take();
        app.handle(Outbound::Choice(question("q1", &["a", "b"], false)));
        assert_eq!(app.questions_waiting(), 1);
        assert!(status_text(&app, 100).contains("questions: 1"));
    }

    #[test]
    fn a_newer_wisp_shows_in_amber_before_the_approval_mode() {
        let app = App {
            status: Some(Status {
                model: "system".into(),
                directory: "~/w".into(),
                approval: "ask".into(),
                update: Some("0.31.1".into()),
                ..Status::default()
            }),
            ..Default::default()
        };
        let text = status_text(&app, 100);
        assert!(text.ends_with("0.31.1 available · ask"), "{text}");
        let line = app.status_line(100);
        let span = line
            .spans
            .iter()
            .find(|span| span.content == "0.31.1 available");
        assert_eq!(span.map(|span| span.style), Some(palette::amber()));
        let quiet = App {
            status: Some(Status {
                model: "system".into(),
                directory: "~/w".into(),
                approval: "ask".into(),
                ..Status::default()
            }),
            ..Default::default()
        };
        assert!(!status_text(&quiet, 100).contains("available"));
    }

    #[test]
    fn a_model_that_can_think_shows_it_after_its_name_as_an_item_that_sends_think() {
        let mut app = App {
            status: Some(Status {
                model: "ollama:q".into(),
                directory: "~/w".into(),
                approval: "ask".into(),
                context_used: Some(0.15),
                think: Some("off".into()),
                ..Status::default()
            }),
            ..Default::default()
        };
        let text = status_text(&app, 100);
        assert!(text.starts_with("ollama:q (off) 15% used · ~/w"), "{text}");
        assert_eq!(
            app.bar_items(),
            vec![BarItem::Model, BarItem::Think, BarItem::Context]
        );
        app.bar = Some(BarItem::Think);
        assert_eq!(app.focused(), Some(BarItem::Think));
        assert_eq!(
            app.activate(),
            Action::Send(Inbound::Message {
                text: "/think".into()
            })
        );
        assert!(app.busy && app.slash_sent);
        // A model with no thinking to set shows none, and the bar has no such item.
        if let Some(status) = app.status.as_mut() {
            status.think = None;
        }
        assert!(!status_text(&app, 100).contains('('));
        // Another system names itself; one that cannot tell its branch (svn without its tool) shows its name alone.
        if let Some(status) = app.status.as_mut() {
            status.vcs = Some("svn".into());
        }
        assert!(status_text(&app, 100).starts_with("ollama:q 15% used · ~/w svn "));
        assert_eq!(app.bar_items(), vec![BarItem::Model, BarItem::Context]);
    }

    #[test]
    fn a_vcs_line_redraws_the_place_and_leaves_the_turn_and_the_input_alone() {
        let vcs = crate::protocol::VcsUpdate {
            vcs: Some("git".into()),
            branch: Some("main".into()),
            dirty: Some(true),
            added: Some(4),
            removed: Some(1),
        };
        // Before the first status there is nothing to redraw.
        let mut app = App::default();
        app.handle(Outbound::Vcs(vcs.clone()));
        assert_eq!(app.status, None);
        app.handle(Outbound::Status(Status {
            model: "system".into(),
            directory: "~/w".into(),
            approval: "ask".into(),
            ..Status::default()
        }));
        app.handle(Outbound::Turn(turn("start", 2, None, None)));
        assert!(app.busy);
        app.handle(Outbound::Vcs(vcs));
        assert!(
            status_text(&app, 100).starts_with("system · ~/w git(main)+4-1"),
            "{}",
            status_text(&app, 100)
        );
        assert!(app.busy, "the turn is still under way");
        assert_eq!(app.turn, Some(TurnState::Running(2)));
    }

    #[test]
    fn the_focused_item_is_black_on_its_own_colour_and_the_hint_names_the_keys() {
        let mut app = with_both_waiting("system");
        app.recall_next();
        assert_eq!(app.focused(), Some(BarItem::Model));
        let rows = drawn(&app, 100);
        assert!(rows[1].contains("enter: switch the model"), "{rows:?}");
        assert!(rows[1].contains("←→ move · ↑ esc back to the input"));
        // The input keeps its line while the bar has the focus.
        assert!(rows[usize::from(INPUT_ROW)].contains("› draft"));
        let model = app
            .status_line(100)
            .spans
            .into_iter()
            .find(|span| span.content == "system");
        assert_eq!(
            model.map(|span| (span.style.fg, span.style.bg)),
            Some((Some(palette::BLACK), Some(palette::WISP)))
        );
        // On the approvals, the highlight keeps their amber.
        app.bar = Some(BarItem::Approvals);
        let approvals = app
            .status_line(100)
            .spans
            .into_iter()
            .find(|span| span.content == "approvals: 1");
        assert_eq!(
            approvals.map(|span| (span.style.fg, span.style.bg)),
            Some((Some(palette::BLACK), Some(palette::AMBER)))
        );
        assert!(drawn(&app, 100)[1].contains("enter: answer the approval"));
        // Back in the input, the hint row is empty again.
        app.leave_bar();
        assert_eq!(drawn(&app, 100)[1], "");
    }

    #[test]
    fn a_narrow_bar_drops_parts_in_turn_and_keeps_what_waits_and_the_focus() {
        let mut app = with_both_waiting("system");
        app.turn = Some(TurnState::Ended {
            seconds: 2.0,
            failed: false,
            tokens: Some((1200, 30)),
        });
        // Wide: everything.
        assert!(status_text(&app, 140).contains("~/src/github.com/pidster/wisp git(main)"));
        // Narrower: the last folder, then the mode and the turn go, then the place, then the gauge.
        let at_70 = status_text(&app, 70);
        assert!(
            at_70.contains("…/wisp git(main)") && !at_70.contains("last:"),
            "{at_70}"
        );
        assert!(at_70.contains("questions: 1 · approvals: 1"), "{at_70}");
        let at_45 = status_text(&app, 45);
        assert!(
            !at_45.contains("wisp:main") && at_45.contains("20% used"),
            "{at_45}"
        );
        let at_32 = status_text(&app, 32);
        assert!(at_32.starts_with("system · questions: 1"), "{at_32}");
        // The turn with the focus stays, and so does the gauge.
        app.recall_next();
        app.bar = Some(BarItem::Turn);
        assert!(status_text(&app, 60).contains("last:2.0s"));
        app.bar = Some(BarItem::Context);
        assert!(status_text(&app, 32).contains("20% used"));
        // Never a panic, at any width, with wide characters in the model's name.
        let mut wide = with_both_waiting("模型:日本語のモデル");
        wide.recall_next();
        for width in [0, 1, 2, 3, 5, 8, 13, 21, 34, 55] {
            let rows = drawn(&wide, width);
            assert!(rows.len() >= usize::from(BAND_HEIGHT));
            let _ = status_text(&wide, width);
            wide.bar = Some(BarItem::Approvals);
        }
    }

    #[test]
    fn a_question_opened_over_a_draft_parks_it_and_gives_it_back() {
        let mut app = with_both_waiting("system");
        app.recall_next();
        app.bar = Some(BarItem::Questions);
        assert_eq!(app.activate(), Action::None);
        // The picker takes typed text on its own row; the draft is not in it.
        assert!(app.picker.is_some() && app.editor.is_empty());
        assert_eq!(app.parked.as_deref(), Some("draft"));
        // Withdrawn elsewhere: the draft comes back all the same.
        app.handle(Outbound::Withdrawn {
            id: "mcp-q1".into(),
        });
        assert_eq!(app.editor.text(), "draft");
        assert!(app.parked.is_none());
        // A command line typed in command mode comes back in command mode.
        let mut command = with_both_waiting("system");
        command.editor.take();
        command.type_char('!');
        for c in "ls".chars() {
            command.type_char(c);
        }
        command.recall_next();
        command.bar = Some(BarItem::Questions);
        command.activate();
        assert_eq!(command.mode, InputMode::Normal);
        command.cancel();
        assert!(command.mode == InputMode::Command && command.editor.text() == "ls");
    }
}
