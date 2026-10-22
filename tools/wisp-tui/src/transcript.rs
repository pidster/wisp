//! The conversation as `wisp-tui` holds it to draw in its pane (ADR 0068): a list of elements, each a line sent, a
//! tool call with its result lines and output, a stretch of thinking, a reply, a run of notes, a slash command's
//! output, or an error. Lines from wisp are grouped as they arrive, by the rule that sets a new part of a turn apart
//! with a blank line (`starts_part`).

use std::cell::RefCell;

use crate::app::{HistoryLine, LineKind, starts_part};
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

    /// The lines its body is drawn as: the first lines wisp says to show, indented, then a line saying how many
    /// are left.
    pub fn body_lines(&self) -> Vec<HistoryLine> {
        let Some(output) = &self.body else {
            return Vec::new();
        };
        let lines: Vec<&str> = output.text.lines().collect();
        let shown = output.shown_lines.min(lines.len());
        let mut drawn: Vec<HistoryLine> = lines[..shown]
            .iter()
            .map(|line| HistoryLine {
                text: format!("    {}", crate::app::sanitise(line)),
                kind: LineKind::ToolOutput,
            })
            .collect();
        if lines.len() > shown {
            let hidden = lines.len() - shown;
            let plural = if hidden == 1 { "" } else { "s" };
            drawn.push(HistoryLine {
                text: format!("    … {hidden} more line{plural} · ctrl-o shows all"),
                kind: LineKind::ToolOutput,
            });
        }
        drawn
    }

    /// Every line drawn for it: its own, then its body's.
    pub fn drawn(&self) -> Vec<HistoryLine> {
        let mut lines = self.lines.clone();
        lines.extend(self.body_lines());
        lines
    }

    /// Forgets the rows drawn for it, after a change.
    fn changed(&self) {
        self.rows.replace(None);
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
        LineKind::ToolOutput => 6,
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
    /// body yet; otherwise it is an element of its own.
    pub fn attach(&mut self, output: ToolOutput) {
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

    #[test]
    fn a_long_output_shows_its_first_lines_and_how_many_are_left() {
        let mut transcript = Transcript::default();
        transcript.push("⚙ run_command seq 30", LineKind::Tool);
        let text: String = (1..=30).map(|n| n.to_string() + "\n").collect();
        transcript.attach(output(&text));
        let drawn = transcript.elements[0].drawn();
        assert_eq!(drawn.len(), 1 + 20 + 1);
        assert_eq!(drawn[21].text, "    … 10 more lines · ctrl-o shows all");
    }
}
