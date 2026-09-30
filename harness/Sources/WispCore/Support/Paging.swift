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
}
