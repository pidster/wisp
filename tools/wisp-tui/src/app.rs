//! The front end's state and rendering: finished lines go above into the terminal's own scrollback,
//! the band at the bottom holds the reply in progress, the input or an approval dialog, and the status.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Padding, Paragraph};
use std::time::{Duration, Instant};
use unicode_width::UnicodeWidthChar;

use crate::editor::{Edit, Editor};
use crate::markdown;
use crate::palette;
use crate::picker::Picker;
use crate::protocol::{Approval, Inbound, Outbound, Status};

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
            }
            Outbound::Status(status) => {
                self.flush_partial();
                self.status = Some(status);
                self.busy = false;
            }
            Outbound::Activity {
                doing,
                turn_seconds,
                ..
            } => {
                let now = Instant::now();
                self.activity = doing.map(|doing| Activity {
                    doing,
                    turn_started: now
                        .checked_sub(Duration::from_secs_f64(turn_seconds.max(0.0)))
                        .unwrap_or(now),
                    since: now,
                });
            }
            Outbound::Turn(turn) => {
                self.flush_partial();
                self.in_fence = false;
                if !turn.is_start() {
                    self.activity = None;
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
            Outbound::Event(event) => {
                if let Some(line) = event.text {
                    self.flush_partial();
                    let kind = if event.kind == "error" {
                        LineKind::Error
                    } else {
                        LineKind::Tool
                    };
                    self.push(&line, kind);
                }
            }
            Outbound::Approval(approval) => {
                self.flush_partial();
                self.approval = Some(approval);
            }
            Outbound::Choice(choice) => {
                self.flush_partial();
                self.picker = Some(Picker::new(choice));
            }
            Outbound::Completions {
                id,
                from,
                candidates,
            } => self.completed(&id, from, candidates),
            Outbound::Exit => self.exited = true,
            Outbound::Unknown => {}
        }
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

    /// A character typed.
    pub fn type_char(&mut self, c: char) -> Action {
        if let Some(approval) = &self.approval {
            let decision = match c.to_ascii_lowercase() {
                'y' => "once",
                's' => "session",
                'p' => "project",
                'a' => "always",
                'n' => "no",
                _ => return Action::None,
            };
            let id = approval.id.clone();
            self.push(&answered(&approval.command, decision), LineKind::Note);
            self.approval = None;
            return Action::Send(Inbound::Answer {
                id,
                decision: decision.to_string(),
            });
        }
        self.edit(&Edit::Insert(c));
        Action::None
    }

    /// Whether the input takes edits: with no dialog up and no turn running, or while a choice that
    /// takes typed text is open.
    fn typing(&self) -> bool {
        match &self.picker {
            Some(picker) => picker.choice.accepts_text,
            None => self.approval.is_none() && !self.busy,
        }
    }

    /// An edit to the input: ignored while a dialog wants its keys or a turn is running.
    pub fn edit(&mut self, edit: &Edit) {
        if self.typing() {
            self.editor.apply(edit);
            self.suggestions = None;
            self.completing = None;
        }
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

    /// Answers the open choice with `value`, `None` for no answer, and closes it.
    fn choose(&mut self, value: Option<String>) -> Action {
        let Some(picker) = self.picker.take() else {
            return Action::None;
        };
        self.editor.take();
        Action::Send(Inbound::Choose {
            id: picker.choice.id,
            value,
        })
    }

    /// Esc: leaves an open choice unanswered; otherwise nothing.
    pub fn cancel(&mut self) -> Action {
        self.choose(None)
    }

    /// Enter: sends the input as a message, echoing it into history; with a choice open, answers it.
    pub fn submit(&mut self) -> Action {
        if let Some(picker) = &self.picker {
            let answer = picker.answer(&self.editor.text());
            return self.choose(answer);
        }
        if self.approval.is_some() || self.busy {
            return Action::None;
        }
        let text = self.editor.take().trim().to_string();
        if text.is_empty() {
            return Action::None;
        }
        self.suggestions = None;
        self.push(&format!("› {text}"), LineKind::User);
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
        if let Some(picker) = &mut self.picker {
            picker.step(false);
            return;
        }
        if self.approval.is_some() || self.busy || self.recall.is_empty() {
            return;
        }
        let index = match self.recall_at {
            None => {
                self.draft = self.editor.take();
                self.recall.len() - 1
            }
            Some(index) => index.saturating_sub(1),
        };
        self.recall_at = Some(index);
        self.editor.set(&self.recall[index]);
    }

    /// Down: moves to the next submitted line, and past the newest back to the draft.
    pub fn recall_next(&mut self) {
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
            self.editor.set(&self.recall[index + 1]);
        } else {
            self.recall_at = None;
            let draft = std::mem::take(&mut self.draft);
            self.editor.set(&draft);
        }
    }

    /// Ctrl-C or Ctrl-D: cancel a dialog first, otherwise quit.
    pub fn interrupt(&mut self) -> Action {
        if self.picker.is_some() {
            return self.cancel();
        }
        if let Some(approval) = self.approval.take() {
            self.push(&answered(&approval.command, "no"), LineKind::Note);
            return Action::Send(Inbound::Answer {
                id: approval.id,
                decision: "no".into(),
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
    /// While a dialog is asked it takes the input's place: the reply row, the dialog, and the status.
    pub fn band_height(&self, width: u16) -> u16 {
        if let Some(picker) = &self.picker {
            return u16::try_from(picker.rows())
                .unwrap_or(u16::MAX)
                .saturating_add(DIALOG_FRAME + 2);
        }
        if let Some(approval) = &self.approval {
            let rows = dialog_lines(approval, dialog_width(width)).len();
            return u16::try_from(rows)
                .unwrap_or(u16::MAX)
                .saturating_add(DIALOG_FRAME + 2);
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
        let mut lines = picker.lines();
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
            height: height.min(area.height.saturating_sub(2)),
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
            let lines = dialog_lines(approval, dialog_width(area.width));
            let height = u16::try_from(lines.len())
                .unwrap_or(u16::MAX)
                .saturating_add(DIALOG_FRAME);
            let block = Block::bordered()
                .border_type(BorderType::Rounded)
                .border_style(palette::level(&approval.level))
                .title(Span::styled(
                    format!(" approve · {} ", approval.level),
                    palette::level(&approval.level),
                ))
                .padding(Padding::horizontal(1));
            let dialog = Rect {
                y: area.y + 1,
                height: height.min(area.height.saturating_sub(2)),
                ..inset
            };
            frame.render_widget(Paragraph::new(lines).block(block), dialog);
            plain(
                frame,
                area.height.saturating_sub(1),
                self.status_line(inset.width),
            );
            return;
        }
        let strip = |frame: &mut Frame, index: u16, glyph: &str| {
            if index < area.height {
                let text = glyph.repeat(usize::from(area.width));
                frame.render_widget(
                    Paragraph::new(text).style(palette::input_edge()),
                    row(index, area),
                );
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
            frame.render_widget(
                Paragraph::new("").style(palette::input_background()),
                row(index, area),
            );
            frame.render_widget(
                Paragraph::new(line).style(palette::input_background()),
                row(index, inset),
            );
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
        let prompt = if self.busy { "…" } else { "›" };
        if self.editor.is_empty() && !self.busy {
            let placeholder = Line::from(vec![
                Span::styled(format!("{prompt} "), palette::prompt()),
                Span::styled(PLACEHOLDER, palette::muted()),
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
                    Span::styled(lead, palette::prompt()),
                    Span::styled(text.clone(), palette::user()),
                ])
            })
            .collect();
        let typing = self.approval.is_none() && !self.busy;
        (
            lines,
            typing.then_some((layout.row - first, PROMPT_CELLS + layout.column)),
        )
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
                let style = if used >= 0.8 {
                    palette::amber()
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
                spans.push(Span::styled(branch.clone(), palette::wisp()));
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
/// under; and the keys, worded as `wisp chat` words them.
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
    lines.push(Line::from(Span::styled(
        fit("[y]once [s]ession [p]roject 30d [a]lways 30d [n]o", width),
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
        _ => "refused",
    };
    format!("⚠ {what}: {command}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Choice, ChoiceOption, Event, Turn};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use serde_json::Value;

    fn event(kind: &str, text: Option<&str>) -> Event {
        Event {
            kind: kind.into(),
            call: Some("c".into()),
            details: Value::Null,
            text: text.map(str::to_string),
        }
    }

    fn turn(phase: &str, number: u64, seconds: Option<f64>, outcome: Option<&str>) -> Turn {
        Turn {
            phase: phase.into(),
            number,
            seconds,
            outcome: outcome.map(str::to_string),
            input_tokens: None,
            output_tokens: None,
        }
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
                })
                .collect(),
            current: Some("system-model".into()),
            accepts_text,
        }
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
            1 + 5 + 2 + 1,
            "reply, question, three options, keys, border, status"
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
                value: Some("coreml".into())
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
                value: Some("30".into())
            })
        );
        assert!(app.editor.is_empty());
        app.handle(Outbound::Choice(choice(&["a"], false)));
        assert_eq!(
            app.cancel(),
            Action::Send(Inbound::Choose {
                id: "c1".into(),
                value: None
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
        // Typing while busy is dropped; a dialog takes over the keys.
        app.type_char('x');
        assert!(app.editor.is_empty());
        app.handle(Outbound::Approval(Approval {
            id: "a1".into(),
            command: "git push".into(),
            line: "git push".into(),
            pattern: "git push *".into(),
            directory: "/r".into(),
            level: "dangerous".into(),
            reasons: vec!["changes repository state".into()],
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
        }
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
        // Reply row, border, command, line, directory, two reasons, pattern, keys, border, status.
        assert_eq!(app.band_height(60), 11);
        let rows = drawn(&app, 60);
        assert!(rows[1].starts_with(" ╭ approve · dangerous "), "{rows:?}");
        assert_eq!(rows[2].trim_end_matches([' ', '│']), " │ git push");
        assert!(rows[3].contains("part of: git add -A && git push"));
        assert!(rows[4].contains("in /repo"));
        assert!(rows[5].contains("- changes repository state"));
        assert!(rows[6].contains("- reaches the network"));
        assert!(rows[7].contains("remembered as git push *"));
        assert!(rows[8].contains("[y]once [s]ession [p]roject 30d [a]lways 30d [n]o"));
        assert!(rows[9].starts_with(" ╰"));
        assert!(rows[10].contains("system"));
        // A command that is its whole line has no "part of" row: command, directory, pattern, keys.
        let only_command = approval("git push", "git push", &[]);
        assert_eq!(dialog_lines(&only_command, 50).len(), 4);
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
}
