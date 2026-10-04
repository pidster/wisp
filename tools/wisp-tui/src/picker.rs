//! A choice a chat command asks (`/config set` without a value, say), picked with the arrow keys or
//! answered by typing when the choice takes text; or, for a choice with toggles (`/models`, ADR 0056), a table
//! whose rows Space turns on and off and Enter saves together. Pure: the terminal and the protocol are the
//! caller's.

use ratatui::text::{Line, Span};

use crate::palette;
use crate::protocol::Choice;

/// Options shown at once; a longer list scrolls to keep the selection in sight.
pub const VISIBLE: usize = 8;

/// A choice being answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Picker {
    /// What was asked.
    pub choice: Choice,
    /// The highlighted option.
    pub selected: usize,
}

impl Picker {
    /// Opens a choice with the current value highlighted.
    pub fn new(choice: Choice) -> Self {
        let selected = choice
            .current
            .as_ref()
            .and_then(|current| choice.options.iter().position(|o| &o.value == current))
            .unwrap_or(0);
        Self { choice, selected }
    }

    /// Moves the highlight up, or down with `down`, stopping at the ends.
    pub fn step(&mut self, down: bool) {
        let last = self.choice.options.len().saturating_sub(1);
        self.selected = if down {
            (self.selected + 1).min(last)
        } else {
            self.selected.saturating_sub(1)
        };
    }

    /// Space in a choice with toggles: turns the highlighted row on or off. Nothing in a plain choice.
    pub fn toggle(&mut self) {
        if !self.choice.toggles {
            return;
        }
        if let Some(option) = self.choice.options.get_mut(self.selected) {
            option.on = Some(!option.on.unwrap_or(false));
        }
    }

    /// The answer Enter gives a choice with toggles: the values of the rows left on, in order; `None` for a
    /// plain choice.
    pub fn values(&self) -> Option<Vec<String>> {
        self.choice.toggles.then(|| {
            self.choice
                .options
                .iter()
                .filter(|option| option.on == Some(true))
                .map(|option| option.value.clone())
                .collect()
        })
    }

    /// The answer Enter gives: the typed text when the choice takes text and some is typed, otherwise
    /// the highlighted option; `None` when there is nothing to give.
    pub fn answer(&self, typed: &str) -> Option<String> {
        let typed = typed.trim();
        if self.choice.accepts_text && !typed.is_empty() {
            return Some(typed.to_string());
        }
        self.choice
            .options
            .get(self.selected)
            .map(|option| option.value.clone())
    }

    /// The first option shown when only `VISIBLE` fit.
    fn first_shown(&self) -> usize {
        let count = self.choice.options.len();
        if count <= VISIBLE {
            0
        } else {
            (self.selected + 1)
                .saturating_sub(VISIBLE)
                .min(count - VISIBLE)
        }
    }

