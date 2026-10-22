//! Copying to the clipboard through the terminal (ADR 0068, point 5): OSC 52, the sequence that asks the terminal to
//! set its clipboard to base64-encoded text, so a copy works wherever the terminal runs, over ssh as well.

/// The most `wisp-tui` copies at once; terminals bound the sequence, and some drop a longer one whole.
pub const COPY_LIMIT: usize = 1024 * 1024;

/// The OSC 52 sequence that sets the clipboard to `text`.
pub fn osc52(text: &str) -> Vec<u8> {
    format!("\x1b]52;c;{}\x07", base64(text.as_bytes())).into_bytes()
}

/// `text` cut to at most `COPY_LIMIT` bytes at a character's edge, and whether it was cut.
pub fn bounded(text: &str) -> (&str, bool) {
    if text.len() <= COPY_LIMIT {
        return (text, false);
    }
    let mut end = COPY_LIMIT;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (&text[..end], true)
}

/// `bytes` in standard base64, padded.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for (index, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if index <= chunk.len() {
                out.push(char::from(
                    ALPHABET[usize::try_from((n >> shift) & 63).unwrap_or(0)],
                ));
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_the_standard_vectors() {
        for (plain, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(plain.as_bytes()), encoded, "{plain}");
        }
    }

    #[test]
    fn the_sequence_carries_the_text_encoded() {
        assert_eq!(osc52("hi ▸"), b"\x1b]52;c;aGkg4pa4\x07");
    }

    #[test]
    fn a_long_text_is_cut_at_the_limit_on_a_characters_edge() {
        let text = "▸".repeat(COPY_LIMIT);
        let (cut, was) = bounded(&text);
        assert!(was && cut.len() <= COPY_LIMIT && cut.len() > COPY_LIMIT - 3);
        assert_eq!(bounded("short"), ("short", false));
    }
}
