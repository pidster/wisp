//! The conversation as `wisp-tui` holds it to draw in its pane (ADR 0068): a list of elements, each a line sent, a
//! tool call with its result lines and output, a stretch of thinking, a reply, a run of notes, a slash command's
//! output, or an error. Lines from wisp are grouped as they arrive, by the rule that sets a new part of a turn apart
//! with a blank line (`starts_part`). A long output or stretch of thinking folds to an info line and its last lines.

use std::cell::RefCell;

use crate::app::{HistoryLine, LineKind, grouped, sanitise, starts_part};
use crate::pane::Row;
use crate::protocol::ToolOutput;

/// One element of the conversation: its lines, and for a tool call or a stretch of thinking the output or the
/// thinking, kept whole as the event carried it.
#[derive(Debug, Default)]
pub struct Element {
    /// Its lines, in the order they arrived.
    pub lines: Vec<HistoryLine>,
    /// A tool's output, or a stretch of thinking's text, drawn under the lines.
    pub body: Option<ToolOutput>,
    /// Whether a body that folds is open: shown whole rather than as its info line and last lines.
    pub open: bool,
    /// The exit status of the command it ran, from its `command.outcome` or `command.typed` details.
    pub exit: Option<i64>,
    /// Whether its body's text was let go to keep the bodies held within `HELD_LIMIT`; its info line stays, and
    /// Ctrl-O pages the output from wisp.
    pub released: bool,
    /// The rows last drawn for it and the width they were drawn at, until it changes.
    pub(crate) rows: RefCell<Option<(u16, Vec<Row>)>>,
}

impl Element {
    /// An element that starts with `line`.
    fn starting(line: HistoryLine) -> Self {
        Self {
            lines: vec![line],
            ..Self::default()
        }
    }

    /// The kind of its first line, `ToolOutput` for an output with no line of its own.
    fn first_kind(&self) -> LineKind {
        self.lines
            .first()
            .map_or(LineKind::ToolOutput, |line| line.kind)
    }

    /// Whether it is a line the person sent: a prompt, a command, or a help request.
    pub fn is_sent(&self) -> bool {
        is_sent(self.first_kind())
    }

    /// The kind of the last line drawn for it: its body's when it has one.
    fn last_kind(&self) -> Option<LineKind> {
        if self.body.is_some() {
            return Some(LineKind::ToolOutput);
        }
        self.lines.last().map(|line| line.kind)
    }

    /// Whether its body folds: it is longer than the lines wisp says to show (`shownOutputLines`), wisp held part
    /// of it back, or its text was let go.
    pub fn folds(&self) -> bool {
        self.body.as_ref().is_some_and(|output| {
            self.released || output.truncated || output.text.lines().count() > output.shown_lines
        })
    }

    /// The info line's words for a body that folds: its lines and size in all, the command's exit status when
    /// known, and where the rest is when it is not here to unfold, as `248 lines · 12.0 KiB · exit 0`.
    fn info(&self) -> String {
        let Some(output) = &self.body else {
            return String::new();
        };
        let mut parts = vec![lines(output.lines), size(output.bytes)];
        if let Some(exit) = self.exit {
            parts.push(format!("exit {exit}"));
        }
        if self.released || (output.truncated && !self.open) {
            parts.push("ctrl-o pages it".into());
        }
        parts.join(" · ")
    }