    /// The lines inside the picker's border, `width` cells wide: the question, the options around the
    /// highlight (`▸` on it, `*` on the current value), and the keys; for a choice with toggles, the table
    /// instead, its heading row and a row per option. The typed-text row, when there is one, is the caller's,
    /// so it can carry the cursor.
    pub fn lines(&self, width: usize) -> Vec<Line<'static>> {
        if self.choice.toggles {
            return self.table(width);
        }
        let mut lines = vec![Line::from(Span::styled(
            self.choice.title.clone(),
            palette::body(),
        ))];
        let first = self.first_shown();
        for (index, option) in self
            .choice
            .options
            .iter()
            .enumerate()
            .skip(first)
            .take(VISIBLE)
        {
            let chosen = index == self.selected;
            let current = self.choice.current.as_deref() == Some(option.value.as_str());
            let mut spans = vec![
                Span::styled(if chosen { "▸ " } else { "  " }, palette::prompt()),
                Span::styled(
                    option.label.clone(),
                    if chosen {
                        palette::user()
                    } else {
                        palette::body()
                    },
                ),
            ];
            if current {
                spans.push(Span::styled(" *", palette::wisp()));
            }
            if !option.detail.is_empty() {
                spans.push(Span::styled(
                    format!("  {}", option.detail),
                    palette::muted(),
                ));
            }
            lines.push(Line::from(spans));
        }
        let keys = match (self.choice.options.is_empty(), self.choice.accepts_text) {
            (true, _) => "type a value · Enter to set · Esc to leave it",
            (false, true) => "↑↓ to move · or type a value · Enter to choose · Esc to leave it",
            (false, false) => "↑↓ to move · Enter to choose · Esc to leave it",
        };
        lines.push(Line::from(Span::styled(keys, palette::muted())));
        lines
    }

    /// A choice with toggles as a table `width` cells wide: the question, the headings, then each row as
    /// `▸ [x]` and its cells, the current value's name after `*`, columns padded to their widest cell. The
    /// columns least worth their room go first when they do not fit, lowest `drop` rank first, as `wisp
    /// models` drops them; the last column is cut to what is left.
    fn table(&self, width: usize) -> Vec<Line<'static>> {
        let columns = &self.choice.columns;
        let cell = |option: &crate::protocol::ChoiceOption, index: usize| -> String {
            let text = option.cells.get(index).cloned().unwrap_or_default();
            if index == 0 {
                let current = self.choice.current.as_deref() == Some(option.value.as_str());
                format!("{} {text}", if current { "*" } else { " " })
            } else {
                text
            }
        };
        let heading = |index: usize| -> String {
            let text = columns
                .get(index)
                .map(|c| c.heading.clone())
                .unwrap_or_default();
            if index == 0 {
                format!("  {text}")
            } else {
                text
            }
        };
        let widths: Vec<usize> = (0..columns.len())
            .map(|index| {
                self.choice
                    .options
                    .iter()
                    .map(|option| cell(option, index).chars().count())
                    .chain(std::iter::once(heading(index).chars().count()))
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        let kept = fitting(columns, &widths, width.saturating_sub(TOGGLE_CELLS));
        let row = |cells: Vec<String>| -> String {
            let mut text = String::new();
            for (position, (index, content)) in kept.iter().zip(cells).enumerate() {
                if position + 1 == kept.len() {
                    text.push_str(&content);
                } else {
                    let pad = widths[*index].saturating_sub(content.chars().count()) + 2;
                    text.push_str(&content);
                    text.push_str(&" ".repeat(pad));
                }
            }
            cut(text.trim_end(), width.saturating_sub(TOGGLE_CELLS))
        };
        let mut lines = vec![
            Line::from(Span::styled(
                cut(&self.choice.title, width),
                palette::body(),
            )),
            Line::from(Span::styled(
                format!(
                    "{}{}",
                    " ".repeat(TOGGLE_CELLS),
                    row(kept.iter().map(|index| heading(*index)).collect())
                ),
                palette::muted(),
            )),
        ];
        let first = self.first_shown();
        for (index, option) in self
            .choice
            .options
            .iter()
            .enumerate()
            .skip(first)
            .take(VISIBLE)
        {
            let chosen = index == self.selected;
            let on = option.on == Some(true);
            lines.push(Line::from(vec![
                Span::styled(if chosen { "▸ " } else { "  " }, palette::prompt()),
                Span::styled(if on { "[x] " } else { "[ ] " }, palette::wisp()),
                Span::styled(
                    row(kept.iter().map(|column| cell(option, *column)).collect()),
                    if chosen {
                        palette::user()
                    } else if on {
                        palette::body()
                    } else {
                        palette::muted()
                    },
                ),
            ]));
        }
        lines.push(Line::from(Span::styled(
            cut(
                "↑↓ to move · Space to turn on or off · Enter to save · Esc to leave them",
                width,
            ),
            palette::muted(),
        )));
        lines
    }

    /// Rows the picker takes inside its border at `width`: its lines, and the typed-text row when it has one.
    pub fn rows(&self, width: usize) -> usize {
        self.lines(width).len() + usize::from(self.choice.accepts_text)
    }
}

/// Cells before a toggle row's first column: the highlight and the box, `▸ [x] `.
const TOGGLE_CELLS: usize = 6;

/// The narrowest the last column is left, as `wisp models` leaves it, before columns are dropped.
const MINIMUM_LAST: usize = 20;

/// The indices of the columns that fit `width` with the last column at least `MINIMUM_LAST` cells: every one
/// when they do, otherwise without the droppable ones, lowest `drop` rank first, until they do or only the
/// undroppable are left. `wisp models` keeps columns the same way (`TerminalTable.fitting`).
fn fitting(
    columns: &[crate::protocol::ChoiceColumn],
    widths: &[usize],
    width: usize,
) -> Vec<usize> {
    let mut kept: Vec<usize> = (0..columns.len()).collect();
    loop {
        let before: usize = kept
            .iter()
            .take(kept.len().saturating_sub(1))
            .map(|index| widths[*index] + 2)
            .sum();
        if before + MINIMUM_LAST <= width {
            return kept;
        }
        let next = kept
            .iter()
            .filter(|index| columns[**index].drop > 0)
            .min_by_key(|index| columns[**index].drop)
            .copied();
        match next {
            Some(index) => kept.retain(|kept| *kept != index),
            None => return kept,
        }
    }
}

