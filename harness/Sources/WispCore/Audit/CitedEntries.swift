import Foundation

/// The entries a reply cites in wisp's own reference forms that the conversation's store does not hold
/// ([ADR 0055](../../../../docs/decisions/0055-cited-entries-checked.md)): a check wisp makes after each reply, with no
/// model, as `TurnToolSummary` counts what the turn ran.
///
/// wisp names stored entries by number, as `entry 7`, `memory "recall entry 7"`, `[output of entry 7 not repeated: …]`,
/// and `entries 7-9` in a recalled turn. A model that writes those forms about entries that do not exist makes its
/// report look checked when it is not (session ce87576a, 2026-10-04: "Result (entry 19)" to "(entry 30)" and "All
/// steps logged in entries 16-30" for steps that never ran, in a thread whose store held about 18 entries). The check
/// reads the singular, plural, list, and range forms, expands ranges up to `expansionLimit` numbers in all, and keeps
/// the numbers no stored entry has. Every stored entry was recorded by this turn or an earlier one, so existing is the
/// whole check.
public enum CitedEntries {
    /// The most numbers one reply's citations expand to; a range past it is checked only up to it, and the line says
    /// so.
    public static let expansionLimit = 100
    /// The most groups of missing numbers the line names before it says how many more.
    static let groupLimit = 8

    /// A citation's numbers in `reply`, in order, without repeats, and whether `expansionLimit` cut them short.
    ///
    /// The forms read, in any case: `entry N`, `entry #N`, `entries N-M` (a hyphen, an en dash, or an em dash),
    /// `entry N–M`, and lists such as `entries 19, 20 and 21` or `entries 3, 5-7, or 9`.
    ///
    /// - Parameter reply: The reply's text.
    /// - Returns: The numbers, and whether the expansion was capped.
    public static func cited(in reply: String) -> (numbers: [Int], capped: Bool) {
        let number = #"#?\d{1,9}(?:\s*[-–—]\s*#?\d{1,9})?"#
        let separator = #"(?:\s*,\s*(?:and\s+|or\s+)?|\s+and\s+|\s+or\s+|\s*&\s*)"#
        guard
            let regex = try? NSRegularExpression(
                pattern: #"\b(?:entry|entries)\s+("# + number + "(?:" + separator + number + ")*)",
                options: [.caseInsensitive])
        else { return ([], false) }
        var numbers: [Int] = []
        var seen: Set<Int> = []
        var capped = false
        let text = reply as NSString
        for match in regex.matches(in: reply, range: NSRange(location: 0, length: text.length)) {
            let list = text.substring(with: match.range(at: 1))
            for item in list.matches(of: /#?(\d{1,9})(?:\s*[-–—]\s*#?(\d{1,9}))?/) {
                guard let low = Int(item.1) else { continue }
                let high = item.2.flatMap { Int($0) } ?? low
                for value in min(low, high)...max(low, high) {
                    guard numbers.count < expansionLimit else {
                        capped = true
                        break
                    }
                    if seen.insert(value).inserted { numbers.append(value) }
                }
            }
        }
        return (numbers, capped)
    }

    /// The numbers `reply` cites that no entry of `store` has, in the order cited, and whether the citations were
    /// cut at `expansionLimit`.
    ///
    /// - Parameters:
    ///   - reply: The reply's text.
    ///   - store: The conversation's record, with the turn's own entries stored.
    /// - Returns: The missing numbers, and whether the expansion was capped.
    public static func missing(in reply: String, store: ThreadRecord) -> (numbers: [Int], capped: Bool) {
        let found = cited(in: reply)
        let known = Set(store.entries.map(\.id))
        return (found.numbers.filter { !known.contains($0) }, found.capped)
    }

    /// The muted line beside the reply for `missing`: `cited but not in this conversation: entries 19–30 (12)`,
    /// consecutive numbers as ranges, at most `groupLimit` groups and then how many more; nil when none is missing.
    ///
    /// - Parameters:
    ///   - missing: The numbers no stored entry has.
    ///   - capped: Whether the citations were cut at `expansionLimit`.
    /// - Returns: The line, or nil.
    public static func line(_ missing: [Int], capped: Bool = false) -> String? {
        guard !missing.isEmpty else { return nil }
        var groups: [(Int, Int)] = []
        for value in missing.sorted() {
            if let last = groups.last, value == last.1 + 1 {
                groups[groups.count - 1].1 = value
            } else {
                groups.append((value, value))
            }
        }
        let named = groups.prefix(groupLimit).map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)–\($0.1)" }
        let more = groups.count > groupLimit ? ", +\(groups.count - groupLimit) more" : ""
        let noun = missing.count == 1 ? "entry" : "entries"
        let count = missing.count == 1 ? "" : " (\(missing.count))"
        let cap = capped ? "; only the first \(expansionLimit) cited were checked" : ""
        return "cited but not in this conversation: \(noun) \(named.joined(separator: ", "))\(more)\(count)\(cap)"
    }
}