    /// The lines its body is drawn as, indented. One that fits is drawn whole. One that folds starts with its info
    /// line, `▸` while folded and `▾` while open; folded, its last `FOLDED_TAIL` lines follow (none when wisp held
    /// part of it back, since what is here is its start); open, all of what the event carried, and a line for what
    /// wisp held back.
    pub fn body_lines(&self) -> Vec<HistoryLine> {
        let Some(output) = &self.body else {
            return Vec::new();
        };
        let lines: Vec<&str> = output.text.lines().collect();
        let indent = |line: &&str| HistoryLine {
            text: format!("    {}", sanitise(line)),
            kind: LineKind::ToolOutput,
        };
        if !self.folds() {
            return lines.iter().map(indent).collect();
        }
        let glyph = if self.open { '▾' } else { '▸' };
        let mut drawn = vec![HistoryLine {
            text: format!("    {glyph} {}", self.info()),
            kind: LineKind::Fold,
        }];
        if self.released {
            return drawn;
        }
        if self.open {
            drawn.extend(lines.iter().map(indent));
            let more = output
                .lines
                .saturating_sub(u64::try_from(lines.len()).unwrap_or(u64::MAX));
            if output.truncated && more > 0 {
                drawn.push(HistoryLine {
                    text: format!("    … {} more: ctrl-o pages the whole", self::lines(more)),
                    kind: LineKind::ToolOutput,
                });
            }
        } else if !output.truncated {
            let tail = FOLDED_TAIL.min(output.shown_lines).min(lines.len());
            drawn.extend(lines[lines.len() - tail..].iter().map(indent));
        }
        drawn
    }

    /// Its text to copy, plain: its lines as they read, then its body whole as the event carried it, folded or not.
    pub fn plain_text(&self) -> String {
        let mut text: Vec<&str> = self.lines.iter().map(|line| line.text.as_str()).collect();
        if let Some(body) = &self.body {
            text.push(body.text.trim_end_matches('\n'));
        }
        text.join("\n")
    }

    /// What it is, for a note about it: the message, the output, the thinking, the reply, the notes.
    pub fn what(&self) -> &'static str {
        match self.first_kind() {
            LineKind::User | LineKind::Command | LineKind::Outside | LineKind::Help => {
                "the message"
            }
            LineKind::Reply | LineKind::Code | LineKind::Fence => "the reply",
            LineKind::Tool
                if self
                    .lines
                    .first()
                    .is_some_and(|line| line.text.starts_with('∴')) =>
            {
                "the thinking"
            }
            LineKind::Tool | LineKind::ToolOutput | LineKind::Fold => "the tool call",
            LineKind::Note => "the notes",
            LineKind::Error => "the error",
            LineKind::Output => "the output",
        }
    }

    /// Every line drawn for it: its own, then its body's.
    pub fn drawn(&self) -> Vec<HistoryLine> {
        let mut lines = self.lines.clone();
        lines.extend(self.body_lines());
        lines
    }

    /// Forgets the rows drawn for it, after a change.
    pub fn changed(&self) {
        self.rows.replace(None);
    }
}

/// Lines a folded body shows under its info line: the end of a build or a test run, where its result is.
pub const FOLDED_TAIL: usize = 3;

/// The bytes of bodies held at most; past it the oldest are let go, keeping their info lines (ADR 0068).
pub const HELD_LIMIT: usize = 32 * 1024 * 1024;

/// `count` lines, with thousands separated: `1 line`, `30,000 lines`.
fn lines(count: u64) -> String {
    format!(
        "{} line{}",
        grouped(count),
        if count == 1 { "" } else { "s" }
    )
}

/// `bytes` for people: `512 bytes`, `12.0 KiB`, `2.1 MiB`.
pub(crate) fn size(bytes: u64) -> String {
    #[allow(clippy::cast_precision_loss)]
    let value = bytes as f64;
    if bytes < 1024 {
        format!("{bytes} byte{}", if bytes == 1 { "" } else { "s" })
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KiB", value / 1024.0)
    } else {
        format!("{:.1} MiB", value / (1024.0 * 1024.0))
    }
}

/// Whether a line of `kind` is one the person sent.
fn is_sent(kind: LineKind) -> bool {
    matches!(
        kind,
        LineKind::User | LineKind::Command | LineKind::Outside | LineKind::Help
    )
}

