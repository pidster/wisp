//! Posting wisp's notifications through the terminal (ADR 0044): the terminal the front end runs in
//! posts a banner under its own name for an escape sequence, OSC 9 in Ghostty and `WezTerm` and OSC 99
//! in kitty (iTerm2 needs a setting, so it is left to wisp's app route). The front end owns the screen, so only it may write one, and only between frames.

use std::io::{self, Write};

use crate::protocol::Notice;

/// The escape sequence a terminal posts a notification for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sequence {
    /// `ESC ] 9 ; text BEL`: Ghostty, iTerm2, `WezTerm`.
    Osc9,
    /// `ESC ] 99 ; metadata ; text ESC \`: kitty's desktop notifications, title and body in two chunks.
    Osc99,
}

/// The sequence the terminal named by the environment posts, or `None` when it posts neither.
///
/// `TERM_PROGRAM` decides when it is set, so a multiplexer inside a known terminal (`tmux`, which does
/// not pass the sequence through) is not taken for the terminal; otherwise `TERM`. The same table as
/// wisp's own terminal route (`TerminalNotification.sequence` in the harness), except iTerm2: it shows
/// OSC 9 only with "Send escape sequence-generated alerts" turned on, and a write that shows nothing would
/// lose the banner, so the front end does not declare `notify` there and wisp posts through the terminal
/// app instead.
pub fn detect(var: impl Fn(&str) -> Option<String>) -> Option<Sequence> {
    if let Some(program) = var("TERM_PROGRAM").filter(|p| !p.is_empty()) {
        return match program.as_str() {
            "ghostty" | "WezTerm" => Some(Sequence::Osc9),
            "kitty" => Some(Sequence::Osc99),
            _ => None,
        };
    }
    match var("TERM").as_deref() {
        Some("xterm-ghostty" | "wezterm") => Some(Sequence::Osc9),
        Some("xterm-kitty") => Some(Sequence::Osc99),
        _ => None,
    }
}

/// `text` safe inside an escape sequence: every control character (C0, DEL, C1: ESC, BEL, and the
/// 8-bit string terminators among them) becomes a space, and `;`, the sequences' field separator,
/// becomes `,`, so the text can neither end the sequence nor be read as parameters.
pub fn sanitised(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            c if c.is_control() => ' ',
            ';' => ',',
            c => c,
        })
        .collect::<String>()
        .trim()
        .to_string()
}

/// The title with the subtitle after it, as one line.
fn heading(notice: &Notice) -> String {
    let title = sanitised(&notice.title);
    match notice.subtitle.as_deref().map(sanitised) {
        Some(subtitle) if !subtitle.is_empty() && !title.is_empty() => {
            format!("{title} — {subtitle}")
        }
        Some(subtitle) if !subtitle.is_empty() => subtitle,
        _ => title,
    }
}

/// The bytes that post `notice` with `sequence`; `id` names a kitty notification's chunks.
pub fn bytes(sequence: Sequence, notice: &Notice, id: &str) -> Vec<u8> {
    let heading = heading(notice);
    let body = sanitised(&notice.body);
    match sequence {
        Sequence::Osc9 => {
            let text = if heading.is_empty() {
                body
            } else {
                format!("{heading}: {body}")
            };
            format!("\x1b]9;{text}\x07").into_bytes()
        }
        Sequence::Osc99 => {
            let id = sanitised(id).replace([':', '=', ' '], "-");
            format!("\x1b]99;i={id}:d=0:p=title;{heading}\x1b\\\x1b]99;i={id}:p=body;{body}\x1b\\")
                .into_bytes()
        }
    }
}

/// Writes each notice's sequence to `out` and flushes; called between frames, never inside one. `next`
/// numbers kitty's notifications so each has its own id.
pub fn post(
    out: &mut impl Write,
    sequence: Sequence,
    notices: &[Notice],
    next: &mut u64,
) -> io::Result<()> {
    if notices.is_empty() {
        return Ok(());
    }
    for notice in notices {
        *next += 1;
        out.write_all(&bytes(
            sequence,
            notice,
            &format!("wisp{}-{next}", std::process::id()),
        ))?;
    }
    out.flush()
}