/// `text` cut to `width` characters, the last one an ellipsis when anything was cut.
fn cut(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    let mut cut: String = text.chars().take(width.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ChoiceOption;

    fn choice(values: &[&str], current: Option<&str>, accepts_text: bool) -> Choice {
        Choice {
            id: "c".into(),
            title: "pick".into(),
            options: values
                .iter()
                .map(|v| ChoiceOption {
                    value: (*v).into(),
                    label: (*v).into(),
                    detail: String::new(),
                    cells: Vec::new(),
                    on: None,
                })
                .collect(),
            current: current.map(str::to_string),
            accepts_text,
            toggles: false,
            columns: Vec::new(),
        }
    }

    fn text(line: &Line) -> String {
        line.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn the_current_value_is_highlighted_and_the_arrows_stop_at_the_ends() {
        let mut picker = Picker::new(choice(
            &["rules", "system-model", "coreml"],
            Some("coreml"),
            false,
        ));
        assert_eq!(picker.selected, 2);
        picker.step(true);
        assert_eq!(picker.selected, 2);
        picker.step(false);
        picker.step(false);
        picker.step(false);
        assert_eq!(picker.answer(""), Some("rules".into()));
        assert_eq!(
            picker.answer("typed"),
            Some("rules".into()),
            "typed text only where it is taken"
        );
        let lines = picker.lines(80);
        assert_eq!(text(&lines[1]), "▸ rules");
        assert_eq!(text(&lines[3]), "  coreml *");
        assert_eq!(
            text(lines.last().unwrap_or(&Line::default())),
            "↑↓ to move · Enter to choose · Esc to leave it"
        );
        assert_eq!(picker.rows(80), 5);
    }

    #[test]
    fn typed_text_answers_where_the_choice_takes_it() {
        let open = Picker::new(choice(&[], None, true));
        assert_eq!(open.answer(" 30 "), Some("30".into()));
        assert_eq!(open.answer(""), None);
        assert_eq!(
            open.rows(80),
            3,
            "the question, the keys, and the typed row"
        );
        let both = Picker::new(choice(&["system"], None, true));
        assert_eq!(both.answer(""), Some("system".into()));
        assert_eq!(both.answer("ollama:x"), Some("ollama:x".into()));
    }

    /// The `/models` picker's choice: three models under four columns, the first two on.
    fn models() -> Choice {
        let row = |value: &str, cells: [&str; 4], on: bool| ChoiceOption {
            value: value.into(),
            label: value.into(),
            detail: String::new(),
            cells: cells.iter().map(|c| (*c).to_string()).collect(),
            on: Some(on),
        };
        Choice {
            id: "m".into(),
            title: "Models".into(),
            options: vec![
                row(
                    "system",
                    ["system", "on-device", "8,192", "tools, vision"],
                    true,
                ),
                row("ollama:a", ["ollama:a", "Ollama", "65,536", "tools"], true),
                row(
                    "ollama:b",
                    ["ollama:b", "Ollama", "", "tools, thinking"],
                    false,
                ),
            ],
            current: Some("ollama:a".into()),
            accepts_text: false,
            toggles: true,
            columns: [
                ("MODEL", 0),
                ("RUNTIME", 2),
                ("CONTEXT", 7),
                ("CAPABILITIES", 0),
            ]
            .iter()
            .map(|(heading, drop)| crate::protocol::ChoiceColumn {
                heading: (*heading).into(),
                drop: *drop,
            })
            .collect(),
        }
    }

    #[test]
    fn a_choice_with_toggles_is_a_table_whose_rows_space_turns_on_and_off() {
        let mut picker = Picker::new(models());
        assert_eq!(picker.selected, 1, "the model in use is highlighted");
        let lines = picker.lines(80);
        assert_eq!(text(&lines[0]), "Models");
        assert_eq!(
            text(&lines[1]),
            "        MODEL     RUNTIME    CONTEXT  CAPABILITIES"
        );
        assert_eq!(
            text(&lines[2]),
            "  [x]   system    on-device  8,192    tools, vision"
        );
        assert_eq!(
            text(&lines[3]),
            "▸ [x] * ollama:a  Ollama     65,536   tools"
        );
        assert_eq!(
            text(&lines[4]),
            "  [ ]   ollama:b  Ollama              tools, thinking"
        );
        assert_eq!(
            text(lines.last().unwrap_or(&Line::default())),
            "↑↓ to move · Space to turn on or off · Enter to save · Esc to leave them"
        );
        picker.toggle();
        picker.step(true);
        picker.toggle();
        assert_eq!(
            picker.values(),
            Some(vec!["system".to_string(), "ollama:b".to_string()])
        );
        // Narrower: the runtime goes first, then the window; the name and capabilities stay, cut to fit.
        let narrow = picker.lines(47);
        assert_eq!(text(&narrow[1]), "        MODEL     CONTEXT  CAPABILITIES");
        assert!(narrow.iter().all(|line| text(line).chars().count() <= 47));
        let narrower = picker.lines(40);
        assert_eq!(text(&narrower[1]), "        MODEL     CAPABILITIES");
        assert_eq!(text(&narrower[2]), "  [x]   system    tools, vision");
        let tiny = picker.lines(24);
        assert_eq!(text(&tiny[2]), "  [x]   system    tools…");
        // A plain choice has no values and no toggling.
        let mut plain = Picker::new(choice(&["a"], None, false));
        plain.toggle();
        assert_eq!(plain.values(), None);
    }

    #[test]
    fn a_long_list_scrolls_to_keep_the_highlight_in_sight() {
        let values: Vec<String> = (1..=20).map(|n| format!("option{n}")).collect();
        let refs: Vec<&str> = values.iter().map(String::as_str).collect();
        let mut picker = Picker::new(choice(&refs, Some("option15"), false));
        assert_eq!(picker.first_shown(), 7);
        let lines = picker.lines(80);
        assert_eq!(lines.len(), 1 + VISIBLE + 1);
        assert_eq!(text(&lines[VISIBLE]), "▸ option15 *");
        picker.selected = 0;
        assert_eq!(picker.first_shown(), 0);
    }
}
