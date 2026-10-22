//! The pane (ADR 0068): the conversation drawn above the band on the alternate screen, element by element, following
//! its end until the person scrolls; and on quitting, the same rows printed into the terminal's scrollback.

use std::cell::Cell;
use std::io::{self, Write};

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use unicode_width::UnicodeWidthChar;

use crate::app::{HistoryLine, LineKind, MARGIN};
use crate::markdown::{self, Tone};
use crate::palette;
use crate::transcript::{Element, Transcript};

/// One row of the pane.
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    /// What it shows.
    pub line: Line<'static>,
    /// A background the whole row takes, edge to edge: a sent line's tint.
    pub tint: Option<Style>,
    /// Whether it starts at the screen's edge rather than inside the margin: a sent line's half-block strips.
    pub edge: bool,
}

impl Row {
    /// A row of text inside the margin.
    fn text(line: Line<'static>) -> Self {
        Self {
            line,
            tint: None,
            edge: false,
        }
    }

    /// An empty row, between parts of a turn.
    fn blank() -> Self {
        Self::text(Line::default())
    }
}

/// The rows `element` takes at `width` cells, drawn once and kept until it changes or the width does.
pub fn rows(element: &Element, width: u16) -> Vec<Row> {
    if let Some((drawn, rows)) = &*element.rows.borrow()
        && *drawn == width
    {
        return rows.clone();
    }
    let rows = build(element, width);
    element.rows.replace(Some((width, rows.clone())));
    rows
}

/// How many rows `element` takes at `width`, with the blank row before it when it starts a new part.
fn height(previous: Option<&Element>, element: &Element, width: u16) -> usize {
    usize::from(Transcript::separated(previous, element)) + rows(element, width).len()
}

/// Draws `element` at `width`: a sent line on its tint between half-block strips, as the input it came from; every
/// other line in its colours, wrapped inside the margin.
fn build(element: &Element, width: u16) -> Vec<Row> {
    let inner = usize::from(width.saturating_sub(MARGIN * 2).max(1));
    let mut rows = Vec::new();
    for line in element.drawn() {
        let styled = styled(&line);
        match sent_tint(line.kind) {
            Some((background, edge)) => {
                let strip = |glyph: &str| Row {
                    line: Line::from(Span::styled(glyph.repeat(usize::from(width)), edge)),
                    tint: None,
                    edge: true,
                };
                rows.push(strip("▄"));
                rows.extend(wrap(&styled, inner).into_iter().map(|line| Row {
                    line,
                    tint: Some(background),
                    edge: false,
                }));
                rows.push(strip("▀"));
            }
            None => rows.extend(wrap(&styled, inner).into_iter().map(Row::text)),
        }
    }
    rows
}

/// `line` broken into rows of at most `width` cells, at a space where one falls in the row and in the middle of a
/// word where none does, each character keeping its style. An empty line is one empty row.
pub fn wrap(line: &Line<'static>, width: usize) -> Vec<Line<'static>> {
    let width = width.max(1);
    let cells: Vec<(char, Style)> = line
        .spans
        .iter()
        .flat_map(|span| {
            let style = line.style.patch(span.style);
            span.content.chars().map(move |c| (c, style))
        })
        .collect();
    let mut rows: Vec<Vec<(char, Style)>> = vec![Vec::new()];
    let mut used = 0;
    for (c, style) in cells {
        let w = c.width().unwrap_or(0);
        if used + w > width && used > 0 {
            let row = rows.last_mut().map(std::mem::take).unwrap_or_default();
            // Break after the row's last space, carrying the word begun since onto the next row.
            let (kept, carried) = match row.iter().rposition(|(c, _)| *c == ' ') {
                Some(space) if space + 1 < row.len() => {
                    let mut kept = row;
                    let carried = kept.split_off(space + 1);
                    (kept, carried)
                }
                _ => (row, Vec::new()),
            };
            if let Some(last) = rows.last_mut() {
                *last = kept;
            }
            used = carried.iter().map(|(c, _)| c.width().unwrap_or(0)).sum();
            rows.push(carried);
        }
        if let Some(row) = rows.last_mut() {
            row.push((c, style));
        }
        used += w;
    }
    rows.into_iter().map(spans).collect()
}

/// Characters back into spans, one for each run of a style.
fn spans(cells: Vec<(char, Style)>) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut run = String::new();
    let mut current: Option<Style> = None;
    for (c, style) in cells {
        if current.is_some_and(|s| s != style) {
            spans.push(Span::styled(
                std::mem::take(&mut run),
                current.unwrap_or_default(),
            ));
        }
        current = Some(style);
        run.push(c);
    }
    if let Some(style) = current {
        spans.push(Span::styled(run, style));
    }
    Line::from(spans)
}

