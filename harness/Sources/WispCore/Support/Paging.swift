import Foundation

/// Splits a long text into pages at line boundaries, for views that must stay bounded (a resource read,
/// a front end's panel).
public enum Paging {
    /// The page size views use: 16 KiB.
    public static let pageBytes = 16 * 1024

    /// Page `number` (from 1) of `text`, and how many pages there are. A line longer than a page is cut
    /// at a character boundary. Nil for a page out of range.
    ///
    /// - Parameters:
    ///   - text: The whole text.
    ///   - number: The page, from 1.
    ///   - size: The most bytes a page holds.
    /// - Returns: The page and the page count, or nil.
    public static func page(_ text: String, number: Int, size: Int = pageBytes) -> (text: String, count: Int)? {
        var pages: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var piece = String(line)
            while piece.utf8.count > size {
                var end = piece.utf8.index(piece.utf8.startIndex, offsetBy: size)
                while !piece.indices.contains(end) { end = piece.utf8.index(before: end) }
                if !current.isEmpty { pages.append(current) }
                pages.append(String(piece[..<end]))
                current = ""
                piece = String(piece[end...])
            }
            let added = current.isEmpty ? piece : current + "\n" + piece
            if added.utf8.count > size, !current.isEmpty {
                pages.append(current)
                current = piece
            } else {
                current = added
            }
        }
        pages.append(current)
        guard number >= 1, number <= pages.count else { return nil }
        return (pages[number - 1], pages.count)
    }

    /// Page `number` (from 1) of `total` bytes read through `read`, and how many pages there are, without reading
    /// the rest: for an output too large to hold whole for each page (a stored output of up to 16 MiB, ADR 0050).
    /// Page `k` ends just after the first newline at or past byte `k × size` within the next `size` bytes, or, with
    /// none there, at the first character boundary from `k × size`; so each page is found from two reads of at most
    /// `size` bytes, pages run in order without gap or overlap, joining them gives the bytes back exactly, and a
    /// page holds whole lines unless a line is longer than a page. A page holds at most twice `size` bytes, and one
    /// may be empty. Nil for a page out of range; empty data is one empty page.
    ///
    /// - Parameters:
    ///   - number: The page, from 1.
    ///   - size: The page size in bytes, at least 1.
    ///   - total: The bytes in all.
    ///   - read: Reads a range of the bytes.
    /// - Returns: The page's bytes and the page count, or nil.
    public static func bytePage(
        number: Int, size: Int, total: Int, read: (Range<Int>) -> Data
    ) -> (
        data: Data, count: Int
    )? {
        guard size > 0, total >= 0 else { return nil }
        let count = max(1, (total + size - 1) / size)
        guard number >= 1, number <= count else { return nil }
        /// Where page `k + 1` starts.
        func boundary(_ k: Int) -> Int {
            guard k > 0 else { return 0 }
            guard k < count else { return total }
            let start = k * size
            let window = read(start..<min(total, start + size))
            if let newline = window.firstIndex(of: 0x0A) {
                return start + window.distance(from: window.startIndex, to: newline) + 1
            }
            // A UTF-8 continuation byte is never a character's start.
            return start + window.prefix { $0 & 0xC0 == 0x80 }.count
        }
        let from = boundary(number - 1)
        let to = max(from, boundary(number))
        return (to > from ? read(from..<to) : Data(), count)
    }
}