/// What kind of element a line belongs in: lines of one class stay together until a new part begins.
fn class(kind: LineKind) -> u8 {
    match kind {
        LineKind::User | LineKind::Command | LineKind::Outside | LineKind::Help => 0,
        LineKind::Reply | LineKind::Code | LineKind::Fence => 1,
        LineKind::Tool => 2,
        LineKind::Note => 3,
        LineKind::Error => 4,
        LineKind::Output => 5,
        LineKind::ToolOutput | LineKind::Fold => 6,
    }
}

/// Whether a line of `kind` reading `text` starts an element after `last`: a sent line, anything after one, after an
/// element with its body (so lines stay in the order they came), a new part of a turn, or a line of another class.
fn starts_element(last: &Element, kind: LineKind, text: &str) -> bool {
    if is_sent(kind) || last.is_sent() || last.body.is_some() {
        return true;
    }
    starts_part(last.last_kind(), kind, text) || class(kind) != class(last.first_kind())
}

/// The conversation, element by element.
#[derive(Debug, Default)]
pub struct Transcript {
    /// The elements, oldest first.
    pub elements: Vec<Element>,
    /// The bytes of body text held, which `HELD_LIMIT` bounds.
    held: usize,
}

impl Transcript {
    /// Adds a line: to the last element, or as the start of a new one.
    pub fn push(&mut self, text: &str, kind: LineKind) {
        let line = HistoryLine {
            text: text.to_string(),
            kind,
        };
        match self.elements.last_mut() {
            Some(last) if !starts_element(last, kind, text) => {
                last.lines.push(line);
                last.changed();
            }
            _ => self.elements.push(Element::starting(line)),
        }
    }

    /// Gives `output` to the tool call or stretch of thinking it ends, the last element when that is one without a
    /// body yet; otherwise it is an element of its own. A body that folds arrives folded.
    pub fn attach(&mut self, output: ToolOutput) {
        self.attach_within(output, HELD_LIMIT);
    }

    /// `attach`, holding at most `limit` bytes of body text: past it the oldest bodies but the newest are let go.
    fn attach_within(&mut self, output: ToolOutput, limit: usize) {
        self.held += output.text.len();
        match self.elements.last_mut() {
            Some(last) if last.body.is_none() && last.first_kind() == LineKind::Tool => {
                last.body = Some(output);
                last.changed();
            }
            _ => self.elements.push(Element {
                body: Some(output),
                ..Element::default()
            }),
        }
        let newest = self.elements.len().saturating_sub(1);
        for element in &mut self.elements[..newest] {
            if self.held <= limit {
                break;
            }
            if let Some(body) = element.body.as_mut().filter(|_| !element.released) {
                self.held = self.held.saturating_sub(body.text.len());
                body.text = String::new();
                element.released = true;
                element.changed();
            }
        }
    }

    /// Records `status` as the exit status of the command the last element ran.
    pub fn set_exit(&mut self, status: i64) {
        if let Some(last) = self.elements.last_mut() {
            last.exit = Some(status);
            last.changed();
        }
    }

    /// Whether `element` is set apart from `previous` by a blank row: it begins a new part of a turn.
    pub fn separated(previous: Option<&Element>, element: &Element) -> bool {
        let Some(previous) = previous else {
            return false;
        };
        let Some(first) = element.lines.first() else {
            return false;
        };
        starts_part(previous.last_kind(), first.kind, &first.text)
    }