#[cfg(test)]
mod tests {
    use super::{Sequence, bytes, detect, post, sanitised};
    use crate::protocol::Notice;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| {
            pairs
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| (*v).to_string())
        }
    }

    fn notice(title: &str, subtitle: Option<&str>, body: &str) -> Notice {
        Notice {
            title: title.into(),
            subtitle: subtitle.map(Into::into),
            body: body.into(),
            sound: false,
        }
    }

    #[test]
    fn the_terminal_is_named_by_term_program_then_term() {
        assert_eq!(
            detect(env(&[("TERM_PROGRAM", "ghostty")])),
            Some(Sequence::Osc9)
        );
        assert_eq!(
            detect(env(&[("TERM_PROGRAM", "iTerm.app")])),
            None,
            "iTerm2 shows OSC 9 only after a setting, so wisp's app route posts instead"
        );
        assert_eq!(
            detect(env(&[("TERM_PROGRAM", "WezTerm")])),
            Some(Sequence::Osc9)
        );
        assert_eq!(
            detect(env(&[("TERM_PROGRAM", "kitty")])),
            Some(Sequence::Osc99)
        );
        assert_eq!(
            detect(env(&[("TERM", "xterm-kitty")])),
            Some(Sequence::Osc99)
        );
        assert_eq!(
            detect(env(&[("TERM", "xterm-ghostty")])),
            Some(Sequence::Osc9)
        );
        // Terminal.app has no sequence; tmux inside kitty is tmux, whatever TERM says.
        assert_eq!(detect(env(&[("TERM_PROGRAM", "Apple_Terminal")])), None);
        assert_eq!(
            detect(env(&[("TERM_PROGRAM", "tmux"), ("TERM", "xterm-kitty")])),
            None
        );
        assert_eq!(detect(env(&[("TERM", "xterm-256color")])), None);
        assert_eq!(detect(env(&[])), None);
    }

    #[test]
    fn osc_9_is_one_sequence_ended_by_bel() {
        assert_eq!(
            bytes(
                Sequence::Osc9,
                &notice("Build", None, "The tests pass."),
                "x"
            ),
            b"\x1b]9;Build: The tests pass.\x07"
        );
        assert_eq!(
            bytes(
                Sequence::Osc9,
                &notice("wisp watch", Some("make test"), "now failing"),
                "x"
            ),
            "\x1b]9;wisp watch — make test: now failing\x07".as_bytes()
        );
    }

    #[test]
    fn osc_99_sends_the_title_then_the_body_under_one_id() {
        assert_eq!(
            bytes(Sequence::Osc99, &notice("Build", None, "done"), "wisp1-1"),
            b"\x1b]99;i=wisp1-1:d=0:p=title;Build\x1b\\\x1b]99;i=wisp1-1:p=body;done\x1b\\"
        );
    }

    #[test]
    fn an_injected_escape_or_bell_never_reaches_the_terminal_raw() {
        let hostile = notice(
            "a\x1b]9;x\x07b",
            Some("\u{9c}c"),
            "d\x1b\\e;f\u{9d}g\x07\x1b[2J",
        );
        // Only the sequences' own ESCs and terminators remain: OSC 9 opens with one ESC and ends with
        // BEL; OSC 99's two chunks each open with ESC and end with ESC \.
        for (sequence, escapes, bells) in [(Sequence::Osc9, 1, 1), (Sequence::Osc99, 4, 0)] {
            let text = String::from_utf8_lossy(&bytes(sequence, &hostile, "i;d")).into_owned();
            assert_eq!(text.matches('\x1b').count(), escapes, "{text:?}");
            assert_eq!(text.matches('\x07').count(), bells, "{text:?}");
            assert!(!text.contains('\u{9c}') && !text.contains('\u{9d}'));
        }
        assert_eq!(sanitised(" a;b\tc\u{7f} "), "a,b c");
        let osc9 = String::from_utf8_lossy(&bytes(Sequence::Osc9, &hostile, "x")).into_owned();
        assert_eq!(osc9, "\x1b]9;a ]9,x b — c: d \\e,f g  [2J\x07");
    }

    #[test]
    fn post_writes_every_notice_and_flushes_and_nothing_for_none() -> std::io::Result<()> {
        let mut out = Vec::new();
        let mut next = 0;
        post(&mut out, Sequence::Osc9, &[], &mut next)?;
        assert!(out.is_empty());
        post(
            &mut out,
            Sequence::Osc9,
            &[notice("a", None, "1"), notice("b", None, "2")],
            &mut next,
        )?;
        assert_eq!(out, b"\x1b]9;a: 1\x07\x1b]9;b: 2\x07");
        assert_eq!(next, 2);
        let mut kitty = Vec::new();
        post(
            &mut kitty,
            Sequence::Osc99,
            &[notice("t", None, "b")],
            &mut next,
        )?;
        let text = String::from_utf8_lossy(&kitty);
        assert!(
            text.contains(&format!("i=wisp{}-3:", std::process::id())),
            "{text}"
        );
        Ok(())
    }
}