/// The background and strip styles a sent line is drawn in: an ordinary prompt's on the sent tint, a command's on the
/// command colour's darker shade, an outside command's on the outside colour's, a help request's on the help colour's;
/// `None` for every other line.
pub fn sent_tint(kind: LineKind) -> Option<(Style, Style)> {
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

/// A line in its colours; a reply's Markdown is rendered here.
pub fn styled(line: &HistoryLine) -> Line<'static> {
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
        LineKind::Fold => return fold(&line.text),
        LineKind::Error => palette::ember(),
    };
    Line::from(Span::styled(line.text.clone(), style))
}

/// An info line in its colours: its `▸` or `▾` in `WISP`, so a fold stands out from the output around it, the rest
/// muted, and an exit status other than 0 in `EMBER`.
fn fold(text: &str) -> Line<'static> {
    let Some(glyph) = text.find(['▸', '▾']) else {
        return Line::from(Span::styled(text.to_string(), palette::muted()));
    };
    let after = glyph + text[glyph..].chars().next().map_or(0, char::len_utf8);
    let mut spans = vec![
        Span::styled(text[..glyph].to_string(), palette::muted()),
        Span::styled(text[glyph..after].to_string(), palette::wisp()),
    ];
    let rest = &text[after..];
    let failed = rest
        .split(" · ")
        .position(|part| part.starts_with("exit ") && part != "exit 0");
    match failed {
        Some(index) => {
            let parts: Vec<&str> = rest.split(" · ").collect();
            let before = parts[..index].join(" · ");
            let tail = parts[index + 1..].join(" · ");
            spans.push(Span::styled(before + " · ", palette::muted()));
            spans.push(Span::styled(parts[index].to_string(), palette::ember()));
            if !tail.is_empty() {
                spans.push(Span::styled(format!(" · {tail}"), palette::muted()));
            }
        }
        None => spans.push(Span::styled(rest.to_string(), palette::muted())),
    }
    Line::from(spans)
}

