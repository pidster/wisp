//! The input line's text and cursor, and every edit the keys can make to them. Pure: the terminal is
//! the caller's, so each edit is tested on its own. The cursor is an index in characters, never inside
//! one; a word is a run of alphanumeric characters, as shells and editors take it.

use unicode_width::UnicodeWidthChar;

/// One edit, as a key or a paste asks for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Edit {
    /// Insert a character at the cursor.
    Insert(char),
    /// Insert pasted text at the cursor; carriage returns become newlines.
    Paste(String),
    /// Insert a newline at the cursor, for a message of several lines.
    Newline,
    /// Delete the character before the cursor.
    Backspace,
    /// Delete the character at the cursor.
    Delete,
    /// Move one character left.
    Left,
    /// Move one character right.
    Right,
    /// Move to the start of the previous word.
    WordLeft,
    /// Move past the end of the next word.
    WordRight,
    /// Move to the start.
    Home,
    /// Move to the end.
    End,
    /// Delete back to the previous whitespace, as readline's Ctrl-W does, so `-m msg` goes in two.
    DeleteWordBefore,
    /// Delete from the start to the cursor.
    KillToStart,
    /// Delete from the cursor to the end.
    KillToEnd,
}

/// The text being composed and where the cursor is in it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Editor {
    /// The characters, so the cursor indexes them directly.
    chars: Vec<char>,
    /// The cursor, from 0 to `chars.len()`.
    cursor: usize,
}

impl Editor {
    /// The text.
    pub fn text(&self) -> String {
        self.chars.iter().collect()
    }

    /// Whether nothing is typed.
    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    /// Replaces the text, with the cursor at its end, as recalling a line does.
    pub fn set(&mut self, text: &str) {
        self.chars = text.chars().collect();
        self.cursor = self.chars.len();
    }

    /// The cursor, as a character index.
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    /// Replaces the characters from `from` to the cursor with `text`, leaving the cursor after it; a
    /// `from` past the cursor inserts at the cursor.
    pub fn replace(&mut self, from: usize, text: &str) {
        let from = from.min(self.cursor);
        self.chars.splice(from..self.cursor, text.chars());
        self.cursor = from + text.chars().count();
    }

    /// Takes the text, leaving the editor empty.
    pub fn take(&mut self) -> String {
        let text = self.text();
        self.set("");
        text
    }

    /// Applies one edit.
    pub fn apply(&mut self, edit: &Edit) {
        match edit {
            Edit::Insert(c) => self.insert(&[*c]),
            Edit::Newline => self.insert(&['\n']),
            Edit::Paste(text) => {
                let normalised = text.replace("\r\n", "\n").replace('\r', "\n");
                let chars: Vec<char> = normalised
                    .chars()
                    .filter(|c| *c == '\n' || !c.is_control())
                    .collect();
                self.insert(&chars);
            }
            Edit::Backspace => {
                if self.cursor > 0 {
                    self.cursor -= 1;
                    self.chars.remove(self.cursor);
                }
            }
            Edit::Delete => {
                if self.cursor < self.chars.len() {
                    self.chars.remove(self.cursor);
                }
            }
            Edit::Left => self.cursor = self.cursor.saturating_sub(1),
            Edit::Right => self.cursor = (self.cursor + 1).min(self.chars.len()),
            Edit::WordLeft => self.cursor = self.word_start_before(),
            Edit::WordRight => self.cursor = self.word_end_after(),
            Edit::Home => self.cursor = 0,
            Edit::End => self.cursor = self.chars.len(),
            Edit::DeleteWordBefore => {
                let start = self.space_start_before();
                self.chars.drain(start..self.cursor);
                self.cursor = start;
            }
            Edit::KillToStart => {
                self.chars.drain(..self.cursor);
                self.cursor = 0;
            }
            Edit::KillToEnd => self.chars.truncate(self.cursor),
        }
    }

    fn insert(&mut self, new: &[char]) {
        self.chars
            .splice(self.cursor..self.cursor, new.iter().copied());
        self.cursor += new.len();
    }

