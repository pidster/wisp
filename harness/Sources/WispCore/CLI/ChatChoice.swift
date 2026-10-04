import Foundation

/// A question with a list of answers for a face to offer: a numbered list in the plain chat, a picker in
/// `wisp-tui` ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)). Only chat commands ask;
/// the model never does.
///
/// A choice with toggles (`toggles`) is a table of rows each on or off, under column headings: the person moves
/// through it, turns rows on and off, and saves the lot, and the answer is the values left on
/// (`ChatChoice.values(answer:)`). `/models` asks one in `wisp-tui` (ADR 0056).
public struct ChatChoice: Equatable, Sendable {
    /// One answer.
    public struct Option: Equatable, Sendable {
        /// What choosing it answers.
        public var value: String
        /// What it is called, often the value itself.
        public var label: String
        /// A line about it, or empty.
        public var detail: String
        /// For a choice with toggles: the row's cells, one per column.
        public var cells: [String]
        /// For a choice with toggles: whether the row is on; nil in a plain choice.
        public var on: Bool?

        /// Creates an option.
        public init(value: String, label: String? = nil, detail: String = "", cells: [String] = [], on: Bool? = nil) {
            self.value = value
            self.label = label ?? value
            self.detail = detail
            self.cells = cells
            self.on = on
        }
    }

    /// A column of a choice with toggles.
    public struct Column: Equatable, Sendable {
        /// Its heading.
        public var heading: String
        /// When a narrow face drops it: 0 never, otherwise in rank order, 1 first (`TerminalTable.fitting`).
        public var drop: Int

        /// Creates a column.
        public init(heading: String, drop: Int = 0) {
            self.heading = heading
            self.drop = drop
        }
    }

    /// For a choice with toggles, its columns; empty for a plain choice.
    public var columns: [Column] = []

    /// Whether the rows are toggled on and off and saved together, rather than one picked.
    public var toggles: Bool { options.contains { $0.on != nil } }

    /// The values a choice with toggles was answered with, the rows left on; nil when the answer is not one (no
    /// answer, or a front end that picked a single value instead).
    ///
    /// - Parameter answer: The answer as the face returned it.
    /// - Returns: The values, or nil.
    public static func values(answer: String?) -> [String]? {
        guard let answer, answer.hasPrefix("[") else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(answer.utf8))
    }

    /// The answer a face returns for a choice with toggles: the values left on, as a JSON array.
    ///
    /// - Parameter values: The values.
    /// - Returns: The answer.
    public static func answer(values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The question.
    public var title: String
    /// The answers on offer; empty when only typed text will do.
    public var options: [Option]
    /// The value in force now, marked in the list.
    public var current: String?
    /// Whether a typed value is taken as well as an option.
    public var acceptsText: Bool

    /// Creates a choice.
    public init(
        title: String, options: [Option], current: String? = nil, acceptsText: Bool = false, columns: [Column] = []
    ) {
        self.title = title
        self.options = options
        self.current = current
        self.acceptsText = acceptsText
        self.columns = columns
    }

    /// Reads an answer typed at a numbered list: a number picks that option, other text is taken as
    /// typed when the choice accepts text, and an empty line, a slash command, or anything else is no
    /// answer.
    public func answer(typed line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("/") else { return nil }
        if let number = Int(text), options.indices.contains(number - 1) { return options[number - 1].value }
        if let option = options.first(where: { $0.value == text }) { return option.value }
        return acceptsText ? text : nil
    }

    /// The lines of a numbered list: the title, one line per option with the current one marked, and
    /// what to type.
    public var numbered: [String] {
        let width = String(options.count).count
        var lines = [title]
        for (index, option) in options.enumerated() {
            let number = String(index + 1)
            let mark = option.value == current ? "*" : " "
            let detail = option.detail.isEmpty ? "" : "  \(option.detail)"
            lines.append(
                "\(mark) \(String(repeating: " ", count: width - number.count))\(number)  \(option.label)\(detail)")
        }
        let how =
            options.isEmpty
            ? "type a value, or press Enter to leave it"
            : acceptsText
                ? "type a number or a value, or press Enter to leave it" : "type a number, or press Enter to leave it"
        lines.append(how)
        return lines
    }
}