    /// Every line as drawn, oldest first, with an empty note for each blank row between parts.
    #[cfg(test)]
    pub fn lines(&self) -> Vec<HistoryLine> {
        let mut lines = Vec::new();
        let mut previous = None;
        for element in &self.elements {
            if Self::separated(previous, element) {
                lines.push(HistoryLine {
                    text: String::new(),
                    kind: LineKind::Note,
                });
            }
            lines.extend(element.drawn());
            previous = Some(element);
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(text: &str) -> ToolOutput {
        ToolOutput {
            id: "e1".into(),
            text: text.into(),
            lines: text.lines().count() as u64,
            bytes: text.len() as u64,
            truncated: false,
            shown_lines: 20,
        }
    }

    fn shape(transcript: &Transcript) -> Vec<Vec<String>> {
        transcript
            .elements
            .iter()
            .map(|element| element.drawn().into_iter().map(|line| line.text).collect())
            .collect()
    }

    #[test]
    fn a_turn_is_grouped_into_its_parts() {
        let mut transcript = Transcript::default();
        transcript.push("› list the files", LineKind::User);
        transcript.push("⚙ run_command ls", LineKind::Tool);
        transcript.push("  ↳ exit 0", LineKind::Tool);
        transcript.attach(output("a\nb"));
        transcript.push("Two files: a and b.", LineKind::Reply);
        transcript.push("```", LineKind::Fence);
        transcript.push("a", LineKind::Code);
        transcript.push("```", LineKind::Fence);
        transcript.push("ran: run_command", LineKind::Note);
        transcript.push("verified: 1 result", LineKind::Note);
        assert_eq!(
            shape(&transcript),
            vec![
                vec!["› list the files"],
                vec!["⚙ run_command ls", "  ↳ exit 0", "    a", "    b"],
                vec!["Two files: a and b.", "```", "a", "```"],
                vec!["ran: run_command", "verified: 1 result"],
            ]
        );
    }

    #[test]
    fn each_tool_call_and_stretch_of_thinking_is_an_element() {
        let mut transcript = Transcript::default();
        transcript.push("∴ thought for 2 s", LineKind::Tool);
        transcript.attach(output("weighing it"));
        transcript.push("⚙ read_file a", LineKind::Tool);
        transcript.push("⚙ read_file b", LineKind::Tool);
        assert_eq!(transcript.elements.len(), 3);
        assert_eq!(
            transcript.elements[0]
                .body
                .as_ref()
                .map(|b| b.text.as_str()),
            Some("weighing it")
        );
    }

    #[test]
    fn a_line_after_an_output_starts_an_element_so_the_order_holds() {
        let mut transcript = Transcript::default();
        transcript.push("  ↳ ok", LineKind::Tool);
        transcript.attach(output("x"));
        transcript.push("  ↳ again", LineKind::Tool);
        assert_eq!(
            shape(&transcript),
            vec![vec!["  ↳ ok", "    x"], vec!["  ↳ again"]]
        );
    }

    #[test]
    fn an_output_with_no_call_before_it_is_an_element_of_its_own() {
        let mut transcript = Transcript::default();
        transcript.push("! ls", LineKind::Command);
        transcript.attach(output("a"));
        assert_eq!(shape(&transcript), vec![vec!["! ls"], vec!["    a"]]);
    }

    #[test]
    fn notes_errors_and_outputs_are_kept_apart() {
        let mut transcript = Transcript::default();
        transcript.push("saved thread chat-1", LineKind::Note);
        transcript.push("model ready", LineKind::Note);
        transcript.push("error: no such model", LineKind::Error);
        transcript.push("thread  model", LineKind::Output);
        transcript.push("chat-1  system", LineKind::Output);
        assert_eq!(transcript.elements.len(), 3);
    }

    #[test]
    fn the_lines_drawn_set_new_parts_apart_with_a_blank() {
        let mut transcript = Transcript::default();
        transcript.push("› hi", LineKind::User);
        transcript.push("⚙ current_date", LineKind::Tool);
        transcript.push("Today.", LineKind::Reply);
        transcript.push("ran: current_date", LineKind::Note);
        let lines: Vec<String> = transcript.lines().into_iter().map(|l| l.text).collect();
        assert_eq!(
            lines,
            vec![
                "› hi",
                "⚙ current_date",
                "",
                "Today.",
                "",
                "ran: current_date"
            ]
        );
    }

    fn texts(element: &Element) -> Vec<String> {
        element.drawn().into_iter().map(|line| line.text).collect()
    }

    #[test]
    fn a_long_output_folds_to_its_info_line_and_last_lines_and_opens_whole() {
        let mut transcript = Transcript::default();
        transcript.push("⚙ run_command seq 30", LineKind::Tool);
        let text: String = (1..=30).map(|n| n.to_string() + "\n").collect();
        transcript.attach(output(&text));
        transcript.set_exit(0);
        let element = &mut transcript.elements[0];
        assert!(element.folds() && !element.open);
        assert_eq!(
            texts(element),
            vec![
                "⚙ run_command seq 30",
                "    ▸ 30 lines · 81 bytes · exit 0",
                "    28",
                "    29",
                "    30"
            ]
        );
        element.open = true;
        let open = texts(element);
        assert_eq!(open.len(), 2 + 30);
        assert_eq!(open[1], "    ▾ 30 lines · 81 bytes · exit 0");
        assert_eq!(open[2], "    1");
    }

    #[test]
    fn an_output_that_fits_is_drawn_whole_and_never_folds() {
        let mut transcript = Transcript::default();
        transcript.push("⚙ read_file a", LineKind::Tool);
        transcript.attach(output("one\ntwo"));
        assert!(!transcript.elements[0].folds());
        assert_eq!(
            texts(&transcript.elements[0]),
            vec!["⚙ read_file a", "    one", "    two"]
        );
    }

    #[test]
    fn an_output_wisp_held_part_of_folds_to_its_info_line_and_opens_to_its_start() {
        let mut transcript = Transcript::default();
        transcript.push("⚙ run_command build", LineKind::Tool);
        transcript.attach(ToolOutput {
            truncated: true,
            lines: 30_000,
            bytes: 2_202_009,
            ..output("start\nmore")
        });
        let element = &mut transcript.elements[0];
        assert_eq!(
            texts(element),
            vec![
                "⚙ run_command build",
                "    ▸ 30,000 lines · 2.1 MiB · ctrl-o pages it"
            ]
        );
        element.open = true;
        assert_eq!(
            texts(element),
            vec![
                "⚙ run_command build",
                "    ▾ 30,000 lines · 2.1 MiB",
                "    start",
                "    more",
                "    … 29,998 lines more: ctrl-o pages the whole",
            ]
        );
    }

    #[test]
    fn thinking_folds_like_an_output_with_no_exit_status() {
        let mut transcript = Transcript::default();
        transcript.push("∴ thought for 4 s", LineKind::Tool);
        transcript.attach(ToolOutput {
            shown_lines: 2,
            ..output("weighing\nthe\noptions")
        });
        assert_eq!(
            texts(&transcript.elements[0]),
            vec![
                "∴ thought for 4 s",
                "    ▸ 3 lines · 20 bytes",
                "    the",
                "    options"
            ]
        );
    }

    #[test]
    fn past_the_limit_the_oldest_bodies_are_let_go_keeping_their_info_lines() {
        let mut transcript = Transcript::default();
        for n in 0..3 {
            transcript.push(&format!("⚙ run_command step {n}"), LineKind::Tool);
            transcript.attach_within(output("0123456789"), 25);
        }
        let released: Vec<bool> = transcript.elements.iter().map(|e| e.released).collect();
        assert_eq!(released, vec![true, false, false]);
        assert_eq!(transcript.held, 20);
        assert_eq!(
            texts(&transcript.elements[0]),
            vec![
                "⚙ run_command step 0",
                "    ▸ 1 line · 10 bytes · ctrl-o pages it"
            ]
        );
    }

    #[test]
    fn counts_and_sizes_read_as_people_write_them() {
        assert_eq!(lines(1), "1 line");
        assert_eq!(lines(999), "999 lines");
        assert_eq!(lines(1_234_567), "1,234,567 lines");
        assert_eq!(size(1), "1 byte");
        assert_eq!(size(1023), "1023 bytes");
        assert_eq!(size(12 * 1024), "12.0 KiB");
        assert_eq!(size(3 * 1024 * 1024 / 2), "1.5 MiB");
    }
}
