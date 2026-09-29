//! wisp's colours: one ghostly pale blue in four tones for everything wisp itself says, an amber
//! accent for things that want attention, an ember accent for danger and errors, and white for the
//! conversation. True colour; the same values live in the Swift chat's `Style`.

use ratatui::style::{Color, Modifier, Style};

/// The brightest tone: the prompt and things to look at.
pub const GLOW: Color = Color::Rgb(0xCF, 0xF1, 0xFF);
/// The main tone: model, status facts, ok states.
pub const WISP: Color = Color::Rgb(0x8F, 0xD3, 0xF4);
/// The quiet tone: tool lines, notes, separators.
pub const MIST: Color = Color::Rgb(0x86, 0xAE, 0xC8);
/// The deep tone: the input row's background.
pub const DEEP: Color = Color::Rgb(0x25, 0x3B, 0x4E);
/// The input's tint halfway to black: the background of a line you sent, in the scrollback.
pub const SENT: Color = Color::Rgb(0x12, 0x1D, 0x27);
/// Attention: approvals, moderate, a nearly full context.
pub const AMBER: Color = Color::Rgb(0xF2, 0xB9, 0x50);
/// Danger and errors.
pub const EMBER: Color = Color::Rgb(0xFF, 0x6B, 0x6B);
/// The conversation.
pub const WHITE: Color = Color::Rgb(0xE6, 0xED, 0xF0);
/// Lines added, in the status line.
pub const ADDED: Color = Color::Rgb(0x7E, 0xD9, 0x8F);
/// Lines removed.
pub const REMOVED: Color = Color::Rgb(0xFF, 0x6B, 0x6B);
/// Tokens read.
pub const TOKENS_IN: Color = Color::Rgb(0xF2, 0xE3, 0x9C);
/// Tokens written: the glow tone.
pub const TOKENS_OUT: Color = GLOW;

/// The user's own words.
pub fn user() -> Style {
    Style::default().fg(WHITE).add_modifier(Modifier::BOLD)
}
/// The model's replies and command output.
pub fn body() -> Style {
    Style::default().fg(WHITE)
}
/// Tool lines, notes, separators.
pub fn muted() -> Style {
    Style::default().fg(MIST)
}
/// The prompt.
pub fn prompt() -> Style {
    Style::default().fg(GLOW).add_modifier(Modifier::BOLD)
}
/// The brightest tone without the prompt's weight: things to look at in the status line.
pub fn glow() -> Style {
    Style::default().fg(GLOW)
}
/// Status facts and ok states.
pub fn wisp() -> Style {
    Style::default().fg(WISP)
}
/// A reply's `**strong**` text.
pub fn strong() -> Style {
    body().add_modifier(Modifier::BOLD)
}
/// A reply's `*emphasis*`.
pub fn emphasis() -> Style {
    body().add_modifier(Modifier::ITALIC)
}
/// A reply's headings.
pub fn heading() -> Style {
    Style::default().fg(GLOW).add_modifier(Modifier::BOLD)
}
/// Code in a reply, inline or in a fenced block.
pub fn code() -> Style {
    Style::default().fg(WISP)
}
/// Attention.
pub fn amber() -> Style {
    Style::default().fg(AMBER)
}
/// Danger.
pub fn ember() -> Style {
    Style::default().fg(EMBER)
}
/// Lines added.
pub fn added() -> Style {
    Style::default().fg(ADDED)
}
/// Lines removed.
pub fn removed() -> Style {
    Style::default().fg(REMOVED)
}
/// Tokens read.
pub fn tokens_in() -> Style {
    Style::default().fg(TOKENS_IN)
}
/// Tokens written.
pub fn tokens_out() -> Style {
    Style::default().fg(TOKENS_OUT)
}
/// The input row's background.
pub fn input_background() -> Style {
    Style::default().bg(DEEP)
}
/// The half-block strips above and below the input: the tint as a foreground on the plain background.
pub fn input_edge() -> Style {
    Style::default().fg(DEEP)
}
/// A sent line's background in the scrollback.
pub fn sent_background() -> Style {
    Style::default().bg(SENT)
}
/// The half-block strips above and below a sent line.
pub fn sent_edge() -> Style {
    Style::default().fg(SENT)
}
/// A risk level in its colour.
pub fn level(level: &str) -> Style {
    match level {
        "dangerous" => ember(),
        "moderate" => amber(),
        _ => wisp(),
    }
}