/// Where a line's lead ends, and its colour, so what happened stands apart from the muted rest: a tool call's `⚙` and
/// tool name in `WISP`, a stretch of thinking's `∴ thought` in `HELP`'s grey, and an answered or waiting approval's
/// `✓` or `⚠` and words up to the colon in `AMBER`, or `EMBER` when it was refused. None for any other line.
pub fn lead(kind: LineKind, text: &str) -> Option<(usize, Style)> {
    let word = |glyph: &str| {
        let after = text.strip_prefix(glyph)?;
        Some(glyph.len() + after.find(' ').unwrap_or(after.len()))
    };
    match kind {
        LineKind::Tool if text.starts_with("⚙ ") => word("⚙ ").map(|end| (end, palette::wisp())),
        LineKind::Tool if text.starts_with("∴ ") => {
            word("∴ ").map(|end| (end, palette::thinking()))
        }
        LineKind::Tool | LineKind::Note if text.starts_with("⚠ ") || text.starts_with("✓ ") => {
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

/// Where the pane is in the conversation, and the size it was last drawn at.
#[derive(Debug, Default)]
pub struct Pane {
    /// The first row shown, once the person has scrolled away from the end; `None` follows the end.
    pub top: Option<usize>,
    /// The width last drawn at, so scrolling knows how the conversation wraps.
    width: Cell<u16>,
    /// The height last drawn at.
    height: Cell<u16>,
}

impl Pane {
    /// The rows the conversation takes at `width`, in all.
    fn total(transcript: &Transcript, width: u16) -> usize {
        let mut previous = None;
        let mut total = 0;
        for element in &transcript.elements {
            total += height(previous, element, width);
            previous = Some(element);
        }
        total
    }

    /// The first row to show for a pane `rows` high over `total` rows: the end's when following, or the row
    /// scrolled to, kept within the conversation.
    fn first(&self, total: usize, rows: usize) -> usize {
        let last_top = total.saturating_sub(rows);
        self.top.map_or(last_top, |top| top.min(last_top))
    }

    /// Rows a page scroll moves: the pane's height less one, so a row of the last page stays in view.
    pub fn page(&self) -> isize {
        isize::try_from(self.height.get().saturating_sub(1).max(1)).unwrap_or(1)
    }

    /// Scrolls by `by` rows (negative is up); reaching the end follows it again.
    pub fn scroll(&mut self, transcript: &Transcript, by: isize) {
        let width = match self.width.get() {
            0 => 80,
            width => width,
        };
        let rows = usize::from(self.height.get().max(1));
        let total = Self::total(transcript, width);
        let last_top = total.saturating_sub(rows);
        let top = self
            .first(total, rows)
            .saturating_add_signed(by)
            .min(last_top);
        self.top = (top < last_top).then_some(top);
    }

    /// Whether the pane follows the end of the conversation.
    #[cfg(test)]
    pub fn following(&self) -> bool {
        self.top.is_none()
    }

    /// Draws the rows of `transcript` that fall in `area`.
    pub fn render(&self, frame: &mut Frame, transcript: &Transcript, area: Rect) {
        self.width.set(area.width);
        self.height.set(area.height);
        if area.height == 0 || area.width == 0 {
            return;
        }
        let rows = usize::from(area.height);
        let first = self.first(Self::total(transcript, area.width), rows);
        let margin = MARGIN.min(area.width / 2);
        let mut at = 0;
        let mut previous = None;
        for element in &transcript.elements {
            let separated = Transcript::separated(previous, element);
            previous = Some(element);
            let drawn = rows_of(element, area.width, separated);
            if at + drawn.len() <= first {
                at += drawn.len();
                continue;
            }
            for row in drawn {
                if at >= first + rows {
                    return;
                }
                if at >= first {
                    let y = area.y + u16::try_from(at - first).unwrap_or(u16::MAX);
                    draw(frame, &row, Rect::new(area.x, y, area.width, 1), margin);
                }
                at += 1;
            }
        }
    }
}

/// `element`'s rows, a blank row first when `separated`.
fn rows_of(element: &Element, width: u16, separated: bool) -> Vec<Row> {
    let mut drawn = Vec::new();
    if separated {
        drawn.push(Row::blank());
    }
    drawn.extend(rows(element, width));
    drawn
}

/// Draws one row into `area`, a single row: its tint across the whole width, its text inside the margin, or at the
/// edge for a strip.
fn draw(frame: &mut Frame, row: &Row, area: Rect, margin: u16) {
    if let Some(tint) = row.tint {
        frame.render_widget(Paragraph::new("").style(tint), area);
    }
    let rect = if row.edge {
        area
    } else {
        Rect {
            x: area.x + margin,
            width: area.width.saturating_sub(margin * 2),
            ..area
        }
    };
    let paragraph = Paragraph::new(row.line.clone());
    frame.render_widget(
        match row.tint {
            Some(tint) => paragraph.style(tint),
            None => paragraph,
        },
        rect,
    );
}

/// Writes the conversation into the terminal's scrollback as the pane draws it at `width`, in its colours, once the
/// alternate screen is left; each row ends with a reset and a newline.
pub fn print(out: &mut impl Write, transcript: &Transcript, width: u16) -> io::Result<()> {
    let margin = " ".repeat(usize::from(MARGIN.min(width / 2)));
    let mut previous = None;
    for element in &transcript.elements {
        let separated = Transcript::separated(previous, element);
        previous = Some(element);
        for row in rows_of(element, width, separated) {
            let mut text = String::new();
            let mut cells = 0;
            if !row.edge {
                text.push_str(&sgr(row.tint.unwrap_or_default()));
                text.push_str(&margin);
                cells += margin.len();
            }
            for span in &row.line.spans {
                let style = row.tint.map_or(span.style, |tint| tint.patch(span.style));
                text.push_str(&sgr(style));
                text.push_str(&span.content);
                cells += span
                    .content
                    .chars()
                    .map(|c| c.width().unwrap_or(0))
                    .sum::<usize>();
            }
            if let Some(tint) = row.tint {
                text.push_str(&sgr(tint));
                text.push_str(&" ".repeat(usize::from(width).saturating_sub(cells)));
            }
            text.push_str("\x1b[0m\n");
            out.write_all(text.as_bytes())?;
        }
    }
    out.flush()
}

/// The escape sequence that sets `style` from a reset: its colours as 24-bit, and bold, dim, and italic.
fn sgr(style: Style) -> String {
    let mut codes = vec![String::from("0")];
    if let Some(Color::Rgb(r, g, b)) = style.fg {
        codes.push(format!("38;2;{r};{g};{b}"));
    }
    if let Some(Color::Rgb(r, g, b)) = style.bg {
        codes.push(format!("48;2;{r};{g};{b}"));
    }
    for (modifier, code) in [
        (Modifier::BOLD, "1"),
        (Modifier::DIM, "2"),
        (Modifier::ITALIC, "3"),
    ] {
        if style.add_modifier.contains(modifier) {
            codes.push(code.into());
        }
    }
    format!("\x1b[{}m", codes.join(";"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ToolOutput;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn plain(line: &Line<'_>) -> String {
        line.spans
            .iter()
            .map(|span| span.content.as_ref())
            .collect()
    }

    fn conversation(replies: usize) -> Transcript {
        let mut transcript = Transcript::default();
        transcript.push("› count", LineKind::User);
        for n in 1..=replies {
            transcript.push(&format!("reply line {n}"), LineKind::Reply);
        }
        transcript
    }

    fn screen(pane: &Pane, transcript: &Transcript, width: u16, height: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).expect("test terminal");
        terminal
            .draw(|frame| pane.render(frame, transcript, frame.area()))
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
    fn replies_are_drawn_with_their_markdown_rendered() {
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
            spans("✓ approved for this turn: git push", LineKind::Note),
            [
                ("✓ approved for this turn".into(), palette::amber()),
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
        let tinted = |text: &str, kind| {
            let mut transcript = Transcript::default();
            transcript.push(text, kind);
            let mut terminal = Terminal::new(TestBackend::new(16, 3)).expect("test terminal");
            terminal
                .draw(|frame| Pane::default().render(frame, &transcript, frame.area()))
                .expect("draw");
            terminal.backend().buffer().clone()
        };
        let buffer = tinted("› hi", LineKind::User);
        let row = |y: u16| {
            (0..16)
                .map(|x| buffer[(x, y)].symbol().to_string())
                .collect::<String>()
        };
        assert_eq!(row(0), "▄".repeat(16));
        assert_eq!(row(1).trim_end(), " › hi");
        assert_eq!(row(2), "▀".repeat(16));
        assert_eq!(
            buffer[(15, 1)].bg,
            palette::SENT,
            "the tint runs edge to edge"
        );
        assert_eq!(buffer[(0, 0)].fg, palette::SENT);
        // A command's line on the command colour's darker shade, an outside command's on the outside colour's, a help
        // request's on the help colour's, each in the same light text.
        for (text, kind, colour) in [
            ("! git status", LineKind::Command, palette::COMMAND_SENT),
            ("!! brew up", LineKind::Outside, palette::OUTSIDE_SENT),
            ("? models", LineKind::Help, palette::HELP_SENT),
        ] {
            let buffer = tinted(text, kind);
            assert_eq!(buffer[(15, 1)].bg, colour, "{text}");
            assert_eq!(buffer[(1, 1)].fg, palette::WHITE, "{text}");
            assert_eq!(
                (buffer[(0, 0)].fg, buffer[(0, 2)].fg),
                (colour, colour),
                "{text}"
            );
        }
        assert_eq!(sent_tint(LineKind::Note), None);
    }

    #[test]
    fn a_line_wraps_at_a_space_and_keeps_its_styles() {
        let line = Line::from(vec![
            Span::styled("one two ", palette::body()),
            Span::styled("three", palette::strong()),
        ]);
        let rows = wrap(&line, 9);
        assert_eq!(
            rows.iter().map(plain).collect::<Vec<_>>(),
            vec!["one two ", "three"]
        );
        assert_eq!(rows[1].spans[0].style, palette::strong());
    }

    #[test]
    fn a_word_longer_than_the_row_is_broken_in_it() {
        let rows = wrap(&Line::from("abcdefghij"), 4);
        assert_eq!(
            rows.iter().map(plain).collect::<Vec<_>>(),
            vec!["abcd", "efgh", "ij"]
        );
        assert_eq!(wrap(&Line::default(), 4).len(), 1);
    }

    #[test]
    fn a_sent_line_is_tinted_between_strips() {
        let transcript = conversation(0);
        let drawn = rows(&transcript.elements[0], 10);
        assert_eq!(drawn.len(), 3);
        assert!(drawn[0].edge && plain(&drawn[0].line) == "▄".repeat(10));
        assert_eq!(drawn[1].tint, Some(palette::sent_background()));
        assert!(drawn[2].edge && plain(&drawn[2].line) == "▀".repeat(10));
    }

    #[test]
    fn the_pane_follows_the_end_until_scrolled() {
        let transcript = conversation(10);
        let mut pane = Pane::default();
        let shown = screen(&pane, &transcript, 30, 4);
        assert_eq!(shown.last().map(String::as_str), Some(" reply line 10"));
        pane.scroll(&transcript, -3);
        assert!(!pane.following());
        assert_eq!(
            screen(&pane, &transcript, 30, 4).last().map(String::as_str),
            Some(" reply line 7")
        );
        pane.scroll(&transcript, 100);
        assert!(pane.following());
    }

    #[test]
    fn scrolling_up_stops_at_the_first_row() {
        let transcript = conversation(10);
        let mut pane = Pane::default();
        let _ = screen(&pane, &transcript, 30, 4);
        pane.scroll(&transcript, -1000);
        assert_eq!(pane.top, Some(0));
        let shown = screen(&pane, &transcript, 30, 4);
        assert_eq!(shown[0], "▄".repeat(30));
    }

    #[test]
    fn a_short_conversation_starts_at_the_top() {
        let transcript = conversation(1);
        let pane = Pane::default();
        let shown = screen(&pane, &transcript, 20, 8);
        // A sent line's strip sets it apart, so the reply follows with no blank row.
        assert_eq!(shown[1], " › count");
        assert_eq!(shown[3], " reply line 1");
        assert_eq!(shown[4], "");
    }

    #[test]
    fn rows_are_kept_until_the_width_changes() {
        let transcript = conversation(1);
        let element = &transcript.elements[1];
        assert_eq!(rows(element, 20).len(), 1);
        assert_eq!(rows(element, 8).len(), 2);
        assert!(matches!(&*element.rows.borrow(), Some((8, _))));
    }

    #[test]
    fn quitting_prints_each_row_in_its_colours() -> std::io::Result<()> {
        let mut transcript = conversation(1);
        transcript.push("⚙ run_command ls", LineKind::Tool);
        transcript.attach(ToolOutput {
            id: "e".into(),
            text: "a".into(),
            lines: 1,
            bytes: 1,
            truncated: false,
            shown_lines: 20,
        });
        let mut out = Vec::new();
        print(&mut out, &transcript, 20)?;
        let text = String::from_utf8_lossy(&out);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3 + 1 + 1 + 2);
        assert!(lines[1].contains("› count") && lines[1].contains("48;2;"));
        assert!(lines[1].ends_with("\x1b[0m"));
        assert!(lines[3].contains("reply line 1"));
        assert!(lines[5].contains("⚙ run_command"));
        assert!(lines[6].contains("    a"));
        Ok(())
    }

    #[test]
    fn a_style_is_written_as_24_bit_colour() {
        assert_eq!(sgr(Style::default()), "\x1b[0m");
        assert_eq!(sgr(palette::user()), "\x1b[0;38;2;230;237;240;1m");
    }
}
