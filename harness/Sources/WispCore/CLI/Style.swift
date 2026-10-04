import Foundation

/// Terminal styling for the CLI faces: on when stdout is a terminal and `NO_COLOR` is unset, off when
/// piped, so transcripts, tests, and other programs see plain text. Every method returns the text
/// unchanged when styling is off.
public struct Style: Sendable, Equatable {
    /// Whether escape sequences are emitted.
    public let enabled: Bool

    /// Creates a style.
    public init(enabled: Bool) { self.enabled = enabled }

    /// No styling.
    public static let plain = Style(enabled: false)

    /// Styling on for a terminal unless `NO_COLOR` is set or `TERM` is `dumb` (the `no-color.org` rule).
    public static func detect(
        isTerminal: Bool, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Style {
        Style(enabled: isTerminal && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb")
    }

    private func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// wisp's palette, shared with the `wisp-tui` front end: one ghostly pale blue in tones for what
    /// wisp itself says, amber for attention, ember for danger, white for the conversation.
    public enum Palette {
        /// The brightest tone: the prompt.
        public static let glow = (0xCF, 0xF1, 0xFF)
        /// The main tone: model, status facts, ok states.
        public static let wisp = (0x8F, 0xD3, 0xF4)
        /// The quiet tone: tool lines, notes, separators.
        public static let mist = (0x86, 0xAE, 0xC8)
        /// Attention: approvals, moderate, a nearly full context.
        public static let amber = (0xF2, 0xB9, 0x50)
        /// Danger and errors.
        public static let ember = (0xFF, 0x6B, 0x6B)
        /// Lines added.
        public static let added = (0x7E, 0xD9, 0x8F)
        /// Lines removed.
        public static let removed = (0xFF, 0x6B, 0x6B)
        /// Tokens read.
        public static let tokensIn = (0xF2, 0xE3, 0x9C)
        /// Tokens written: the glow tone.
        public static let tokensOut = glow
        /// A command the person types after `!` (ADR 0049): `wisp-tui`'s input box in command mode, a muted pale
        /// amber, more orange than yellow and apart from `amber`, so a command never looks like a warning; the
        /// plain chat colours its prompt marker with it.
        public static let command = (0xE8, 0xB5, 0x77)
        /// A command's line in `wisp-tui`'s scrollback: `command` at half its brightness, as a sent prompt's
        /// tint is the input box's.
        public static let commandSent = (0x74, 0x5A, 0x3C)
    }

    private func rgb(_ colour: (Int, Int, Int), _ text: String) -> String {
        wrap("38;2;\(colour.0);\(colour.1);\(colour.2)", text)
    }

    /// The prompt: the brightest tone, bold.
    public func prompt(_ text: String) -> String { bold(rgb(Palette.glow, text)) }
    /// Status facts and ok states.
    public func wisp(_ text: String) -> String { rgb(Palette.wisp, text) }
    /// The brightest tone without the prompt's weight: things to look at in the status line.
    public func glow(_ text: String) -> String { rgb(Palette.glow, text) }
    /// Tool lines, notes, separators.
    public func muted(_ text: String) -> String { rgb(Palette.mist, text) }
    /// Attention.
    public func amber(_ text: String) -> String { rgb(Palette.amber, text) }
    /// Danger.
    public func ember(_ text: String) -> String { rgb(Palette.ember, text) }
    /// Lines added, in the status line.
    public func added(_ text: String) -> String { rgb(Palette.added, text) }
    /// Lines removed.
    public func removed(_ text: String) -> String { rgb(Palette.removed, text) }
    /// Tokens read, in the footer.
    public func tokensIn(_ text: String) -> String { rgb(Palette.tokensIn, text) }
    /// Tokens written.
    public func tokensOut(_ text: String) -> String { rgb(Palette.tokensOut, text) }
    /// The prompt marker of a command the person typed after `!`: the command colour, bold.
    public func command(_ text: String) -> String { bold(rgb(Palette.command, text)) }

    /// Bold.
    public func bold(_ text: String) -> String { wrap("1", text) }
    /// Dim, for wisp's own notes and tool activity.
    public func dim(_ text: String) -> String { wrap("2", text) }
    /// Red, for errors and dangerous.
    public func red(_ text: String) -> String { wrap("31", text) }
    /// Green.
    public func green(_ text: String) -> String { wrap("32", text) }
    /// Yellow, for approvals and moderate.
    public func yellow(_ text: String) -> String { wrap("33", text) }
    /// Blue.
    public func blue(_ text: String) -> String { wrap("34", text) }
    /// Magenta.
    public func magenta(_ text: String) -> String { wrap("35", text) }
    /// Cyan, for the prompt.
    public func cyan(_ text: String) -> String { wrap("36", text) }

    /// A risk level in its colour: safe in the main tone, moderate amber, dangerous ember.
    public func level(_ level: RiskLevel) -> String {
        switch level {
        case .safe: wisp(level.rawValue)
        case .moderate: amber(level.rawValue)
        case .dangerous: ember(level.rawValue)
        }
    }

    /// Strips this style's escape sequences from `text`, for tests and width arithmetic.
    public static func stripped(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
    }
}