    /// Where a word before the cursor starts: back over separators, then over the word.
    fn word_start_before(&self) -> usize {
        let mut index = self.cursor;
        while index > 0 && !self.chars[index - 1].is_alphanumeric() {
            index -= 1;
        }
        while index > 0 && self.chars[index - 1].is_alphanumeric() {
            index -= 1;
        }
        index
    }

    /// Where a whitespace-delimited word before the cursor starts: back over spaces, then over the rest.
    fn space_start_before(&self) -> usize {
        let mut index = self.cursor;
        while index > 0 && self.chars[index - 1].is_whitespace() {
            index -= 1;
        }
        while index > 0 && !self.chars[index - 1].is_whitespace() {
            index -= 1;
        }
        index
    }

    /// Where the next word ends: forward over separators, then over the word.
    fn word_end_after(&self) -> usize {
        let mut index = self.cursor;
        while index < self.chars.len() && !self.chars[index].is_alphanumeric() {
            index += 1;
        }
        while index < self.chars.len() && self.chars[index].is_alphanumeric() {
            index += 1;
        }
        index
    }

    /// The text laid out in rows of `width` cells: a new row at each newline and wherever the next
    /// character would not fit, wide characters taking two cells. Returns the rows and the cursor's row
    /// and column; a cursor at the end of a full row moves to the start of a new one, so it always has a
    /// cell.
    pub fn rows(&self, width: usize) -> Layout {
        let width = width.max(1);
        let mut rows = vec![String::new()];
        let mut column = 0;
        let mut cursor = None;
        for (index, &c) in self.chars.iter().enumerate() {
            if c == '\n' {
                if index == self.cursor {
                    cursor = Some((rows.len() - 1, column));
                }
                rows.push(String::new());
                column = 0;
                continue;
            }
            let cells = c.width().unwrap_or(0);
            if column + cells > width {
                rows.push(String::new());
                column = 0;
            }
            if index == self.cursor {
                cursor = Some((rows.len() - 1, column));
            }
            if let Some(last) = rows.last_mut() {
                last.push(c);
            }
            column += cells;
        }
        let (row, column) = cursor.unwrap_or_else(|| {
            if column >= width {
                rows.push(String::new());
                (rows.len() - 1, 0)
            } else {
                (rows.len() - 1, column)
            }
        });
        Layout { rows, row, column }
    }

    /// Where each cursor position, from 0 to the text's length, is drawn at `width` cells: its row and column,
    /// laid out exactly as `rows` lays the text out, so a position past a full row is on the next.
    fn positions(&self, width: usize) -> Vec<(usize, usize)> {
        let width = width.max(1);
        let mut out = Vec::with_capacity(self.chars.len() + 1);
        let (mut row, mut column) = (0, 0);
        for &c in &self.chars {
            if c == '\n' {
                out.push((row, column));
                row += 1;
                column = 0;
                continue;
            }
            let cells = c.width().unwrap_or(0);
            if column + cells > width {
                row += 1;
                column = 0;
            }
            out.push((row, column));
            column += cells;
        }
        out.push(if column >= width {
            (row + 1, 0)
        } else {
            (row, column)
        });
        out
    }

    /// Moves the cursor a row down (or up) in the text laid out at `width` cells, to the column nearest the one
    /// it is in without passing it, as editors do; returns false, leaving it where it is, when it is on the last
    /// row (or the first) already.
    pub fn step_row(&mut self, width: usize, down: bool) -> bool {
        let positions = self.positions(width);
        let (row, column) = positions[self.cursor.min(positions.len() - 1)];
        let last = positions.last().map_or(0, |position| position.0);
        let target = match (down, row) {
            (true, row) if row >= last => return false,
            (true, row) => row + 1,
            (false, 0) => return false,
            (false, row) => row - 1,
        };
        let mut best = None;
        for (index, &(at_row, at_column)) in positions.iter().enumerate() {
            if at_row == target && (best.is_none() || at_column <= column) {
                best = Some(index);
            }
        }
        match best {
            Some(index) => {
                self.cursor = index;
                true
            }
            None => false,
        }
    }
}

