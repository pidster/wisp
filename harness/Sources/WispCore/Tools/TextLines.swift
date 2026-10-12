import Foundation

/// A text file's lines as bytes, each with its own ending: how `read_file` numbers lines and `edit_file` edits them,
/// so the two agree on every file. A line ends at a line feed, at a carriage return and line feed, or at a carriage
/// return alone (a classic Mac OS file). The ending is kept apart from the line's text, so an edit rewrites the text
/// and keeps the ending, and every byte outside the edit is written back exactly as it was, invalid UTF-8 included.
///
/// Lines are split on bytes, never on `Character`: Swift reads `"\r\n"` as one grapheme, so a `String` split at
/// `"\n"` finds no line break in a CRLF file, and an edit of its line 1 once replaced the whole file (2026-10-12).
struct TextLines: Equatable {
    /// How a line ends.
    enum Ending: Equatable {
        /// `\n`, the Unix ending.
        case lineFeed
        /// `\r\n`, the Windows ending.
        case carriageReturnLineFeed
        /// `\r` alone, the classic Mac OS ending.
        case carriageReturn
        /// No ending: the text after the last one.
        case none

        /// The ending's bytes.
        var bytes: [UInt8] {
            switch self {
            case .lineFeed: [TextLines.lineFeed]
            case .carriageReturnLineFeed: [TextLines.carriageReturn, TextLines.lineFeed]
            case .carriageReturn: [TextLines.carriageReturn]
            case .none: []
            }
        }
    }

    /// One segment of the file: a line's text and how it ends.
    struct Line: Equatable {
        /// The text, without its ending.
        var text: [UInt8]
        /// The ending.
        var ending: Ending
    }

    /// The line feed byte.
    static let lineFeed: UInt8 = 0x0A
    /// The carriage return byte.
    static let carriageReturn: UInt8 = 0x0D

    /// Every line with its ending, then the text after the last ending, which is empty when the file ends with one
    /// and has the ending `none`. Never empty: a file with `n` line endings has `n + 1` segments.
    var segments: [Line]

    /// Splits `bytes` into segments.
    ///
    /// - Parameter bytes: The file.
    init(_ bytes: [UInt8]) {
        var segments: [Line] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == Self.lineFeed || byte == Self.carriageReturn else {
                index += 1
                continue
            }
            let text = Array(bytes[start..<index])
            if byte == Self.carriageReturn, index + 1 < bytes.count, bytes[index + 1] == Self.lineFeed {
                segments.append(Line(text: text, ending: .carriageReturnLineFeed))
                index += 2
            } else {
                segments.append(Line(text: text, ending: byte == Self.lineFeed ? .lineFeed : .carriageReturn))
                index += 1
            }
            start = index
        }
        segments.append(Line(text: Array(bytes[start...]), ending: .none))
        self.segments = segments
    }

    /// The lines `read_file` numbers: every segment but a final empty one. An empty file has none.
    var count: Int { segments.count - (segments.last?.text.isEmpty == true ? 1 : 0) }

    /// The file's bytes, segment by segment.
    var bytes: [UInt8] { segments.flatMap { $0.text + $0.ending.bytes } }

    /// Line `index` (from 0) as text, decoded as UTF-8 with replacement.
    ///
    /// - Parameter index: The segment.
    /// - Returns: Its text, without the ending.
    func text(_ index: Int) -> String { String(decoding: segments[index].text, as: UTF8.self) }

    /// The ending most lines have, which a line break inserted by an edit takes: ties go to the line feed, then the
    /// carriage return and line feed; a file with no ending at all gets the line feed.
    var dominantEnding: Ending {
        let order: [Ending] = [.lineFeed, .carriageReturnLineFeed, .carriageReturn]
        let counts = order.map { ending in segments.count(where: { $0.ending == ending }) }
        guard let most = counts.max(), most > 0, let index = counts.firstIndex(of: most) else { return .lineFeed }
        return order[index]
    }

    /// `bytes` with every line ending made one line feed, and for each byte of that the offset in `bytes` where it
    /// starts, plus one entry for the end: so a range found in the result maps back onto whole endings, and a match
    /// never splits a carriage return from its line feed.
    ///
    /// - Parameter bytes: The text.
    /// - Returns: The normalised bytes, and their origins (one more than the bytes).
    static func normalised(_ bytes: [UInt8]) -> (bytes: [UInt8], origins: [Int]) {
        var out: [UInt8] = []
        var origins: [Int] = []
        out.reserveCapacity(bytes.count)
        origins.reserveCapacity(bytes.count + 1)
        var index = 0
        while index < bytes.count {
            origins.append(index)
            if bytes[index] == carriageReturn {
                out.append(lineFeed)
                index += index + 1 < bytes.count && bytes[index + 1] == lineFeed ? 2 : 1
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        origins.append(bytes.count)
        return (out, origins)
    }

    /// `bytes` with every line ending, of whatever kind, replaced by `ending`.
    ///
    /// - Parameters:
    ///   - bytes: The text.
    ///   - ending: The ending to use; `none` is taken as the line feed.
    /// - Returns: The converted bytes.
    static func converting(_ bytes: [UInt8], to ending: Ending) -> [UInt8] {
        let replacement = ending == .none ? Ending.lineFeed.bytes : ending.bytes
        return normalised(bytes).bytes.flatMap { $0 == lineFeed ? replacement : [$0] }
    }

    /// The number of line endings in `bytes`, a carriage return and line feed counting once.
    ///
    /// - Parameter bytes: The text.
    /// - Returns: The count.
    static func endings(in bytes: [UInt8]) -> Int { TextLines(bytes).segments.count - 1 }

    /// The non-overlapping places `needle` occurs in `haystack`, first to last.
    ///
    /// - Parameters:
    ///   - needle: The bytes sought; empty is found nowhere.
    ///   - haystack: The bytes searched.
    /// - Returns: The ranges of `haystack` that match.
    static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Range<Int>] {
        guard let first = needle.first, needle.count <= haystack.count else { return [] }
        var found: [Range<Int>] = []
        var index = 0
        while index + needle.count <= haystack.count {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) {
                found.append(index..<index + needle.count)
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    /// `text` split at line feeds, on Unicode scalars rather than `Character`, so a carriage return before a line
    /// feed stays at the end of its line and joining the pieces with `"\n"` gives `text` back. For tool output, whose
    /// lines are counted and cited as they were written (`ToolOutput`, `OutputStore`).
    ///
    /// - Parameter text: The text.
    /// - Returns: The pieces, an empty one after a final line feed.
    static func splitAtLineFeeds(_ text: String) -> [Substring] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) }
    }
}
