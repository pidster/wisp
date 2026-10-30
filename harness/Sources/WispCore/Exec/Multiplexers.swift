/// Programs whose first word is the verb (`git commit`, `cargo build`), listed in
/// `Resources/multiplexers.txt` and embedded at build time. For these the approval pattern includes
/// the verb ([ADR 0027](../../../../docs/decisions/0027-verb-patterns.md)).
public enum Multiplexers {
    /// The program names, from the embedded list.
    public static let programs: Set<String> = parse(MultiplexersText.text)

    /// Parses the list: one name per line, `#` comments and blank lines ignored.
    ///
    /// - Parameter text: The list's text.
    /// - Returns: The program names.
    public static func parse(_ text: String) -> Set<String> {
        Set(
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }
}