/// The input laid out for display.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    /// The rows, at least one.
    pub rows: Vec<String>,
    /// The row the cursor is on.
    pub row: usize,
    /// The cursor's column in cells.
    pub column: usize,
}

impl Layout {
    /// The first row to show when only `visible` rows fit: 0 while everything fits, else a window that
    /// ends at the cursor's row, so the line being typed stays in sight.
    pub fn first_shown(&self, visible: usize) -> usize {
        let visible = visible.max(1);
        if self.rows.len() <= visible {
            0
        } else {
            (self.row + 1)
                .saturating_sub(visible)
                .min(self.rows.len() - visible)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn editor(text: &str, cursor: usize) -> Editor {
        let mut editor = Editor::default();
        editor.set(text);
        editor.cursor = cursor;
        editor
    }

    fn after(text: &str, cursor: usize, edit: &Edit) -> (String, usize) {
        let mut editor = editor(text, cursor);
        editor.apply(edit);
        (editor.text(), editor.cursor)
    }

    #[test]
    fn characters_go_in_at_the_cursor_and_come_out_around_it() {
        assert_eq!(after("helo", 3, &Edit::Insert('l')), ("hello".into(), 4));
        assert_eq!(after("hello", 5, &Edit::Backspace), ("hell".into(), 4));
        assert_eq!(after("hello", 0, &Edit::Backspace), ("hello".into(), 0));
        assert_eq!(after("hello", 1, &Edit::Delete), ("hllo".into(), 1));
        assert_eq!(after("hello", 5, &Edit::Delete), ("hello".into(), 5));
        assert_eq!(after("ab", 1, &Edit::Newline), ("a\nb".into(), 2));
        assert_eq!(after("naïve", 3, &Edit::Backspace), ("nave".into(), 2));
    }

    #[test]
    fn the_cursor_moves_by_character_word_and_line() {
        assert_eq!(after("abc", 0, &Edit::Left), ("abc".into(), 0));
        assert_eq!(after("abc", 3, &Edit::Right), ("abc".into(), 3));
        assert_eq!(after("run the tests", 13, &Edit::WordLeft).1, 8);
        assert_eq!(after("run the  tests", 9, &Edit::WordLeft).1, 4);
        assert_eq!(after("run the tests", 0, &Edit::WordRight).1, 3);
        assert_eq!(after("run the tests", 3, &Edit::WordRight).1, 7);
        assert_eq!(after("abc", 2, &Edit::Home).1, 0);
        assert_eq!(after("abc", 0, &Edit::End).1, 3);
    }

    #[test]
    fn words_and_ends_are_deleted_up_to_the_cursor() {
        assert_eq!(
            after("git commit -m msg", 17, &Edit::DeleteWordBefore),
            ("git commit -m ".into(), 14)
        );
        assert_eq!(
            after("git commit -m ", 14, &Edit::DeleteWordBefore),
            ("git commit ".into(), 11)
        );
        assert_eq!(after("abc def", 4, &Edit::KillToStart), ("def".into(), 0));
        assert_eq!(after("abc def", 3, &Edit::KillToEnd), ("abc".into(), 3));
    }

    #[test]
    fn a_word_is_replaced_up_to_the_cursor() {
        let mut ed = editor("/con rest", 4);
        ed.replace(0, "/config ");
        assert_eq!((ed.text(), ed.cursor()), ("/config  rest".into(), 8));
        let mut past = editor("ab", 1);
        past.replace(5, "x");
        assert_eq!((past.text(), past.cursor()), ("axb".into(), 2));
    }

    #[test]
    fn paste_inserts_text_whole_with_line_ends_normalised_and_controls_dropped() {
        assert_eq!(
            after("[]", 1, &Edit::Paste("a\r\nb\rc\td".into())),
            ("[a\nb\ncd]".into(), 7)
        );
        let mut editor = Editor::default();
        editor.set("draft");
        assert_eq!(editor.cursor, 5);
        assert_eq!(editor.take(), "draft");
        assert!(editor.is_empty() && editor.cursor == 0);
    }

    #[test]
    fn text_is_laid_out_in_rows_with_the_cursor_placed() {
        let layout = |text: &str, cursor: usize, width: usize| editor(text, cursor).rows(width);
        let single = layout("hello", 5, 10);
        assert_eq!(
            (single.rows, single.row, single.column),
            (vec!["hello".to_string()], 0, 5)
        );
        let lines = layout("one\ntwo", 7, 10);
        assert_eq!(
            (lines.rows, lines.row, lines.column),
            (vec!["one".into(), "two".into()], 1, 3)
        );
        // A cursor on the newline is at the end of its line.
        let on_newline = layout("one\ntwo", 3, 10);
        assert_eq!((on_newline.row, on_newline.column), (0, 3));
        // Long lines wrap at the width; a cursor at the end of a full row moves to a new one.
        let wrapped = layout("abcdefgh", 8, 4);
        assert_eq!(
            (wrapped.rows, wrapped.row, wrapped.column),
            (vec!["abcd".into(), "efgh".into(), String::new()], 2, 0)
        );
        let mid = layout("abcdefgh", 5, 4);
        assert_eq!((mid.row, mid.column), (1, 1));
        // Wide characters take two cells and wrap whole.
        let wide = layout("a日本", 3, 4);
        assert_eq!(
            (wide.rows, wide.row, wide.column),
            (vec!["a日".into(), "本".into()], 1, 2)
        );
        let empty = layout("", 0, 0);
        assert_eq!(
            (empty.rows, empty.row, empty.column),
            (vec![String::new()], 0, 0)
        );
    }

    #[test]
    fn a_tall_input_shows_the_rows_around_the_cursor() {
        let tall = editor("1\n2\n3\n4\n5\n6\n7\n8", 15).rows(10);
        assert_eq!(tall.rows.len(), 8);
        assert_eq!(tall.first_shown(3), 5);
        let top = editor("1\n2\n3\n4\n5\n6\n7\n8", 0).rows(10);
        assert_eq!(top.first_shown(3), 0);
        let middle = editor("1\n2\n3\n4\n5\n6\n7\n8", 8).rows(10);
        assert_eq!((middle.row, middle.first_shown(3)), (4, 2));
        assert_eq!(editor("short", 5).rows(10).first_shown(3), 0);
    }

    #[test]
    fn up_and_down_move_the_cursor_a_row_keeping_its_column_and_stop_at_the_edges() {
        let step = |text: &str, cursor: usize, width: usize, down: bool| {
            let mut editor = editor(text, cursor);
            let moved = editor.step_row(width, down);
            (moved, editor.cursor)
        };
        // Lines of a message: the same column, or the end of a shorter line.
        assert_eq!(step("abcd\nef\nghij", 3, 10, true), (true, 7));
        assert_eq!(step("abcd\nef\nghij", 7, 10, true), (true, 10));
        assert_eq!(step("abcd\nef\nghij", 10, 10, false), (true, 7));
        assert_eq!(step("abcd\nef\nghij", 6, 10, false), (true, 1));
        // The last row goes no further down, the first no further up.
        assert_eq!(step("abcd\nef", 6, 10, true), (false, 6));
        assert_eq!(step("abcd\nef", 2, 10, false), (false, 2));
        assert_eq!(step("one line", 3, 10, true), (false, 3));
        assert_eq!(step("", 0, 10, true), (false, 0));
        // Rows a long line wraps to count as rows.
        assert_eq!(step("abcdefgh", 1, 4, true), (true, 5));
        assert_eq!(step("abcdefgh", 6, 4, false), (true, 2));
        // A cursor past a full last row is on a row of its own, below it.
        assert_eq!(step("abcd", 4, 4, false), (true, 0));
        assert_eq!(step("abcd", 0, 4, true), (true, 4));
        // Wide characters: the nearest column that does not pass the cursor's.
        assert_eq!(step("日本語\nabcd", 7, 10, false), (true, 1));
        assert_eq!(step("x", 1, 0, true), (false, 1));
    }
}
