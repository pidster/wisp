import Testing

@testable import WispCore

/// The names wisp turns into file names and URI segments: thread ids, session ids, saved transcripts.
@Suite struct SafeNameTests {
    @Test func theNamesInUseStayValid() {
        for name in [
            "git", "git2", "triage-a1b2c3d4", "my_chat.v2", "-", "0", String(repeating: "a", count: 64),
            "6f1e2d3c-0b9a-4c8d-9e7f-1a2b3c4d5e6f",
        ] {
            #expect(SafeName.isValid(name), "\(name)")
        }
    }

    @Test func onlyASCIILettersDigitsAndDotUnderscoreHyphenAreAllowed() {
        // Letters and digits of other scripts, fullwidth forms, and combining marks look like ASCII ones in a path or
        // a URI, so the rule's [A-Za-z0-9._-] is ASCII.
        for name in [
            "", "café", "cafe\u{301}", "٣", "ｇｉｔ", "git push", "a/b", "..\u{2215}x", String(repeating: "a", count: 65),
            "x\u{200D}",
        ] {
            #expect(!SafeName.isValid(name), "\(name)")
        }
    }
}
